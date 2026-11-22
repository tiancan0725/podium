import SwiftUI

/// Light or dark controls on the iPad. The projector always shows the slides as they are.
enum Appearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match iPad"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

/// A gentle tint over the page on the iPad only, to take the glare off bright white slides and papers.
/// It multiplies the page's colours, so text stays crisp; ink is drawn on top untinted.
enum PageTint: String, CaseIterable, Identifiable {
    case off, warm, sepia, dim
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .warm: "Warm paper"
        case .sepia: "Sepia"
        case .dim: "Dimmed"
        }
    }

    var color: Color? {
        switch self {
        case .off: nil
        case .warm: Color(red: 1.0, green: 0.95, blue: 0.86)
        case .sepia: Color(red: 0.96, green: 0.88, blue: 0.74)
        case .dim: Color(white: 0.82)
        }
    }
}

extension Color {
    private static func adaptive(dark: CGFloat, light: CGFloat) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: dark, alpha: 1) : UIColor(white: light, alpha: 1) })
    }

    /// Behind the slide.
    static let stageBackground = adaptive(dark: 0.10, light: 0.92)
    /// Tool bar, notes strip.
    static let barBackground = adaptive(dark: 0.13, light: 0.97)
    /// Claude panel.
    static let panelBackground = adaptive(dark: 0.14, light: 0.98)
    /// Text editor fields.
    static let fieldBackground = adaptive(dark: 0.16, light: 1.0)
    /// The selected tool or option.
    static let selectedFill = Color.primary.opacity(0.14)
}
