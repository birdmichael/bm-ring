import CoreLocation
import SwiftUI

/// Sync keepalive settings (bm-ring fork).
///
/// iOS decides when background work runs; this screen layers every battery-cheap
/// wake source so at least one of them fires often: silent-push pings from your
/// own relay server, significant-change location wakes (the Tesla trick at 1% of
/// the battery cost), plus the app's existing BGTask / Bluetooth-restoration wakes.
/// Nothing here runs continuously — that's the whole point.
struct KeepaliveSettingsView: View {
    @State private var locWakeEnabled = LocationWakeSync.shared.isEnabled
    @State private var authStatus = LocationWakeSync.shared.authorizationStatus
    @State private var lastWake = LocationWakeSync.shared.lastWake
    @State private var wakeCount = LocationWakeSync.shared.wakeCount

    var body: some View {
        List {
            pushSection
            locationSection
            statusSection
        }
        .navigationTitle("Sync keepalive")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Ensure the singleton exists so its init can (re)start monitoring.
            _ = LocationWakeSync.shared
            refresh()
        }
    }

    private func refresh() {
        let s = LocationWakeSync.shared
        locWakeEnabled = s.isEnabled
        authStatus = s.authorizationStatus
        lastWake = s.lastWake
        wakeCount = s.wakeCount
    }

    // MARK: - Push pings

    private var pushSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your relay server can send a silent push with ") +
                Text("{\"sync\": true}").font(.caption.monospaced()) +
                Text(" — the app wakes and runs a short sync, no buzz.")
                    .font(.callout)
                Text("Example cron (every 30 min):")
                    .font(.caption).foregroundStyle(.secondary)
                Text("*/30 * * * * curl -s -X POST localhost:8902/buzz -d '{\"sync\":true}'")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Push-triggered sync")
        } footer: {
            Text("Best-effort like all silent pushes; Apple throttles abuse. " +
                 "A few pings per hour is fine — a per-minute heartbeat is not. " +
                 "Full relay setup: docs/PUSH_VIBRATION.md.")
        }
    }

    // MARK: - Location wakes

    private var locationSection: some View {
        Section {
            Toggle(isOn: $locWakeEnabled) {
                Label("Sync on movement", systemImage: "location.fill")
            }
            .onChange(of: locWakeEnabled) { _, newValue in
                let s = LocationWakeSync.shared
                if newValue {
                    if s.authorizationStatus == .authorizedAlways {
                        s.isEnabled = true
                    } else {
                        s.requestAuthorization()
                        // Stay visually off until Always is actually granted; the
                        // delegate flips us on via locationManagerDidChangeAuthorization.
                        locWakeEnabled = false
                    }
                } else {
                    s.isEnabled = false
                }
                refresh()
            }
            if authStatus != .authorizedAlways && locWakeEnabled == false {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Needs \"Always\" location access — iOS only delivers " +
                         "significant-change wakes to Always-authorized apps.")
                        .font(.caption)
                }
            }
        } header: {
            Text("Movement-triggered sync")
        } footer: {
            Text("The Tesla trick, diet version: Tesla keeps its app alive with CONTINUOUS " +
                 "location (real battery cost). This uses SIGNIFICANT-CHANGE monitoring — " +
                 "iOS wakes the app only on cell-tower handovers (~500 m+). Zero cost while " +
                 "still; one short BLE drain per move, throttled to every 30 min. " +
                 "We never read your actual position (3 km accuracy requested).")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("Location wakes")
                Spacer()
                Text("\(wakeCount)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Last wake")
                Spacer()
                Text(lastWake.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Location permission")
                Spacer()
                Text(authLabel).foregroundStyle(.secondary)
            }
        }
    }

    private var authLabel: String {
        switch authStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using (insufficient)"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not asked"
        @unknown default: return "Unknown"
        }
    }
}
