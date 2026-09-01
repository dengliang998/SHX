import Foundation

struct KiteShellConfigurationArchive: Codable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let product: String
    let exportedAt: Date
    let profiles: [ServerProfile]
    let groups: [String]?
    let globalCommands: [QuickCommand]?

    init(profiles: [ServerProfile], groups: [String] = [], globalCommands: [QuickCommand] = []) {
        schemaVersion = Self.currentSchemaVersion
        product = "SHX"
        exportedAt = Date()
        self.profiles = profiles.map { profile in
            var copy = profile
            // Security-scoped bookmarks are local capabilities and must never be exported.
            copy.identityFileBookmark = nil
            return copy
        }
        self.groups = groups
        self.globalCommands = globalCommands
    }
}

enum ProfileExchangeService {
    static func write(
        profiles: [ServerProfile],
        groups: [String] = [],
        globalCommands: [QuickCommand] = [],
        to url: URL
    ) throws {
        let archive = KiteShellConfigurationArchive(profiles: profiles, groups: groups, globalCommands: globalCommands)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(archive).write(to: url, options: .atomic)
    }

}

struct ConnectionProbeResult: Sendable {
    let isReachable: Bool
    let summary: String
    let technicalDetail: String
}

enum ConnectionProbe {
    static func test(host: String, port: Int, timeout: Int) async -> ConnectionProbeResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = [
                "-vz",
                "-G", String(max(1, min(timeout, 60))),
                host,
                String(port)
            ]
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ConnectionProbeResult(
                    isReachable: false,
                    summary: "无法启动网络测试",
                    technicalDetail: error.localizedDescription
                )
            }

            let combined = [
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus == 0 {
                return ConnectionProbeResult(
                    isReachable: true,
                    summary: "地址与端口可以访问",
                    technicalDetail: combined
                )
            }

            let lowercased = combined.lowercased()
            let summary: String
            if lowercased.contains("nodename nor servname") || lowercased.contains("name or service not known") {
                summary = "无法解析服务器地址"
            } else if lowercased.contains("timed out") || lowercased.contains("operation timed out") {
                summary = "连接服务器超时"
            } else if lowercased.contains("refused") {
                summary = "服务器拒绝了端口连接"
            } else if lowercased.contains("no route") {
                summary = "没有到服务器的网络路由"
            } else {
                summary = "地址或端口暂时无法访问"
            }
            return ConnectionProbeResult(
                isReachable: false,
                summary: summary,
                technicalDetail: combined
            )
        }.value
    }
}
