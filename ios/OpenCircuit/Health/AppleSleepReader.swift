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
        // Prefer the latest NIGHT (≥3 h asleep) over a recent nap: a 2 PM nap
        // ending today must not outrank last night's real sleep.
        let nightlike = nights.filter { asleepMinutes(in: $0.value) >= 180 }
        let pool = nightlike.isEmpty ? nights : nightlike
        guard let latestMorning = pool.keys.max(),
              let night = pool[latestMorning], !night.isEmpty else { return nil }
        return summarize(night, morning: latestMorning)
    }

    /// Total asleep seconds in a sample group (for night-vs-nap classification).
    private static func asleepMinutes(in samples: [HKCategorySample]) -> Int {
        var total: TimeInterval = 0
        for s in samples {
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { continue }
            switch v {
            case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified, .asleep:
                total += s.endDate.timeIntervalSince(s.startDate)
            case .awake, .inBed:
                break
            @unknown default:
                break
            }
        }
        return Int(total / 60)
    }

    private static func summarize(_ samples: [HKCategorySample], morning: Date) -> AppleSleepNight {
        // Prefer the Apple Watch source when several writers exist.
        let watchSamples = samples.filter { isWatchRevision($0.sourceRevision) }
        let use = watchSamples.isEmpty ? samples : watchSamples
        let sourceName = use.first?.sourceRevision.source.name ?? "Apple Health"
        // Sum seconds first, divide once — per-sample Int truncation would leak
        // several minutes per night.
        var core: TimeInterval = 0, deep: TimeInterval = 0, rem: TimeInterval = 0
        var unspecified: TimeInterval = 0, awake: TimeInterval = 0, inBed: TimeInterval = 0
        for s in use {
            let dur = s.endDate.timeIntervalSince(s.startDate)
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { continue }
            switch v {
            case .asleepCore: core += dur
            case .asleepDeep: deep += dur
            case .asleepREM: rem += dur
            case .asleepUnspecified: unspecified += dur
            case .awake: awake += dur
            case .inBed: inBed += dur
            case .asleep: unspecified += dur  // legacy
            @unknown default: break
            }
        }
        let m = { (t: TimeInterval) in Int(t / 60) }
        let asleep = m(core) + m(deep) + m(rem) + m(unspecified)
        return AppleSleepNight(morning: morning,
                               asleepMinutes: asleep,
                               coreMinutes: m(core), deepMinutes: m(deep), remMinutes: m(rem),
                               unspecifiedMinutes: m(unspecified), awakeMinutes: m(awake),
                               inBedMinutes: m(inBed), sourceName: sourceName)
    }

    private static func isWatchRevision(_ revision: HKSourceRevision) -> Bool {
        // Same rule as WatchCoexistence — keep them in sync. productType
        // ("Watch7,4") lives on the revision, not on HKSource.
        if let product = revision.productType, product.hasPrefix("Watch") { return true }
        return revision.source.name.localizedCaseInsensitiveContains("watch")
    }
}
