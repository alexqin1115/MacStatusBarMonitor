import Foundation
import IOKit

// =============================================================================
// LIVE CLOCK SPEEDS — private-library disclosure
//
// This file reads CPU/GPU performance-state residency counters through
// /usr/lib/libIOReport.dylib, resolved dynamically at runtime. IOReport is
// NOT a documented public API — this is one step beyond the read-only
// SMC/IORegistry access used elsewhere in this project, in the same
// read-only, no-privileges spirit (it needs no sudo and cannot change
// anything). It is the same source `powermetrics` and tools like macmon use.
//
// How it works: each refresh takes a sample and diffs it against the
// previous one, giving the time each CPU/GPU cluster spent in every DVFS
// performance state. Weighting those residencies against the chip's
// frequency tables (read from the device tree by DeviceInfoProvider) yields
// the average clock each cluster actually ran at during the interval.
//
// Every failure path — library missing, symbols renamed in a future macOS,
// unexpected state counts — degrades to nil, and the UI shows "Unavailable".
// V1 features never depend on anything here.
// =============================================================================

final class ClockProvider {

    struct Reading {
        /// Average clock of the fastest active CPU cluster over the last
        /// interval, in GHz. nil = unavailable.
        var cpuGHz: Double? = nil
        /// Average GPU clock over the last interval, in GHz.
        /// 0 = GPU fully idle (parked). nil = unavailable.
        var gpuGHz: Double? = nil
        /// Average package power over the last interval, from the SoC's
        /// "Energy Model" counters (energy delta ÷ elapsed time).
        var cpuWatts: Double? = nil
        var gpuWatts: Double? = nil
    }

