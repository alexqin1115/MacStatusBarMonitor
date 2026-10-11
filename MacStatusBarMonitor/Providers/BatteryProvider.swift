import Foundation
import IOKit
import IOKit.ps

/// Reads battery state through the public IOPowerSources API, plus the
/// instantaneous power flow from the AppleSmartBattery registry entry.
/// Returns nil on machines without an internal battery (desktops).
final class BatteryProvider {
    /// Original battery energy rating, not remaining charge or health.
    /// Apple specifies 69.6 Wh for the 14-inch 2023 MacBook Pro.
    /// Source: https://support.apple.com/en-us/111340, footnote 3.
    static func designCapacityWattHours() -> Double? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        switch String(cString: bytes) {
        case "Mac14,9", "Mac14,5": return 69.6
        default: return nil
        }
    }

    func sample() -> BatteryStats? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = info[kIOPSCurrentCapacityKey] as? Int,
                let max = info[kIOPSMaxCapacityKey] as? Int,
                max > 0 else {
                continue
            }

            let isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            let isPluggedIn = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let isCharged = info[kIOPSIsChargedKey] as? Bool ?? false

            var minutes: Int?
            if isCharging {
                minutes = info[kIOPSTimeToFullChargeKey] as? Int
            } else if !isPluggedIn {
                minutes = info[kIOPSTimeToEmptyKey] as? Int
            }
            if let value = minutes, value <= 0 { minutes = nil } // -1 means "still estimating"

            let power = readPower()
            let health = readHealth()
            return BatteryStats(
                level: min(max == 0 ? 0 : Double(current) / Double(max), 1),
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                isCharged: isCharged,
                minutesRemaining: minutes,
                powerWatts: power?.watts,
                isDischarging: power?.discharging ?? false,
                cycleCount: health.cycles,
                healthFraction: health.fraction
            )
        }
        return nil
    }

    /// Cycle count and max/design capacity from AppleSmartBattery. Apple
    /// Silicon publishes AppleRawMaxCapacity + DesignCapacity in mAh.
    private func readHealth() -> (cycles: Int?, fraction: Double?) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.doubleValue
        }
        let cycles = number("CycleCount").map { Int($0) }
        var fraction: Double?
        if let maxCap = number("AppleRawMaxCapacity"), let design = number("DesignCapacity"),
           design > 0, maxCap > 0 {
            let value = maxCap / design
            if value > 0.2, value <= 1.2 { fraction = min(value, 1) } // plausibility guard
        }
        return (cycles, fraction)
    }

    /// Instantaneous battery power = |Amperage| × Voltage, from the
    /// AppleSmartBattery registry entry (public, no sudo, ~µs per read).
    /// Amperage is signed: negative = discharging (drawing from battery).
    private func readPower() -> (watts: Double, discharging: Bool)? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.doubleValue
        }
        guard let amperageMA = number("Amperage"), let voltageMV = number("Voltage"),
              voltageMV > 0 else {
            return nil
        }
        let watts = abs(amperageMA) / 1000.0 * voltageMV / 1000.0
        guard watts.isFinite, watts < 500 else { return nil } // guard against garbage
        return (watts, amperageMA < 0)
    }
}
