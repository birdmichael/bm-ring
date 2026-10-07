import SwiftUI

/// Apple-measured sleep row for the sleep detail section (bm-ring fork).
///
/// Shows last night as Apple Health recorded it (Apple Watch staging when present),
/// tagged with its source. This is MEASURED sleep, not the ring's inference — when
/// both exist, this row is the one to trust for stages. Hidden when Apple Health
/// holds no sleep at all.
struct AppleSleepRow: View {
    @State private var night: AppleSleepNight?
    @State private var loaded = false

    var body: some View {
        Group {
            if let night {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "applewatch").font(.caption2).foregroundStyle(.blue)
                        Text("Apple sleep").font(.caption2).foregroundStyle(.secondary)
                        Text(formatDuration(night.asleepMinutes)).font(.caption.weight(.semibold)).monospacedDigit()
                        Text("· \(night.sourceName)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if night.hasStages {
                        HStack(spacing: 10) {
                            stageChip("Deep", night.deepMinutes, .indigo)
                            stageChip("Core", night.coreMinutes, .blue)
                            stageChip("REM", night.remMinutes, .teal)
                            if night.awakeMinutes > 0 {
                                stageChip("Awake", night.awakeMinutes, .orange)
                            }
                        }
                        .font(.caption2)
                    } else if night.unspecifiedMinutes > 0 {
                        Text("Unstaged \(formatDuration(night.unspecifiedMinutes)) — no Watch staging for this night.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            night = await AppleSleepReader.lastNight()
        }
    }

    private func stageChip(_ label: String, _ mins: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(formatDuration(mins))")
        }
        .foregroundStyle(.secondary)
    }

    private func formatDuration(_ mins: Int) -> String {
        "\(mins / 60)h \(mins % 60)m"
    }
}
