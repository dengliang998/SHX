import AppKit
import CryptoKit
import Foundation

struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let rawComponents = normalized.split(separator: ".")
        guard (1...3).contains(rawComponents.count),
              rawComponents.allSatisfy({ Int($0) != nil }) else { return nil }
        let components = rawComponents.compactMap { Int($0) } + Array(repeating: 0, count: 3 - rawComponents.count)
        major = components[0]
        minor = components[1]
        patch = components[2]
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct UpdateManifest: Codable, Sendable {
    let product: String
    let version: String
    let build: Int
    let assetName: String
    let sha256: String
    let minimumSystemVersion: String
    let signature: String

    var signingPayload: Data {
        Data(
            [product, version, String(build), assetName, sha256.lowercased(), minimumSystemVersion]
                .joined(separator: "\n")
                .utf8
        )
    }

    func verifies(publicKeyBase64: String) -> Bool {
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let signatureData = Data(base64Encoded: signature),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: signingPayload)
    }
}

struct AvailableAppUpdate: Sendable {
    let version: String
    let build: Int
    let releasePageURL: URL
    let downloadURL: URL
    let manifest: UpdateManifest
}

enum UpdateCheckResult: Sendable {
    case upToDate
    case available(AvailableAppUpdate)
}

enum SoftwareUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(version: String)
    case preparing
    case failed(String)

    var summary: String {
        switch self {
        case .idle: "Updates have not been checked yet"
        case .checking: "Checking GitHub Releases…"
        case .upToDate: "KiteShell is up to date"
        case .available(let version): "KiteShell \(version) is available"
        case .downloading(let version): "Downloading KiteShell \(version)…"
        case .preparing: "Verifying and preparing the update…"
        case .failed(let message): message
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .preparing: true
        default: false
        }
    }
}

enum GitHubReleaseUpdaterError: LocalizedError {
    case invalidResponse
    case noRelease
    case missingManifest
    case invalidManifest
    case incompatibleSystem(String)
    case missingAsset
    case checksumMismatch
    case cannotMount(String)
    case invalidApplication
    case updaterMissing
    case installLocationNotWritable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "GitHub returned an unrecognized response."
        case .noRelease: "No stable KiteShell release is available on GitHub."
        case .missingManifest: "The release does not include an update manifest."
        case .invalidManifest: "The update manifest is invalid or has an invalid signature. Installation was stopped."
        case .incompatibleSystem(let version): "This update requires macOS \(version) or later."
        case .missingAsset: "The release does not include the installation image named by the signed manifest."
        case .checksumMismatch: "The installation image failed SHA-256 verification. Installation was stopped."
        case .cannotMount(let detail): "The update image could not be mounted: \(detail)"
        case .invalidApplication: "The update image does not contain a valid KiteShell.app."
        case .updaterMissing: "This KiteShell build does not contain the updater helper."
        case .installLocationNotWritable: "The current installation folder is not writable. Install this release manually."
        }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease, assets
    }
}

struct PreparedAppUpdate: Sendable {
    let helperURL: URL
    let sourceApplicationURL: URL
    let destinationApplicationURL: URL
    let mountPoint: URL
    let workspaceURL: URL
}

struct GitHubReleaseUpdater: Sendable {
    static let repository = "jinwang-aibai/KiteShell"
    static let manifestAssetName = "KiteShell-update.json"

