import Foundation
import IOKit

/// Static device facts. Everything here is read once and cached — never on
/// the 2-second refresh path.
enum DeviceInfoProvider {

    /// Max P-core CPU clock in GHz, and max GPU clock in GHz, read once from
    /// the device tree's P-state tables (`pmgr` → `voltage-statesN-sram`).
    /// These are static hardware ceilings — macOS doesn't expose the *live*
    /// per-core frequency to apps without admin/powermetrics, so we surface
    /// the max rather than fake a fluctuating number. nil if unreadable.
    /// Ordered DVFS frequency tables in GHz, one entry per performance state
    /// (index-aligned with the IOReport residency states ClockProvider reads).
    static let eCoreClocksGHz: [Double] = pStateTable(keys: ["voltage-states1-sram", "voltage-states1"])
    static let pCoreClocksGHz: [Double] = pStateTable(keys: ["voltage-states5-sram", "voltage-states5"])
    static let gpuClocksGHz: [Double] = pStateTable(keys: ["voltage-states9-sram", "voltage-states9"])

    static let cpuMaxClockGHz: Double? = {
        let best = (pCoreClocksGHz + eCoreClocksGHz).max() ?? 0
        return (1.0...4.2).contains(best) ? best : nil
    }()

    static let gpuMaxClockGHz: Double? = {
        let best = gpuClocksGHz.max() ?? 0
        return (0.3...2.0).contains(best) ? best : nil
    }()

    /// Reads a P-state table (array of little-endian UInt32 [freq_Hz,
    /// voltage] pairs) preserving order — index alignment with the IOReport
    /// state list matters more than filtering, so entries pass through as-is.
    private static func pStateTable(keys: [String]) -> [Double] {
        let pmgr = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr")
        guard pmgr != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(pmgr) }

        for key in keys {
            guard let data = IORegistryEntryCreateCFProperty(
                pmgr, key as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Data, data.count >= 8 else {
                continue
            }
            let freqs = data.withUnsafeBytes { raw -> [Double] in
                let u32 = raw.bindMemory(to: UInt32.self)
                var result: [Double] = []
                var i = 0
                while i + 1 < u32.count { // pairs: frequency, voltage
                    result.append(Double(UInt32(littleEndian: u32[i])) / 1_000_000_000.0)
                    i += 2
                }
                return result
            }
            if freqs.contains(where: { $0 > 0.1 }) {
                // Some tables (GPU) lead with a 0 Hz "off" entry that has no
                // corresponding IOReport state — drop it so state N maps to
                // the Nth real frequency.
                return Array(freqs.drop(while: { $0 < 0.05 }))
            }
        }
        return []
    }

    /// Marketing chip name, e.g. "M2 Pro" (from "Apple M2 Pro").
    /// nil when it can't be read; Intel brand strings pass through shortened.
    static let chipName: String? = {
        guard let brand = sysctlString("machdep.cpu.brand_string"), !brand.isEmpty else {
            return nil
        }
        if brand.hasPrefix("Apple ") {
            let name = String(brand.dropFirst("Apple ".count)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Apple Silicon" : name
        }
        // Intel: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz" -> "Core i7-9750H"
        let cleaned = brand
            .replacingOccurrences(of: "(R)", with: "")
            .replacingOccurrences(of: "(TM)", with: "")
        if let model = cleaned.split(separator: "@").first {
            let words = model.split(separator: " ").filter { $0 != "Intel" && $0 != "CPU" }
            let short = words.prefix(3).joined(separator: " ")
            return short.isEmpty ? brand : short
        }
        return brand
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
