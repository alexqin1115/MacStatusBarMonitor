import Foundation
import Darwin

/// Reads memory pressure from `host_statistics64` (`HOST_VM_INFO64`).
/// "Used" follows Activity Monitor's definition: app memory
/// (internal minus purgeable) + wired + compressed.
final class MemoryProvider {
    func sample() -> MemoryStats? {
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        var vmStats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }

        let total = ProcessInfo.processInfo.physicalMemory
        let appPages = max(0, Int64(vmStats.internal_page_count) - Int64(vmStats.purgeable_count))
        let usedPages = appPages + Int64(vmStats.wire_count) + Int64(vmStats.compressor_page_count)
        let used = min(UInt64(max(0, usedPages)) * UInt64(pageSize), total)
        func bytes(_ pages: Int64) -> UInt64 { UInt64(max(0, pages)) * UInt64(pageSize) }
        var stats = MemoryStats(total: total, used: used, free: total - used)
        stats.app = bytes(appPages)
        stats.wired = bytes(Int64(vmStats.wire_count))
        stats.compressed = bytes(Int64(vmStats.compressor_page_count))
        stats.cached = bytes(Int64(vmStats.external_page_count) + Int64(vmStats.purgeable_count))
        stats.swapUsed = Self.swapUsed()
        stats.pressureLevel = Self.pressureLevel()
        return stats
    }

    private static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    private static func pressureLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }
}
