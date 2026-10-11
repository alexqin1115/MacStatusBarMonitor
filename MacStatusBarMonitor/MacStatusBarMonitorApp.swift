import SwiftUI
import AppKit

@main
struct MacStatusBarMonitorApp: App {
    @StateObject private var store: StatsStore
    @StateObject private var loginItem = LoginItemManager()

    init() {
        let store = StatsStore()
        _store = StateObject(wrappedValue: store)
        MenuBarVisibility.checkAfterLaunch { _ in }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store, loginItem: loginItem)
        } label: {
            MenuBarLabel(title: store.titleModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// On notched MacBooks, macOS parks new status items underneath the camera
/// housing when the menu bar is already full — the item exists but can't be
/// seen. There is no API to reposition it, so we log a clear diagnostic and
/// let the caller switch the label to its most compact format.
private enum MenuBarVisibility {
    @MainActor
    static func checkAfterLaunch(after seconds: TimeInterval = 4,
                                 onResult: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard let window = NSApp.windows.first(where: {
                      String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.frame.minY > 0
                  }),
                  let screen = window.screen ?? NSScreen.main,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else {
                onResult(false) // no status window yet, or no notch
                return
            }
            let frame = window.frame
            let hidden = frame.minX >= left.maxX - 1 && frame.maxX <= right.minX + 1
            if hidden {
                NSLog(
                    "MacStatusBarMonitor: menu bar item is hidden under the camera notch " +
                    "(item x %.0f-%.0f, notch x %.0f-%.0f). The menu bar is full - remove " +
                    "some menu bar icons (System Settings > Control Center) or use an " +
                    "external display to see it.",
                    frame.minX, frame.maxX, left.maxX, right.minX
                )
            }
            onResult(hidden)
        }
    }
}
