import SwiftUI
import Charts

// MARK: - Shared building blocks

/// Area + line trend with no axes — the "glance" element of every card.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    /// Fixed 0...1 for usage metrics; nil auto-scales (e.g. watts).
    var domain: ClosedRange<Double>? = 0...1

    var body: some View {
        let points = values.count > 1 ? values : [0, 0]
        let yDomain: ClosedRange<Double> = {
            if let domain { return domain }
            // Auto-scale with a floor on the span so a flat line stays a line.
            let low = points.min() ?? 0, high = points.max() ?? 1
            let span = max(high - low, 4)
            let mid = (high + low) / 2
            return (mid - span)...(mid + span)
        }()
        // Newest sample sits at the right edge; history scrolls in from there.
        let xDomain = Double(points.count - StatsHistory.capacity)...Double(max(points.count - 1, 1))
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("v", value))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", index), y: .value("v", value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .frame(height: 34)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Compact glass card: small title row, then arbitrary content.
struct DashCard<Content: View>: View {
    let icon: String
    let title: String
    let tint: Color
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

/// Large rounded number with a small unit; digits roll like Apple's own UI.
struct BigNumber: View {
    let value: String
    let unit: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

/// Two-column caption row; shows an em dash when the value is unavailable.
struct SubRow: View {
    let label: String
    let value: String?
    var body: some View {
        HStack {
            Text(label)
            Spacer(minLength: 6)
            Text(value ?? "—")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }
}

struct FlatBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.gradient)
                    .frame(width: max(8, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - CPU

struct CPUDashCard: View {
    let stats: SystemStats
    let history: StatsHistory

    var body: some View {
        let cpu = stats.cpu
        let tint = UsageColor.load(cpu?.usage ?? 0)
        DashCard(icon: "cpu", title: "CPU", tint: tint, trailing: cpu.map { "\($0.coreCount) cores" }) {
            BigNumber(value: cpu.map { String(format: "%.0f", $0.usage * 100) } ?? "—", unit: "%")
            Sparkline(values: history.cpu, tint: tint)
            if let usages = cpu?.coreUsages, !usages.isEmpty {
                CoreBars(usages: usages, eCount: cpu?.eCoreCount ?? 0)
            }
            SubRow(label: cpu?.currentClockGHz == 0 ? "Idle" : "Clock",
                   value: cpu?.currentClockGHz.flatMap { $0 > 0 ? StatsFormat.clock($0) : nil } ?? cpu?.maxClockGHz.map { "max " + StatsFormat.clock($0) })
            SubRow(label: "Power", value: cpu?.powerWatts.map(StatsFormat.watts))
            SubRow(label: "Temp", value: stats.sensors.cpuTemperature.map(StatsFormat.temperature))
            if let l = cpu?.loadAverage, l.count == 3 {
                SubRow(label: "Load", value: String(format: "%.1f · %.1f · %.1f", l[0], l[1], l[2]))
            }
        }
    }
}

/// One capsule bar per core; efficiency cores (teal) are grouped before
/// performance cores (accent), mirroring the kernel's enumeration order.
struct CoreBars: View {
    let usages: [Double]
    let eCount: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(usages.enumerated()), id: \.offset) { index, value in
                if index == eCount, eCount > 0 {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 20)
                }
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill((index < eCount ? Color.teal : Color.blue).gradient)
                        .frame(height: max(3, 22 * value))
                }
                .frame(maxWidth: 8)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.24), value: usages)
        .accessibilityLabel("Per-core usage")
    }
}

// MARK: - GPU

struct GPUDashCard: View {
    let stats: SystemStats
    let history: StatsHistory

    var body: some View {
        let gpu = stats.gpu
        let tint = (gpu?.usage).map { UsageColor.load($0, base: .purple) } ?? .purple
        DashCard(icon: "square.stack.3d.up", title: "GPU", tint: tint,
                 trailing: gpu?.coreCount.map { "\($0) cores" }) {
            BigNumber(value: (gpu?.usage).map { String(format: "%.0f", $0 * 100) } ?? "—", unit: "%")
            Sparkline(values: history.gpu, tint: tint)
            SubRow(label: "Clock", value: gpu?.currentClockGHz.map { $0 > 0 ? StatsFormat.clock($0) : "Idle" })
            SubRow(label: "Power", value: gpu?.powerWatts.map(StatsFormat.watts))
            if let r = gpu?.rendererUtilization, let t = gpu?.tilerUtilization {
                SubRow(label: "Render · Tiler", value: "\(StatsFormat.percent(r)) · \(StatsFormat.percent(t))")
            }
            SubRow(label: "Memory", value: gpu?.memoryUsedBytes.map { StatsFormat.memory($0) })
            SubRow(label: "Temp", value: stats.sensors.gpuTemperature.map(StatsFormat.temperature))
        }
    }
}

// MARK: - Memory

struct MemoryDashCard: View {
    let stats: SystemStats
    let history: StatsHistory

    private static let pressureNames: [Int: (String, Color)] = [1: ("Normal", .green), 2: ("Warning", .orange), 4: ("Critical", .red)]

