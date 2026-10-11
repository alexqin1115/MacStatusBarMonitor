// Diagnostic harness: runs the EXACT same MenuBarExtra + views as the real
// app, then dumps every window the process owns. A healthy menu bar item
// shows up as an NSStatusBarWindow whose frame sits in the menu bar.
// Build with the app sources (minus MacStatusBarMonitorApp.swift).
import SwiftUI
import AppKit

@main
struct DiagApp: App {
    @StateObject private var store = StatsStore()

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            print("=== window dump (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
            for window in NSApp.windows {
                let cls = String(describing: type(of: window))
                print("class=\(cls) frame=\(window.frame) visible=\(window.isVisible) level=\(window.level.rawValue)")
            }
            print("windowCount=\(NSApp.windows.count)")
            for screen in NSScreen.screens {
                print("screen frame=\(screen.frame) visible=\(screen.visibleFrame) safeInsets=\(screen.safeAreaInsets)")
                if #available(macOS 12.0, *) {
                    print("  auxTopLeft=\(String(describing: screen.auxiliaryTopLeftArea)) auxTopRight=\(String(describing: screen.auxiliaryTopRightArea))")
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
