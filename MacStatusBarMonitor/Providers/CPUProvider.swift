import Foundation
import Darwin

/// Reads total CPU usage from the kernel's aggregate tick counters
/// (`host_statistics` / `HOST_CPU_LOAD_INFO`), plus a per-core breakdown
/// (`host_processor_info`) split into efficiency vs performance clusters.
/// Usage is the delta between two samples, so the very first call takes a
/// short extra sample internally. All public APIs.
final class CPUProvider {
    private var previousLoad: host_cpu_load_info?
    private var previousCoreTicks: [[UInt32]]?
    /// Last valid reading. Returned when the kernel counters haven't ticked
    /// since the previous sample (0 ticks elapsed), instead of reporting nil.
    private var lastStats: CPUStats?

    /// Apple Silicon enumerates efficiency cores first; the split point comes
    /// from sysctl (hw.perflevel1 = efficiency). 0 on Intel → no split shown.
    private static let eCoreCount: Int = {
        var value = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel1.logicalcpu", &value, &size, nil, 0)
        return max(0, value)
    }()

    func sample() -> CPUStats? {
        guard let current = readLoad() else { return nil }

        if let previous = previousLoad {
            var stats = usage(from: previous, to: current)
            guard stats != nil else {
                // No new ticks since the last sample (refreshes can outpace the
                // counters). Keep the old baseline so the next delta is real,
                // and keep showing the last good value rather than a blank.
                return lastStats
            }
            previousLoad = current
            applyClusterSplit(to: &stats)
            applyLoadAverage(to: &stats)
            lastStats = stats
            return stats
        }

        // First sample ever: take a short second reading so we can return a
        // real value immediately. Only runs once, on a background thread.
        usleep(400_000)
        guard let second = readLoad() else {
            previousLoad = current
            return nil
        }
        previousLoad = second
        var stats = usage(from: current, to: second)
        applyClusterSplit(to: &stats)
        applyLoadAverage(to: &stats)
        lastStats = stats
        return stats
    }

    // MARK: - E/P cluster split (per-core ticks)

    private func applyClusterSplit(to stats: inout CPUStats?) {
        guard stats != nil, Self.eCoreCount > 0,
              let cores = readCoreTicks() else { return }
        defer { previousCoreTicks = cores }
        guard let previous = previousCoreTicks, previous.count == cores.count else { return }

        var perCore: [Double] = []
        for index in 0..<cores.count {
            let user = Double(cores[index][0] &- previous[index][0])
            let system = Double(cores[index][1] &- previous[index][1])
            let idle = Double(cores[index][2] &- previous[index][2])
            let nice = Double(cores[index][3] &- previous[index][3])
            let total = user + system + idle + nice
            perCore.append(total > 0 ? min(max((user + system + nice) / total, 0), 1) : 0)
        }
        stats?.coreUsages = perCore
        stats?.eCoreCount = min(Self.eCoreCount, cores.count)

        func busyFraction(range: Range<Int>) -> Double? {
            var busy = 0.0, total = 0.0
            for index in range where index < cores.count {
                // tick order: user, system, idle, nice
                let user = Double(cores[index][0] &- previous[index][0])
                let system = Double(cores[index][1] &- previous[index][1])
                let idle = Double(cores[index][2] &- previous[index][2])
                let nice = Double(cores[index][3] &- previous[index][3])
                busy += user + system + nice
                total += user + system + nice + idle
            }
            guard total > 0 else { return nil }
            return min(max(busy / total, 0), 1)
        }

        let eCount = min(Self.eCoreCount, cores.count)
        stats?.eCoreUsage = busyFraction(range: 0..<eCount)
        stats?.pCoreUsage = busyFraction(range: eCount..<cores.count)
    }

    private func readCoreTicks() -> [[UInt32]]? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var cores: [[UInt32]] = []
        cores.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            var ticks: [UInt32] = []
            for state in 0..<states {
                ticks.append(UInt32(bitPattern: info[core * states + state]))
            }
            cores.append(ticks)
        }
        return cores
    }

    private func applyLoadAverage(to stats: inout CPUStats?) {
        guard stats != nil else { return }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            stats?.loadAverage = loads
        }
    }

    private func usage(from start: host_cpu_load_info, to end: host_cpu_load_info) -> CPUStats? {
        let user = Double(end.cpu_ticks.0 &- start.cpu_ticks.0)
        let system = Double(end.cpu_ticks.1 &- start.cpu_ticks.1)
        let idle = Double(end.cpu_ticks.2 &- start.cpu_ticks.2)
        let nice = Double(end.cpu_ticks.3 &- start.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return CPUStats(
            usage: min(max(busy / total, 0), 1),
            coreCount: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    private func readLoad() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}
