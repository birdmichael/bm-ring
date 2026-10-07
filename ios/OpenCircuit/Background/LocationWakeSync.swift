// Battery-friendly keepalive via significant location change (bm-ring fork).
//
// ══ THE TESLA COMPARISON, HONESTLY ══
//
// Tesla's phone key keeps its app alive with CONTINUOUS background location —
// the app basically never sleeps, so BLE to the car is instant. It works, and
// Tesla owners pay for it in battery (it's a known drain complaint).
//
// This is the same idea at 1% of the cost: SIGNIFICANT-CHANGE location monitoring.
// iOS wakes the app only when the phone changes cell towers (~500 m+ movement).
// Cost when still: zero — no GPS, no polling, the cell radio was on anyway. Cost
// per wake: one short BLE drain (~20 s radio). You move → the app wakes → it grabs
// whatever the ring banked since last time. At night you don't move, but you also
// don't need daytime-fresh data at 3 AM — the morning foreground open covers it.
//
// This does NOT replace the existing wakes (BGTask, BT state restoration, push);
// it layers on top. Every wake runs the same cheap "sync if due" check.
//
// Requires "Always" location permission — significant-change monitoring is an
// Always-only API. That's a sensitive ask, so this is OPT-IN and off by default,
// with the permission rationale stated plainly in the settings screen.

import CoreLocation
import Foundation
import os

@MainActor
final class LocationWakeSync: NSObject {
    static let shared = LocationWakeSync()

    private let log = Logger(subsystem: "com.standardsoftwaresolutions.opencircuit",
                             category: "locwake")
    private let defaults: UserDefaults
    private let manager = CLLocationManager()

    enum Key {
        static let enabled = "keepalive.locwake.enabled"
        static let lastWake = "keepalive.locwake.lastWake"
        static let wakeCount = "keepalive.locwake.wakeCount"
    }

    /// Minimum gap between location-triggered syncs. Significant-change fires on
    /// every tower handover in a moving car — without this, a commute would spam
    /// BLE drains. 30 min keeps it to a handful of syncs per day of movement.
    static let minInterval: TimeInterval = 30 * 60

    override init() {
        self.defaults = .standard
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers  // we don't care WHERE
        if isEnabled { start() }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set {
            defaults.set(newValue, forKey: Key.enabled)
            newValue ? start() : stop()
        }
    }

    var lastWake: Date? {
        let t = defaults.double(forKey: Key.lastWake)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var wakeCount: Int { defaults.integer(forKey: Key.wakeCount) }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// Call when the user flips the toggle on. Requests Always (required for
    /// significant-change); if the user picks "While Using", we say so and stay off.
    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    private func start() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            log.warning("significant-change monitoring unavailable on this device")
            return
        }
        manager.startMonitoringSignificantLocationChanges()
        log.info("significant-change monitoring started")
    }

    private func stop() {
        manager.stopMonitoringSignificantLocationChanges()
        log.info("significant-change monitoring stopped")
    }

    private func handleWake() {
        let now = Date()
        if let last = lastWake, now.timeIntervalSince(last) < Self.minInterval {
            log.debug("location wake throttled (last \(now.timeIntervalSince(last), format: .number)s ago)")
            return
        }
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastWake)
        defaults.set(wakeCount + 1, forKey: Key.wakeCount)
        log.info("location wake → opportunistic sync")
        Task {
            do {
                let store = try OpenCircuitApp.backgroundStore()
                let service = RingBackgroundSyncService(store: store, health: HealthKitWriter())
                _ = try await service.syncVitals(timeout: 20, allowLivePoll: false)
            } catch {
                self.log.warning("location-wake sync failed: \(error.localizedDescription)")
            }
        }
    }
}

extension LocationWakeSync: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        handleWake()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.warning("location manager error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // User granted Always after the fact — (re)start if they had enabled us.
        if isEnabled, manager.authorizationStatus == .authorizedAlways {
            start()
        }
    }
}
