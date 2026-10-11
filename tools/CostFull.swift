// Cost experiment B: full MenuBarExtra app (label + panel), panel never
// opened. Also reports whether the panel content's onAppear fires while the
// panel is closed.
import SwiftUI
import AppKit

@main
struct CostFullApp: App {
    @StateObject private var store = StatsStore()

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            print(String(format: "full app: %.2f cpu-seconds over 30s wall (%.1f%%)", cpu, cpu / 30 * 100))
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
                .onAppear { print("panel content onAppear fired (panel closed!)") }
                .onDisappear { print("panel content onDisappear fired") }
        } label: {
            MenuBarLabel(title: store.titleModel)
        }
        .menuBarExtraStyle(.window)
    }
}