    func check(currentVersion: String, currentBuild: Int) async throws -> UpdateCheckResult {
        let releaseURL = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        let releaseData = try await requestData(from: releaseURL)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)
        guard !release.draft, !release.prerelease else { throw GitHubReleaseUpdaterError.noRelease }
        guard let manifestAsset = release.assets.first(where: { $0.name == Self.manifestAssetName }) else {
            throw GitHubReleaseUpdaterError.missingManifest
        }
        let manifestData = try await requestData(from: manifestAsset.browserDownloadURL)
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: manifestData)
        guard manifest.product == "KiteShell",
              manifest.version == release.tagName.trimmingPrefix("v"),
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "KiteShellUpdatePublicKey") as? String,
              manifest.verifies(publicKeyBase64: publicKey) else {
            throw GitHubReleaseUpdaterError.invalidManifest
        }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let installedSystemVersion = SemanticVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
        guard let minimumSystemVersion = SemanticVersion(manifest.minimumSystemVersion),
              let installedSystemVersion,
              installedSystemVersion >= minimumSystemVersion else {
            throw GitHubReleaseUpdaterError.incompatibleSystem(manifest.minimumSystemVersion)
        }
        guard let package = release.assets.first(where: { $0.name == manifest.assetName }) else {
            throw GitHubReleaseUpdaterError.missingAsset
        }

        let remoteVersion = SemanticVersion(manifest.version)
        let localVersion = SemanticVersion(currentVersion)
        let isNewer = if let remoteVersion, let localVersion {
            remoteVersion > localVersion || (remoteVersion == localVersion && manifest.build > currentBuild)
        } else {
            manifest.build > currentBuild
        }
        guard isNewer else { return .upToDate }
        return .available(
            AvailableAppUpdate(
                version: manifest.version,
                build: manifest.build,
                releasePageURL: release.htmlURL,
                downloadURL: package.browserDownloadURL,
                manifest: manifest
            )
        )
    }

    func prepareInstallation(_ update: AvailableAppUpdate) async throws -> PreparedAppUpdate {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "KiteShell-Update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var mountedPoint: URL?
        do {
            let downloaded = try await download(from: update.downloadURL)
            let imageURL = workspace.appending(path: update.manifest.assetName)
            try FileManager.default.moveItem(at: downloaded, to: imageURL)
            let digest = try await Task.detached(priority: .utility) {
                try Self.sha256(of: imageURL)
            }.value
            guard digest.caseInsensitiveCompare(update.manifest.sha256) == .orderedSame else {
                throw GitHubReleaseUpdaterError.checksumMismatch
            }

            let mountPoint = try await Task.detached(priority: .utility) {
                try Self.mount(imageURL)
            }.value
            mountedPoint = mountPoint
            guard let sourceApp = Self.findApplication(in: mountPoint) else {
                throw GitHubReleaseUpdaterError.invalidApplication
            }
            guard let helper = Bundle.main.url(forResource: "KiteShellUpdater", withExtension: nil) else {
                throw GitHubReleaseUpdaterError.updaterMissing
            }
            let copiedHelper = workspace.appending(path: "KiteShellUpdater")
            try FileManager.default.copyItem(at: helper, to: copiedHelper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copiedHelper.path)

            let destination = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
                throw GitHubReleaseUpdaterError.installLocationNotWritable
            }
            return PreparedAppUpdate(
                helperURL: copiedHelper,
                sourceApplicationURL: sourceApp,
                destinationApplicationURL: destination,
                mountPoint: mountPoint,
                workspaceURL: workspace
            )
        } catch {
            if let mountedPoint {
                _ = try? Self.detach(mountedPoint)
            }
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    @MainActor
    func launchInstaller(_ prepared: PreparedAppUpdate) throws {
        let process = Process()
        process.executableURL = prepared.helperURL
        process.arguments = [
            "--source", prepared.sourceApplicationURL.path,
            "--destination", prepared.destinationApplicationURL.path,
            "--pid", String(ProcessInfo.processInfo.processIdentifier),
            "--mount-point", prepared.mountPoint.path,
            "--workspace", prepared.workspaceURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApplication.shared.terminate(nil)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func requestData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KiteShell/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GitHubReleaseUpdaterError.invalidResponse
        }
        return data
    }

    private func download(from url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("KiteShell/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        let (location, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GitHubReleaseUpdaterError.invalidResponse
        }
        return location
    }

    private static func mount(_ imageURL: URL) throws -> URL {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", imageURL.path, "-nobrowse", "-readonly", "-plist"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            let detail = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubReleaseUpdaterError.cannotMount(detail)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func detach(_ mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private static func findApplication(in mountPoint: URL) -> URL? {
        let direct = mountPoint.appending(path: "KiteShell.app", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return try? FileManager.default.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "app" && $0.lastPathComponent == "KiteShell.app" })
    }
}
