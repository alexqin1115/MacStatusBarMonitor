import Foundation
import IOKit

// =============================================================================
// V2 SENSOR SUPPORT — see the header comment in SMC.swift for the limitation
// notes. Everything in this file is optional: if the SMC is unreachable or a
// sensor doesn't exist on this machine, the corresponding value stays nil and
// the UI shows "Unavailable". V1 never depends on anything here.
// =============================================================================

/// Reads CPU/GPU/battery temperatures and fan speeds.
///
/// Sensor keys differ between Intel and every Apple Silicon generation, so
/// instead of hardcoding one chip's key list we enumerate all SMC keys once
/// and keep those that look like the sensors we want (by prefix + data type +
/// a plausibility check on the value). Battery temperature additionally has a
/// public-ish path through the AppleSmartBattery IORegistry entry, which is
/// tried first.
final class HardwareSensorProvider {
    private let smc = SMCClient()
    private var discovery: Discovery?

    private struct Discovery {
        var cpuKeys: [String]
        var gpuKeys: [String]
        var batteryKeys: [String]
        var fanCount: Int
    }

    func sample() -> SensorStats {
        var stats = SensorStats.unavailable
        stats.thermalPressure = Self.thermalPressureRank()
        stats.batteryTemperature = batteryTemperatureFromIORegistry()

        guard let smc else { return stats }
        stats.smcAvailable = true

        let discovery = self.discovery ?? discover(using: smc)
        self.discovery = discovery

        stats.cpuTemperature = hottestTemperature(of: discovery.cpuKeys, using: smc)
        stats.gpuTemperature = hottestTemperature(of: discovery.gpuKeys, using: smc)
        if stats.batteryTemperature == nil {
            stats.batteryTemperature = averageTemperature(of: discovery.batteryKeys, using: smc)
        }
        stats.fanSpeeds = (0..<discovery.fanCount).compactMap { index in
            smc.readDouble(key: "F\(index)Ac").flatMap { rpm in
                (0..<20_000).contains(Int(rpm)) ? rpm : nil
            }
        }
        return stats
    }

    // MARK: - Discovery

    private func discover(using smc: SMCClient) -> Discovery {
        var cpuKeys: [String] = []
        var gpuKeys: [String] = []
        var batteryKeys: [String] = []

        // Discovery filters by key pattern and decodability ONLY. Value
        // plausibility is enforced at every read instead — a sensor that
        // reads parked-junk at launch (e.g. GPU asleep) must not be excluded
        // for the lifetime of the process.
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard smc.readDouble(key: key) != nil else { continue } // undecodable type
            let prefix = String(key.prefix(2))
            switch prefix {
            case "Tp", "Tc", "TC": // Apple Silicon CPU cores / Intel CPU proximity+die
                cpuKeys.append(key)
            case "Tg", "TG": // GPU
                gpuKeys.append(key)
            case "TB": // battery (TB0T, TB1T, ...)
                if key.hasSuffix("T") { batteryKeys.append(key) }
            default:
                break
            }
        }

        let fanCount = Int(smc.readDouble(key: "FNum") ?? 0)
        return Discovery(
            cpuKeys: cpuKeys,
            gpuKeys: gpuKeys,
            batteryKeys: batteryKeys,
            fanCount: min(max(fanCount, 0), 8)
        )
    }

    /// Hottest sensor — the number users expect for "CPU temperature".
    /// (Read-time range filters below reject parked-sensor junk values;
    /// a powered die can't be colder than ~15°C.)
    private func hottestTemperature(of keys: [String], using smc: SMCClient) -> Double? {
        keys.compactMap { smc.readDouble(key: $0) }
            .filter { $0 > 15 && $0 < 120 }
            .max()
    }

    private func averageTemperature(of keys: [String], using smc: SMCClient) -> Double? {
        let values = keys.compactMap { smc.readDouble(key: $0) }.filter { $0 > 5 && $0 < 70 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// System thermal pressure — fully public API. This is the OS's own
    /// throttling signal: anything above nominal means macOS is actively
    /// trading performance for heat.
    private static func thermalPressureRank() -> Int? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return nil
        }
    }

    // MARK: - Battery temperature via IORegistry (no SMC needed)

    private func batteryTemperatureFromIORegistry() -> Double? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let raw = IORegistryEntryCreateCFProperty(
            service, "Temperature" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Int else {
            return nil
        }
        // AppleSmartBattery follows the Smart Battery System spec: tenths of
        // a Kelvin (e.g. 3089 -> 35.75°C). Verified against the SMC TB0T key
        // on this machine.
        let celsius = Double(raw) / 10.0 - 273.15
        return (celsius > 0 && celsius < 80) ? celsius : nil
    }
}
