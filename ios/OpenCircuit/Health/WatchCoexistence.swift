// Apple Watch coexistence — per-interval exclusion (bm-ring fork).
//
// ══ THE PROBLEM ══
//
// Wearing a Watch and the ring together means two writers for steps, active
// energy, and sleep. Apple Health itself blends overlapping sources per TIME
// INTERVAL by source priority (verified by users: Watch wins where it has data,
// the other source fills the gaps). But third-party apps often naively SUM raw
// samples — and then you get double steps.
//
// ══ WHAT THIS DOES ══
//
// The same blending, at the WRITE side: before writing the ring's steps / active
// energy / sleep for an interval, check whether the Watch already wrote that
// type for that interval. Covered → skip (the data is already there). Gap →
// write (e.g. Watch on the charger 6 PM–10 PM: the ring's evening steps land,
// nothing is lost, nothing doubles).
//
// This is deliberately NOT a 24-hour window or a paired/not-paired check:
//   • Watch paired but on charger all day → no Watch data → ring writes everything.
//   • Watch worn 9–18, off in the evening → ring writes only the evening.
//   • No Watch at all → every check returns false → identical to old behavior.
//
// Skipped samples are watermarked as handled (not retried): the interval is
// already covered in HealthKit by the Watch, so retrying would only create the
// duplicates this exists to prevent.
//
// Honest limits:
//   • "Watch" is detected by source productType ("Watch7,4") or name — a renamed
//     source containing "watch" still matches; a non-Watch device named
//     "watch" would false-positive (nobody does this).
//   • One extra HealthKit query per flush for the pending range — cheap.
//   • If the user DELETES Watch data later, the ring won't backfill the gap
//     (watermark already passed). Deleting Health data and expecting a third-
//     party app to notice is outside what any sync does.

import Foundation
import HealthKit
import OpenCircuitKit

/// Which conflicting kinds defer to the Watch when it has interval coverage.
enum WatchCoexistence {
    /// The kinds this applies to. Sampled metrics (HR, HRV, SpO2, …) are never
    /// excluded — more samples only help, and nothing sums them.
    static let deferredKinds: Set<MetricKind> = [.steps, .activeEnergy, .sleep]

    private enum Key {
        static let enabled = "watchcoexist.enabled"
    }

    /// Master switch. Default ON — when there's no Watch it changes nothing,
    /// so there's no reason to default off.
    static var isEnabled: Bool {
        get {
            // Default true: distinguish "never set" from "explicitly off".
            if UserDefaults.standard.object(forKey: Key.enabled) == nil { return true }
            return UserDefaults.standard.bool(forKey: Key.enabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    private static var store = HKHealthStore()

    /// True if any Apple Watch source wrote `type` overlapping [start, end].
    static func watchCovered(type: HKSampleType, start: Date, end: Date) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKSample] = await withCheckedContinuation { cont in
            // Limit 1: we only need existence, not the data.
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1,
                                  sortDescriptors: nil) { _, result, _ in
                cont.resume(returning: result ?? [])
            }
            store.execute(q)
        }
        return samples.contains { isWatchSource($0.sourceRevision.source) }
    }

    /// Filter ring samples: drop those whose interval the Watch already covered.
    /// Returns (kept, skipped) — the caller watermarks BOTH as handled.
    static func filter(_ samples: [QuantitySample], kind: MetricKind,
                       hkType: HKSampleType) async -> (kept: [QuantitySample], skipped: [QuantitySample]) {
        guard isEnabled, deferredKinds.contains(kind), !samples.isEmpty else {
            return (samples, [])
        }
        // One range query for the whole batch's span, then per-sample membership
        // against the Watch-covered sub-intervals. Samples are short (minutes),
        // so per-sample checks are a handful of cheap queries; batch the range
        // first to avoid a query per sample when there's no Watch at all.
        let starts = samples.map(\.start)
        let ends = samples.map(\.end)
        guard let rangeStart = starts.min(), let rangeEnd = ends.max() else {
            return (samples, [])
        }
        let covered = await watchIntervals(type: hkType, start: rangeStart, end: rangeEnd)
        guard !covered.isEmpty else { return (samples, []) }  // no Watch → old behavior
        var kept: [QuantitySample] = []
        var skipped: [QuantitySample] = []
        for s in samples {
            // Covered if the sample's midpoint falls inside a Watch interval.
            // Midpoint (not overlap) so a 5-min ring sample straddling a Watch
            // boundary isn't dropped for 1 min of overlap.
            let mid = s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2)
            if covered.contains(where: { $0.contains(mid) }) {
                skipped.append(s)
            } else {
                kept.append(s)
            }
        }
        return (kept, skipped)
    }

    /// Watch-covered intervals for `type` in [start, end], merged.
    static func watchIntervals(type: HKSampleType, start: Date, end: Date) async -> [DateInterval] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKSample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, result, _ in
                cont.resume(returning: result ?? [])
            }
            store.execute(q)
        }
        let intervals = samples
            .filter { isWatchSource($0.sourceRevision.source) }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }
        // Merge overlapping/adjacent.
        var merged: [DateInterval] = []
        for iv in intervals {
            if let last = merged.last, last.end >= iv.start {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, iv.end))
            } else {
                merged.append(iv)
            }
        }
        return merged
    }

    /// Sleep-night check: did the Watch write any sleep overlapping the night?
    static func watchCoveredNight(start: Date, end: Date) async -> Bool {
        guard isEnabled else { return false }
        return await watchCovered(type: HKCategoryType(.sleepAnalysis), start: start, end: end)
    }

    private static func isWatchSource(_ source: HKSource) -> Bool {
        let product = source.sourceRevision.productType ?? ""
        if product.hasPrefix("Watch") { return true }
        return source.name.localizedCaseInsensitiveContains("watch")
    }
}
