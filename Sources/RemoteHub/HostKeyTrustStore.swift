import CryptoKit
import Foundation

struct TrustedHostRecord: Identifiable, Hashable, Sendable {
    var id: String { "\(host):\(algorithm):\(fingerprint)" }
    let host: String
    let algorithm: String
    let fingerprint: String
}

enum HostKeyTrustStore {
    static var knownHostsURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return base
            .appending(path: "KiteShell", directoryHint: .isDirectory)
            .appending(path: "known_hosts", directoryHint: .notDirectory)
    }

    static var userKnownHostsSSHOption: String? {
        guard let path = try? prepareKnownHostsFile().path else { return nil }
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "UserKnownHostsFile=\"\(escaped)\""
    }

    static func isTrusted(_ profile: ServerProfile) -> Bool {
        !trustedLines(for: profile).isEmpty
    }

    static func forget(profile: ServerProfile) throws {
        try forget(hostSpecifier: hostSpecifier(profile))
    }

    static func trustedHostRecords() -> [TrustedHostRecord] {
        guard let knownHostsURL,
              let text = try? String(contentsOf: knownHostsURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3,
                  let keyData = Data(base64Encoded: String(parts[2])) else { return nil }
            let digest = Data(SHA256.hash(data: keyData))
                .base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
            return TrustedHostRecord(
                host: String(parts[0]),
                algorithm: String(parts[1]),
                fingerprint: "SHA256:\(digest)"
            )
        }
    }

    static func forget(hostSpecifier: String) throws {
        let url = try prepareKnownHostsFile()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let kept = text.components(separatedBy: .newlines).filter { line in
            guard let field = line.split(separator: " ").first else { return false }
            return !field.split(separator: ",").contains(Substring(hostSpecifier))
        }
        try writeKnownHosts(kept.filter { !$0.isEmpty }.joined(separator: "\n") + "\n", to: url)
    }

    private static func prepareKnownHostsFile() throws -> URL {
        guard let knownHostsURL else { throw CocoaError(.fileNoSuchFile) }
        let directory = knownHostsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            try Data().write(to: knownHostsURL, options: [.atomic, .withoutOverwriting])
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: knownHostsURL.path
        )
        return knownHostsURL
    }

    private static func writeKnownHosts(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func trustedLines(for profile: ServerProfile) -> [String] {
        guard let knownHostsURL,
              let text = try? String(contentsOf: knownHostsURL, encoding: .utf8) else { return [] }
        let specifier = hostSpecifier(profile)
        return text.components(separatedBy: .newlines).filter { line in
            guard let field = line.split(separator: " ").first else { return false }
            return field.split(separator: ",").contains(Substring(specifier))
        }
    }

    private static func hostSpecifier(_ profile: ServerProfile) -> String {
        profile.port == 22 ? profile.host : "[\(profile.host)]:\(profile.port)"
    }
}
