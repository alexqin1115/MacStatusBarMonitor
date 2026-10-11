import Foundation

/// A single snapshot of everything the app monitors.
/// Every section is optional so one failing provider never takes down the rest.
struct SystemStats {
    /// Marketing chip name ("M2 Pro"); static, filled from a cached lookup.
    var chipName: String?
    var cpu: CPUStats?
    var gpu: GPUStats?
    var memory: MemoryStats?
    var battery: BatteryStats?
    var sensors: SensorStats = .unavailable
    var lastUpdated: Date?

    static let empty = SystemStats()
}

struct CPUStats {
    /// Total usage across all cores, 0...1.
    var usage: Double
    var coreCount: Int
    /// Maximum P-core clock in GHz (static spec from the P-state table).
    var maxClockGHz: Double?
    /// Average clock the fastest active cluster ran at over the last
    /// interval (IOReport residencies). nil = unavailable.
    var currentClockGHz: Double?
    /// Average CPU package power over the last interval, in watts.
    var powerWatts: Double?
    /// Efficiency-core / performance-core busy fractions, 0...1.
    var eCoreUsage: Double?
    var pCoreUsage: Double?
    /// Classic 1/5/15-minute load averages.
    var loadAverage: [Double]?
    /// Per-core busy fractions in kernel order (efficiency cores first on
    /// Apple Silicon), plus how many leading entries are efficiency cores.
    var coreUsages: [Double]?
    var eCoreCount: Int?
}

struct MemoryStats {
    var total: UInt64
    var used: UInt64
    var free: UInt64
    /// Activity-Monitor-style breakdown, in bytes. nil = unavailable.
    var app: UInt64?
    var wired: UInt64?
    var compressed: UInt64?
    /// File cache that macOS can reclaim (external + purgeable pages).
    var cached: UInt64?
    var swapUsed: UInt64?
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int?

    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct BatteryStats {
    /// Charge level, 0...1.
    var level: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var isCharged: Bool
    /// Estimated minutes to empty (on battery) or to full (charging), when known.
    var minutesRemaining: Int?
    /// Instantaneous battery power flow in watts (|amperage| × voltage).
    /// This is the total system draw when unplugged, or the charge rate when
    /// plugged in. nil when the values can't be read.
    var powerWatts: Double?
    /// True when energy is leaving the battery (system running on battery).
    var isDischarging: Bool = false
    /// Charge cycles completed (AppleSmartBattery CycleCount).
    var cycleCount: Int?
    /// Max capacity as a fraction of design capacity (battery health), 0...1.
    var healthFraction: Double?

    var statusLabel: String {
        if isCharged { return "Charged" }
        if isCharging { return "Charging" }
        if isPluggedIn { return "Plugged In" }
        return "On Battery"
    }
}

struct SensorStats {
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var batteryTemperature: Double?
    /// System thermal pressure (public ProcessInfo.thermalState):
    /// 0 nominal, 1 fair, 2 serious, 3 critical. nil = unknown.
    var thermalPressure: Int? = nil
    /// One entry per fan, in RPM. Empty on fanless machines or when unreadable.
    var fanSpeeds: [Double]
    /// Whether the SMC could be opened at all (used to word the UI).
    var smcAvailable: Bool

    static let unavailable = SensorStats(
        cpuTemperature: nil,
        gpuTemperature: nil,
        batteryTemperature: nil,
        fanSpeeds: [],
        smcAvailable: false
    )
}

// MARK: - Formatting helpers

enum StatsFormat {
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    private static let diskFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func memory(_ bytes: UInt64) -> String {
        memoryFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func disk(_ bytes: UInt64) -> String {
        diskFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", (fraction * 100).rounded())
    }

    static func temperature(_ celsius: Double) -> String {
        String(format: "%.0f°C", celsius)
    }

    static func rpm(_ value: Double) -> String {
        String(format: "%.0f RPM", value)
    }

    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return hours > 0 ? String(format: "%d:%02d", hours, mins) : "\(mins) min"
    }

    static func clock(_ ghz: Double) -> String {
        String(format: "%.2f GHz", ghz)
    }

    static func watts(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f W", value) : String(format: "%.0f W", value)
    }
}


/// Rolling one-sample-per-second history (newest last) feeding the sparklines.
struct StatsHistory {
    static let capacity = 60
    var cpu: [Double] = []
    var gpu: [Double] = []
    var memory: [Double] = []
    var batteryWatts: [Double] = []

    mutating func append(from stats: SystemStats) {
        Self.push(&cpu, stats.cpu?.usage)
        Self.push(&gpu, stats.gpu?.usage)
        Self.push(&memory, stats.memory?.fraction)
        Self.push(&batteryWatts, stats.battery?.powerWatts)
    }

    private static func push(_ array: inout [Double], _ value: Double?) {
        guard let value else { return }
        array.append(value)
        if array.count > capacity { array.removeFirst(array.count - capacity) }
    }
}
