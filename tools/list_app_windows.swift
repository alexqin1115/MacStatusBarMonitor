// Lists every window owned by a given pid (all layers, on- and off-screen).
import CoreGraphics
import Foundation

let targetPid = Int(CommandLine.arguments.dropFirst().first ?? "") ?? -1
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    exit(2)
}
var found = 0
for window in list {
    guard let pid = window[kCGWindowOwnerPID as String] as? Int, pid == targetPid else { continue }
    let layer = window[kCGWindowLayer as String] as? Int ?? -999
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
    print("layer=\(layer) onscreen=\(onscreen) bounds=\(bounds)")
    found += 1
}
print("total windows for pid \(targetPid): \(found)")
