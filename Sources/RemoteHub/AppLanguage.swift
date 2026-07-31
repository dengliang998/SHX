import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .chinese
    }

    static func text(chinese: String, english: String) -> String {
        current == .english ? english : chinese
    }
}
