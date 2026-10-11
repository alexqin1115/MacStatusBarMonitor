// Renders the real MenuBarView (live StatsStore data) into PNGs in both
// light and dark appearance, without needing screen-recording permission.
// Build with the app sources (minus MacStatusBarMonitorApp.swift).
import SwiftUI
import AppKit

@main
struct PreviewApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var store: StatsStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = StatsStore()
        // First refresh takes ~1s (CPU baseline + ps); give it two cycles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            self.capture(appearance: .aqua, path: "/tmp/msbm_panel_light.png")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.capture(appearance: .darkAqua, path: "/tmp/msbm_panel_dark.png")
                exit(0)
            }
        }
    }

    @MainActor
    private func capture(appearance: NSAppearance.Name, path: String) {
        window?.orderOut(nil)

        let hosting = NSHostingController(
            rootView: MenuBarView(store: store, loginItem: LoginItemManager(), scrollHeight: nil)
                .background(.regularMaterial)
        )
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(hosting.view.fittingSize)
        window.setFrameOrigin(NSPoint(x: 40, y: 60))
        window.orderFront(nil)
        self.window = window

        window.layoutIfNeeded()
        window.displayIfNeeded()

        guard let contentView = window.contentView,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            print("FAILED to create bitmap for \(path)")
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("FAILED to encode \(path)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) size=\(contentView.bounds.size)")
        } catch {
            print("FAILED to write \(path): \(error)")
        }
    }
}
