import Foundation
import IOKit

// =============================================================================
// GPU stats via the graphics accelerator's IORegistry entry.
//
// Same access class as the rest of this project's sensor code: read-only
// public IOKit calls (IOServiceGetMatchingService / IORegistryEntryCreate-
// CFProperty). The PROPERTY CONTENTS are vendor-specific and undocumented —
// "PerformanceStatistics"/"Device Utilization %" is the same source iStat-
// style tools use — so everything fails soft to nil and the UI shows
// "Unavailable" rather than fake numbers.
// =============================================================================

struct GPUStats {
    /// Device utilization 0...1, when the accelerator publishes it.
    var usage: Double?
    /// Physical GPU core count, when published (Apple Silicon does).
    var coreCount: Int?
    /// Maximum GPU clock in GHz (static spec from the P-state table).
    var maxClockGHz: Double?
    /// Average GPU clock over the last interval (IOReport residencies).
    /// 0 = fully idle. nil = unavailable.
    var currentClockGHz: Double?
    /// Average GPU power over the last interval, in watts.
    var powerWatts: Double?
    /// Unified memory currently claimed by the GPU, in bytes.
    var memoryUsedBytes: UInt64?
    /// Renderer / tiler pipeline utilization, 0...1.
    var rendererUtilization: Double?
    var tilerUtilization: Double?
}

final class GPUProvider {
    /// Core count never changes — read once.
    private lazy var cachedCoreCount: Int? = readCoreCount()

    func sample() -> GPUStats {
        var stats = GPUStats(coreCount: cachedCoreCount)
        // One PerformanceStatistics read per refresh (microseconds) feeds
        // utilization, GPU memory, and the renderer/tiler split together.
        if let statistics = readPerformanceStatistics() {
            stats.usage = percent(statistics, keys: ["Device Utilization %", "GPU Activity(%)"])
            stats.rendererUtilization = percent(statistics, keys: ["Renderer Utilization %"])
            stats.tilerUtilization = percent(statistics, keys: ["Tiler Utilization %"])
            if let bytes = statistics["In use system memory"] as? Int, bytes >= 0 {
                stats.memoryUsedBytes = UInt64(bytes)
            }
        }
        return stats
    }

    // MARK: - IORegistry reads

    private func readPerformanceStatistics() -> [String: Any]? {
        guard let service = copyAcceleratorService() else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
    }

    private func percent(_ statistics: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = statistics[key] as? Int, (0...100).contains(value) {
                return Double(value) / 100.0
            }
            if let value = statistics[key] as? Double, (0...100).contains(value) {
                return value / 100.0
            }
        }
        return nil
    }

    private func readCoreCount() -> Int? {
        guard let service = copyAcceleratorService() else { return nil }
        defer { IOObjectRelease(service) }

        guard let count = IORegistryEntryCreateCFProperty(
            service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Int, count > 0, count < 512 else {
            return nil
        }
        return count
    }

    /// The Apple Silicon accelerator (AGXAccelerator…) is a subclass of
    /// IOAccelerator, so one matching call covers current and older Macs.
    private func copyAcceleratorService() -> io_service_t? {
        for className in ["IOAccelerator", "AGXAccelerator"] {
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault, IOServiceMatching(className)
            )
            if service != IO_OBJECT_NULL { return service }
        }
        return nil
    }
}
