import Foundation
import ServiceManagement
import SwiftUI

/// Manages "Launch at Login" via the modern `SMAppService.mainApp` API
/// (macOS 13+). No helper bundle, no privileged install — the app registers
/// itself as a login item that macOS manages in System Settings > General >
/// Login Items.
///
/// The first time the app ever runs it enables itself automatically, so the
/// menu bar item reappears after every restart without the user doing
/// anything. After that, the footer toggle is the source of truth and a
/// one-time flag stops us from re-enabling something the user turned off.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private let service = SMAppService.mainApp
    private static let didAutoEnableKey = "didAutoEnableLoginItem"

    init() {
        isEnabled = service.status == .enabled
        enableOnFirstLaunch()
    }

    /// On the very first launch, opt in by default so the app comes back
    /// after restarts. Runs once ever, guarded by a UserDefaults flag.
    private func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didAutoEnableKey) else { return }
        defaults.set(true, forKey: Self.didAutoEnableKey)
        if service.status != .enabled {
            setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                // requiresApproval is thrown when the user disabled the item
                // in System Settings; registering again is still correct.
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("MacStatusBarMonitor: login-item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        // Re-read the real status rather than trusting the requested value.
        isEnabled = service.status == .enabled
    }

    func refreshStatus() {
        isEnabled = service.status == .enabled
    }
}
