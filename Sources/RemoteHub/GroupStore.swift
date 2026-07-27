import Foundation

struct GroupStore {
    private let key = "connectionGroups.v1"

    func load(profileGroups: [String]) -> [String] {
        normalized((UserDefaults.standard.stringArray(forKey: key) ?? []) + profileGroups + ["默认分组"])
    }

    func save(_ groups: [String]) {
        UserDefaults.standard.set(normalized(groups), forKey: key)
    }

    private func normalized(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        let cleaned = values.compactMap { value -> String? in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
        return cleaned.sorted { lhs, rhs in
            if lhs == "默认分组" { return true }
            if rhs == "默认分组" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}
