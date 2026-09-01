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

struct KiteShellImportPayload: Sendable {
    let profiles: [ServerProfile]
    let groups: [String]
    let globalCommands: [QuickCommand]
    let skippedFiles: Int
}

enum ProfileExchangeError: LocalizedError {
    case unsupportedArchive
    case unsupportedSchema(Int)
    case noProfiles

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive:
            "这不是可识别的 SHX 配置文件。"
        case .unsupportedSchema(let version):
            "配置文件版本（\(version)）高于当前应用支持的版本。"
        case .noProfiles:
            "配置文件中没有可导入的连接。"
        }
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

    static func load(urls: [URL]) async -> KiteShellImportPayload {
        await Task.detached(priority: .utility) {
            var profiles: [ServerProfile] = []
            var groups: [String] = []
            var globalCommands: [QuickCommand] = []
            var skippedFiles = 0

            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let archive = try decoder.decode(KiteShellConfigurationArchive.self, from: data)
                    guard archive.product == "SHX" else {
                        skippedFiles += 1
                        continue
                    }
                    guard archive.schemaVersion <= KiteShellConfigurationArchive.currentSchemaVersion else {
                        skippedFiles += 1
                        continue
                    }
                    profiles.append(contentsOf: archive.profiles.map { profile in
                        var imported = profile
                        imported.identityFileBookmark = nil
                        imported.updatedAt = Date()
                        return imported
                    })
                    groups.append(contentsOf: archive.groups ?? [])
                    globalCommands.append(contentsOf: archive.globalCommands ?? [])
                } catch {
                    skippedFiles += 1
                }
            }

            return KiteShellImportPayload(
                profiles: profiles,
                groups: Array(Set(groups)).sorted(),
                globalCommands: globalCommands,
                skippedFiles: skippedFiles
            )
        }.value
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