    var body: some View {
        let mem = stats.memory
        let tint = UsageColor.load(mem?.fraction ?? 0, base: .green)
        DashCard(icon: "memorychip", title: "Memory", tint: tint, trailing: mem.map { StatsFormat.memory($0.total) }) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                BigNumber(value: mem.map { String(format: "%.1f", Double($0.used) / 1_073_741_824) } ?? "—", unit: "GB")
                Text(StatsFormat.percent(mem?.fraction ?? 0))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if let mem, let app = mem.app, let wired = mem.wired, let comp = mem.compressed {
                let total = Double(max(mem.total, 1))
                SegmentedBar(parts: [(Double(app) / total, .blue),
                                     (Double(wired) / total, .orange),
                                     (Double(comp) / total, .yellow),
                                     (Double(mem.cached ?? 0) / total, .gray.opacity(0.7))])
                HStack(spacing: 6) {
                    Legend(color: .blue, text: "App")
                    Legend(color: .orange, text: "Wired")
                    Legend(color: .yellow, text: "Comp.")
                    Legend(color: .gray.opacity(0.7), text: "Cache")
                }
            }
            Sparkline(values: history.memory, tint: tint)
            if let level = mem?.pressureLevel, let p = Self.pressureNames[level] {
                HStack {
                    Text("Pressure").foregroundStyle(.secondary)
                    Spacer()
                    Text(p.0).foregroundStyle(p.1)
                }
                .font(.system(size: 10.5, weight: .semibold))
            }
            SubRow(label: "Swap", value: mem?.swapUsed.map { StatsFormat.memory($0) })
        }
    }
}

struct SegmentedBar: View {
    let parts: [(Double, Color)]
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1.5) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(part.1.gradient)
                        .frame(width: max(part.0 > 0 ? 2 : 0, g.size.width * part.0))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .clipShape(Capsule())
    }
}

struct Legend: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
        }
    }
}

// MARK: - Battery

struct BatteryDashCard: View {
    let stats: SystemStats
    let history: StatsHistory

    var body: some View {
        let b = stats.battery
        let tint = b.map { UsageColor.battery($0.level) } ?? .secondary
        DashCard(icon: symbol(b), title: "Battery", tint: tint, trailing: b?.statusLabel) {
            if let b {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    BigNumber(value: String(format: "%.0f", b.level * 100), unit: "%")
                    if b.isCharging { Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(.green) }
                }
                FlatBar(fraction: b.level, tint: tint)
                Sparkline(values: history.batteryWatts, tint: tint, domain: nil)
                SubRow(label: b.isDischarging ? "Draw" : "Charge", value: b.powerWatts.map(StatsFormat.watts))
                SubRow(label: b.isCharging ? "To full" : "Remaining", value: b.minutesRemaining.map { StatsFormat.duration(minutes: $0) })
                SubRow(label: "Health", value: b.healthFraction.map { StatsFormat.percent($0) })
                SubRow(label: "Cycles", value: b.cycleCount.map { "\($0)" })
                SubRow(label: "Temp", value: stats.sensors.batteryTemperature.map(StatsFormat.temperature))
            } else {
                Text("No internal battery").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(_ b: BatteryStats?) -> String {
        guard let b else { return "battery.0" }
        if b.isCharging { return "battery.100.bolt" }
        switch b.level {
        case ..<0.125: return "battery.0"
        case ..<0.375: return "battery.25"
        case ..<0.625: return "battery.50"
        case ..<0.875: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Thermals strip

struct ThermalDashCard: View {
    let stats: SystemStats

    var body: some View {
        let s = stats.sensors
        DashCard(icon: "fan", title: "Thermals", tint: .orange, trailing: nil) {
            HStack(spacing: 16) {
                temp("CPU", s.cpuTemperature)
                temp("GPU", s.gpuTemperature)
                temp("Battery", s.batteryTemperature)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    if s.fanSpeeds.isEmpty {
                        Text(s.smcAvailable ? "No fans" : "SMC unavailable")
                            .font(.system(size: 11.5, weight: .semibold))
                    } else {
                        Text(StatsFormat.rpm(s.fanSpeeds.reduce(0, +) / Double(s.fanSpeeds.count)))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Text(s.fanSpeeds.count > 1 ? "\(s.fanSpeeds.count) fans avg" : "Fan")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func temp(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 1) {
            Text(value.map { String(format: "%.0f°", $0) } ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Header

struct DashHeader: View {
    let stats: SystemStats
    @Binding var refreshSpin: Double
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.medium")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("System Monitor").font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            thermalPill
            Button {
                withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .rotationEffect(.degrees(refreshSpin))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Refresh now")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var subtitle: String {
        let up = ProcessInfo.processInfo.systemUptime
        let h = Int(up) / 3600, m = (Int(up) % 3600) / 60
        let chip = stats.chipName.map { "\($0) · " } ?? ""
        return "\(chip)Up \(h)h \(m)m"
    }

    private var thermalPill: some View {
        let rank = stats.sensors.thermalPressure ?? 0
        let name = MenuBarView.thermalPressureNames[min(rank, 3)]
        let ok = rank == 0
        let tint: Color = ok ? .green : MenuBarView.thermalPressureTints[min(rank, 3)]
        return StatusBadge(text: name, tint: tint, systemImage: ok ? "checkmark.circle.fill" : "thermometer.high")
    }
}
