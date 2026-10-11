// Lists every window at the status-bar layer (25) with its owner.
import CoreGraphics
import Foundation

guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    exit(2)
}
for window in list {
    guard let layer = window[kCGWindowLayer as String] as? Int, layer == 25 else { continue }
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = window[kCGWindowOwnerPID as String] as? Int ?? -1
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = bounds["X"] ?? "?", w = bounds["Width"] ?? "?"
    print("layer=25 owner=\(owner) pid=\(pid) x=\(x) width=\(w)")
}
