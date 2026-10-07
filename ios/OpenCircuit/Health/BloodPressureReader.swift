// Blood pressure from Apple Health (bm-ring fork).
//
// The ring does not measure blood pressure, and the vendor app's "BP trends" are
// PPG-model ESTIMATES — not measurements. This reader does the honest thing instead:
// it reads REAL cuff readings the user (or their Bluetooth cuff: Omron, Withings…)
// saved into Apple Health, and trends those. No data is invented; when there are no
// cuff readings, the card says so instead of showing a modelled number.

import Foundation
import HealthKit

/// One cuff reading: systolic/diastolic in mmHg.
struct BloodPressureReading: Equatable, Identifiable {
    var id: Date { date }
    var date: Date
    var systolic: Double
    var diastolic: Double
    var sourceName: String

    /// AHA-ish band for the systolic number, for color only — not a diagnosis.
    var band: String {
        switch systolic {
        case ..<120 where diastolic < 80: return "Normal"
        case ..<130 where diastolic < 80: return "Elevated"
        case ..<140, _ where diastolic < 90: return "High (1)"
        default: return "High (2)"
        }
    }
}

@MainActor
enum BloodPressureReader {
    private static var store = HKHealthStore()

    /// Readings from the last `days` days, newest first. Pairs systolic+diastolic
    /// samples that share a timestamp (cuffs write both at once).
    static func recent(days: Int = 30, limit: Int = 60) async -> [BloodPressureReading] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let sysType = HKQuantityType(.bloodPressureSystolic)
        let diaType = HKQuantityType(.bloodPressureDiastolic)
        let end = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: end) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let mmHg = HKUnit.millimeterOfMercury()

        let sys = await fetch(sysType, predicate: predicate)
        let dia = await fetch(diaType, predicate: predicate)
        // Pair systolic+diastolic written together. Cuffs write both at once, but
        // timestamps can differ by seconds (or the two writes straddle a minute
        // boundary), so match within a ±2 min window instead of exact-minute buckets.
        // Each diastolic sample is used once (nearest wins).
        var usedDia = Set<Int>()
        var out: [BloodPressureReading] = []
        for s in sys {
            var best: (idx: Int, dist: Double)?
            for (j, d) in dia.enumerated() where !usedDia.contains(j) {
                let dist = abs(d.startDate.timeIntervalSince(s.startDate))
                guard dist <= 120 else { continue }
                if best == nil || dist < best!.dist { best = (j, dist) }
            }
            guard let match = best else { continue }
            usedDia.insert(match.idx)
            let d = dia[match.idx]
            out.append(BloodPressureReading(date: s.startDate,
                                            systolic: s.quantity.doubleValue(for: mmHg),
                                            diastolic: d.quantity.doubleValue(for: mmHg),
                                            sourceName: s.sourceRevision.source.name))
            if out.count >= limit { break }
        }
        return out
    }

    private static func fetch(_ type: HKQuantityType,
                              predicate: NSPredicate) async -> [HKQuantitySample] {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: false)]) { _, result, _ in
                cont.resume(returning: (result as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
    }
}
