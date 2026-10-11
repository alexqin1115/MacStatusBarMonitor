import Foundation
import SwiftUI

/// Coordinates all individual providers into one snapshot.
/// `collect()` is synchronous and is always called from a background thread.
final class SystemStatsProvider {
    private let cpuProvider = CPUProvider()
    private let gpuProvider = GPUProvider()
    private let clockProvider = ClockProvider()
    private let memoryProvider = MemoryProvider()
    private let batteryProvider = BatteryProvider()
    private let sensorProvider = HardwareSensorProvider()

    /// `includeExpensive` controls the SMC sensor reads. While the panel is
    /// closed only the cheap kernel counters are needed for the menu bar
    /// label, so the expensive part is skipped and the previous values
    /// carried over.
    func collect(includeExpensive: Bool, carryingOver previous: SystemStats) -> SystemStats {
        var stats = SystemStats.empty
        stats.chipName = DeviceInfoProvider.chipName // cached, not re-read
        stats.cpu = cpuProvider.sample()
        stats.cpu?.maxClockGHz = DeviceInfoProvider.cpuMaxClockGHz // cached
        stats.gpu = gpuProvider.sample()
        stats.gpu?.maxClockGHz = DeviceInfoProvider.gpuMaxClockGHz // cached
        let clocks = clockProvider.sample() // IOReport residency delta, sub-ms
        stats.cpu?.currentClockGHz = clocks.cpuGHz
        stats.gpu?.currentClockGHz = clocks.gpuGHz
        stats.cpu?.powerWatts = clocks.cpuWatts
        stats.gpu?.powerWatts = clocks.gpuWatts
        stats.memory = memoryProvider.sample()
        stats.battery = batteryProvider.sample()
        if includeExpensive {
            stats.sensors = sensorProvider.sample()
        } else {
            stats.sensors = previous.sensors
        }
        stats.lastUpdated = Date()
        return stats
    }
}

/// Tiny observable for the menu bar label only. Kept separate from the main
/// store so a label repaint never drags the whole panel's view graph with it.
@MainActor
final class MenuBarTitleModel: ObservableObject {
    @Published fileprivate(set) var text = "CPU –– · MEM ––"
}

/// Observable source of truth for the UI. The closed menu bar refreshes every
/// two seconds. An open panel refreshes twice per second so live metrics can
/// transition smoothly without making the background monitor expensive.
///
/// Publishing is deliberately split in two: the label title (cheap, updated
/// only when the rendered text actually changes) and the full `stats`
/// snapshot (published only while the panel is open, so a closed panel costs
/// no SwiftUI render work).
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var stats: SystemStats = .empty
    @Published private(set) var isRefreshing = false
    /// Published only while the panel is open (same rule as `stats`).
    @Published private(set) var history = StatsHistory()
    private var historyBuffer = StatsHistory()
    private var lastHistorySample = Date.distantPast
    let titleModel = MenuBarTitleModel()

    private let provider = SystemStatsProvider()
    private var timer: Timer?
    private var isCollecting = false
    private var isPanelVisible = false
    private var latestSnapshot: SystemStats = .empty

    private static let idleRefreshInterval = 2.0
    private static let visibleRefreshInterval = 0.25

    var isLoading: Bool { stats.lastUpdated == nil }

    init() {
        scheduleRefresh(interval: Self.idleRefreshInterval)
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    func panelDidAppear() {
        isPanelVisible = true
        scheduleRefresh(interval: Self.visibleRefreshInterval)
        stats = latestSnapshot
        refresh()
    }

    func panelDidDisappear() {
        isPanelVisible = false
        scheduleRefresh(interval: Self.idleRefreshInterval)
    }

    private func scheduleRefresh(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !isCollecting else { return }
        isCollecting = true
        isRefreshing = true
        let provider = self.provider
        let previous = latestSnapshot
        // First collection is always full so the panel has data before its
        // first open; afterwards expensive work only runs while it's visible.
        let includeExpensive = isPanelVisible || previous.lastUpdated == nil
        Task.detached(priority: .utility) {
            let newStats = provider.collect(
                includeExpensive: includeExpensive,
                carryingOver: previous
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.publish(newStats)
                self.isRefreshing = false
                self.isCollecting = false
            }
        }
    }

    private func publish(_ newStats: SystemStats) {
        latestSnapshot = newStats

        // One sparkline sample per second, buffered even while closed.
        if newStats.lastUpdated.map({ $0.timeIntervalSince(lastHistorySample) >= 1.0 }) ?? false {
            lastHistorySample = newStats.lastUpdated ?? Date()
            historyBuffer.append(from: newStats)
        }

        // Deliberately short. CPU and memory provide the most useful
        // always-visible baseline when the menu bar is crowded.
        let cpu = newStats.cpu.map { StatsFormat.percent($0.usage) } ?? "––"
        let memory = newStats.memory.map { StatsFormat.percent($0.fraction) } ?? "––"
        let title = "CPU \(cpu) · MEM \(memory)"
        if title != titleModel.text {
            titleModel.text = title
        }

        // First snapshot always lands so the panel never opens empty; after
        // that, only a visible panel pays for view updates.
        if isPanelVisible || stats.lastUpdated == nil {
            stats = smoothedForDisplay(newStats)
            history = historyBuffer
        }
    }

    /// CPU and GPU values are inherently spiky over short intervals. Smooth
    /// only the panel's display snapshot so the menu bar keeps reporting the
    /// latest raw values while the expanded monitor remains readable.
    private func smoothedForDisplay(_ incoming: SystemStats) -> SystemStats {
        guard stats.lastUpdated != nil else { return incoming }
        var display = incoming
        if let previous = stats.cpu?.usage, let current = incoming.cpu?.usage {
            display.cpu?.usage = smoothed(current, from: previous)
        }
        if let previous = stats.gpu?.usage, let current = incoming.gpu?.usage {
            display.gpu?.usage = smoothed(current, from: previous)
        }
        return display
    }

    private func smoothed(_ current: Double, from previous: Double) -> Double {
        let difference = abs(current - previous)
        let blend = difference > 0.45 ? 0.62 : 0.30
        return previous + (current - previous) * blend
    }
}
