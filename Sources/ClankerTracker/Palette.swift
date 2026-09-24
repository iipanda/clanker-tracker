import AppKit
import ClankerCore
import SwiftUI

/// Colors from the design board's CSS tokens, light and dark.
enum Palette {
    static let accentNS = dynamic(light: 0x7447EE, dark: 0x9D70FF)
    static let warnNS = dynamic(light: 0xB0620A, dark: 0xF2B13A)
    static let okNS = dynamic(light: 0x0D7A5B, dark: 0x55D3A4)
    static let critNS = dynamic(light: 0xC42F2A, dark: 0xFF6B61)
    /// Second series color for Codex next to Claude Code's accent.
    static let codexNS = dynamic(light: 0x1F8AC0, dark: 0x5BB6E8)

    static let accent = Color(nsColor: accentNS)
    static let warn = Color(nsColor: warnNS)
    static let ok = Color(nsColor: okNS)
    static let crit = Color(nsColor: critNS)
    static let codex = Color(nsColor: codexNS)
    static let track = Color.primary.opacity(0.09)
    static let line = Color.primary.opacity(0.09)

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum LimitState {
    case calm, warn, hit

    init(_ f: Forecast?) {
        guard let f else { self = .calm; return }
        self = f.isHit ? .hit : f.alertRunout != nil ? .warn : .calm
    }

    var color: Color? {
        switch self {
        case .calm: nil
        case .warn: Palette.warn
        case .hit: Palette.crit
        }
    }
}
