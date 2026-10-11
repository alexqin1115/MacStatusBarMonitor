// Sensor availability probe — prints what the SMC exposes on this Mac.
// Build: compiled together with Models/ and Providers/ sources (see README).
import Foundation
import IOKit

print("=== SMC probe ===")
guard let smc = SMCClient() else {
    print("SMC: NOT AVAILABLE (service open failed)")
    exit(0)
}
print("SMC: opened OK")

let keys = smc.allKeys()
print("total keys: \(keys.count)")

var temps: [(String, Double)] = []
for key in keys where key.hasPrefix("T") {
    if let value = smc.readDouble(key: key), value > 1, value < 125 {
        temps.append((key, value))
    }
}
print("--- plausible temperature keys (\(temps.count)) ---")
for (key, value) in temps.sorted(by: { $0.0 < $1.0 }) {
    print(String(format: "%@ = %.2f", key, value))
}

print("--- fans ---")
if let fanCount = smc.readDouble(key: "FNum") {
    print("FNum = \(Int(fanCount))")
    for index in 0..<Int(fanCount) {
        let actual = smc.readDouble(key: "F\(index)Ac")
        let min = smc.readDouble(key: "F\(index)Mn")
        let max = smc.readDouble(key: "F\(index)Mx")
        print("F\(index)Ac = \(actual.map { String(format: "%.0f", $0) } ?? "nil") (min \(min ?? -1), max \(max ?? -1))")
    }
} else {
    print("FNum unavailable")
}

print("--- battery temperature (IORegistry AppleSmartBattery) ---")
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
if service != IO_OBJECT_NULL {
    if let raw = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
        print("raw Temperature = \(raw)  (/100 -> \(Double(raw)/100.0)°C, /10-273.15 -> \(Double(raw)/10.0 - 273.15)°C)")
    } else {
        print("Temperature property missing")
    }
    IOObjectRelease(service)
} else {
    print("AppleSmartBattery service missing")
}

print("--- provider summary ---")
let provider = HardwareSensorProvider()
let stats = provider.sample()
print("cpuTemperature = \(stats.cpuTemperature.map { String(format: "%.1f°C", $0) } ?? "Unavailable")")
print("gpuTemperature = \(stats.gpuTemperature.map { String(format: "%.1f°C", $0) } ?? "Unavailable")")
print("batteryTemperature = \(stats.batteryTemperature.map { String(format: "%.1f°C", $0) } ?? "Unavailable")")
print("fanSpeeds = \(stats.fanSpeeds)")
print("smcAvailable = \(stats.smcAvailable)")
