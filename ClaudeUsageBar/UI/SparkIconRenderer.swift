import AppKit
import SwiftUI

/// Renders the menu bar status icon.
///
/// ## Why original artwork
/// The icon is drawn from primitives (arcs) in this file. It embeds no third-party
/// artwork, no vendor logo, and no SF Symbol, so it carries no external copyright or
/// trademark exposure. Apple licenses SF Symbols for in-app UI but not for
/// logo/trademark-adjacent use, and this project must not evoke Anthropic's marks.
///
/// ## Why a ring instead of a glyph
/// A static glyph conveys nothing about usage. A ring encodes the selected window's
/// utilization as swept angle, so the menu bar communicates level at a glance and the
/// tint only reinforces what the geometry already shows.
///
/// ## Rendering notes
/// Apple's HIG prefers template images so the system tints for light/dark menu bars.
/// This app intentionally color-codes usage bands, which requires a non-template image.
/// Neutral and stale states fall back to `secondaryLabelColor`, which is appearance
/// adaptive, so the icon still reads correctly in both menu bar appearances.
enum UsageRingRenderer {
    /// Menu bar status images are measured in points; 16pt is comfortable next to
    /// the 11pt percentage label without crowding neighbouring status items.
    static let canvasSize = NSSize(width: 16, height: 16)
    private static let lineWidth: CGFloat = 2.2
    /// Inset so the stroke, which straddles the path, stays fully inside the canvas.
    private static var radius: CGFloat { (canvasSize.width - lineWidth) / 2 - 0.5 }

    static func image(
        percent: Double,
        band: UsageColorBand,
        stale: Bool
    ) -> NSImage {
        let tint = nsColor(for: band, stale: stale)
        let fraction = fractionFilled(forPercent: percent)

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

            // Track: the full circle at low contrast so the ring reads as a gauge
            // even at 0%, rather than disappearing into the menu bar.
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setStrokeColor(tint.withAlphaComponent(0.28).cgColor)
            context.addArc(
                center: center,
                radius: radius,
                startAngle: 0,
                endAngle: .pi * 2,
                clockwise: false
            )
            context.strokePath()

            guard fraction > 0 else { return true }

            // Progress: sweeps clockwise from 12 o'clock, matching how progress
            // rings are read elsewhere on Apple platforms.
            let start = CGFloat.pi / 2
            context.setStrokeColor(tint.cgColor)
            context.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: start - (.pi * 2 * fraction),
                clockwise: true
            )
            context.strokePath()
            return true
        }

        // Non-template: the band colour is meaningful and must survive system tinting.
        image.isTemplate = false
        image.accessibilityDescription = "Claude usage \(Int(percent.rounded())) percent"
        return image
    }

    /// Clamps to 0...1 and treats a non-finite percentage as empty, so a malformed
    /// utilization value can never produce an unbounded or NaN sweep angle.
    static func fractionFilled(forPercent percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(max(percent / 100, 0), 1)
    }

    static func nsColor(for band: UsageColorBand, stale: Bool) -> NSColor {
        if stale { return .secondaryLabelColor }
        // System adaptive status colors (Light / Dark / Auto).
        switch band {
        case .green: return .systemGreen
        case .yellow: return .systemOrange
        case .red: return .systemRed
        case .neutral: return .secondaryLabelColor
        }
    }

    static func swiftUIColor(for band: UsageColorBand, stale: Bool) -> Color {
        Color(nsColor: nsColor(for: band, stale: stale))
    }
}

struct UsageMenuLabel: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        HStack(spacing: 4) {
            Image(
                nsImage: UsageRingRenderer.image(
                    percent: monitor.menuPercent,
                    band: monitor.colorBand,
                    stale: monitor.isStale
                )
            )
            if preferences.showPercentInMenu {
                Text("\(Int(monitor.menuPercent.rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if monitor.usage == nil {
            switch monitor.authStatus {
            case .disconnected, .unknown:
                return "Claude usage — connect Claude Code"
            case .signInRequired:
                return "Claude usage — sign in with Claude Code"
            case .keychainDenied:
                return "Claude usage — allow Keychain access"
            case .keychainError:
                return "Claude usage — Keychain unavailable"
            case .apiKeyOnly, .unsupportedPlan:
                return "Claude usage — plan doesn’t include usage bars"
            default:
                return "Claude usage unavailable"
            }
        }
        return "\(preferences.menuPercentSource.accessibilityName) \(Int(monitor.menuPercent.rounded())) percent"
    }
}
