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
        "版本 \(short)（\(build)）"
    }

    static var signingType: String {
        Bundle.main.object(forInfoDictionaryKey: "KiteShellSigningType") as? String
            ?? "开发构建"
    }
}
