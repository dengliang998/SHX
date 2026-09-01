import AppKit
import Network
import SwiftTerm
import SwiftUI

enum TerminalWorkingDirectoryParser {
    static func remotePath(from value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("/") {
            return value
        }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "file",
              let encodedPath = components.percentEncodedPath.removingPercentEncoding,
              encodedPath.hasPrefix("/") else {
            return nil
        }
        return encodedPath
    }
}

enum TerminalClipboardShortcut: Equatable {
    case copy
    case paste

    static func resolve(
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> TerminalClipboardShortcut? {
        let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
        guard relevantModifiers == .command else { return nil }
        switch characters?.lowercased() {
        case "c": return .copy
        case "v": return .paste
        default: return nil
        }
    }
}

final class ObservedLocalProcessTerminalView: LocalProcessTerminalView {
    var onTermination: (@MainActor @Sendable (Int32?) -> Void)?

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        let callback = onTermination
        Task { @MainActor in
            callback?(exitCode)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ownsFirstResponder else {
            // Returning false is important here. SwiftTerm's superclass may still
            // consume Command-C/Command-V while a SwiftUI field editor owns focus,
            // which prevents path, search and inline-rename fields from receiving
            // the standard macOS shortcuts.
            return false
        }
        guard let shortcut = TerminalClipboardShortcut.resolve(
            characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags
        ) else {
            return super.performKeyEquivalent(with: event)
        }

        switch shortcut {
        case .copy:
            let item = NSMenuItem()
            item.action = #selector(copy(_:))
            guard validateUserInterfaceItem(item) else {
                NSSound.beep()
                return true
            }
            copy(self)
        case .paste:
            paste(self)
        }
        return true
    }

    private var ownsFirstResponder: Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        if firstResponder === self { return true }
        guard let view = firstResponder as? NSView else { return false }
        return view.isDescendant(of: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = validateUserInterfaceItem(copyItem)
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = validateUserInterfaceItem(pasteItem)
        menu.addItem(pasteItem)

        menu.addItem(.separator())
        let selectAllItem = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        selectAllItem.isEnabled = validateUserInterfaceItem(selectAllItem)
        menu.addItem(selectAllItem)
        return menu
    }

    override func paste(_ sender: Any) {
        guard UserDefaults.standard.bool(forKey: "confirmRiskyPaste"),
              let value = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let lowercased = value.lowercased()
        let isRisky = value.contains("\n") || value.contains("\r") ||
            ["rm -", "shutdown", "reboot", "mkfs", "kill -9", "systemctl stop"]
                .contains { lowercased.contains($0) }
        guard isRisky else {
            super.paste(sender)
            return
        }
        let alert = NSAlert()
        alert.messageText = "粘贴多行或高风险内容？"
        alert.informativeText = "粘贴到终端后，换行可能立即执行命令。请确认剪贴板内容来自可信来源。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "粘贴")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { super.paste(sender) }
    }
}

final class TerminalProcessObserver: NSObject, LocalProcessTerminalViewDelegate {
    var onWorkingDirectoryChange: (@MainActor @Sendable (String?) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        let callback = onWorkingDirectoryChange
        Task { @MainActor in
            callback?(directory)
        }
    }
}

enum TerminalServiceStartupPolicy {
    static let startupDelayMilliseconds = 1_000

    static func shouldStartServices(connectionState: ConnectionState, shellReady: Bool) -> Bool {
        connectionState == .connected && shellReady
    }
}

enum TerminalShellBootstrap {
    static func command(
        token: String,
        integration: String,
        startupDirectory: String,
        initializationCommand: String?
    ) -> String {
        var commonLines = [integration]
        if startupDirectory.hasPrefix("/") {
            commonLines.append("cd -- \(RemoteFileService.shellQuote(startupDirectory))")
        }
        if let initializationCommand,
           !initializationCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commonLines.append(initializationCommand)
        }

        let directory = "/tmp/shx-\(token)"
        let bashRC = "\(directory)/.bashrc"
        let zshRC = "\(directory)/.zshrc"
        let bashLines = [
            "if [ -f \"$HOME/.bashrc\" ]; then . \"$HOME/.bashrc\"; fi"
        ] + commonLines
        let zshLines = [
            "if [ -f \"$HOME/.zshrc\" ]; then . \"$HOME/.zshrc\"; fi"
        ] + commonLines
        let encode = { (lines: [String]) in
            lines.map(RemoteFileService.shellQuote).joined(separator: " ")
        }

