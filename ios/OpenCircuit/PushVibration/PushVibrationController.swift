// Push-to-Vibrate — buzz the Gen 3 ring when OUR OWN server sends us a push.
//
// ══ WHY THIS EXISTS ══
//
// iOS gives third-party apps no access to SYSTEM notifications, so the Android
// trick (NotificationListenerService → buzz on any notification) is impossible
// here. What IS possible: this app receiving pushes addressed TO ITSELF. Run the
// tiny personal relay in push-server/ (or any webhook → APNs bridge you like),
// send a push for whatever event you care about — server alerts, Home Assistant,
// cron jobs, email filters — and the app buzzes the ring on arrival. Your
// events, your server, your rules. No RingConn account, no third-party cloud.
//
// Delivery notes (honest):
//  • Silent pushes are best-effort. iOS throttles apps that abuse them; keep it
//    to events that matter, not a per-minute heartbeat.
//  • A woken app gets ~30 s. Enough to reconnect BLE and fire the command if the
//    ring is nearby and bonded; not enough to wait for a ring across the house.
//  • The motor has no delivery receipt (`8b 00 8b` = frame accepted, not felt).
//    Outcomes are recorded as accepted/blocked/missed, never "felt".
//
// Payload contract (JSON):
//   { "aps": { "content-available": 1 },
//     "buzz": { "pattern": "notification" | "long", "count": 1...5 } }
// `buzz` is optional — absent means "use the user's configured default".

import Foundation
import OpenCircuitKit
import os
import UIKit

/// Outcome of the last push-triggered buzz, for the settings screen.
enum PushBuzzOutcome: String, Codable {
    case ok
    case blockedNotEnabled
    case blockedNoRing      // no saved/known ring to connect to
    case blockedLinkDown    // reconnect attempted, ring never became ready
    case blockedBusy        // ring was syncing/measuring
    case blockedCharger     // ring on charger — buzzing an empty case is a lie
    case blockedUnsupported // connected device has no motor (not a Gen 3)

    var displayName: String {
        switch self {
        case .ok: return "Buzzed"
        case .blockedNotEnabled: return "Feature off"
        case .blockedNoRing: return "No ring paired"
        case .blockedLinkDown: return "Ring unreachable"
        case .blockedBusy: return "Ring busy"
        case .blockedCharger: return "Ring on charger"
        case .blockedUnsupported: return "No vibration motor"
        }
    }
}

@MainActor
final class PushVibrationController {
    static let shared = PushVibrationController()

    private let log = Logger(subsystem: "com.standardsoftwaresolutions.opencircuit",
                             category: "pushvibe")
    private let defaults: UserDefaults

    enum Key {
        static let enabled = "pushvibe.enabled"
        static let pattern = "pushvibe.pattern"           // VibrationPattern rawValue
        static let count = "pushvibe.count"               // 1...5
        static let deviceToken = "pushvibe.deviceToken"   // hex string
        static let lastPushAt = "pushvibe.lastPushAt"     // Date timeIntervalSince1970
        static let lastOutcome = "pushvibe.lastOutcome"   // PushBuzzOutcome rawValue
        static let totalBuzzes = "pushvibe.totalBuzzes"
    }

