import SwiftUI

/// Capsule badge: "Charging", "On Battery", "Unavailable", ...
struct StatusBadge: View {
    let text: String
    var tint: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
    }
}

/// Shared color ramps so "meaningful" colors stay consistent across the app.
enum UsageColor {
    /// Higher is worse (CPU, memory, disk).
    static func load(_ fraction: Double, base: Color = .blue) -> Color {
        switch fraction {
        case ..<0.75: return base
        case ..<0.90: return .yellow
        default: return .red
        }
    }

    /// Higher is better (battery level).
    static func battery(_ level: Double) -> Color {
        switch level {
        case ..<0.10: return .red
        case ..<0.25: return .yellow
        default: return .green
        }
    }
}
