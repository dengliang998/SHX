import AppKit
import CryptoKit
import Foundation
import SwiftTerm
import Testing
@testable import RemoteHub

struct ModelsTests {
    @Test
    func terminalClipboardShortcutsUseStandardMacModifiers() {
        #expect(TerminalClipboardShortcut.resolve(characters: "c", modifiers: .command) == .copy)
        #expect(TerminalClipboardShortcut.resolve(characters: "V", modifiers: .command) == .paste)
        #expect(TerminalClipboardShortcut.resolve(characters: "c", modifiers: [.command, .shift]) == nil)
        #expect(TerminalClipboardShortcut.resolve(characters: "c", modifiers: .control) == nil)
    }

    @MainActor
    @Test
    func terminalCommandCCopiesTheActiveSelection() throws {
        let pasteboard = NSPasteboard.general
        let previousValue = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousValue {
                pasteboard.setString(previousValue, forType: .string)
            }
        }

        let terminal = ObservedLocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = terminal
        #expect(window.makeFirstResponder(terminal))
        terminal.feed(text: "KiteShell clipboard regression test")
        terminal.selectAll(nil)
        pasteboard.clearContents()

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )
        #expect(terminal.performKeyEquivalent(with: event))
        #expect(pasteboard.string(forType: .string)?.contains("KiteShell clipboard regression test") == true)
    }

    @MainActor
    @Test
    func terminalDoesNotCaptureClipboardShortcutsFromTextFields() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let terminal = ObservedLocalProcessTerminalView(
            frame: NSRect(x: 0, y: 40, width: 640, height: 320)
        )
        let textField = NSTextField(frame: NSRect(x: 12, y: 8, width: 300, height: 24))
        container.addSubview(terminal)
        container.addSubview(textField)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        #expect(window.makeFirstResponder(textField))

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )
        )
        #expect(!terminal.performKeyEquivalent(with: event))
        #expect(window.firstResponder !== terminal)
    }

    @Test
    func quickConnectionParserSupportsHostnameAndIPv6() {
        #expect(QuickConnectionParser.parse("deploy@example.com:2222") == QuickConnectionAddress(username: "deploy", host: "example.com", port: 2222))
        #expect(QuickConnectionParser.parse("root@[2001:db8::1]:2200") == QuickConnectionAddress(username: "root", host: "2001:db8::1", port: 2200))
        #expect(QuickConnectionParser.parse("admin@192.168.1.2") == QuickConnectionAddress(username: "admin", host: "192.168.1.2", port: 22))
        #expect(QuickConnectionParser.parse("example.com") == nil)
        #expect(QuickConnectionParser.parse("root@example.com:70000") == nil)
    }

    @Test
    func defaultSSHPortIsOmittedFromDisplayAddress() {
        let profile = ServerProfile(name: "Example", host: "example.com", username: "deploy")
        #expect(profile.displayAddress == "deploy@example.com")
    }

    @Test
    func customSSHPortIsIncludedInDisplayAddress() {
        let profile = ServerProfile(name: "Example", host: "example.com", port: 2222, username: "deploy")
        #expect(profile.displayAddress == "deploy@example.com:2222")
    }

    @Test
    func connectionStateHasTruthfulLabels() {
        #expect(ConnectionState.connecting.label == "连接中")
        #expect(ConnectionState.connected.label == "已连接")
        #expect(ConnectionState.failed.label == "连接失败")
    }

    @Test
    func legacyProfilesDecodeWithoutQuickCommands() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy",
          "host": "legacy.example.com",
          "port": 22,
          "username": "root",
          "authentication": "私钥",
          "group": "默认分组",
          "tags": [],
          "notes": "",
          "isFavorite": false
        }
        """
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.id == id)
        #expect(profile.quickCommands.isEmpty)
        #expect(profile.connectionTimeout == 10)
        #expect(profile.keepAliveInterval == 15)
        #expect(profile.reconnectPolicy == .threeTimes)
        #expect(profile.identityFilePath.isEmpty)
    }

    @Test
    func profileAdvancedSettingsSurviveRoundTrip() throws {
        let profile = ServerProfile(
            name: "Advanced",
            host: "10.0.0.8",
            port: 2222,
            username: "deploy",
            authentication: .privateKey,
            tags: ["production", "api"],
            notes: "Primary API",
            identityFilePath: "/Users/example/.ssh/id_ed25519",
            connectionTimeout: 21,
            keepAliveInterval: 30,
            startupDirectory: "/srv/api",
            initializationCommand: "source /etc/profile.d/app.sh",
            runsInitializationCommand: true,
            reconnectPolicy: .continuous
        )
        let decoded = try JSONDecoder().decode(
            ServerProfile.self,
            from: JSONEncoder().encode(profile)
        )
        #expect(decoded.identityFilePath == profile.identityFilePath)
        #expect(decoded.connectionTimeout == 21)
        #expect(decoded.keepAliveInterval == 30)
        #expect(decoded.startupDirectory == "/srv/api")
        #expect(decoded.initializationCommand == "source /etc/profile.d/app.sh")
        #expect(decoded.runsInitializationCommand)
        #expect(decoded.reconnectPolicy == .continuous)
        #expect(decoded.tags == ["production", "api"])
    }

    @Test
    func configurationExportRemovesSecurityScopedBookmark() throws {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "kiteshell-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let profile = ServerProfile(
            name: "Export",
            host: "example.com",
            username: "root",
            identityFilePath: "/Users/example/.ssh/id_ed25519",
            identityFileBookmark: Data([1, 2, 3, 4])
        )
        try ProfileExchangeService.write(profiles: [profile], to: output)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(
            KiteShellConfigurationArchive.self,
            from: Data(contentsOf: output)
        )
        #expect(archive.schemaVersion == KiteShellConfigurationArchive.currentSchemaVersion)
        #expect(archive.profiles.count == 1)
        #expect(archive.profiles[0].identityFileBookmark == nil)
        #expect(archive.profiles[0].identityFilePath == profile.identityFilePath)
    }

    @Test
    func configurationExportIncludesGroupsAndGlobalCommands() throws {
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }
        let command = QuickCommand(name: "Deploy", command: "./deploy.sh")
        try ProfileExchangeService.write(
            profiles: [],
            groups: ["生产环境"],
            globalCommands: [command],
            to: output
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(KiteShellConfigurationArchive.self, from: Data(contentsOf: output))
        #expect(archive.groups == ["生产环境"])
        #expect(archive.globalCommands == [command])
    }

    @Test
    func remoteVersionCommandSafelyQuotesPath() {
        let command = RemoteFileService.versionCommand(path: "/srv/it's/app.conf")
        #expect(command.contains("'/srv/it'\"'\"'s/app.conf'"))
    }

    @Test
    func knownHostsOptionQuotesApplicationSupportPath() {
        let option = HostKeyTrustStore.userKnownHostsSSHOption
        #expect(option?.hasPrefix("UserKnownHostsFile=\"") == true)
        #expect(option?.hasSuffix("KiteShell/known_hosts\"") == true)
        #expect(option?.contains("Application Support") == true)
    }

    @Test
    func localCredentialVaultEncryptsAndRestrictsFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kiteshell-vault-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vault = LocalCredentialVault(baseDirectory: directory)
        let profileID = UUID()
        let secret = "local-vault-secret-that-must-not-be-plain-text"
        try vault.savePassword(secret, profileID: profileID)

        #expect(try vault.readPassword(profileID: profileID) == secret)
        let encrypted = try Data(contentsOf: directory.appending(path: "credentials.vault"))
        #expect(encrypted.range(of: Data(secret.utf8)) == nil)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: "credentials.vault").path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }

    @Test
    func finalShellPasswordDecoderMatchesJavaReference() {
        let encoded = "eU15IxpjG1olIXZEeBsWK3AyLhO4+e3E8nqkLx+Sp77fvvwY0vmkcQ=="
        #expect(FinalShellPasswordDecoder.decode(encoded) == "KiteShell-FinalShell-Test-2026!")
        #expect(FinalShellPasswordDecoder.decode("not-base64") == nil)
    }

    @Test
    func semanticVersionsUseNumericOrdering() {
        #expect(SemanticVersion("1.0.1")! > SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("v2.0.0")! > SemanticVersion("1.99.99")!)
        #expect(SemanticVersion("1.0.0-beta") == SemanticVersion("1.0.0"))
        #expect(SemanticVersion("14.0") == SemanticVersion("14.0.0"))
        #expect(SemanticVersion("invalid") == nil)
    }

    @Test
    func updateManifestRequiresMatchingEd25519Signature() throws {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((0..<32).map(UInt8.init))
        )
        let unsigned = UpdateManifest(
            product: "KiteShell",
            version: "1.0.1",
            build: 101,
            assetName: "KiteShell-1.0.1.dmg",
            sha256: String(repeating: "a", count: 64),
            minimumSystemVersion: "14.0",
            signature: ""
        )
        let signature = try privateKey.signature(for: unsigned.signingPayload).base64EncodedString()
        let signed = UpdateManifest(
            product: unsigned.product,
            version: unsigned.version,
            build: unsigned.build,
            assetName: unsigned.assetName,
            sha256: unsigned.sha256,
            minimumSystemVersion: unsigned.minimumSystemVersion,
            signature: signature
        )
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        #expect(signed.verifies(publicKeyBase64: publicKey))

        let tampered = UpdateManifest(
            product: signed.product,
            version: "1.0.2",
            build: signed.build,
            assetName: signed.assetName,
            sha256: signed.sha256,
            minimumSystemVersion: signed.minimumSystemVersion,
            signature: signed.signature
        )
        #expect(!tampered.verifies(publicKeyBase64: publicKey))
    }

    @Test
    func connectionOrganizationProvidesBuiltInTagsAndStableNormalization() {
        let profile = ServerProfile(
            name: "Fixture",
            host: "127.0.0.1",
            username: "tester",
            tags: [" Production ", "内网", "Production", ""]
        )
        #expect(ConnectionOrganization.normalizeTags(profile.tags) == ["内网", "Production"])
        #expect(ConnectionOrganization.availableTags(from: [profile]) == ["内网", "外网", "Production"])
    }

    @Test
    func updaterChecksSignedReleaseFixtureEndToEnd() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifestURL = URL(string: "https://fixtures.example/KiteShell-update.json")!
        let downloadURL = URL(string: "https://fixtures.example/KiteShell-1.1.0.dmg")!
        let latestURL = URL(string: "https://fixtures.example/releases/latest")!
        let unsigned = UpdateManifest(
            product: "KiteShell",
            version: "1.1.0",
            build: 110,
            assetName: "KiteShell-1.1.0.dmg",
            sha256: String(repeating: "a", count: 64),
            minimumSystemVersion: "14.0",
            signature: ""
        )
        let manifest = UpdateManifest(
            product: unsigned.product,
            version: unsigned.version,
            build: unsigned.build,
            assetName: unsigned.assetName,
            sha256: unsigned.sha256,
            minimumSystemVersion: unsigned.minimumSystemVersion,
            signature: try privateKey.signature(for: unsigned.signingPayload).base64EncodedString()
        )
        let releaseData = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.1.0",
            "html_url": "https://github.com/jinwang-aibai/KiteShell/releases/tag/v1.1.0",
            "draft": false,
            "prerelease": false,
            "assets": [
                ["name": "KiteShell-update.json", "browser_download_url": manifestURL.absoluteString],
                ["name": "KiteShell-1.1.0.dmg", "browser_download_url": downloadURL.absoluteString],
            ],
        ])
        let manifestData = try JSONEncoder().encode(manifest)
        let fixtures = [latestURL: releaseData, manifestURL: manifestData]
        let updater = GitHubReleaseUpdater(
            configuration: GitHubReleaseUpdaterConfiguration(
                latestReleaseURL: latestURL,
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
            ),
            dataLoader: { url in
                guard let data = fixtures[url] else { throw GitHubReleaseUpdaterError.invalidResponse }
                return data
            }
        )

        let result = try await updater.check(currentVersion: "1.0.0", currentBuild: 101)
        switch result {
        case .available(let update):
            #expect(update.version == "1.1.0")
            #expect(update.build == 110)
            #expect(update.downloadURL == downloadURL)
        case .upToDate:
            Issue.record("A newer signed release should be available")
        }

        let upToDate = try await updater.check(currentVersion: "1.1.0", currentBuild: 110)
        if case .available = upToDate {
            Issue.record("The installed release should be up to date")
        }
    }

    @Test
    func updaterReportsUnavailableReleaseSourceClearly() async {
        let updater = GitHubReleaseUpdater(
            configuration: GitHubReleaseUpdaterConfiguration(
                latestReleaseURL: URL(string: "https://fixtures.example/releases/latest")!,
                publicKeyBase64: "fixture"
            ),
            dataLoader: { _ in throw GitHubReleaseUpdaterError.releaseSourceUnavailable(404) }
        )
        do {
            _ = try await updater.check(currentVersion: "1.0.0", currentBuild: 100)
            Issue.record("An unavailable release source must fail")
        } catch let error as GitHubReleaseUpdaterError {
            guard case .releaseSourceUnavailable(let status) = error else {
                Issue.record("Unexpected updater error: \(error)")
                return
            }
            #expect(status == 404)
            #expect(error.localizedDescription.contains("404"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func updaterRejectsUnsignedManifestFixture() async throws {
        let latestURL = URL(string: "https://fixtures.example/releases/latest")!
        let manifestURL = URL(string: "https://fixtures.example/KiteShell-update.json")!
        let releaseData = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.1.0",
            "html_url": "https://fixtures.example/releases/v1.1.0",
            "draft": false,
            "prerelease": false,
            "assets": [
                ["name": "KiteShell-update.json", "browser_download_url": manifestURL.absoluteString],
                ["name": "KiteShell-1.1.0.dmg", "browser_download_url": "https://fixtures.example/KiteShell-1.1.0.dmg"],
            ],
        ])
        let manifestData = try JSONEncoder().encode(UpdateManifest(
            product: "KiteShell",
            version: "1.1.0",
            build: 110,
            assetName: "KiteShell-1.1.0.dmg",
            sha256: String(repeating: "a", count: 64),
            minimumSystemVersion: "14.0",
            signature: Data(repeating: 0, count: 64).base64EncodedString()
        ))
        let fixtures = [latestURL: releaseData, manifestURL: manifestData]
        let updater = GitHubReleaseUpdater(
            configuration: GitHubReleaseUpdaterConfiguration(
                latestReleaseURL: latestURL,
                publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            ),
            dataLoader: { url in
                guard let data = fixtures[url] else { throw GitHubReleaseUpdaterError.invalidResponse }
                return data
            }
        )
        do {
            _ = try await updater.check(currentVersion: "1.0.0", currentBuild: 100)
            Issue.record("An unsigned manifest must never be accepted")
        } catch let error as GitHubReleaseUpdaterError {
            guard case .invalidManifest = error else {
                Issue.record("Unexpected updater error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func connectionValidationExplainsInvalidFields() {
        let profile = ServerProfile(
            name: "Invalid",
            host: "",
            port: 70_000,
            username: "",
            startupDirectory: "relative/path"
        )
        let issues = ConnectionDiagnosticService.validate(profile)
        #expect(issues.count == 4)
        #expect(issues.contains("主机为空"))
        #expect(issues.contains("用户名为空"))
    }

    @Test
    func quickCommandsSurviveProfileRoundTrip() throws {
        let command = QuickCommand(name: "查看日志", command: "cd /var/log\ntail -n 50 system.log")
        let profile = ServerProfile(
            name: "Example",
            host: "example.com",
            username: "deploy",
            quickCommands: [command]
        )
        let decoded = try JSONDecoder().decode(
            ServerProfile.self,
            from: JSONEncoder().encode(profile)
        )
        #expect(decoded.quickCommands == [command])
    }

    @Test
    func quickCommandVariablesResolveAndLegacyDefaultsRemainSafe() throws {
        let command = QuickCommand(
            name: "Deploy",
            command: "cd /srv/${service}\nsystemctl restart ${service}",
            executionMode: .insert,
            tags: ["deploy"]
        )
        #expect(command.variableNames == ["service"])
        #expect(command.resolving(variables: ["service": "api"]).contains("/srv/api"))
        #expect(command.executionMode == .insert)

        let legacy = try JSONDecoder().decode(
            QuickCommand.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","command":"uptime"}"#.utf8)
        )
        #expect(legacy.executionMode == .confirm)
        #expect(legacy.tags.isEmpty)
    }

    @Test
    func openSSHConfigImportExpandsAliasesAndIdentityFile() {
        let payload = OpenSSHConfigImporter.parse(
            """
            Host production-api
              HostName 10.0.0.12
              User deploy
              Port 2222
              IdentityFile ~/.ssh/id_ed25519

            Host *.internal
              User root
            """
        )
        #expect(payload.profiles.count == 1)
        #expect(payload.profiles[0].name == "production-api")
        #expect(payload.profiles[0].host == "10.0.0.12")
        #expect(payload.profiles[0].port == 2222)
        #expect(payload.profiles[0].authentication == .privateKey)
        #expect(payload.profiles[0].identityFilePath.hasSuffix("/.ssh/id_ed25519"))
    }

    @Test
    func portForwardSpecificationsMatchOpenSSHSyntax() {
        let local = PortForwardConfiguration(
            name: "Web",
            kind: .local,
            bindAddress: "127.0.0.1",
            listenPort: 8080,
            targetHost: "127.0.0.1",
            targetPort: 80,
            isEnabled: true
        )
        let socks = PortForwardConfiguration(
            name: "SOCKS",
            kind: .dynamic,
            bindAddress: "127.0.0.1",
            listenPort: 1080,
            targetHost: "",
            targetPort: 0,
            isEnabled: false
        )
        #expect(local.isValid)
        #expect(local.kind.sshFlag == "-L")
        #expect(local.sshSpecification == "127.0.0.1:8080:127.0.0.1:80")
        #expect(socks.isValid)
        #expect(socks.kind.sshFlag == "-D")
        #expect(socks.sshSpecification == "127.0.0.1:1080")
    }

    @Test
    func upstreamProxyBuildsSafeOpenSSHProxyCommand() {
        let socks = UpstreamProxyConfiguration(kind: .socks5, host: "127.0.0.1", port: 1080)
        #expect(socks.isValid)
        #expect(socks.proxyCommand == "/usr/bin/nc -x 127.0.0.1:1080 -X 5 %h %p")
        let injected = UpstreamProxyConfiguration(kind: .httpConnect, host: "proxy;touch /tmp/x", port: 8080)
        #expect(!injected.isValid)
        #expect(injected.proxyCommand == nil)
    }

    @Test
    func privateKeyInspectorDistinguishesEncryptedOpenSSHKeys() throws {
        func writeKey(cipher: String) throws -> URL {
            var payload = Data("openssh-key-v1\0".utf8)
            let length = UInt32(cipher.utf8.count).bigEndian
            withUnsafeBytes(of: length) { payload.append(contentsOf: $0) }
            payload.append(Data(cipher.utf8))
            let text = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            \(payload.base64EncodedString())
            -----END OPENSSH PRIVATE KEY-----
            """
            let url = FileManager.default.temporaryDirectory
                .appending(path: "kiteshell-key-\(UUID().uuidString)")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let encrypted = try writeKey(cipher: "aes256-ctr")
        let plain = try writeKey(cipher: "none")
        defer {
            try? FileManager.default.removeItem(at: encrypted)
            try? FileManager.default.removeItem(at: plain)
        }
        #expect(PrivateKeyInspector.requiresPassphrase(at: encrypted.path))
        #expect(!PrivateKeyInspector.requiresPassphrase(at: plain.path))
    }

    @Test
    func terminalThemesProvideCompleteANSIPalettes() {
        #expect(TerminalThemeOption.allCases.count >= 6)
        for option in TerminalThemeOption.allCases {
            #expect(option.definition.ansi.count == 16)
        }
    }

    @Test(arguments: [
        ("file:///home/deploy", "/home/deploy"),
        ("file://server.example.com/var/log", "/var/log"),
        ("file:///path%20with%20spaces", "/path with spaces"),
        ("/srv/app", "/srv/app")
    ])
    func parsesTerminalWorkingDirectory(value: String, expected: String) {
        #expect(TerminalWorkingDirectoryParser.remotePath(from: value) == expected)
    }

    @Test
    func rejectsNonFileWorkingDirectoryValues() {
        #expect(TerminalWorkingDirectoryParser.remotePath(from: "https://example.com/tmp") == nil)
        #expect(TerminalWorkingDirectoryParser.remotePath(from: "relative/path") == nil)
        #expect(TerminalWorkingDirectoryParser.remotePath(from: nil) == nil)
    }

    @Test
    func swiftTermOSC7EventFeedsDirectoryParser() {
        let headless = HeadlessTerminal { _ in }
        headless.terminal.feed(text: "\u{1b}]7;file://remote-host/srv/current%20release\u{1b}\\")
        #expect(headless.terminal.hostCurrentDirectory == "file://remote-host/srv/current%20release")
        #expect(
            TerminalWorkingDirectoryParser.remotePath(
                from: headless.terminal.hostCurrentDirectory
            ) == "/srv/current release"
        )
    }

    @Test
    func remoteFileMutationCommandsAreSafelyQuoted() {
        let file = RemoteFileEntry(
            name: "report's.txt",
            isDirectory: false,
            sizeBytes: 12,
            modifiedAt: "2026-07-22 10:00",
            permissions: "644",
            owner: "deploy"
        )
        #expect(
            RemoteFileService.createFileCommand(parent: "/srv/app", name: "a'b.sh")
                == "touch -- '/srv/app/a'\"'\"'b.sh'"
        )
        #expect(
            RemoteFileService.duplicateCommand(parent: "/srv/app", entry: file, newName: "copy's.txt")
                == "cp -p -- '/srv/app/report'\"'\"'s.txt' '/srv/app/copy'\"'\"'s.txt'"
        )
        #expect(
            RemoteFileService.changePermissionsCommand(parent: "/srv/app", entry: file, mode: "600")
                == "chmod -- 600 '/srv/app/report'\"'\"'s.txt'"
        )
    }

    @Test @MainActor
    func remoteEditWatcherDetectsSaveAndRetriesFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kiteshell-edit-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = directory.appending(path: "config.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let initialSnapshot = RemoteFileSnapshot.read(from: file)
        var syncAttempts = 0
        let watcher = RemoteFileEditWatcher(
            localURL: file,
            pollInterval: .milliseconds(20),
            settleDelay: 0.03,
            retryDelay: 0.05
        ) {
            syncAttempts += 1
            return syncAttempts >= 2
        }
        watcher.start()
        try Data("after with changes".utf8).write(to: file, options: .atomic)
        let deadline = ContinuousClock.now + .seconds(2)
        while syncAttempts < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        watcher.stop()

        #expect(RemoteFileSnapshot.read(from: file) != initialSnapshot)
        #expect(syncAttempts >= 2)
    }

    @Test
    func remoteEditSnapshotDetectsSameSizeContentChangeWithPreservedMetadata() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kiteshell-snapshot-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("before".utf8).write(to: file)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        let before = try #require(RemoteFileSnapshot.read(from: file))

        try Data("after!".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        let after = try #require(RemoteFileSnapshot.read(from: file))

        #expect(before.size == after.size)
        #expect(before.modificationDate == after.modificationDate)
        #expect(before.fileNumber == after.fileNumber)
        #expect(before.contentSignature != after.contentSignature)
        #expect(before != after)
    }

    @Test @MainActor
    func remoteEditWatcherQueuesSaveThatArrivesDuringSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kiteshell-edit-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = directory.appending(path: "config.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        var syncAttempts = 0
        let watcher = RemoteFileEditWatcher(
            localURL: file,
            pollInterval: .milliseconds(15),
            settleDelay: 0.02,
            retryDelay: 0.03
        ) {
            syncAttempts += 1
            if syncAttempts == 1 {
                try? await Task.sleep(for: .milliseconds(120))
            }
            return true
        }
        watcher.start()
        try Data("first save".utf8).write(to: file, options: .atomic)
        let firstDeadline = ContinuousClock.now + .seconds(1)
        while syncAttempts < 1, ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Data("second save during upload".utf8).write(to: file, options: .atomic)

        let deadline = ContinuousClock.now + .seconds(2)
        while syncAttempts < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        watcher.stop()

        #expect(syncAttempts >= 2)
    }

    @Test
    func uploadBatchReportsPerFileAndOverallProgress() {
        let urls = [URL(fileURLWithPath: "/tmp/one.bin"), URL(fileURLWithPath: "/tmp/two.bin")]
        var batch = UploadBatchProgress(urls: urls)
        #expect(batch.items.count == 2)
        #expect(batch.overallFraction == 0)

        batch.items[0].totalBytes = 100
        batch.items[0].transferredBytes = 100
        batch.items[0].status = .completed
        batch.items[1].totalBytes = 200
        batch.items[1].transferredBytes = 100
        batch.items[1].status = .uploading

        #expect(batch.completedCount == 1)
        #expect(batch.overallFraction == 0.75)
        #expect(batch.items[1].fractionCompleted == 0.5)
        #expect(!batch.isFinished)

        batch.items[1].status = .failed("fixture")
        #expect(batch.failedCount == 1)
        #expect(batch.isFinished)

        batch.items[0].status = .cancelled
        #expect(batch.cancelledCount == 1)
        #expect(batch.isFinished)
    }

    @Test
    func localUploadMetricsCountDirectoryContents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kiteshell-upload-metrics-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = directory.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 17).write(to: directory.appending(path: "one.bin"))
        try Data(repeating: 2, count: 29).write(to: nested.appending(path: "two.bin"))
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(LocalUploadMetrics.measure(directory) == LocalUploadMetrics(isDirectory: true, totalBytes: 46))
        #expect(LocalUploadMetrics.measure(directory.appending(path: "one.bin")) == LocalUploadMetrics(isDirectory: false, totalBytes: 17))
    }

    @Test
    func remoteTransferSizeCommandsQuotePaths() {
        let file = RemoteFileService.transferSizeCommand(path: "/tmp/a'b.txt", isDirectory: false)
        #expect(file.contains("stat -f"))
        #expect(file.contains("stat -c"))
        #expect(file.contains("'/tmp/a'\"'\"'b.txt'"))

        let directory = RemoteFileService.transferSizeCommand(path: "/tmp/a'b", isDirectory: true)
        #expect(directory.contains("find '/tmp/a'\"'\"'b' -type f"))
        #expect(directory.contains("stat -f"))
        #expect(directory.contains("-printf"))
    }

    @Test
    func monitorParserSupportsDarwinAndPartialMetrics() throws {
        let darwin = try LinuxMonitorService.parse("""
        __PLATFORM__
        Darwin
        __UPTIME__
        43210
        __LOAD__
        1.25 1.10 0.95
        __CPU__
        0.3750
        __MEM__
        MemTotal:\t16777216
        MemAvailable:\t8388608
        __NET__
        123456\t654321
        __DISKS__
        /\t100000\t40000\t60000
        __PROCESSES__
        42 wang zsh 2.5 1.0
        __END__
        """)
        #expect(darwin.platform == "Darwin")
        #expect(darwin.uptimeSeconds == 43_210)
        #expect(darwin.cpuUsage == 0.375)
        #expect(darwin.memoryUsage == 0.5)
        #expect(darwin.unavailableSections.isEmpty)

        let partial = try LinuxMonitorService.parse("""
        __PLATFORM__
        Darwin
        __LOAD__
        0.50 0.40 0.30
        __DISKS__
        /\t100000\t50000\t50000
        __END__
        """)
        #expect(partial.loadAverage == "0.50 0.40 0.30")
        #expect(partial.cpuUsage == nil)
        #expect(partial.memoryUsage == nil)
        #expect(partial.disks.count == 1)
        #expect(partial.unavailableSections.contains("CPU"))
        #expect(partial.unavailableSections.contains("内存"))
    }

    @Test
    func remoteDirectoryParserSupportsPortableHexNames() throws {
        let listing = try RemoteFileService.parse("""
        __PWD__\t/Users/wang
        __FILEHEX__\tf\t4d792046696c652e747874\t128\t2026-08-11 09:22\t644\twang
        __FILEHEX__\td\t446f63756d656e7473\t160\t2026-08-10 12:00\t755\twang
        """)
        #expect(listing.path == "/Users/wang")
        #expect(listing.entries.map(\.name) == ["Documents", "My File.txt"])
        #expect(listing.entries[0].isDirectory)

        let command = RemoteFileService.command(path: "/Users/wang")
        #expect(!command.contains("find ."))
        #expect(command.contains("stat -f"))
        #expect(command.contains("stat -c"))
        #expect(command.contains("od -An -tx1"))
    }

    @Test
    func monitorCommandRunsAgainstLocalMac() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", LinuxMonitorService.command]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0)
        let snapshot = try LinuxMonitorService.parse(text)
        #expect(snapshot.platform == "Darwin")
        #expect((snapshot.uptimeSeconds ?? 0) > 0)
        #expect((snapshot.uptimeSeconds ?? .infinity) < 365 * 24 * 60 * 60)
        #expect(snapshot.memoryTotalKB != nil)
        #expect(!snapshot.disks.isEmpty)
        #expect(!snapshot.processes.isEmpty)
    }

    @Test
    func portableDirectoryCommandRunsAgainstLocalMac() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kiteshell-portable-list-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: directory.appending(path: "空 格.txt"))
        try FileManager.default.createDirectory(
            at: directory.appending(path: "Documents"),
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", RemoteFileService.command(path: directory.path)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0)
        let listing = try RemoteFileService.parse(text)
        #expect(listing.path == directory.path)
        #expect(listing.entries.map(\.name) == ["Documents", "空 格.txt"])
        #expect(listing.entries.first(where: { $0.name == "空 格.txt" })?.sizeBytes == 7)
    }
}