    /// How long (s) a background push waits for the BLE link before giving up.
    /// Well inside the ~30 s silent-push budget, leaving margin for the vibrate write.
    static let linkWaitBudget: TimeInterval = 20
    static let maxCount = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Settings (UserDefaults; tiny struct, no migration risk — same
    // rationale as RingAlarmController: not worth a SwiftData schema)

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var pattern: VibrationPattern {
        get {
            let raw = defaults.integer(forKey: Key.pattern)
            return VibrationPattern(rawValue: UInt8(clamping: raw)) ?? .notification
        }
        set { defaults.set(Int(newValue.rawValue), forKey: Key.pattern) }
    }

    var count: Int {
        get { min(max(defaults.integer(forKey: Key.count), 1), Self.maxCount) }
        set { defaults.set(min(max(newValue, 1), Self.maxCount), forKey: Key.count) }
    }

    var deviceTokenHex: String? {
        defaults.string(forKey: Key.deviceToken)
    }

    var lastOutcome: PushBuzzOutcome? {
        guard let raw = defaults.string(forKey: Key.lastOutcome) else { return nil }
        return PushBuzzOutcome(rawValue: raw)
    }

    var lastPushAt: Date? {
        let t = defaults.double(forKey: Key.lastPushAt)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var totalBuzzes: Int { defaults.integer(forKey: Key.totalBuzzes) }

    // MARK: - APNs registration (called from AppDelegate)

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(hex, forKey: Key.deviceToken)
        log.info("APNs device token registered (\(hex.prefix(8))…)")
        NotificationCenter.default.post(name: .pushVibrationTokenUpdated, object: nil)
    }

    func didFailToRegister(error: Error) {
        log.error("APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Push handling (MainActor; AppDelegate hops via Task)

    /// Returns true if the push was ours (had a `buzz` key or feature on).
    /// Callers use this for the fetchCompletionHandler result.
    /// Must be called on the MainActor (AppDelegate hops there).
    func handlePush(userInfo: [AnyHashable: Any]) -> Bool {
        processPush(userInfo: userInfo)
        return true
    }

    private func processPush(userInfo: [AnyHashable: Any]) {
        recordPush()
        guard isEnabled else { return record(.blockedNotEnabled) }

        // Per-push override, else the user's configured default.
        var pattern = self.pattern
        var count = self.count
        if let buzz = userInfo["buzz"] as? [String: Any] {
            if let name = buzz["pattern"] as? String {
                if name == "long" { pattern = .long }
                else if name == "notification" { pattern = .notification }
            }
            if let c = buzz["count"] as? Int {
                count = min(max(c, 1), Self.maxCount)
            }
        }

        let scanner = RingScanner.shared
        if let session = scanner.session, session.ready {
            buzz(session: session, pattern: pattern, count: count)
            return
        }
        // Not connected — one reconnect attempt, then poll briefly for readiness.
        log.info("push buzz: no live session, attempting reconnect")
        guard scanner.reconnectKnownPeripheral() else {
            return record(.blockedNoRing)
        }
        let deadline = Date().addingTimeInterval(Self.linkWaitBudget)
        Task {
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if let session = RingScanner.shared.session, session.ready {
                    self.buzz(session: session, pattern: pattern, count: count)
                    return
                }
            }
            self.record(.blockedLinkDown)
            self.log.warning("push buzz: ring never became ready within budget")
        }
    }

    private func buzz(session: RingSession, pattern: VibrationPattern, count: Int) {
        // 1.2 s spacing keeps multi-buzz patterns distinguishable on the wrist.
        let ok = session.vibrateBurst(pattern, count: count, spacing: 1.2)
        if ok {
            defaults.set(totalBuzzes + 1, forKey: Key.totalBuzzes)
            record(.ok)
            log.info("push buzz: fired \(count)x \(String(describing: pattern))")
        } else {
            // vibrateBurst returns false when the ring refused; map the block reason.
            let outcome: PushBuzzOutcome
            switch session.lastVibrationBlock {
            case .ringUnsupported: outcome = .blockedUnsupported
            case .ringOnCharger: outcome = .blockedCharger
            case .ringBusy: outcome = .blockedBusy
            default: outcome = .blockedLinkDown
            }
            record(outcome)
            log.warning("push buzz blocked: \(String(describing: session.lastVibrationBlock))")
        }
    }

    private func recordPush() {
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastPushAt)
    }

    private func record(_ outcome: PushBuzzOutcome) {
        defaults.set(outcome.rawValue, forKey: Key.lastOutcome)
        NotificationCenter.default.post(name: .pushVibrationOutcomeUpdated, object: nil)
    }
}

extension Notification.Name {
    static let pushVibrationTokenUpdated = Notification.Name("pushvibe.tokenUpdated")
    static let pushVibrationOutcomeUpdated = Notification.Name("pushvibe.outcomeUpdated")
}