        return "set -eu; mkdir -p \(RemoteFileService.shellQuote(directory)); " +
            "printf '%s\\n' \(encode(bashLines)) > \(RemoteFileService.shellQuote(bashRC)); " +
            "printf '%s\\n' \(encode(zshLines)) > \(RemoteFileService.shellQuote(zshRC)); " +
            "case \"${SHELL:-/bin/sh}\" in */bash) exec bash --noprofile --rcfile \(RemoteFileService.shellQuote(bashRC)) -i ;; " +
            "*/zsh) ZDOTDIR=\(RemoteFileService.shellQuote(directory)); export ZDOTDIR; exec zsh -i ;; " +
            "*) . \(RemoteFileService.shellQuote(bashRC)); exec \"${SHELL:-/bin/sh}\" -i ;; " +
            "esac"
    }
}

@MainActor
final class TerminalSessionController {
    private static let localNetworkAccessConfirmedKey = "localNetworkAccessConfirmed"
    let id = UUID()
    let profile: ServerProfile
    let jumpHost: ServerProfile?
    let terminalView: ObservedLocalProcessTerminalView
    var onStateChange: (@MainActor @Sendable (ConnectionState) -> Void)?
    var onShellReady: (@MainActor @Sendable () -> Void)?
    var onWorkingDirectoryChange: (@MainActor @Sendable (String) -> Void)?

    private(set) var hasStarted = false
    private var state: ConnectionState = .connecting
    private var connectionWatchTask: Task<Void, Never>?
    private let sentinelURL: URL
    private let controlSocketPath: String
    private var passwordBroker: OneTimePasswordBroker?
    private var localNetworkProbe: NWConnection?
    private var localNetworkProbeTimeoutTask: Task<Void, Never>?
    private var didLaunchSSH = false
    private let processObserver = TerminalProcessObserver()
    private var shellReadyTask: Task<Void, Never>?
    private var identityFileURL: URL?
    private var isAccessingIdentityFile = false

    var remoteCommandContext: RemoteCommandContext {
        RemoteCommandContext(
            controlSocketPath: controlSocketPath,
            destination: "\(profile.username)@\(profile.host)",
            port: profile.port
        )
    }

    init(profile: ServerProfile, jumpHost: ServerProfile?, oneTimePassword: String?) {
        self.profile = profile
        self.jumpHost = jumpHost
        let token = UUID().uuidString.lowercased()
        sentinelURL = URL(fileURLWithPath: "/tmp/remotehub-\(token).connected")
        controlSocketPath = "/tmp/remotehub-\(token).sock"
        terminalView = ObservedLocalProcessTerminalView(frame: .zero)
        if let oneTimePassword {
            passwordBroker = OneTimePasswordBroker(password: oneTimePassword)
        }
        resolveIdentityFile()
        configureAppearance()
        terminalView.processDelegate = processObserver
        processObserver.onWorkingDirectoryChange = { [weak self] value in
            self?.handleWorkingDirectory(value)
        }
        terminalView.onTermination = { [weak self] exitCode in
            self?.handleTermination(exitCode: exitCode)
        }
    }

    func start() {
        guard !hasStarted else { return }
        cleanupConnectionArtifacts()
        hasStarted = true
        setState(.connecting)

        do {
            try passwordBroker?.start()
        } catch {
            passwordBroker = nil
        }

        if Self.isPrivateNetworkHost(profile.host) && !Self.hasConfirmedLocalNetworkAccess {
            requestLocalNetworkAccessThenLaunchSSH()
        } else {
            launchSSHProcess()
        }
    }

    private func launchSSHProcess() {
        guard hasStarted, !didLaunchSSH else { return }
        didLaunchSSH = true
        localNetworkProbeTimeoutTask?.cancel()
        localNetworkProbeTimeoutTask = nil
        localNetworkProbe?.cancel()
        localNetworkProbe = nil

        terminalView.startProcess(
            executable: "/usr/bin/ssh",
            args: sshArguments,
            environment: sshEnvironment,
            execName: "ssh",
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        watchForAuthenticatedConnection()
    }

    func terminate() {
        connectionWatchTask?.cancel()
        shellReadyTask?.cancel()
        localNetworkProbeTimeoutTask?.cancel()
        localNetworkProbeTimeoutTask = nil
        if didLaunchSSH {
            terminalView.terminate()
        }
        didLaunchSSH = false
        hasStarted = false
        passwordBroker?.cancel()
        localNetworkProbe?.cancel()
        localNetworkProbe = nil
        cleanupConnectionArtifacts()
        releaseIdentityFileAccess()
    }

    func applyAppearance() {
        let storedSize = UserDefaults.standard.double(forKey: "terminalFontSize")
        let fontSize = storedSize > 0 ? storedSize : 13
        let selectedTheme = TerminalThemeOption(
            rawValue: UserDefaults.standard.string(forKey: "terminalTheme") ?? ""
        ) ?? .midnight
        let theme = selectedTheme.definition

        terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.lineSpacing = max(0.9, min(1.5, UserDefaults.standard.double(forKey: "terminalLineSpacing").nonZero(or: 1.0)))
        let storedScrollback = UserDefaults.standard.integer(forKey: "terminalScrollback")
        terminalView.changeScrollback(storedScrollback > 0 ? storedScrollback : 5_000)
        terminalView.optionAsMetaKey = UserDefaults.standard.object(forKey: "terminalOptionAsMeta") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "terminalOptionAsMeta")
        let cursor = TerminalCursorStyleOption(
            rawValue: UserDefaults.standard.string(forKey: "terminalCursorStyle") ?? ""
        ) ?? .block
        terminalView.terminal.setCursorStyle(cursor.swiftTermStyle)
        terminalView.nativeBackgroundColor = theme.background
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.caretColor = theme.cursor
        terminalView.caretTextColor = theme.background
        terminalView.selectedTextBackgroundColor = theme.selection
        terminalView.selectedTextForegroundColor = theme.foreground
        terminalView.installColors(theme.ansi)
        terminalView.needsDisplay = true
    }

