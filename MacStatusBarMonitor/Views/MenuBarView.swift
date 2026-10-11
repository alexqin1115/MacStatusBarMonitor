import SwiftUI
import AppKit

/// Compact text shown in the menu bar itself. Observes only the lightweight
/// title model, never the full stats snapshot.
struct MenuBarLabel: View {
    @ObservedObject var title: MenuBarTitleModel

    var body: some View {
        Text(title.text)
            .monospacedDigit()
    }
}

/// Footer "Launch at Login" toggle. A small checkbox-style control backed by
/// the OS login-item registration.
struct LoginToggleView: View {
    @ObservedObject var loginItem: LoginItemManager

    var body: some View {
        Button {
            loginItem.setEnabled(!loginItem.isEnabled)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: loginItem.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(loginItem.isEnabled ? Color.accentColor : .secondary)
                Text("Launch at Login")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .help("Automatically start System Monitor when you log in")
    }
}

/// The dropdown panel — a small Control Center-style summary of the machine.
/// The dropdown panel — a compact dashboard: four metric cards, a thermals
/// strip, and the Launch-at-Login / Quit footer.
struct MenuBarView: View {
    @ObservedObject var store: StatsStore
    /// nil in the offscreen preview tool (which has no app lifecycle).
    var loginItem: LoginItemManager? = nil
    /// Height of the scrollable area. nil renders everything unclipped —
    /// used by the offscreen preview tool to inspect the full panel.
    var scrollHeight: CGFloat? = 560
    @State private var refreshSpin = 0.0

    static let thermalPressureNames = ["Nominal", "Fair", "Serious", "Critical"]
    static let thermalPressureTints: [Color] = [.secondary, .yellow, .orange, .red]

    var body: some View {
        VStack(spacing: 0) {
            DashHeader(stats: store.stats, refreshSpin: $refreshSpin) { store.refresh() }
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            CPUDashCard(stats: store.stats, history: store.history)
                            GPUDashCard(stats: store.stats, history: store.history)
                        }
                        GridRow {
                            MemoryDashCard(stats: store.stats, history: store.history)
                            BatteryDashCard(stats: store.stats, history: store.history)
                        }
                    }
                    ThermalDashCard(stats: store.stats)
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 12)
                .redacted(reason: store.isLoading ? .placeholder : [])
            }
            .frame(height: scrollHeight)
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { store.panelDidAppear() }
        .onDisappear { store.panelDidDisappear() }
    }

    private var footer: some View {
        HStack {
            if let loginItem {
                LoginToggleView(loginItem: loginItem)
            }
            Spacer(minLength: 6)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Quit")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
            .help("Quit System Monitor")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
