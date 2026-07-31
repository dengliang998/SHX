import Foundation

enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "KiteShellReleaseLabel") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "开发版"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var display: String {
        AppLanguage.text(
            chinese: "版本 \(short)（\(build)）",
            english: "Version \(short) (\(build))"
        )
    }

    static var signingType: String {
        Bundle.main.object(forInfoDictionaryKey: "KiteShellSigningType") as? String
            ?? AppLanguage.text(chinese: "开发构建", english: "Development Build")
    }
}
