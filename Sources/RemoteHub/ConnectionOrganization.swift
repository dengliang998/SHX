import Foundation

enum ConnectionOrganization {
    static let defaultGroup = "默认分组"
    static let lanTag = "内网"
    static let wanTag = "外网"
    static let builtInTags = [lanTag, wanTag]

    static func normalizeTags<S: Sequence>(_ tags: S) -> [String] where S.Element == String {
        var seen: Set<String> = []
        return tags.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
        .sorted { lhs, rhs in
            let leftIndex = builtInTags.firstIndex(of: lhs)
            let rightIndex = builtInTags.firstIndex(of: rhs)
            if let leftIndex, let rightIndex { return leftIndex < rightIndex }
            if leftIndex != nil { return true }
            if rightIndex != nil { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    static func availableTags(from profiles: [ServerProfile]) -> [String] {
        normalizeTags(builtInTags + profiles.flatMap(\.tags))
    }

    static func displayName(forGroup group: String) -> String {
        guard group == defaultGroup else { return group }
        return AppLanguage.text(chinese: defaultGroup, english: "Default Group")
    }

    static func displayName(forTag tag: String) -> String {
        switch tag {
        case lanTag: AppLanguage.text(chinese: lanTag, english: "LAN")
        case wanTag: AppLanguage.text(chinese: wanTag, english: "WAN")
        default: tag
        }
    }
}
