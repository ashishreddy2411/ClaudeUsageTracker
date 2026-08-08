import AppKit
import SwiftUI

/// Apple menu-bar utility chassis + Anthropic brand restraint
/// (`UI-UX-Inspirations/Apple.md` + `Anthropic.md`), following **system appearance**.
///
/// Surfaces and ink are semantic (`NSColor` / SwiftUI hierarchical styles) so Light,
/// Dark, and Auto stay readable. Brand voltage is coral on the primary CTA only —
/// never a fixed cream floor that fights dark Form chrome.
enum PopoverTheme {
    // MARK: Surfaces (system — follow Light / Dark / Auto)

    /// Menu-bar panel floor (signed-out and signed-in).
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Alias for call-site clarity; same adaptive floor as `canvas`.
    static let parchment = canvas
    /// Settings page floor under grouped Form (matches popover).
    static let settingsFloor = Color(nsColor: .windowBackgroundColor)
    /// Soft divider — system separator adapts in both appearances.
    static let hairline = Color(nsColor: .separatorColor)

    // MARK: Ink (system label hierarchy)

    static let ink = Color(nsColor: .labelColor)
    static let body = Color(nsColor: .secondaryLabelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let mutedSoft = Color(nsColor: .tertiaryLabelColor)

    // MARK: Accent (Anthropic coral — scarce; readable on light and dark chrome)

    static let coral = Color(red: 204 / 255, green: 120 / 255, blue: 92 / 255) // #cc785c
    static let coralActive = Color(red: 169 / 255, green: 88 / 255, blue: 62 / 255) // #a9583e
    static let onPrimary = Color.white

    // MARK: Semantic status (system adaptive)

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)

    // MARK: Typography (Apple SF Pro ladder — 300/400/600; no 500)

    static func brandTitle() -> Font {
        .system(size: 22, weight: .semibold, design: .default) // ~tagline / display-sm
    }

    static func bodyCallout() -> Font {
        .system(size: 15, weight: .regular, design: .default)
    }

    static func sectionLabel() -> Font {
        .system(size: 13, weight: .semibold, design: .default)
    }

    static func percent() -> Font {
        .system(size: 20, weight: .semibold, design: .default).monospacedDigit()
    }

    static func caption() -> Font {
        .system(size: 12, weight: .regular, design: .default)
    }

    static func finePrint() -> Font {
        .system(size: 11, weight: .regular, design: .default)
    }

    static func footerLink() -> Font {
        .system(size: 12, weight: .regular, design: .default)
    }

    static func buttonLabel() -> Font {
        .system(size: 15, weight: .regular, design: .default)
    }
}

/// Scarce coral pill — Anthropic primary voltage on Apple pill grammar.
struct CoralPillButtonStyle: ButtonStyle {
    var disabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PopoverTheme.buttonLabel())
            .foregroundStyle(PopoverTheme.onPrimary.opacity(disabled ? 0.7 : 1))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .padding(.horizontal, 22)
            .background(
                Capsule(style: .continuous)
                    .fill(fillColor(pressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed && !disabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func fillColor(pressed: Bool) -> Color {
        if disabled { return PopoverTheme.coral.opacity(0.45) }
        return pressed ? PopoverTheme.coralActive : PopoverTheme.coral
    }
}

/// Quiet text link for utility footer (Apple text-link / Anthropic button-text-link).
struct QuietTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PopoverTheme.footerLink())
            .foregroundStyle(configuration.isPressed ? PopoverTheme.coral : PopoverTheme.muted)
    }
}
