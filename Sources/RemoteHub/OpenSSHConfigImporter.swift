import Foundation

struct OpenSSHImportPayload: Sendable {
    let profiles: [ServerProfile]
    let skippedHosts: Int
}

enum OpenSSHConfigImporter {
    private struct Block {
        var aliases: [String] = []
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?
    }

    static func load(urls: [URL]) async -> OpenSSHImportPayload {
        await Task.detached(priority: .utility) {
            var profiles: [ServerProfile] = []
            var skipped = 0
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    skipped += 1
                    continue
                }
                let result = parse(text)
                profiles.append(contentsOf: result.profiles)
                skipped += result.skippedHosts
            }
            return OpenSSHImportPayload(profiles: profiles, skippedHosts: skipped)
        }.value
    }

    static func parse(_ text: String) -> OpenSSHImportPayload {
        var blocks: [Block] = []
        var current: Block?

        for rawLine in text.components(separatedBy: .newlines) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let keyword = parts[0].lowercased()
            let value = parts.dropFirst().joined(separator: " ")

            if keyword == "host" {
                if let current { blocks.append(current) }
                let aliases = parts.dropFirst().map(String.init).filter {
                    !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!")
                }
                current = Block(aliases: aliases)
                continue
            }

            guard current != nil else { continue }
            switch keyword {
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = Int(value)
            case "identityfile": current?.identityFile = expandHome(value)
            default: break
            }
        }
        if let current { blocks.append(current) }

        var profiles: [ServerProfile] = []
        var skipped = 0
        for block in blocks {
            for alias in block.aliases {
                let host = block.hostName ?? alias
                guard !host.isEmpty, let user = block.user, !user.isEmpty else {
                    skipped += 1
                    continue
                }
                let identityFile = block.identityFile ?? ""
                profiles.append(
                    ServerProfile(
                        name: alias,
                        host: host,
                        port: block.port ?? 22,
                        username: user,
                        authentication: identityFile.isEmpty ? .sshAgent : .privateKey,
                        group: "OpenSSH",
                        identityFilePath: identityFile
                    )
                )
            }
        }
        return OpenSSHImportPayload(profiles: profiles, skippedHosts: skipped)
    }

    private static func expandHome(_ value: String) -> String {
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if unquoted == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if unquoted.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appending(path: String(unquoted.dropFirst(2)))
                .path
        }
        return unquoted
    }
}
