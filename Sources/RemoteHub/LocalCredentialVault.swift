import CryptoKit
import Foundation

struct LocalCredentialVault {
    enum VaultError: LocalizedError {
        case invalidKey
        case missingKey
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                "本地凭据密钥已损坏。"
            case .missingKey:
                "本地凭据密钥不存在，无法读取已有凭据。"
            case .invalidPayload:
                "本地凭据文件无法解密或内容已损坏。"
            }
        }
    }

    private struct Payload: Codable {
        var schemaVersion = 1
        var entries: [String: Data] = [:]
    }

    private let directoryURL: URL
    private let keyURL: URL
    private let vaultURL: URL

    init(baseDirectory: URL? = nil) {
        let directory: URL
        if let baseDirectory {
            directory = baseDirectory
        } else {
            directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appending(path: "SHX", directoryHint: .isDirectory)
                .appending(path: "Credentials", directoryHint: .isDirectory)
        }
        directoryURL = directory
        keyURL = directory.appending(path: ".local-key", directoryHint: .notDirectory)
        vaultURL = directory.appending(path: "credentials.vault", directoryHint: .notDirectory)
    }

    func save(_ secret: Data, account: String) throws {
        var payload = try loadPayload()
        payload.entries[account] = secret
        try write(payload)
    }

    func read(account: String) throws -> Data? {
        try loadPayload().entries[account]
    }

    func remove(account: String) throws {
        var payload = try loadPayload()
        guard payload.entries.removeValue(forKey: account) != nil else { return }
        try write(payload)
    }

    func savePassword(_ password: String, profileID: UUID) throws {
        try save(Data(password.utf8), account: "password:\(profileID.uuidString)")
    }

    func readPassword(profileID: UUID) throws -> String? {
        guard let data = try read(account: "password:\(profileID.uuidString)") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removePassword(profileID: UUID) throws {
        try remove(account: "password:\(profileID.uuidString)")
    }

    func savePrivateKeyPassphrase(_ passphrase: String, profileID: UUID) throws {
        try save(Data(passphrase.utf8), account: "private-key:\(profileID.uuidString)")
    }

    func readPrivateKeyPassphrase(profileID: UUID) throws -> String? {
        guard let data = try read(account: "private-key:\(profileID.uuidString)") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removePrivateKeyPassphrase(profileID: UUID) throws {
        try remove(account: "private-key:\(profileID.uuidString)")
    }

    private func loadPayload() throws -> Payload {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return Payload() }
        let key = try loadOrCreateKey()
        do {
            let combined = try Data(contentsOf: vaultURL)
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            guard payload.schemaVersion == 1 else { throw VaultError.invalidPayload }
            return payload
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.invalidPayload
        }
    }

    private func write(_ payload: Payload) throws {
        try prepareDirectory()
        let key = try loadOrCreateKey()
        let plaintext = try JSONEncoder().encode(payload)
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else { throw VaultError.invalidPayload }
        try combined.write(to: vaultURL, options: .atomic)
        try setPermissions(0o600, at: vaultURL)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else { throw VaultError.invalidKey }
            return SymmetricKey(data: data)
        }
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            throw VaultError.missingKey
        }
        try prepareDirectory()
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        try data.write(to: keyURL, options: .withoutOverwriting)
        try setPermissions(0o600, at: keyURL)
        return SymmetricKey(data: data)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(0o700, at: directoryURL)
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}

enum PrivateKeyInspector {
    static func requiresPassphrase(at path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = FileManager.default.contents(atPath: trimmed),
              let text = String(data: data, encoding: .utf8) else { return false }
        if text.contains("BEGIN ENCRYPTED PRIVATE KEY") || text.contains("Proc-Type: 4,ENCRYPTED") {
            return true
        }
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }
        let encoded = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let payload = Data(base64Encoded: encoded) else { return false }
        let magic = Data("openssh-key-v1\0".utf8)
        guard payload.starts(with: magic), payload.count >= magic.count + 4 else { return false }
        var offset = magic.count
        let lengthData = payload[offset..<(offset + 4)]
        let length = lengthData.reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard length > 0, payload.count >= offset + length,
              let cipher = String(data: payload[offset..<(offset + length)], encoding: .utf8) else {
            return false
        }
        return cipher != "none"
    }
}
