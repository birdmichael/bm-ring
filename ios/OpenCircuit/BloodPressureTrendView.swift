import SwiftUI

/// Blood-pressure trend card (bm-ring fork). REAL cuff readings from Apple Health only —
/// never modelled. Hidden content replaced by an honest empty state when the user has
/// no cuff data.
struct BloodPressureTrendView: View {
    @State private var readings: [BloodPressureReading]?
    @State private var loaded = false

    var body: some View {
        Group {
            if let readings {
                if readings.isEmpty {
                    emptyState
                } else {
                    content(readings)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            readings = await BloodPressureReader.recent()
        }
        .navigationTitle("Blood Pressure")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.text.square").font(.largeTitle).foregroundStyle(.secondary)
            Text("No cuff readings in Apple Health")
                .font(.headline)
            Text("This card shows measurements from a real blood-pressure cuff " +
                 "(or manual entries in the Health app) — never estimates. " +
                 "Pair a Bluetooth cuff or log a reading in Health to see trends here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func content(_ readings: [BloodPressureReading]) -> some View {
        List {
            Section {
                ForEach(readings.prefix(14)) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(Int(r.systolic))/\(Int(r.diastolic))")
                                .font(.headline.monospacedDigit())
                            Text(r.band).font(.caption2).foregroundStyle(bandColor(r))
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(r.date, style: .date).font(.caption)
                            Text(r.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Recent readings (mmHg)")
            } footer: {
                Text("From \(readings.first?.sourceName ?? "Apple Health"). Bands are rough " +
                     "reference ranges, not a diagnosis — talk to a clinician about what yours mean.")
            }
            if let avg = average(readings.prefix(14)) {
                Section("14-reading average") {
                    HStack {
                        Text("\(Int(avg.sys))/\(Int(avg.dia)) mmHg")
                            .font(.title3.weight(.semibold)).monospacedDigit()
                        Spacer()
                        Text(trendWord(readings)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func average(_ rs: ArraySlice<BloodPressureReading>) -> (sys: Double, dia: Double)? {
        guard !rs.isEmpty else { return nil }
        return (rs.map(\.systolic).reduce(0, +) / Double(rs.count),
                rs.map(\.diastolic).reduce(0, +) / Double(rs.count))
    }

    /// Crude trend: compare the newest 3 vs the oldest 3 of the shown window.
    private func trendWord(_ readings: [BloodPressureReading]) -> String {
        let w = Array(readings.prefix(14))
        guard w.count >= 6 else { return "Not enough data for trend" }
        let newAvg = w.prefix(3).map(\.systolic).reduce(0, +) / 3
        let oldAvg = w.suffix(3).map(\.systolic).reduce(0, +) / 3
        let d = newAvg - oldAvg
        if d < -3 { return "Trending down" }
        if d > 3 { return "Trending up" }
        return "Holding steady"
    }

    private func bandColor(_ r: BloodPressureReading) -> Color {
        switch r.band {
        case "Normal": return .green
        case "Elevated": return .yellow
        default: return .orange
        }
    }
}
