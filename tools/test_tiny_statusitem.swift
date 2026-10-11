// Creates a minimal 1-character NSStatusItem and reports whether macOS gave
// it a window (i.e. whether there is any free menu bar space at all).
import AppKit
import CoreGraphics

final class Delegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "•"
        self.item = item

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("isVisible=\(item.isVisible)")
            let pid = ProcessInfo.processInfo.processIdentifier
            var found = 0
            if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
                for window in list {
                    if let owner = window[kCGWindowOwnerPID as String] as? Int, owner == Int(pid) {
                        let layer = window[kCGWindowLayer as String] as? Int ?? -999
                        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
                        print("own window: layer=\(layer) bounds=\(bounds)")
                        found += 1
                    }
                }
            }
            print("own windows: \(found)")
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
