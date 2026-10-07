import SwiftUI
import UIKit
import OpenCircuitKit

/// Push-to-Vibrate settings — buzz the Gen 3 ring when OUR OWN server sends a push.
///
/// Reached from `DeviceInfoView`, next to "Vibration & alarm". The motor command is
/// Gen-3-only (`RingVibration.isSupported`), so like its neighbour this screen hides
/// itself on other models rather than offering a button that does nothing.
///
/// The copy is blunt about the one thing users will otherwise assume: a push does not
/// guarantee a buzz. iOS throttles silent pushes, the app gets ~30 s of background
/// runtime, and the ring must be in range. What IS guaranteed: nothing leaves your
/// control — the relay server is yours, the push is yours, the token never leaves
/// the phone except to the server address you configure.
struct PushVibrationSettingsView: View {
    private var controller: PushVibrationController { .shared }

    @State private var isEnabled = PushVibrationController.shared.isEnabled
    @State private var pattern = PushVibrationController.shared.pattern
    @State private var count = PushVibrationController.shared.count
    @State private var token = PushVibrationController.shared.deviceTokenHex
    @State private var lastOutcome = PushVibrationController.shared.lastOutcome
    @State private var lastPushAt = PushVibrationController.shared.lastPushAt
    @State private var totalBuzzes = PushVibrationController.shared.totalBuzzes
    @State private var testResult: String?

    var body: some View {
        List {
            enableSection
            patternSection
            statusSection
            setupSection
            testSection
        }
        .navigationTitle("Push vibrations")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .pushVibrationTokenUpdated)) { _ in
            token = controller.deviceTokenHex
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushVibrationOutcomeUpdated)) { _ in
            lastOutcome = controller.lastOutcome
            lastPushAt = controller.lastPushAt
            totalBuzzes = controller.totalBuzzes
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Label("Buzz on push", systemImage: "bell.and.waves.left.and.right")
            }
            .onChange(of: isEnabled) { _, newValue in controller.isEnabled = newValue }
        } footer: {
            Text("When your own push relay (see Setup below) sends this phone a push, "
                + "the ring buzzes. iOS can't give apps access to system notifications, "
                + "so this is the way in: you decide what sends a push — server alerts, "
                + "Home Assistant, cron jobs — and each one becomes a buzz. Best-effort: "
                + "iOS throttles silent pushes, and the ring must be nearby and charged.")
        }
    }

    // MARK: - Pattern

    private var patternSection: some View {
        Section {
            Picker("Pattern", selection: $pattern) {
                ForEach(VibrationPattern.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .onChange(of: pattern) { _, newValue in controller.pattern = newValue }
            Stepper("Buzzes per push: \(count)", value: $count, in: 1...PushVibrationController.maxCount)
                .onChange(of: count) { _, newValue in controller.count = newValue }
        } header: {
            Text("Default buzz")
        } footer: {
            Text("A single push can carry its own pattern and count to override this default — "
                + "see push-server/README.md. Useful for severity levels: one triple-pulse for "
                + "info, five long buzzes for the server being on fire.")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack {
                Text("Device token")
                Spacer()
                if let token {
                    Text("\(token.prefix(12))…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not registered")
                        .foregroundStyle(.secondary)
                }
            }
            if let token {
                Button {
                    UIPasteboard.general.string = token
                } label: {
                    Label("Copy full token", systemImage: "doc.on.doc")
                }
            }
            HStack {
                Text("Last push")
                Spacer()
                Text(lastPushAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Last outcome")
                Spacer()
                Text(lastOutcome?.displayName ?? "—")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Total buzzes")
                Spacer()
                Text("\(totalBuzzes)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("The token identifies this phone to YOUR relay server. Paste it into the "
                + "server's config — never into anyone else's. If you reinstall the app, "
                + "the token changes; update the server config to match.")
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Get an Apple Developer membership (APNs requires it).")
                Text("2. Create a push key (.p8) in the developer portal.")
                Text("3. Run push-server/ on any always-on machine.")
                Text("4. Send it webhooks — it turns each one into a buzz.")
            }
            .font(.callout)
        } header: {
            Text("Setup")
        } footer: {
            Text("Full walkthrough with commands: docs/PUSH_VIBRATION.md in the repo. "
                + "No RingConn account involved at any step.")
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Button {
                let session = RingScanner.shared.session
                if let session, session.ready {
                    let ok = session.vibrateBurst(pattern, count: count, spacing: 1.2)
                    testResult = ok ? "Buzz sent — check your finger." : "Blocked: \(session.lastVibrationBlock.map(String.init(describing:)) ?? "unknown")"
                } else {
                    testResult = "Ring not connected."
                }
            } label: {
                Label("Test buzz now", systemImage: "hand.tap")
            }
            if let testResult {
                Text(testResult)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Tests the motor path directly, without involving a push — if this works "
                + "but pushes don't, the problem is on the relay-server side.")
        }
    }
}