    // MARK: - libIOReport symbols (resolved once)

    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Iterate = @convention(c) (CFDictionary?, @convention(block) (CFDictionary?) -> Int32) -> Void
    private typealias ChannelString = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary?) -> Int32
    private typealias StateNameForIndex = @convention(c) (CFDictionary?, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary?, Int32) -> Int64
    private typealias SimpleValue = @convention(c) (CFDictionary?, UnsafeMutableRawPointer?) -> Int64

    private struct Library {
        let copyChannels: CopyChannelsInGroup
        let createSubscription: CreateSubscription
        let createSamples: CreateSamples
        let createDelta: CreateSamplesDelta
        let iterate: Iterate
        let channelName: ChannelString
        let subGroup: ChannelString
        let stateCount: StateCount
        let stateName: StateNameForIndex
        let stateResidency: StateResidency
        let unitLabel: ChannelString
        let simpleValue: SimpleValue

        static let shared: Library? = {
            guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
            func load<T>(_ name: String, as type: T.Type) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let copy = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
                  let sub = load("IOReportCreateSubscription", as: CreateSubscription.self),
                  let samples = load("IOReportCreateSamples", as: CreateSamples.self),
                  let delta = load("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
                  let iterate = load("IOReportIterate", as: Iterate.self),
                  let name = load("IOReportChannelGetChannelName", as: ChannelString.self),
                  let group = load("IOReportChannelGetSubGroup", as: ChannelString.self),
                  let count = load("IOReportStateGetCount", as: StateCount.self),
                  let stateName = load("IOReportStateGetNameForIndex", as: StateNameForIndex.self),
                  let residency = load("IOReportStateGetResidency", as: StateResidency.self),
                  let unit = load("IOReportChannelGetUnitLabel", as: ChannelString.self),
                  let simple = load("IOReportSimpleGetIntegerValue", as: SimpleValue.self) else {
                return nil
            }
            return Library(
                copyChannels: copy, createSubscription: sub, createSamples: samples,
                createDelta: delta, iterate: iterate, channelName: name, subGroup: group,
                stateCount: count, stateName: stateName, stateResidency: residency,
                unitLabel: unit, simpleValue: simple
            )
        }()
    }

    private struct Subscription {
        let subscription: UnsafeMutableRawPointer
        let channels: CFMutableDictionary
        var previousSample: CFDictionary?
        var previousDate: Date?
    }

    private var cpuSubscription: Subscription?
    private var gpuSubscription: Subscription?
    private var energySubscription: Subscription?

    init() {
        cpuSubscription = Self.subscribe(group: "CPU Stats")
        gpuSubscription = Self.subscribe(group: "GPU Stats")
        energySubscription = Self.subscribe(group: "Energy Model")
        // Prime the baselines so the first real refresh has a delta.
        _ = takeDelta(of: &cpuSubscription)
        _ = takeDelta(of: &gpuSubscription)
        _ = takeDelta(of: &energySubscription)
    }

    private static func subscribe(group: String) -> Subscription? {
        guard let lib = Library.shared,
              let channels = lib.copyChannels(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            return nil
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = lib.createSubscription(nil, channels, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeRetainedValue() else {
            return nil
        }
        return Subscription(subscription: subscription, channels: subscribedChannels)
    }

    // MARK: - Sampling

    func sample() -> Reading {
        var reading = Reading()
        guard Library.shared != nil else { return reading }

        if let (delta, seconds) = takeDelta(of: &energySubscription), seconds > 0.2 {
            let joules = energyJoules(in: delta, channels: ["CPU Energy", "GPU Energy"])
            if let cpuJ = joules["CPU Energy"] {
                let watts = cpuJ / seconds
                if watts >= 0, watts < 300 { reading.cpuWatts = watts }
            }
            if let gpuJ = joules["GPU Energy"] {
                let watts = gpuJ / seconds
                if watts >= 0, watts < 300 { reading.gpuWatts = watts }
            }
        }

        if let (delta, _) = takeDelta(of: &cpuSubscription) {
            let clusters = residencies(in: delta, subgroup: "CPU Complex Performance States")
            var best: Double = 0
            for (channel, states) in clusters {
                let table = channel.hasPrefix("E")
                    ? DeviceInfoProvider.eCoreClocksGHz
                    : DeviceInfoProvider.pCoreClocksGHz
                if let ghz = Self.weightedGHz(states: states, table: table), ghz > best {
                    best = ghz
                }
            }
            if best > 0.1, best < 5 { reading.cpuGHz = best }
        }

        if let (delta, _) = takeDelta(of: &gpuSubscription) {
            let clusters = residencies(in: delta, subgroup: "GPU Performance States")
            if let states = clusters["GPUPH"] ?? clusters.values.first {
                if let ghz = Self.weightedGHz(states: states, table: DeviceInfoProvider.gpuClocksGHz) {
                    reading.gpuGHz = (ghz < 5) ? ghz : nil
                } else {
                    reading.gpuGHz = 0 // sampled fine, but zero active residency: idle
                }
            }
        }

        return reading
    }

    /// Samples the group and returns the delta against the previous sample,
    /// plus the elapsed wall time the delta covers.
    private func takeDelta(of subscription: inout Subscription?) -> (CFDictionary, TimeInterval)? {
        guard let lib = Library.shared, var sub = subscription else { return nil }
        let now = Date()
        guard let current = lib.createSamples(sub.subscription, sub.channels, nil)?.takeRetainedValue() else {
            return nil
        }
        defer {
            sub.previousSample = current
            sub.previousDate = now
            subscription = sub
        }
        guard let previous = sub.previousSample, let previousDate = sub.previousDate,
              let delta = lib.createDelta(previous, current, nil)?.takeRetainedValue() else {
            return nil
        }
        return (delta, now.timeIntervalSince(previousDate))
    }

    /// Sums the named simple energy channels in a delta, normalized to joules
    /// (channels report in nJ/uJ/mJ — the unit label decides).
    private func energyJoules(in delta: CFDictionary, channels wanted: [String]) -> [String: Double] {
        guard let lib = Library.shared else { return [:] }
        var result: [String: Double] = [:]
        lib.iterate(delta) { channel in
            guard let channel,
                  let name = lib.channelName(channel)?.takeUnretainedValue() as String?,
                  wanted.contains(name) else { return 0 }
            let raw = Double(lib.simpleValue(channel, nil))
            let unit = (lib.unitLabel(channel)?.takeUnretainedValue() as String?) ?? ""
            let scale: Double
            switch unit {
            case "nJ": scale = 1e-9
            case "uJ", "µJ": scale = 1e-6
            case "mJ": scale = 1e-3
            case "J": scale = 1
            default: return 0 // unknown unit — don't guess
            }
            result[name] = raw * scale
            return 0
        }
        return result
    }

    /// Collects (stateName, residency) lists per channel for one subgroup.
    private func residencies(in delta: CFDictionary, subgroup: String) -> [String: [(name: String, residency: Int64)]] {
        guard let lib = Library.shared else { return [:] }
        var result: [String: [(name: String, residency: Int64)]] = [:]
        lib.iterate(delta) { channel in
            guard let channel else { return 0 }
            guard (lib.subGroup(channel)?.takeUnretainedValue() as String?) == subgroup else { return 0 }
            let name = lib.channelName(channel)?.takeUnretainedValue() as String? ?? "?"
            var states: [(String, Int64)] = []
            for index in 0..<lib.stateCount(channel) {
                let stateName = lib.stateName(channel, index)?.takeUnretainedValue() as String? ?? "?"
                states.append((stateName, lib.stateResidency(channel, index)))
            }
            result[name] = states
            return 0
        }
        return result
    }

    /// Residency-weighted average frequency. Idle/off/down states are
    /// skipped; the remaining states map onto the frequency table in order.
    /// Returns nil when there was no active residency at all.
    private static func weightedGHz(states: [(name: String, residency: Int64)], table: [Double]) -> Double? {
        guard !table.isEmpty else { return nil }
        var activeIndex = 0
        var totalResidency: Int64 = 0
        var weighted = 0.0
        for (name, residency) in states {
            switch name {
            case "IDLE", "OFF", "DOWN":
                continue
            default:
                defer { activeIndex += 1 }
                guard activeIndex < table.count, residency > 0 else { continue }
                totalResidency += residency
                weighted += table[activeIndex] * Double(residency)
            }
        }
        guard totalResidency > 0 else { return nil }
        return weighted / Double(totalResidency)
    }
}
