// Cost experiment A: StatsStore alone (timer + providers, no UI).
import SwiftUI

@main
@MainActor
struct CostHeadless {
    static func main() {
        let store = StatsStore()
        _ = store
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 30))
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        print(String(format: "headless: %.2f cpu-seconds over 30s wall (%.1f%%)", cpu, cpu / 30 * 100))
    }
}
