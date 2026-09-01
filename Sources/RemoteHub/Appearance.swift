import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentColorOption: String, CaseIterable, Identifiable {
    case blue = "蓝色"
    case green = "绿色"
    case purple = "紫色"
    case orange = "橙色"
    case graphite = "石墨色"
    case custom = "自定义"

    var id: String { rawValue }

    func color(customHex: String) -> Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .purple: .purple
        case .orange: .orange
        case .graphite: .gray
        case .custom: Color(hex: customHex) ?? .blue
        }
    }
}

extension Color {
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let integer = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((integer >> 16) & 0xFF) / 255,
            green: Double((integer >> 8) & 0xFF) / 255,
            blue: Double(integer & 0xFF) / 255
        )
    }

    var hexRGB: String? {
        guard let converted = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(converted.redComponent * 255)),
            Int(round(converted.greenComponent * 255)),
            Int(round(converted.blueComponent * 255))
        )
    }
}

extension View {
    /// Uses the macOS 26 Liquid Glass surface when available and keeps the
    /// existing material treatment on supported older deployment targets.
    @ViewBuilder
    func macOS26Glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func macOS26GlassToolbar() -> some View {
        if #available(macOS 26.0, *) {
            toolbarBackground(.visible, for: .windowToolbar)
        } else {
            self
        }
    }
}
