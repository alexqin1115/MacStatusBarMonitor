// Verifies (without screen-recording permission) that the app has put a
// status item in the menu bar: status item windows live at window layer 25.
import CoreGraphics
import Foundation

guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("could not list windows")
    exit(2)
}
for window in list {
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          owner == "MacStatusBarMonitor",
          let layer = window[kCGWindowLayer as String] as? Int else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("window owner=\(owner) layer=\(layer) bounds=\(bounds)")
}
exit(0)
