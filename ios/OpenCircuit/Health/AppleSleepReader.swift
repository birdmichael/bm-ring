// Apple Sleep as source of truth (bm-ring fork).
//
// The ring never transmits a hypnogram — any staging from ring data is inference.
// Apple Health, on the other hand, holds REAL staged sleep when the wearer uses an
// Apple Watch (or iPhone sleep tracking): asleepCore / asleepDeep / asleepREM /
// asleepAwake, written by Apple's own algorithms from wrist sensors.
//
// This reader prefers Apple's data when it exists and says so plainly in the UI.
// No score is invented here: what Apple measured is shown, what it didn't measure
// is not shown. Falls back to nothing (not to the ring estimate) — the ring's own
// estimate already has its own card.

import Foundation
import HealthKit

/// One night of Apple-measured sleep.
struct AppleSleepNight: Equatable {
    /// Local calendar day the night belongs to (the morning you woke up).
    var morning: Date
    var asleepMinutes: Int
    var coreMinutes: Int
    var deepMinutes: Int
    var remMinutes: Int
    var unspecifiedMinutes: Int  // older watchOS / iPhone: asleep without stage
    var awakeMinutes: Int
    var inBedMinutes: Int
    /// e.g. "Apple Watch" — whose samples these are.
    var sourceName: String

    var hasStages: Bool { coreMinutes + deepMinutes + remMinutes > 0 }
}

@MainActor
enum AppleSleepReader {
    private static var store = HKHealthStore()

    /// The most recent night with Apple sleep data, looking back `days` days.
    /// Returns nil when Apple Health holds no sleep (no Watch, no sleep schedule).
    static func lastNight(days: Int = 3) async -> AppleSleepNight? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let type = HKCategoryType(.sleepAnalysis)
        let end = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: end) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)]) { _, result, _ in
                cont.resume(returning: (result as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        guard !samples.isEmpty else { return nil }
        // Group samples into nights by the morning they end on (local calendar).
        let cal = Calendar.current
        var nights: [Date: [HKCategorySample]] = [:]
        for s in samples {
            let morning = cal.startOfDay(for: s.endDate)
            nights[morning, default: []].append(s)
        }
        guard let latestMorning = nights.keys.max(),
              let night = nights[latestMorning], !night.isEmpty else { return nil }
        return summarize(night, morning: latestMorning)
    }

    private static func summarize(_ samples: [HKCategorySample], morning: Date) -> AppleSleepNight {
        var core = 0, deep = 0, rem = 0, unspecified = 0, awake = 0, inBed = 0
        // Prefer the Apple Watch source when several writers exist.
        let watchSamples = samples.filter { $0.sourceRevision.source.name.localizedCaseInsensitiveContains("watch") }
        let use = watchSamples.isEmpty ? samples : watchSamples
        let sourceName = use.first?.sourceRevision.source.name ?? "Apple Health"
        for s in use {
            let mins = Int(s.endDate.timeIntervalSince(s.startDate) / 60)
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { continue }
            switch v {
            case .asleepCore: core += mins
            case .asleepDeep: deep += mins
            case .asleepREM: rem += mins
            case .asleepUnspecified: unspecified += mins
            case .awake: awake += mins
            case .inBed: inBed += mins
            case .asleep: unspecified += mins  // legacy
            @unknown default: break
            }
        }
        return AppleSleepNight(morning: morning,
                               asleepMinutes: core + deep + rem + unspecified,
                               coreMinutes: core, deepMinutes: deep, remMinutes: rem,
                               unspecifiedMinutes: unspecified, awakeMinutes: awake,
                               inBedMinutes: inBed, sourceName: sourceName)
    }
}