    var terminalBackgroundColor: NSColor {
        let selectedTheme = TerminalThemeOption(
            rawValue: UserDefaults.standard.string(forKey: "terminalTheme") ?? ""
        ) ?? .midnight
        return selectedTheme.definition.background
    }

    func sendCommand(_ command: String) {
        guard hasStarted, !command.isEmpty else { return }
        terminalView.send(txt: command + "\r")
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func insertText(_ text: String) {
        guard hasStarted, !text.isEmpty else { return }
        terminalView.send(txt: text)
        terminalView.window?.makeFirstResponder(terminalView)
    }

    @discardableResult
    func findNext(_ text: String) -> Bool {
        terminalView.findNext(text)
    }

    @discardableResult
    func findPrevious(_ text: String) -> Bool {
        terminalView.findPrevious(text)
    }

    func clearSearch() {
        terminalView.clearSearch()
    }

    private func configureAppearance() {
        applyAppearance()
        terminalView.optionAsMetaKey = true
        terminalView.linkReporting = .implicit
    }

    private func requestLocalNetworkAccessThenLaunchSSH() {
        guard let port = NWEndpoint.Port(rawValue: UInt16(profile.port)) else {
            launchSSHProcess()
            return
        }

        let probe = NWConnection(
            host: NWEndpoint.Host(profile.host),
            port: port,
            using: .tcp
        )
        localNetworkProbe = probe
        probe.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor [weak self] in
                    Self.hasConfirmedLocalNetworkAccess = true
                    self?.launchSSHProcess()
                }
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.launchSSHProcess()
                }
            default:
                break
            }
        }
        probe.start(queue: DispatchQueue.global(qos: .userInitiated))

        localNetworkProbeTimeoutTask?.cancel()
        localNetworkProbeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.launchSSHProcess()
        }
    }

    private static var hasConfirmedLocalNetworkAccess: Bool {
        get { UserDefaults.standard.bool(forKey: localNetworkAccessConfirmedKey) }
        set { UserDefaults.standard.set(newValue, forKey: localNetworkAccessConfirmedKey) }
    }

    private static func isPrivateNetworkHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix(".local") || normalized.hasPrefix("fe80:") ||
            normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return true
        }

        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    private var sshArguments: [String] {
        var arguments = [
            "-tt",
            "-p", String(profile.port),
            "-o", "ConnectTimeout=\(max(1, min(profile.connectionTimeout, 60)))",
            "-o", "ServerAliveInterval=\(max(0, min(profile.keepAliveInterval, 300)))",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "ControlPersist=no",
            "-o", "PermitLocalCommand=yes",
            "-o", "LocalCommand=/usr/bin/touch \(sentinelURL.path)"
        ]

        if let knownHostsOption = HostKeyTrustStore.userKnownHostsSSHOption {
            arguments.append(contentsOf: [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", knownHostsOption,
                "-o", "GlobalKnownHostsFile=/dev/null"
            ])
        } else {
            arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=accept-new"])
        }

        switch profile.authentication {
        case .password:
            arguments.append(contentsOf: [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "NumberOfPasswordPrompts=1"
            ])
        case .privateKey:
            arguments.append(contentsOf: [
                "-o", "PreferredAuthentications=publickey,keyboard-interactive,password"
            ])
            if let identityFileURL {
                arguments.append(contentsOf: [
                    "-i", identityFileURL.path,
                    "-o", "IdentitiesOnly=yes"
                ])
            }
        case .sshAgent:
            arguments.append(contentsOf: [
                "-o", "IdentitiesOnly=no"
            ])
        }

        if let jumpHost {
            var jump = "\(jumpHost.username)@\(jumpHost.host)"
            if jumpHost.port != 22 { jump += ":\(jumpHost.port)" }
            arguments.append(contentsOf: ["-J", jump])
        } else if let proxyCommand = profile.upstreamProxy.proxyCommand {
            arguments.append(contentsOf: ["-o", "ProxyCommand=\(proxyCommand)"])
        }

        let enabledForwards = profile.portForwards.filter { $0.isEnabled && $0.isValid }
        if !enabledForwards.isEmpty {
            arguments.append(contentsOf: ["-o", "ExitOnForwardFailure=yes"])
            for forward in enabledForwards {
                arguments.append(contentsOf: [forward.kind.sshFlag, forward.sshSpecification])
            }
        }

        let integration = #"__kiteshell_cwd(){ printf '\033]7;file://%s%s\033\\' "${HOSTNAME:-remote}" "$PWD"; }; if [ -n "$BASH_VERSION" ]; then case ";$PROMPT_COMMAND;" in *";__kiteshell_cwd;"*) ;; *) PROMPT_COMMAND="__kiteshell_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}";; esac; elif [ -n "$ZSH_VERSION" ]; then autoload -Uz add-zsh-hook >/dev/null 2>&1; add-zsh-hook precmd __kiteshell_cwd; fi; __kiteshell_cwd"#
        let startupDirectory = profile.startupDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let initializationCommand = profile.runsInitializationCommand
            ? profile.initializationCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let shellCommand = TerminalShellBootstrap.command(
            token: id.uuidString.lowercased(),
            integration: integration,
            startupDirectory: startupDirectory,
            initializationCommand: initializationCommand
        )

        arguments.append("--")
        arguments.append("\(profile.username)@\(profile.host)")
        arguments.append(shellCommand)
        return arguments
    }

    private var sshEnvironment: [String]? {
        guard let passwordBroker,
              let askPassURL = askPassHelperURL else {
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["SSH_ASKPASS"] = askPassURL.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "SHX"
        environment["SHX_ASKPASS_SOCKET"] = passwordBroker.socketPath
        return environment.map { "\($0.key)=\($0.value)" }
    }

    private var askPassHelperURL: URL? {
        let bundled = Bundle.main.resourceURL?.appending(path: "SHXAskPass")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Packaging/SHXAskPass")
        return FileManager.default.isExecutableFile(atPath: development.path) ? development : nil
    }

    private func watchForAuthenticatedConnection() {
        connectionWatchTask?.cancel()
        connectionWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && hasStarted {
                if FileManager.default.fileExists(atPath: sentinelURL.path) {
                    try? FileManager.default.removeItem(at: sentinelURL)
                    if Self.isPrivateNetworkHost(profile.host) {
                        Self.hasConfirmedLocalNetworkAccess = true
                    }
                    passwordBroker?.cancel()
                    passwordBroker = nil
                    setState(.connected)
                    scheduleShellReady()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func handleTermination(exitCode: Int32?) {
        connectionWatchTask?.cancel()
        shellReadyTask?.cancel()
        localNetworkProbeTimeoutTask?.cancel()
        localNetworkProbeTimeoutTask = nil
        localNetworkProbe?.cancel()
        localNetworkProbe = nil
        didLaunchSSH = false
        hasStarted = false
        passwordBroker?.cancel()
        cleanupConnectionArtifacts()
        setState(state == .connected ? .disconnected : .failed)
    }

    private func setState(_ newState: ConnectionState) {
        state = newState
        onStateChange?(newState)
    }

    private func cleanupConnectionArtifacts() {
        try? FileManager.default.removeItem(at: sentinelURL)
        try? FileManager.default.removeItem(atPath: controlSocketPath)
    }

    private func scheduleShellReady() {
        shellReadyTask?.cancel()
        shellReadyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, hasStarted else { return }
            onShellReady?()
        }
    }

    private func resolveIdentityFile() {
        guard profile.authentication == .privateKey else { return }
        if let bookmark = profile.identityFileBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                identityFileURL = url
                isAccessingIdentityFile = url.startAccessingSecurityScopedResource()
                return
            }
        }
        let path = profile.identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            identityFileURL = URL(fileURLWithPath: path)
        }
    }

    private func releaseIdentityFileAccess() {
        if isAccessingIdentityFile {
            identityFileURL?.stopAccessingSecurityScopedResource()
        }
        isAccessingIdentityFile = false
    }

    private func handleWorkingDirectory(_ value: String?) {
        guard let path = TerminalWorkingDirectoryParser.remotePath(from: value) else { return }
        onWorkingDirectoryChange?(path)
    }
}

private extension Double {
    func nonZero(or fallback: Double) -> Double { self == 0 ? fallback : self }
}

enum TerminalStartupScheduler {
    @MainActor
    static func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in action() }
    }
}

struct NativeTerminalHost: NSViewRepresentable {
    let controller: TerminalSessionController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = controller.terminalView
        TerminalStartupScheduler.schedule {
            controller.start()
            controller.terminalView.window?.makeFirstResponder(controller.terminalView)
        }
        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
