import AppKit
import Foundation
import SwiftTerm

enum TerminalCursorStyleOption: String, CaseIterable, Identifiable {
    case block = "方块"
    case underline = "下划线"
    case bar = "竖线"

    var id: String { rawValue }

    var swiftTermStyle: CursorStyle {
        switch self {
        case .block: .blinkBlock
        case .underline: .blinkUnderline
        case .bar: .blinkBar
        }
    }
}

enum TerminalThemeOption: String, CaseIterable, Identifiable {
    case midnight = "深海蓝"
    case graphite = "石墨黑"
    case nord = "Nord"
    case dracula = "Dracula"
    case solarizedDark = "Solarized Dark"
    case paper = "暖纸白"

    var id: String { rawValue }

    var definition: TerminalThemeDefinition {
        switch self {
        case .midnight:
            TerminalThemeDefinition(
                background: "07111D", foreground: "DCEAF5", cursor: "55D6BE",
                selection: "244D70",
                ansi: ["101820", "EF6B73", "57D68D", "F5C66A", "62A9FF", "C792EA", "55D6BE", "DCEAF5", "4D6275", "FF7B83", "69E39E", "FFD780", "78B7FF", "D7A6F3", "70E2CE", "FFFFFF"]
            )
        case .graphite:
            TerminalThemeDefinition(
                background: "15171B", foreground: "E7E7E7", cursor: "F2C94C",
                selection: "3B3F46",
                ansi: ["202226", "E06C75", "98C379", "E5C07B", "61AFEF", "C678DD", "56B6C2", "D7DAE0", "5C6370", "FF7A85", "B2DD8D", "F1D18A", "75BEFF", "DA8CEA", "6FD1DA", "FFFFFF"]
            )
        case .nord:
            TerminalThemeDefinition(
                background: "2E3440", foreground: "D8DEE9", cursor: "88C0D0",
                selection: "434C5E",
                ansi: ["3B4252", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "88C0D0", "E5E9F0", "4C566A", "D06F79", "B1D196", "F0D399", "8FBCBB", "C89FC0", "8FCDD7", "ECEFF4"]
            )
        case .dracula:
            TerminalThemeDefinition(
                background: "282A36", foreground: "F8F8F2", cursor: "FFB86C",
                selection: "44475A",
                ansi: ["21222C", "FF5555", "50FA7B", "F1FA8C", "6272A4", "BD93F9", "8BE9FD", "F8F8F2", "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF"]
            )
        case .solarizedDark:
            TerminalThemeDefinition(
                background: "002B36", foreground: "93A1A1", cursor: "2AA198",
                selection: "073642",
                ansi: ["073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5", "586E75", "CB4B16", "859900", "B58900", "839496", "6C71C4", "93A1A1", "FDF6E3"]
            )
        case .paper:
            TerminalThemeDefinition(
                background: "F7F3E8", foreground: "2C3038", cursor: "2166D1",
                selection: "C8DCF7",
                ansi: ["2C3038", "C83E4D", "3A7D44", "9A6D00", "2166D1", "8A4FFF", "137C8B", "DFD9CC", "686D76", "E04F5F", "4B9656", "B98300", "3478E5", "A566FF", "1A95A6", "FFFFFF"]
            )
        }
    }
}

struct TerminalThemeDefinition {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
    let ansi: [SwiftTerm.Color]

    init(
        background: String,
        foreground: String,
        cursor: String,
        selection: String,
        ansi: [String]
    ) {
        self.background = Self.nsColor(hex: background)
        self.foreground = Self.nsColor(hex: foreground)
        self.cursor = Self.nsColor(hex: cursor)
        self.selection = Self.nsColor(hex: selection)
        self.ansi = ansi.map(Self.terminalColor(hex:))
    }

    private static func components(hex: String) -> (UInt8, UInt8, UInt8) {
        let value = UInt64(hex, radix: 16) ?? 0
        return (
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        )
    }

    private static func nsColor(hex: String) -> NSColor {
        let (red, green, blue) = components(hex: hex)
        return NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    private static func terminalColor(hex: String) -> SwiftTerm.Color {
        let (red, green, blue) = components(hex: hex)
        return SwiftTerm.Color(
            red: UInt16(red) * 257,
            green: UInt16(green) * 257,
            blue: UInt16(blue) * 257
        )
    }
}
