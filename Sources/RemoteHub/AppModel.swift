import AppKit
import Combine
import Foundation

struct ImportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum CredentialPromptKind {
    case password
    case privateKeyPassphrase

    var title: String {
        switch self {
        case .password: "输入 SSH 密码"
        case .privateKeyPassphrase: "输入私钥口令"
        }
    }

    var fieldLabel: String {
        switch self {
        case .password: "SSH 密码"
        case .privateKeyPassphrase: "私钥口令"
        }
    }
}

struct PasswordRequest: Identifiable {
    let id = UUID()
    let profile: ServerProfile
    let reconnectSessionID: UUID?
    let pendingCommand: QuickCommand?
    let kind: CredentialPromptKind
}

@MainActor
final class AppModel: ObservableObject {
    private struct RemoteEditKey: Hashable {
        let sessionID: UUID
        let remotePath: String
    }

    private struct RemoteEditHandle {
        let localURL: URL
        let watcher: RemoteFileEditWatcher
        var remoteVersion: String?
    }

    enum Route {
        case connectionCenter
        case workspace
    }

    @Published var route: Route = .connectionCenter
    @Published var servers: [ServerProfile]
    @Published var groups: [String]
    @Published var sessions: [Session] = []
    @Published var selectedSessionID: UUID?
    @Published var terminalControllers: [UUID: TerminalSessionController] = [:]
    @Published var isInspectorVisible = true
    @Published var isFilePanelVisible = true
    @Published var focusMode = false
    @Published var isPresentingNewConnection = false
    @Published var isPresentingConnectionLauncher = false
    @Published var isPresentingQuickConnect = false
    @Published var importNotice: ImportNotice?
    @Published var passwordRequest: PasswordRequest?
    @Published var monitorStates: [UUID: MonitorLoadState] = [:]
    @Published var remoteDirectoryStates: [UUID: RemoteDirectoryState] = [:]
    @Published var fileTransferActivity: [UUID: String] = [:]
    @Published var uploadBatches: [UUID: UploadBatchProgress] = [:]
    @Published var remoteEditActivity: [UUID: String] = [:]
    @Published var directoryFollowEnabled: [UUID: Bool] = [:]
    @Published var globalQuickCommands: [QuickCommand] = CommandStore().loadCommands()
    @Published var commandExecutionHistory: [CommandExecutionRecord] = CommandStore().loadHistory()
    @Published var softwareUpdateState: SoftwareUpdateState = .idle

    private let profileStore = ProfileStore()
    private let groupStore = GroupStore()
    private let commandStore = CommandStore()
    private let credentialVault = LocalCredentialVault()
    private let workspaceStore = WorkspaceStore()
    private let releaseUpdater = GitHubReleaseUpdater()
    private var availableSoftwareUpdate: AvailableAppUpdate?
    private var softwareUpdateTask: Task<Void, Never>?
    private var monitorTasks: [UUID: Task<Void, Never>] = [:]
    private var remoteDirectoryTasks: [UUID: Task<Void, Never>] = [:]
    private var fileTransferTasks: [UUID: Task<Void, Never>] = [:]
    private var fileTransferIDs: [UUID: UUID] = [:]
    private var fileTransferControls: [UUID: TransferProcessControl] = [:]
    private var pendingSessionCommands: [UUID: QuickCommand] = [:]
    private var pendingCommandTasks: [UUID: Task<Void, Never>] = [:]
    private var directorySyncTasks: [UUID: Task<Void, Never>] = [:]
    private var automaticReconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var automaticReconnectAttempts: [UUID: Int] = [:]
    private var remoteEditHandles: [RemoteEditKey: RemoteEditHandle] = [:]
    private var remoteEditPreparationTasks: [RemoteEditKey: Task<Void, Never>] = [:]
    private var reportedRemoteEditFailures: Set<RemoteEditKey> = []

    init() {
        let loadedServers = profileStore.load()
        servers = loadedServers
        groups = groupStore.load(profileGroups: loadedServers.map(\.group))
        restoreWorkspaceIfNeeded()
        DiagnosticsCenter.record("app", "应用启动，已加载 \(servers.count) 条连接配置")
        scheduleAutomaticUpdateCheck()
    }

    var selectedSession: Session? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var selectedTerminalController: TerminalSessionController? {
        guard let selectedSessionID else { return nil }
        return terminalControllers[selectedSessionID]
    }

    func showConnectionCenter() {
        route = .connectionCenter
    }

    func showWorkspace() {
        guard selectedSession != nil else { return }
        route = .workspace
    }

    var canInstallSoftwareUpdate: Bool {
        availableSoftwareUpdate != nil && !softwareUpdateState.isBusy
    }

    func checkForUpdates(silent: Bool = false) {
        guard !softwareUpdateState.isBusy else { return }
        softwareUpdateTask?.cancel()
        if !silent { softwareUpdateState = .checking }
        softwareUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await releaseUpdater.check(
                    currentVersion: AppVersion.short,
                    currentBuild: Int(AppVersion.build) ?? 0
                )
                UserDefaults.standard.set(Date(), forKey: "lastAutomaticUpdateCheck")
                switch result {
                case .upToDate:
                    availableSoftwareUpdate = nil
                    softwareUpdateState = silent ? .idle : .upToDate
                case .available(let update):
                    availableSoftwareUpdate = update
                    softwareUpdateState = .available(version: update.version)
                }
            } catch is CancellationError {
                if !silent { softwareUpdateState = .idle }
            } catch {
                DiagnosticsCenter.record("update", "Update check failed: \(error.localizedDescription)")
                if !silent { softwareUpdateState = .failed(error.localizedDescription) }
            }
            softwareUpdateTask = nil
        }
    }

    func installAvailableSoftwareUpdate() {
        guard let update = availableSoftwareUpdate, !softwareUpdateState.isBusy else { return }
        softwareUpdateState = .downloading(version: update.version)
        softwareUpdateTask?.cancel()
        softwareUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await releaseUpdater.prepareInstallation(update)
                softwareUpdateState = .preparing
                try releaseUpdater.launchInstaller(prepared)
            } catch is CancellationError {
                softwareUpdateState = .available(version: update.version)
            } catch {
                DiagnosticsCenter.record("update", "Update installation failed: \(error.localizedDescription)")
                softwareUpdateState = .failed(error.localizedDescription)
            }
            softwareUpdateTask = nil
        }
    }

    func openAvailableSoftwareRelease() {
        guard let url = availableSoftwareUpdate?.releasePageURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleAutomaticUpdateCheck() {
        let lastCheck = UserDefaults.standard.object(forKey: "lastAutomaticUpdateCheck") as? Date
        guard lastCheck == nil || Date().timeIntervalSince(lastCheck!) >= 86_400 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.checkForUpdates(silent: true)
        }
    }

    func requestOpenSession(for profile: ServerProfile) {
        requestOpenSession(for: profile, pendingCommand: nil, oneTimeCredential: nil)
    }

    func requestOpenSession(for profile: ServerProfile, oneTimeCredential: String?) {
        requestOpenSession(for: profile, pendingCommand: nil, oneTimeCredential: oneTimeCredential)
    }

    func requestRunQuickCommand(_ command: QuickCommand, for profile: ServerProfile) {
        if let session = sessions.first(where: {
            $0.profile.id == profile.id && $0.state == .connected
        }) {
            selectSession(session)
            runQuickCommand(command, in: session.id)
            return
        }
        requestOpenSession(for: profile, pendingCommand: command, oneTimeCredential: nil)
    }

    private func requestOpenSession(
        for profile: ServerProfile,
        pendingCommand: QuickCommand?,
        oneTimeCredential: String?
    ) {
        // OpenSSH records a first-seen host key itself with accept-new. This keeps
        // first connections non-blocking while still refusing changed host keys.
        DiagnosticsCenter.record("security", "首次主机密钥由 OpenSSH 静默记录；密钥变化时阻止连接")
        requestCredentialsAndOpen(
            profile,
            pendingCommand: pendingCommand,
            oneTimeCredential: oneTimeCredential
        )
    }

    private func requestCredentialsAndOpen(
        _ profile: ServerProfile,
        pendingCommand: QuickCommand?,
        oneTimeCredential: String?
    ) {
        if let oneTimeCredential, !oneTimeCredential.isEmpty {
            openSession(for: profile, password: oneTimeCredential, pendingCommand: pendingCommand)
            return
        }
        if profile.authentication == .privateKey,
           PrivateKeyInspector.requiresPassphrase(at: profile.identityFilePath) {
            if let savedPassphrase = try? credentialVault.readPrivateKeyPassphrase(profileID: profile.id),
               !savedPassphrase.isEmpty {
                openSession(for: profile, password: savedPassphrase, pendingCommand: pendingCommand)
                return
            }
            passwordRequest = PasswordRequest(
                profile: profile,
                reconnectSessionID: nil,
                pendingCommand: pendingCommand,
                kind: .privateKeyPassphrase
            )
            return
        }
        guard profile.authentication == .password else {
            openSession(for: profile, password: nil, pendingCommand: pendingCommand)
            return
        }
        if let savedPassword = try? credentialVault.readPassword(profileID: profile.id),
           !savedPassword.isEmpty {
            openSession(for: profile, password: savedPassword, pendingCommand: pendingCommand)
            return
        }
        passwordRequest = PasswordRequest(
            profile: profile,
            reconnectSessionID: nil,
            pendingCommand: pendingCommand,
            kind: .password
        )
    }

    func submitPassword(
        _ password: String,
        remember: Bool,
        for request: PasswordRequest
    ) {
        passwordRequest = nil
        if remember {
            do {
                switch request.kind {
                case .password:
                    try credentialVault.savePassword(password, profileID: request.profile.id)
                case .privateKeyPassphrase:
                    try credentialVault.savePrivateKeyPassphrase(password, profileID: request.profile.id)
                }
            } catch {
                importNotice = ImportNotice(
                    title: "密码未能保存",
                    message: "本次仍会继续连接，但本地凭据保存失败：\(error.localizedDescription)"
                )
            }
        }
        if let sessionID = request.reconnectSessionID {
            reconnectSession(id: sessionID, password: password)
        } else {
            openSession(
                for: request.profile,
                password: password,
                pendingCommand: request.pendingCommand
            )
        }
    }

    private func openSession(
        for profile: ServerProfile,
        password: String?,
        pendingCommand: QuickCommand?
    ) {
        let session = Session(profile: profile)
        sessions.append(session)
        if let pendingCommand {
            pendingSessionCommands[session.id] = pendingCommand
        }
        terminalControllers[session.id] = makeTerminalController(for: session, password: password)
        selectedSessionID = session.id
        route = .workspace
        persistWorkspace()
    }

    func addServer(
        _ profile: ServerProfile,
        password: String? = nil,
        rememberPassword: Bool = true
    ) {
        var profile = profile
        profile.updatedAt = Date()
        servers.append(profile)
        ensureGroupExists(profile.group)
        profileStore.save(servers)
        updatePassword(password, for: profile, remember: rememberPassword)
        isPresentingNewConnection = false
    }

    func updateServer(
        _ profile: ServerProfile,
        password: String? = nil,
        rememberPassword: Bool = true
    ) {
        guard let index = servers.firstIndex(where: { $0.id == profile.id }) else { return }
        let previous = servers[index]
        var profile = profile
        profile.createdAt = previous.createdAt
        profile.updatedAt = Date()
        servers[index] = profile
        ensureGroupExists(profile.group)
        profileStore.save(servers)
        updatePassword(password, for: profile, remember: rememberPassword)
        for sessionIndex in sessions.indices where sessions[sessionIndex].profile.id == profile.id {
            sessions[sessionIndex].profile = profile
        }
        persistWorkspace()
        if previous.authentication == .password && profile.authentication != .password {
            try? credentialVault.removePassword(profileID: profile.id)
        }
        if previous.authentication == .privateKey && profile.authentication != .privateKey {
            try? credentialVault.removePrivateKeyPassphrase(profileID: profile.id)
        }
    }

    private func updatePassword(_ password: String?, for profile: ServerProfile, remember: Bool) {
        guard profile.authentication == .password, let password, !password.isEmpty else { return }
        do {
            if remember {
                try credentialVault.savePassword(password, profileID: profile.id)
            } else {
                try credentialVault.removePassword(profileID: profile.id)
            }
        } catch {
            importNotice = ImportNotice(
                title: "密码未能保存",
                message: remember ? "本地凭据保存失败：\(error.localizedDescription)" : "无法清除旧密码：\(error.localizedDescription)"
            )
        }
    }

    func deleteServer(_ profile: ServerProfile) {
        let relatedSessions = sessions.filter { $0.profile.id == profile.id }
        for session in relatedSessions {
            closeSession(session)
        }
        servers.removeAll { $0.id == profile.id }
        profileStore.save(servers)
        try? credentialVault.removePassword(profileID: profile.id)
        try? credentialVault.removePrivateKeyPassphrase(profileID: profile.id)
        persistWorkspace()
    }

    func forgetPassword(for profile: ServerProfile) {
        try? credentialVault.removePassword(profileID: profile.id)
        importNotice = ImportNotice(
            title: "密码已清除",
            message: "下次连接 \(profile.name) 时会重新询问密码。"
        )
    }

    func forgetPrivateKeyPassphrase(for profile: ServerProfile) {
        try? credentialVault.removePrivateKeyPassphrase(profileID: profile.id)
        importNotice = ImportNotice(
            title: "私钥口令已清除",
            message: "下次使用 \(profile.name) 的加密私钥时会重新询问口令。"
        )
    }

    func hasSavedPassword(for profile: ServerProfile) -> Bool {
        guard profile.authentication == .password else { return false }
        return ((try? credentialVault.readPassword(profileID: profile.id)) ?? nil)?.isEmpty == false
    }

    func duplicateServer(_ profile: ServerProfile) {
        let now = Date()
        let copy = ServerProfile(
            name: uniqueServerName(base: "\(profile.name) 副本"),
            host: profile.host,
            port: profile.port,
            username: profile.username,
            authentication: profile.authentication,
            group: profile.group,
            tags: profile.tags,
            notes: profile.notes,
            isFavorite: false,
            quickCommands: profile.quickCommands.map {
                QuickCommand(name: $0.name, command: $0.command)
            },
            identityFilePath: profile.identityFilePath,
            identityFileBookmark: profile.identityFileBookmark,
            connectionTimeout: profile.connectionTimeout,
            keepAliveInterval: profile.keepAliveInterval,
            startupDirectory: profile.startupDirectory,
            initializationCommand: profile.initializationCommand,
            runsInitializationCommand: profile.runsInitializationCommand,
            reconnectPolicy: profile.reconnectPolicy,
            jumpHostID: profile.jumpHostID,
            upstreamProxy: profile.upstreamProxy,
            portForwards: profile.portForwards,
            createdAt: now,
            updatedAt: now
        )
        servers.append(copy)
        ensureGroupExists(copy.group)
        profileStore.save(servers)
        importNotice = ImportNotice(
            title: "已复制连接",
            message: "已创建 \(copy.name)，凭据不会随连接复制。"
        )
    }

    func createGroup(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !groups.contains(name) else { return }
        groups.append(name)
        groupStore.save(groups)
        groups = groupStore.load(profileGroups: servers.map(\.group))
    }

    func renameGroup(_ oldName: String, to rawName: String) {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, oldName != newName, !groups.contains(newName) else { return }
        for index in servers.indices where servers[index].group == oldName {
            servers[index].group = newName
            servers[index].updatedAt = Date()
        }
        groups = groups.map { $0 == oldName ? newName : $0 }
        profileStore.save(servers)
        groupStore.save(groups)
        groups = groupStore.load(profileGroups: servers.map(\.group))
        for profile in servers where profile.group == newName { refreshSessionProfiles(profileID: profile.id) }
    }

    func deleteGroup(_ name: String) {
        guard name != "默认分组" else { return }
        for index in servers.indices where servers[index].group == name {
            servers[index].group = "默认分组"
            servers[index].updatedAt = Date()
        }
        groups.removeAll { $0 == name }
        profileStore.save(servers)
        groupStore.save(groups)
        groups = groupStore.load(profileGroups: servers.map(\.group))
    }

    func moveServer(_ profileID: UUID, toGroup group: String) {
        guard groups.contains(group), let index = servers.firstIndex(where: { $0.id == profileID }) else { return }
        servers[index].group = group
        servers[index].updatedAt = Date()
        profileStore.save(servers)
        refreshSessionProfiles(profileID: profileID)
    }

    private func ensureGroupExists(_ group: String) {
        guard !groups.contains(group) else { return }
        groups.append(group)
        groupStore.save(groups)
        groups = groupStore.load(profileGroups: servers.map(\.group))
    }

    func importFinalShellFiles(_ urls: [URL]) async {
        let payload = await FinalShellImporter.load(urls: urls)
        var knownConnections: [String: ServerProfile] = [:]
        for server in servers {
            knownConnections[Self.connectionIdentity(server)] = server
        }
        var importedCount = 0
        var duplicateCount = 0
        var savedCredentialCount = 0
        var credentialSaveFailureCount = 0

        for profile in payload.profiles {
            let identity = Self.connectionIdentity(profile)
            let targetProfile: ServerProfile
            if let existing = knownConnections[identity] {
                duplicateCount += 1
                targetProfile = existing
            } else {
                knownConnections[identity] = profile
                servers.append(profile)
                importedCount += 1
                targetProfile = profile
            }

            if let password = payload.decodedPasswords[profile.id] {
                do {
                    try credentialVault.savePassword(password, profileID: targetProfile.id)
                    savedCredentialCount += 1
                } catch {
                    credentialSaveFailureCount += 1
                }
            }
        }

        if importedCount > 0 {
            profileStore.save(servers)
            groups = groupStore.load(profileGroups: servers.map(\.group))
            groupStore.save(groups)
        }

        var details = ["已导入 \(importedCount) 条 SSH 连接。"]
        if duplicateCount > 0 {
            details.append("跳过 \(duplicateCount) 条重复连接。")
        }
        if payload.skippedRecords > 0 {
            details.append("跳过 \(payload.skippedRecords) 条无法识别的记录。")
        }
        if savedCredentialCount > 0 {
            details.append("已解析并保存 \(savedCredentialCount) 个密码到本地加密凭据库。")
        }
        if payload.failedCredentialCount > 0 {
            details.append("有 \(payload.failedCredentialCount) 个 FinalShell 密码无法解析；对应连接首次使用时需要重新输入。")
        }
        if credentialSaveFailureCount > 0 {
            details.append("有 \(credentialSaveFailureCount) 个已解析密码无法写入本地凭据库。")
        }

        importNotice = ImportNotice(
            title: importedCount > 0 ? "导入完成" : "没有可导入的连接",
            message: details.joined(separator: "\n")
        )
    }

    func exportKiteShellConfiguration(to url: URL) throws {
        try ProfileExchangeService.write(
            profiles: servers,
            groups: groups,
            globalCommands: globalQuickCommands,
            to: url
        )
    }

    func importKiteShellFiles(_ urls: [URL]) async {
        let payload = await ProfileExchangeService.load(urls: urls)
        var knownConnections = Set(servers.map(Self.connectionIdentity))
        var importedCount = 0
        var duplicateCount = 0

        for profile in payload.profiles {
            let identity = Self.connectionIdentity(profile)
            guard !knownConnections.contains(identity) else {
                duplicateCount += 1
                continue
            }
            knownConnections.insert(identity)
            servers.append(profile)
            importedCount += 1
        }

        if importedCount > 0 {
            profileStore.save(servers)
        }
        for group in payload.groups { createGroup(named: group) }
        var knownCommandIDs = Set(globalQuickCommands.map(\.id))
        for command in payload.globalCommands where knownCommandIDs.insert(command.id).inserted {
            globalQuickCommands.append(command)
        }
        commandStore.saveCommands(globalQuickCommands)
        groups = groupStore.load(profileGroups: servers.map(\.group))
        groupStore.save(groups)

        var details = ["已导入 \(importedCount) 条连接。"]
        if duplicateCount > 0 {
            details.append("跳过 \(duplicateCount) 条重复连接。")
        }
        if payload.skippedFiles > 0 {
            details.append("有 \(payload.skippedFiles) 个文件不是受支持的 KiteShell 配置。")
        }
        details.append("导入文件不包含密码；需要时会在首次连接时询问。")

        importNotice = ImportNotice(
            title: importedCount > 0 ? "导入完成" : "没有可导入的连接",
            message: details.joined(separator: "\n")
        )
    }

    func importOpenSSHConfigFiles(_ urls: [URL]) async {
        let payload = await OpenSSHConfigImporter.load(urls: urls)
        var knownConnections = Set(servers.map(Self.connectionIdentity))
        var importedCount = 0
        var duplicateCount = 0
        for profile in payload.profiles {
            let identity = Self.connectionIdentity(profile)
            guard !knownConnections.contains(identity) else {
                duplicateCount += 1
                continue
            }
            knownConnections.insert(identity)
            servers.append(profile)
            importedCount += 1
        }
        if importedCount > 0 {
            profileStore.save(servers)
            groups = groupStore.load(profileGroups: servers.map(\.group))
            groupStore.save(groups)
        }

        var details = ["已导入 \(importedCount) 条 OpenSSH 连接。"]
        if duplicateCount > 0 { details.append("跳过 \(duplicateCount) 条重复连接。") }
        if payload.skippedHosts > 0 {
            details.append("跳过 \(payload.skippedHosts) 个通配符或缺少 User 的 Host。")
        }
        importNotice = ImportNotice(
            title: importedCount > 0 ? "导入完成" : "没有可导入的连接",
            message: details.joined(separator: "\n")
        )
    }

    func toggleFavorite(_ profile: ServerProfile) {
        guard let index = servers.firstIndex(where: { $0.id == profile.id }) else { return }
        servers[index].isFavorite.toggle()
        profileStore.save(servers)
    }

    func selectSession(_ session: Session) {
        selectedSessionID = session.id
        route = .workspace
        persistWorkspace()
    }

    func closeSession(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasSelected = selectedSessionID == session.id
        sessions.remove(at: index)
        terminalControllers[session.id]?.terminate()
        terminalControllers[session.id] = nil
        stopRemoteServices(for: session.id, removeState: true)
        pendingSessionCommands[session.id] = nil
        pendingCommandTasks[session.id]?.cancel()
        pendingCommandTasks[session.id] = nil
        directorySyncTasks[session.id]?.cancel()
        directorySyncTasks[session.id] = nil
        automaticReconnectTasks[session.id]?.cancel()
        automaticReconnectTasks[session.id] = nil
        automaticReconnectAttempts[session.id] = nil

        if wasSelected {
            if sessions.isEmpty {
                selectedSessionID = nil
                route = .connectionCenter
            } else {
                selectedSessionID = sessions[min(index, sessions.count - 1)].id
            }
        }
        persistWorkspace()
    }

    func closeSelectedSession() {
        guard let selectedSession else { return }
        closeSession(selectedSession)
    }

    func moveSession(_ sessionID: UUID, before targetID: UUID) {
        guard sessionID != targetID,
              let sourceIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let originalTargetIndex = sessions.firstIndex(where: { $0.id == targetID }) else { return }
        let session = sessions.remove(at: sourceIndex)
        let targetIndex = sourceIndex < originalTargetIndex ? originalTargetIndex - 1 : originalTargetIndex
        sessions.insert(session, at: targetIndex)
        persistWorkspace()
    }

    func reconnectSelectedSession() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }) else { return }
        if session.profile.authentication == .password {
            if let savedPassword = try? credentialVault.readPassword(profileID: session.profile.id),
               !savedPassword.isEmpty {
                reconnectSession(id: id, password: savedPassword)
                return
            }
            passwordRequest = PasswordRequest(
                profile: session.profile,
                reconnectSessionID: session.id,
                pendingCommand: nil,
                kind: .password
            )
        } else if session.profile.authentication == .privateKey,
                  PrivateKeyInspector.requiresPassphrase(at: session.profile.identityFilePath) {
            if let savedPassphrase = try? credentialVault.readPrivateKeyPassphrase(profileID: session.profile.id),
               !savedPassphrase.isEmpty {
                reconnectSession(id: id, password: savedPassphrase)
                return
            }
            passwordRequest = PasswordRequest(
                profile: session.profile,
                reconnectSessionID: session.id,
                pendingCommand: nil,
                kind: .privateKeyPassphrase
            )
        } else {
            reconnectSession(id: id, password: nil)
        }
    }

    func reconnectSelectedSessionRequestingPassword() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }),
              session.profile.authentication == .password else { return }
        try? credentialVault.removePassword(profileID: session.profile.id)
        passwordRequest = PasswordRequest(
            profile: session.profile,
            reconnectSessionID: session.id,
            pendingCommand: nil,
            kind: .password
        )
    }

    func reconnectSelectedSessionRequestingPrivateKeyPassphrase() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }),
              session.profile.authentication == .privateKey else { return }
        try? credentialVault.removePrivateKeyPassphrase(profileID: session.profile.id)
        passwordRequest = PasswordRequest(
            profile: session.profile,
            reconnectSessionID: session.id,
            pendingCommand: nil,
            kind: .privateKeyPassphrase
        )
    }

    func toggleInspector() {
        isInspectorVisible.toggle()
        if isInspectorVisible { focusMode = false }
        persistWorkspace()
    }

    func toggleFilePanel() {
        isFilePanelVisible.toggle()
        if isFilePanelVisible { focusMode = false }
        persistWorkspace()
    }

    func toggleFocusMode() {
        focusMode.toggle()
        persistWorkspace()
    }

    func clearSavedWorkspace() {
        workspaceStore.clear()
        importNotice = ImportNotice(
            title: "已清除工作区记录",
            message: "下次启动将打开连接中心，不会恢复当前标签。"
        )
    }

    func clearRemoteEditCache() {
        for handle in remoteEditHandles.values { handle.watcher.stop() }
        remoteEditHandles = [:]
        remoteEditPreparationTasks.values.forEach { $0.cancel() }
        remoteEditPreparationTasks = [:]
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = cacheRoot.appending(path: "KiteShell/RemoteEdits", directoryHint: .isDirectory)
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            importNotice = ImportNotice(title: "缓存已清理", message: "远程编辑临时副本已删除；连接、凭据和脚本未受影响。")
        } catch {
            importNotice = ImportNotice(title: "无法清理缓存", message: error.localizedDescription)
        }
    }

    func applyTerminalAppearance() {
        for controller in terminalControllers.values {
            controller.applyAppearance()
        }
    }

    func quickCommands(for sessionID: UUID) -> [QuickCommand] {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return [] }
        return servers.first(where: { $0.id == session.profile.id })?.quickCommands
            ?? session.profile.quickCommands
    }

    func runQuickCommand(_ command: QuickCommand, in sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }), session.state == .connected else { return }
        terminalControllers[sessionID]?.sendCommand(command.command)
        recordCommandExecution(command, profileName: session.profile.name, mode: command.executionMode)
        selectedSessionID = sessionID
        route = .workspace
    }

    func runResolvedQuickCommand(_ command: QuickCommand, content: String, mode: CommandExecutionMode, in sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }), session.state == .connected else { return }
        if mode == .insert {
            terminalControllers[sessionID]?.insertText(content)
        } else {
            terminalControllers[sessionID]?.sendCommand(content)
        }
        recordCommandExecution(command, profileName: session.profile.name, mode: mode)
        selectedSessionID = sessionID
        route = .workspace
    }

    func saveQuickCommand(_ command: QuickCommand, for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let profileIndex = servers.firstIndex(where: { $0.id == session.profile.id }) else { return }
        if let commandIndex = servers[profileIndex].quickCommands.firstIndex(where: { $0.id == command.id }) {
            servers[profileIndex].quickCommands[commandIndex] = command
        } else {
            servers[profileIndex].quickCommands.append(command)
        }
        profileStore.save(servers)
    }

    func deleteQuickCommand(_ command: QuickCommand, for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let profileIndex = servers.firstIndex(where: { $0.id == session.profile.id }) else { return }
        servers[profileIndex].quickCommands.removeAll { $0.id == command.id }
        profileStore.save(servers)
    }

    func saveGlobalQuickCommand(_ command: QuickCommand) {
        if let index = globalQuickCommands.firstIndex(where: { $0.id == command.id }) {
            globalQuickCommands[index] = command
        } else {
            globalQuickCommands.append(command)
        }
        commandStore.saveCommands(globalQuickCommands)
    }

    func deleteGlobalQuickCommand(_ command: QuickCommand) {
        globalQuickCommands.removeAll { $0.id == command.id }
        commandStore.saveCommands(globalQuickCommands)
    }

    func clearCommandExecutionHistory() {
        commandExecutionHistory = []
        commandStore.saveHistory([])
    }

    private func recordCommandExecution(_ command: QuickCommand, profileName: String, mode: CommandExecutionMode) {
        commandExecutionHistory.insert(
            CommandExecutionRecord(commandName: command.name, profileName: profileName, mode: mode),
            at: 0
        )
        if commandExecutionHistory.count > 100 { commandExecutionHistory.removeLast(commandExecutionHistory.count - 100) }
        commandStore.saveHistory(commandExecutionHistory)
    }

    func sendTerminalCommand(_ command: String, in sessionID: UUID) {
        guard sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        terminalControllers[sessionID]?.sendCommand(command)
        selectedSessionID = sessionID
        route = .workspace
    }

    func insertTerminalText(_ text: String, in sessionID: UUID) {
        guard sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        terminalControllers[sessionID]?.insertText(text)
        selectedSessionID = sessionID
        route = .workspace
    }

    func portForwards(for sessionID: UUID) -> [PortForwardConfiguration] {
        guard let profileID = sessions.first(where: { $0.id == sessionID })?.profile.id else { return [] }
        return servers.first(where: { $0.id == profileID })?.portForwards ?? []
    }

    func savePortForward(_ configuration: PortForwardConfiguration, for sessionID: UUID) {
        guard configuration.isValid,
              let session = sessions.first(where: { $0.id == sessionID }),
              let profileIndex = servers.firstIndex(where: { $0.id == session.profile.id }) else { return }
        if let index = servers[profileIndex].portForwards.firstIndex(where: { $0.id == configuration.id }) {
            servers[profileIndex].portForwards[index] = configuration
        } else {
            servers[profileIndex].portForwards.append(configuration)
        }
        servers[profileIndex].updatedAt = Date()
        profileStore.save(servers)
        refreshSessionProfiles(profileID: servers[profileIndex].id)
    }

    func togglePortForward(_ configuration: PortForwardConfiguration, for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let profileIndex = servers.firstIndex(where: { $0.id == session.profile.id }),
              let forwardIndex = servers[profileIndex].portForwards.firstIndex(where: { $0.id == configuration.id }) else { return }
        let shouldEnable = !servers[profileIndex].portForwards[forwardIndex].isEnabled

        guard session.state == .connected,
              let controller = terminalControllers[sessionID] else {
            servers[profileIndex].portForwards[forwardIndex].isEnabled = shouldEnable
            profileStore.save(servers)
            refreshSessionProfiles(profileID: servers[profileIndex].id)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await SSHControlService.setPortForward(
                    configuration,
                    enabled: shouldEnable,
                    context: controller.remoteCommandContext
                )
                guard let currentProfileIndex = servers.firstIndex(where: { $0.id == session.profile.id }),
                      let currentForwardIndex = servers[currentProfileIndex].portForwards.firstIndex(where: { $0.id == configuration.id }) else { return }
                servers[currentProfileIndex].portForwards[currentForwardIndex].isEnabled = shouldEnable
                profileStore.save(servers)
                refreshSessionProfiles(profileID: servers[currentProfileIndex].id)
            } catch {
                importNotice = ImportNotice(
                    title: shouldEnable ? "无法启动端口转发" : "无法停止端口转发",
                    message: error.localizedDescription
                )
            }
        }
    }

    func deletePortForward(_ configuration: PortForwardConfiguration, for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              servers.contains(where: { $0.id == session.profile.id }) else { return }
        let remove = { [weak self] in
            guard let self,
                  let currentIndex = servers.firstIndex(where: { $0.id == session.profile.id }) else { return }
            servers[currentIndex].portForwards.removeAll { $0.id == configuration.id }
            profileStore.save(servers)
            refreshSessionProfiles(profileID: servers[currentIndex].id)
        }

        if configuration.isEnabled,
           session.state == .connected,
           let controller = terminalControllers[sessionID] {
            Task { @MainActor [weak self] in
                do {
                    try await SSHControlService.setPortForward(
                        configuration,
                        enabled: false,
                        context: controller.remoteCommandContext
                    )
                    remove()
                } catch {
                    self?.importNotice = ImportNotice(
                        title: "无法删除运行中的转发",
                        message: error.localizedDescription
                    )
                }
            }
        } else {
            remove()
        }
    }

    func refreshMonitor(for sessionID: UUID) {
        if configuredMonitorInterval > 0 {
            startMonitor(for: sessionID)
            return
        }
        monitorTasks[sessionID]?.cancel()
        monitorTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadMonitorSnapshot(for: sessionID)
            monitorTasks[sessionID] = nil
        }
    }

    func refreshMonitorPolling() {
        for session in sessions where session.state == .connected {
            startMonitor(for: session.id)
        }
    }

    func terminateRemoteProcess(pid: Int, in sessionID: UUID) {
        guard pid > 1,
              let controller = terminalControllers[sessionID],
              sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await SSHCommandRunner.run(
                    context: controller.remoteCommandContext,
                    command: "kill -TERM -- \(pid)"
                )
                importNotice = ImportNotice(
                    title: "已发送终止信号",
                    message: "已向 PID \(pid) 发送 SIGTERM。进程列表将在下一次采样时更新。"
                )
                refreshMonitor(for: sessionID)
            } catch {
                importNotice = ImportNotice(
                    title: "无法结束进程",
                    message: error.localizedDescription
                )
            }
        }
    }

    func refreshRemoteDirectory(for sessionID: UUID) {
        let path: String?
        if case .loaded(let listing) = remoteDirectoryStates[sessionID] {
            path = listing.path
        } else {
            path = nil
        }
        loadRemoteDirectory(for: sessionID, path: path)
    }

    func openRemoteDirectory(for sessionID: UUID, path: String) {
        loadRemoteDirectory(for: sessionID, path: path)
    }

    func openRemoteDirectory(for sessionID: UUID, entry: RemoteFileEntry) {
        guard entry.isDirectory,
              case .loaded(let listing) = remoteDirectoryStates[sessionID] else { return }
        loadRemoteDirectory(
            for: sessionID,
            path: RemoteFileService.childPath(parent: listing.path, name: entry.name)
        )
    }

    func openParentRemoteDirectory(for sessionID: UUID) {
        guard case .loaded(let listing) = remoteDirectoryStates[sessionID],
              listing.path != "/" else { return }
        loadRemoteDirectory(
            for: sessionID,
            path: RemoteFileService.parentPath(of: listing.path)
        )
    }

    func isFollowingTerminalDirectory(for sessionID: UUID) -> Bool {
        directoryFollowEnabled[sessionID] ?? true
    }

    func toggleTerminalDirectoryFollowing(for sessionID: UUID) {
        directoryFollowEnabled[sessionID] = !(directoryFollowEnabled[sessionID] ?? true)
    }

    func uploadFiles(_ urls: [URL], to sessionID: UUID) {
        guard !urls.isEmpty,
              let controller = terminalControllers[sessionID],
              let directory = currentRemoteDirectory(for: sessionID),
              sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        let controllerID = controller.id
        let batch = UploadBatchProgress(urls: urls)
        let operationID = batch.id
        fileTransferTasks[sessionID]?.cancel()
        fileTransferControls[sessionID]?.cancel()
        let transferControl = TransferProcessControl()
        fileTransferControls[sessionID] = transferControl
        fileTransferIDs[sessionID] = operationID
        fileTransferActivity[sessionID] = nil
        uploadBatches[sessionID] = batch
        fileTransferTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var failureCount = 0
            for (index, url) in urls.enumerated() {
                guard !Task.isCancelled,
                      terminalControllers[sessionID]?.id == controllerID,
                      fileTransferIDs[sessionID] == operationID else { return }
                updateUploadItem(sessionID: sessionID, batchID: operationID, index: index) {
                    $0.status = .preparing
                }

                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let metrics = await Task.detached(priority: .utility) {
                    LocalUploadMetrics.measure(url)
                }.value
                let remotePath = RemoteFileService.childPath(
                    parent: directory,
                    name: url.lastPathComponent
                )
                updateUploadItem(sessionID: sessionID, batchID: operationID, index: index) {
                    $0.isDirectory = metrics.isDirectory
                    $0.totalBytes = metrics.totalBytes
                    $0.status = .uploading
                    $0.startedAt = Date()
                }

                let progressTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self,
                              terminalControllers[sessionID]?.id == controllerID,
                              fileTransferIDs[sessionID] == operationID else { return }
                        if let output = try? await SSHCommandRunner.run(
                            context: controller.remoteCommandContext,
                            command: RemoteFileService.transferSizeCommand(
                                path: remotePath,
                                isDirectory: metrics.isDirectory
                            )
                        ), let bytes = Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            updateUploadItem(
                                sessionID: sessionID,
                                batchID: operationID,
                                index: index
                            ) {
                                $0.transferredBytes = metrics.totalBytes > 0
                                    ? min(max(0, bytes), metrics.totalBytes)
                                    : max(0, bytes)
                                if let startedAt = $0.startedAt {
                                    let elapsed = max(0.1, Date().timeIntervalSince(startedAt))
                                    $0.bytesPerSecond = Double($0.transferredBytes) / elapsed
                                }
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(350))
                    }
                }

                do {
                    try await SFTPTransferService.upload(
                        localURL: url,
                        remotePath: remotePath,
                        context: controller.remoteCommandContext,
                        control: transferControl
                    )
                    progressTask.cancel()
                    guard !Task.isCancelled else { return }
                    updateUploadItem(sessionID: sessionID, batchID: operationID, index: index) {
                        $0.transferredBytes = metrics.totalBytes
                        if let startedAt = $0.startedAt {
                            let elapsed = max(0.1, Date().timeIntervalSince(startedAt))
                            $0.bytesPerSecond = Double(metrics.totalBytes) / elapsed
                        }
                        $0.status = .completed
                    }
                } catch is CancellationError {
                    progressTask.cancel()
                    if fileTransferIDs[sessionID] == operationID {
                        markUnfinishedUploadItemsCancelled(sessionID: sessionID, batchID: operationID)
                    }
                    return
                } catch {
                    progressTask.cancel()
                    failureCount += 1
                    updateUploadItem(sessionID: sessionID, batchID: operationID, index: index) {
                        $0.status = .failed(error.localizedDescription)
                    }
                }
            }

            guard terminalControllers[sessionID]?.id == controllerID,
                  fileTransferIDs[sessionID] == operationID,
                  !Task.isCancelled else { return }
            if failureCount > 0 {
                importNotice = ImportNotice(
                    title: "部分文件上传失败",
                    message: "成功 \(urls.count - failureCount) 个，失败 \(failureCount) 个。可在上传进度列表中查看每个文件的错误。"
                )
            }
            UserNotificationService.post(
                title: failureCount > 0 ? "KiteShell 上传部分失败" : "KiteShell 上传完成",
                body: failureCount > 0
                    ? "完成 \(urls.count - failureCount) 个，失败 \(failureCount) 个。"
                    : "\(urls.count) 个项目已全部上传。"
            )
            loadRemoteDirectory(for: sessionID, path: directory)
            if fileTransferIDs[sessionID] == operationID {
                fileTransferTasks[sessionID] = nil
                fileTransferIDs[sessionID] = nil
                fileTransferControls[sessionID] = nil
            }
        }
    }

    func clearUploadBatch(for sessionID: UUID) {
        guard uploadBatches[sessionID]?.isFinished == true else { return }
        uploadBatches[sessionID] = nil
    }

    func cancelUploadBatch(for sessionID: UUID) {
        guard let batch = uploadBatches[sessionID], !batch.isFinished else { return }
        fileTransferTasks[sessionID]?.cancel()
        fileTransferControls[sessionID]?.cancel()
        fileTransferControls[sessionID] = nil
        fileTransferTasks[sessionID] = nil
        fileTransferIDs[sessionID] = nil
        fileTransferActivity[sessionID] = nil
        markUnfinishedUploadItemsCancelled(sessionID: sessionID, batchID: batch.id)
    }

    func pauseUploadBatch(for sessionID: UUID) {
        guard var batch = uploadBatches[sessionID], !batch.isFinished else { return }
        fileTransferControls[sessionID]?.pause()
        for index in batch.items.indices where batch.items[index].status == .uploading {
            batch.items[index].status = .paused
        }
        uploadBatches[sessionID] = batch
    }

    func resumeUploadBatch(for sessionID: UUID) {
        guard var batch = uploadBatches[sessionID], batch.isPaused else { return }
        fileTransferControls[sessionID]?.resume()
        for index in batch.items.indices where batch.items[index].status == .paused {
            batch.items[index].status = .uploading
        }
        uploadBatches[sessionID] = batch
    }

    func retryFailedUploads(for sessionID: UUID) {
        guard let batch = uploadBatches[sessionID] else { return }
        let urls = batch.items.compactMap { item -> URL? in
            switch item.status {
            case .failed, .cancelled:
                item.localURL
            case .waiting, .preparing, .uploading, .paused, .completed:
                nil
            }
        }
        guard !urls.isEmpty else { return }
        uploadFiles(urls, to: sessionID)
    }

    func downloadRemoteFile(
        _ entry: RemoteFileEntry,
        from sessionID: UUID,
        to localURL: URL
    ) {
        guard let controller = terminalControllers[sessionID],
              let directory = currentRemoteDirectory(for: sessionID),
              sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        let controllerID = controller.id
        let operationID = UUID()
        let remotePath = RemoteFileService.childPath(parent: directory, name: entry.name)
        fileTransferTasks[sessionID]?.cancel()
        fileTransferControls[sessionID]?.cancel()
        fileTransferControls[sessionID] = nil
        fileTransferIDs[sessionID] = operationID
        fileTransferActivity[sessionID] = "正在下载 \(entry.name)…"
        fileTransferTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await SFTPTransferService.download(
                    remotePath: remotePath,
                    localURL: localURL,
                    isDirectory: entry.isDirectory,
                    context: controller.remoteCommandContext
                )
                guard terminalControllers[sessionID]?.id == controllerID,
                      fileTransferIDs[sessionID] == operationID,
                      !Task.isCancelled else { return }
                fileTransferActivity[sessionID] = nil
                UserNotificationService.post(
                    title: "KiteShell 下载完成",
                    body: "\(entry.name) 已下载。"
                )
                importNotice = ImportNotice(title: "下载完成", message: "文件已保存到所选位置。")
            } catch {
                guard fileTransferIDs[sessionID] == operationID,
                      !Task.isCancelled else { return }
                fileTransferActivity[sessionID] = nil
                importNotice = ImportNotice(title: "下载失败", message: error.localizedDescription)
                UserNotificationService.post(
                    title: "KiteShell 下载失败",
                    body: "\(entry.name) 未能下载。"
                )
            }
            if fileTransferIDs[sessionID] == operationID {
                fileTransferTasks[sessionID] = nil
                fileTransferIDs[sessionID] = nil
            }
        }
    }

    func openRemoteFileForEditing(_ entry: RemoteFileEntry, from sessionID: UUID) {
        guard !entry.isDirectory,
              let directory = currentRemoteDirectory(for: sessionID) else { return }
        let remotePath = RemoteFileService.childPath(parent: directory, name: entry.name)
        let key = RemoteEditKey(sessionID: sessionID, remotePath: remotePath)

        if let handle = remoteEditHandles[key],
           FileManager.default.fileExists(atPath: handle.localURL.path) {
            if !NSWorkspace.shared.open(handle.localURL) {
                importNotice = ImportNotice(
                    title: "无法打开本地副本",
                    message: "macOS 没有找到可打开 \(entry.name) 的应用。"
                )
            } else {
                setRemoteEditActivity("正在编辑 \(entry.name) · 保存后自动同步", for: sessionID)
            }
            return
        }

        guard let controller = terminalControllers[sessionID],
              sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        let controllerID = controller.id

        do {
            let localURL = try makeRemoteEditURL(fileName: entry.name, sessionID: sessionID)
            remoteEditPreparationTasks[key]?.cancel()
            setRemoteEditActivity("正在下载并打开 \(entry.name)…", for: sessionID)
            remoteEditPreparationTasks[key] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { remoteEditPreparationTasks[key] = nil }
                do {
                    try await SFTPTransferService.download(
                        remotePath: remotePath,
                        localURL: localURL,
                        context: controller.remoteCommandContext
                    )
                    guard terminalControllers[sessionID]?.id == controllerID,
                          sessions.first(where: { $0.id == sessionID })?.state == .connected,
                          !Task.isCancelled else { return }

                    guard NSWorkspace.shared.open(localURL) else {
                        throw RemoteCommandError.launchFailed("macOS 没有找到可打开 \(entry.name) 的应用")
                    }

                    let watcher = RemoteFileEditWatcher(localURL: localURL) { [weak self] in
                        guard let self else { return true }
                        return await self.syncEditedRemoteFile(
                            key: key,
                            localURL: localURL,
                            fileName: entry.name
                        )
                    }
                    let remoteVersion = try? await SSHCommandRunner.run(
                        context: controller.remoteCommandContext,
                        command: RemoteFileService.versionCommand(path: remotePath)
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    remoteEditHandles[key] = RemoteEditHandle(
                        localURL: localURL,
                        watcher: watcher,
                        remoteVersion: remoteVersion?.isEmpty == false ? remoteVersion : nil
                    )
                    watcher.start()
                    setRemoteEditActivity(
                        "正在编辑 \(entry.name) · 保存后自动同步",
                        for: sessionID,
                        clearAfter: 3
                    )
                } catch is CancellationError {
                    return
                } catch {
                    remoteEditActivity[sessionID] = nil
                    importNotice = ImportNotice(title: "无法打开远程文件", message: error.localizedDescription)
                }
            }
        } catch {
            remoteEditActivity[sessionID] = nil
            importNotice = ImportNotice(title: "无法创建本地编辑副本", message: error.localizedDescription)
        }
    }

    func loadRemoteTextFile(_ entry: RemoteFileEntry, from sessionID: UUID) async throws -> RemoteTextDocument {
        guard !entry.isDirectory,
              entry.sizeBytes <= 2 * 1_024 * 1_024,
              let directory = currentRemoteDirectory(for: sessionID),
              let controller = terminalControllers[sessionID],
              sessions.first(where: { $0.id == sessionID })?.state == .connected else {
            if entry.sizeBytes > 2 * 1_024 * 1_024 { throw RemoteTextEditorError.tooLarge(entry.sizeBytes) }
            throw RemoteTextEditorError.unavailable
        }
        let path = RemoteFileService.childPath(parent: directory, name: entry.name)
        let encoded = try await SSHCommandRunner.run(
            context: controller.remoteCommandContext,
            command: "base64 < \(RemoteFileService.shellQuote(path))"
        )
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let content = String(data: data, encoding: .utf8),
              !content.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RemoteTextEditorError.binary
        }
        let version = try? await SSHCommandRunner.run(
            context: controller.remoteCommandContext,
            command: RemoteFileService.versionCommand(path: path)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteTextDocument(
            content: content,
            remoteVersion: version?.isEmpty == false ? version : nil,
            usesCRLF: content.contains("\r\n")
        )
    }

    func saveRemoteTextFile(
        _ content: String,
        entry: RemoteFileEntry,
        expectedVersion: String?,
        in sessionID: UUID
    ) async throws -> String? {
        guard let directory = currentRemoteDirectory(for: sessionID),
              let controller = terminalControllers[sessionID],
              sessions.first(where: { $0.id == sessionID })?.state == .connected else {
            throw RemoteTextEditorError.unavailable
        }
        let path = RemoteFileService.childPath(parent: directory, name: entry.name)
        if let expectedVersion,
           let current = try? await SSHCommandRunner.run(
                context: controller.remoteCommandContext,
                command: RemoteFileService.versionCommand(path: path)
           ).trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty,
           current != expectedVersion {
            throw RemoteTextEditorError.changedRemotely
        }
        let localURL = FileManager.default.temporaryDirectory.appending(path: "KiteShell-\(UUID().uuidString)-\(entry.name)")
        defer { try? FileManager.default.removeItem(at: localURL) }
        try Data(content.utf8).write(to: localURL, options: .atomic)
        try await SFTPTransferService.upload(localURL: localURL, remotePath: path, context: controller.remoteCommandContext)
        loadRemoteDirectory(for: sessionID, path: directory)
        let newVersion = try? await SSHCommandRunner.run(
            context: controller.remoteCommandContext,
            command: RemoteFileService.versionCommand(path: path)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return newVersion?.isEmpty == false ? newVersion : nil
    }

    func createRemoteDirectory(named name: String, in sessionID: UUID) {
        guard validateRemoteName(name),
              let directory = currentRemoteDirectory(for: sessionID) else {
            showInvalidRemoteNameNotice()
            return
        }
        performRemoteFileMutation(
            command: RemoteFileService.createDirectoryCommand(parent: directory, name: name),
            sessionID: sessionID,
            directory: directory,
            successTitle: "文件夹已创建"
        )
    }

    func createRemoteFile(named name: String, in sessionID: UUID) {
        guard validateRemoteName(name),
              let directory = currentRemoteDirectory(for: sessionID) else {
            showInvalidRemoteNameNotice()
            return
        }
        performRemoteFileMutation(
            command: RemoteFileService.createFileCommand(parent: directory, name: name),
            sessionID: sessionID,
            directory: directory,
            successTitle: "文件已创建"
        )
    }

    func duplicateRemoteEntry(_ entry: RemoteFileEntry, as newName: String, in sessionID: UUID) {
        guard validateRemoteName(newName),
              let directory = currentRemoteDirectory(for: sessionID) else {
            showInvalidRemoteNameNotice()
            return
        }
        performRemoteFileMutation(
            command: RemoteFileService.duplicateCommand(
                parent: directory,
                entry: entry,
                newName: newName
            ),
            sessionID: sessionID,
            directory: directory,
            successTitle: "副本已创建"
        )
    }

    func changeRemotePermissions(_ entry: RemoteFileEntry, mode: String, in sessionID: UUID) {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil,
              let directory = currentRemoteDirectory(for: sessionID) else {
            importNotice = ImportNotice(title: "权限格式无效", message: "请输入三位或四位八进制权限，例如 644、755 或 0755。")
            return
        }
        performRemoteFileMutation(
            command: RemoteFileService.changePermissionsCommand(
                parent: directory,
                entry: entry,
                mode: trimmed
            ),
            sessionID: sessionID,
            directory: directory,
            successTitle: "文件权限已更新"
        )
    }

    func renameRemoteEntry(_ entry: RemoteFileEntry, to newName: String, in sessionID: UUID) {
        guard validateRemoteName(newName),
              let directory = currentRemoteDirectory(for: sessionID) else {
            showInvalidRemoteNameNotice()
            return
        }
        performRemoteFileMutation(
            command: RemoteFileService.renameCommand(
                parent: directory,
                oldName: entry.name,
                newName: newName
            ),
            sessionID: sessionID,
            directory: directory,
            successTitle: "重命名完成"
        )
    }

    func moveRemoteEntry(_ entry: RemoteFileEntry, to destinationPath: String, in sessionID: UUID) {
        let destination = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard destination.hasPrefix("/"),
              let directory = currentRemoteDirectory(for: sessionID) else {
            importNotice = ImportNotice(title: "目标路径无效", message: "请输入以 / 开头的远程绝对路径。")
            return
        }
        performRemoteFileMutation(
            command: RemoteFileService.moveCommand(
                parent: directory,
                entry: entry,
                destinationPath: destination
            ),
            sessionID: sessionID,
            directory: directory,
            successTitle: "移动完成"
        )
    }

    func deleteRemoteEntry(_ entry: RemoteFileEntry, in sessionID: UUID) {
        guard let directory = currentRemoteDirectory(for: sessionID) else { return }
        performRemoteFileMutation(
            command: RemoteFileService.deleteCommand(parent: directory, entry: entry),
            sessionID: sessionID,
            directory: directory,
            successTitle: "已删除 \(entry.name)"
        )
    }

    private func reconnectSession(
        id: UUID,
        password: String?,
        resetAutomaticAttempts: Bool = true
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        automaticReconnectTasks[id]?.cancel()
        automaticReconnectTasks[id] = nil
        if resetAutomaticAttempts {
            automaticReconnectAttempts[id] = 0
        }
        terminalControllers[id]?.terminate()
        stopRemoteServices(for: id, removeState: false)
        sessions[index].state = .reconnecting
        monitorStates[id] = .idle
        remoteDirectoryStates[id] = .idle
        terminalControllers[id] = makeTerminalController(for: sessions[index], password: password)
    }

    private func makeTerminalController(
        for session: Session,
        password: String?
    ) -> TerminalSessionController {
        let controller = TerminalSessionController(
            profile: session.profile,
            jumpHost: session.profile.jumpHostID.flatMap { jumpHostID in
                servers.first { $0.id == jumpHostID }
            },
            oneTimePassword: password
        )
        let controllerID = controller.id
        controller.onStateChange = { [weak self] state in
            self?.updateConnectionState(
                sessionID: session.id,
                controllerID: controllerID,
                state: state
            )
        }
        controller.onWorkingDirectoryChange = { [weak self] path in
            self?.syncRemoteDirectory(sessionID: session.id, path: path)
        }
        return controller
    }

    private func updateConnectionState(
        sessionID: UUID,
        controllerID: UUID,
        state: ConnectionState
    ) {
        guard terminalControllers[sessionID]?.id == controllerID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        sessions[sessionIndex].state = state
        DiagnosticsCenter.record("ssh", "会话状态更新为 \(state.label)")

        if state == .connected {
            automaticReconnectTasks[sessionID]?.cancel()
            automaticReconnectTasks[sessionID] = nil
            automaticReconnectAttempts[sessionID] = 0
            startMonitor(for: sessionID)
            loadRemoteDirectory(for: sessionID, path: nil)
            runPendingCommandAfterShellIsReady(for: sessionID)
        } else {
            stopRemoteServices(for: sessionID, removeState: false)
            if state == .failed || state == .disconnected {
                pendingSessionCommands[sessionID] = nil
                pendingCommandTasks[sessionID]?.cancel()
                pendingCommandTasks[sessionID] = nil
                scheduleAutomaticReconnect(for: sessionID)
            }
        }

        guard state == .connected,
              let profileIndex = servers.firstIndex(where: { $0.id == sessions[sessionIndex].profile.id }) else {
            return
        }
        servers[profileIndex].lastConnectedAt = Date()
        profileStore.save(servers)
    }

    private func scheduleAutomaticReconnect(for sessionID: UUID) {
        guard automaticReconnectTasks[sessionID] == nil,
              let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let profile = sessions[index].profile
        let policy = profile.reconnectPolicy
        guard policy != .disabled else { return }

        let completedAttempts = automaticReconnectAttempts[sessionID] ?? 0
        if let maximum = policy.maximumAttempts, completedAttempts >= maximum { return }

        let password: String?
        if profile.authentication == .password {
            guard let saved = try? credentialVault.readPassword(profileID: profile.id),
                  !saved.isEmpty else { return }
            password = saved
        } else if profile.authentication == .privateKey,
                  PrivateKeyInspector.requiresPassphrase(at: profile.identityFilePath) {
            guard let saved = try? credentialVault.readPrivateKeyPassphrase(profileID: profile.id),
                  !saved.isEmpty else { return }
            password = saved
        } else {
            password = nil
        }

        let nextAttempt = completedAttempts + 1
        automaticReconnectAttempts[sessionID] = nextAttempt
        sessions[index].state = .reconnecting
        let delay = min(pow(2.0, Double(nextAttempt - 1)), 30)
        automaticReconnectTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled,
                  let current = sessions.first(where: { $0.id == sessionID }),
                  current.state == .reconnecting else { return }
            automaticReconnectTasks[sessionID] = nil
            reconnectSession(
                id: sessionID,
                password: password,
                resetAutomaticAttempts: false
            )
        }
    }

    private func startMonitor(for sessionID: UUID) {
        monitorTasks[sessionID]?.cancel()
        guard sessions.first(where: { $0.id == sessionID })?.state == .connected else {
            monitorStates[sessionID] = .idle
            return
        }

        let effectiveInterval = configuredMonitorInterval
        guard effectiveInterval > 0 else {
            monitorStates[sessionID] = .idle
            monitorTasks[sessionID] = nil
            return
        }

        monitorTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  sessions.first(where: { $0.id == sessionID })?.state == .connected {
                await loadMonitorSnapshot(for: sessionID)
                guard !Task.isCancelled else { break }
                let configured = configuredMonitorInterval
                if configured <= 0 {
                    monitorStates[sessionID] = .idle
                    break
                }
                try? await Task.sleep(for: .seconds(configured))
            }
            monitorTasks[sessionID] = nil
        }
    }

    private func loadMonitorSnapshot(for sessionID: UUID) async {
        guard let controller = terminalControllers[sessionID],
              sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        if case .loaded = monitorStates[sessionID] {
            // Keep the last sample visible while the next one is collected.
        } else {
            monitorStates[sessionID] = .loading
        }

        let controllerID = controller.id
        do {
            let output = try await SSHCommandRunner.run(
                context: controller.remoteCommandContext,
                command: LinuxMonitorService.command
            )
            var snapshot = try await Task.detached(priority: .utility) {
                try LinuxMonitorService.parse(output)
            }.value
            guard terminalControllers[sessionID]?.id == controllerID,
                  sessions.first(where: { $0.id == sessionID })?.state == .connected,
                  !Task.isCancelled else { return }
            if case .loaded(let previous) = monitorStates[sessionID] {
                let elapsed = max(0.1, snapshot.sampledAt.timeIntervalSince(previous.sampledAt))
                snapshot.networkReceiveBytesPerSecond = Double(
                    max(0, snapshot.networkReceiveBytes - previous.networkReceiveBytes)
                ) / elapsed
                snapshot.networkTransmitBytesPerSecond = Double(
                    max(0, snapshot.networkTransmitBytes - previous.networkTransmitBytes)
                ) / elapsed
            }
            monitorStates[sessionID] = .loaded(snapshot)
        } catch is CancellationError {
            return
        } catch {
            guard terminalControllers[sessionID]?.id == controllerID,
                  sessions.first(where: { $0.id == sessionID })?.state == .connected,
                  !Task.isCancelled else { return }
            monitorStates[sessionID] = .failed(error.localizedDescription)
        }
    }

    private func loadRemoteDirectory(for sessionID: UUID, path: String?) {
        remoteDirectoryTasks[sessionID]?.cancel()
        guard let controller = terminalControllers[sessionID],
              sessions.first(where: { $0.id == sessionID })?.state == .connected else {
            remoteDirectoryStates[sessionID] = .idle
            return
        }

        let controllerID = controller.id
        remoteDirectoryStates[sessionID] = .loading(path: path)
        remoteDirectoryTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await SSHCommandRunner.run(
                    context: controller.remoteCommandContext,
                    command: RemoteFileService.command(path: path)
                )
                let listing = try await Task.detached(priority: .utility) {
                    try RemoteFileService.parse(output)
                }.value
                guard terminalControllers[sessionID]?.id == controllerID,
                      sessions.first(where: { $0.id == sessionID })?.state == .connected,
                      !Task.isCancelled else { return }
                remoteDirectoryStates[sessionID] = .loaded(listing)
            } catch is CancellationError {
                return
            } catch {
                guard terminalControllers[sessionID]?.id == controllerID,
                      sessions.first(where: { $0.id == sessionID })?.state == .connected,
                      !Task.isCancelled else { return }
                remoteDirectoryStates[sessionID] = .failed(error.localizedDescription)
            }
            remoteDirectoryTasks[sessionID] = nil
        }
    }

    private func stopRemoteServices(for sessionID: UUID, removeState: Bool) {
        monitorTasks[sessionID]?.cancel()
        monitorTasks[sessionID] = nil
        remoteDirectoryTasks[sessionID]?.cancel()
        remoteDirectoryTasks[sessionID] = nil
        fileTransferTasks[sessionID]?.cancel()
        fileTransferTasks[sessionID] = nil
        fileTransferIDs[sessionID] = nil
        fileTransferActivity[sessionID] = nil
        if var batch = uploadBatches[sessionID], !batch.isFinished {
            for index in batch.items.indices {
                switch batch.items[index].status {
                case .waiting, .preparing, .uploading, .paused:
                    batch.items[index].status = .failed("SSH 连接已中断")
                case .completed, .failed, .cancelled:
                    break
                }
            }
            uploadBatches[sessionID] = batch
        }
        directorySyncTasks[sessionID]?.cancel()
        directorySyncTasks[sessionID] = nil
        if removeState {
            stopRemoteFileEditing(for: sessionID)
            uploadBatches[sessionID] = nil
            monitorStates[sessionID] = nil
            remoteDirectoryStates[sessionID] = nil
        }
    }

    private var configuredMonitorInterval: Double {
        guard UserDefaults.standard.object(forKey: "monitorInterval") != nil else { return 3 }
        return UserDefaults.standard.double(forKey: "monitorInterval")
    }

    private func currentRemoteDirectory(for sessionID: UUID) -> String? {
        guard case .loaded(let listing) = remoteDirectoryStates[sessionID] else { return nil }
        return listing.path
    }

    private func updateUploadItem(
        sessionID: UUID,
        batchID: UUID,
        index: Int,
        update: (inout UploadItemProgress) -> Void
    ) {
        guard var batch = uploadBatches[sessionID],
              batch.id == batchID,
              batch.items.indices.contains(index) else { return }
        update(&batch.items[index])
        uploadBatches[sessionID] = batch
    }

    private func markUnfinishedUploadItemsCancelled(sessionID: UUID, batchID: UUID) {
        guard var batch = uploadBatches[sessionID], batch.id == batchID else { return }
        for index in batch.items.indices {
            switch batch.items[index].status {
            case .waiting, .preparing, .uploading, .paused:
                batch.items[index].status = .cancelled
            case .completed, .failed, .cancelled:
                break
            }
        }
        uploadBatches[sessionID] = batch
    }

    private func makeRemoteEditURL(fileName: String, sessionID: UUID) throws -> URL {
        guard let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw RemoteCommandError.launchFailed("无法访问 macOS 缓存目录")
        }
        let directory = cacheRoot
            .appending(path: "KiteShell", directoryHint: .isDirectory)
            .appending(path: "RemoteEdits", directoryHint: .isDirectory)
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    private func syncEditedRemoteFile(
        key: RemoteEditKey,
        localURL: URL,
        fileName: String
    ) async -> Bool {
        guard let controller = terminalControllers[key.sessionID],
              sessions.first(where: { $0.id == key.sessionID })?.state == .connected else {
            reportRemoteEditFailure(
                key: key,
                fileName: fileName,
                detail: "SSH 连接当前不可用。连接恢复后会自动重试。"
            )
            return false
        }
        let controllerID = controller.id
        setRemoteEditActivity("正在同步 \(fileName)…", for: key.sessionID)
        do {
            if let expectedVersion = remoteEditHandles[key]?.remoteVersion,
               let currentVersion = try? await SSHCommandRunner.run(
                    context: controller.remoteCommandContext,
                    command: RemoteFileService.versionCommand(path: key.remotePath)
               ).trimmingCharacters(in: .whitespacesAndNewlines),
               !currentVersion.isEmpty,
               currentVersion != expectedVersion {
                remoteEditHandles[key]?.watcher.stop()
                remoteEditHandles[key] = nil
                remoteEditActivity[key.sessionID] = nil
                importNotice = ImportNotice(
                    title: "远程文件已被修改",
                    message: "为避免覆盖服务器上的新版本，KiteShell 已停止自动回传 \(fileName)。你的本地副本仍保留在缓存中；重新打开远程文件可下载服务器最新版本。"
                )
                return true
            }
            try await SFTPTransferService.upload(
                localURL: localURL,
                remotePath: key.remotePath,
                context: controller.remoteCommandContext
            )
            guard terminalControllers[key.sessionID]?.id == controllerID,
                  sessions.first(where: { $0.id == key.sessionID })?.state == .connected else {
                return false
            }

            if let newVersion = try? await SSHCommandRunner.run(
                context: controller.remoteCommandContext,
                command: RemoteFileService.versionCommand(path: key.remotePath)
            ).trimmingCharacters(in: .whitespacesAndNewlines), !newVersion.isEmpty {
                remoteEditHandles[key]?.remoteVersion = newVersion
            }

            let recoveredFromFailure = reportedRemoteEditFailures.remove(key) != nil
            setRemoteEditActivity(
                recoveredFromFailure
                    ? "\(fileName) 已重新同步到服务器"
                    : "\(fileName) 已同步到服务器",
                for: key.sessionID,
                clearAfter: 2.5
            )
            if case .loaded(let listing) = remoteDirectoryStates[key.sessionID],
               listing.path == RemoteFileService.parentPath(of: key.remotePath) {
                loadRemoteDirectory(for: key.sessionID, path: listing.path)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            reportRemoteEditFailure(
                key: key,
                fileName: fileName,
                detail: error.localizedDescription
            )
            return false
        }
    }

    private func reportRemoteEditFailure(
        key: RemoteEditKey,
        fileName: String,
        detail: String
    ) {
        remoteEditActivity[key.sessionID] = "\(fileName) 同步失败 · 等待重试"
        guard reportedRemoteEditFailures.insert(key).inserted else { return }
        importNotice = ImportNotice(
            title: "本地修改暂未同步",
            message: "\(detail)\n\n本地副本会继续保留，KiteShell 将每 3 秒自动重试，不会丢失刚才的编辑。"
        )
    }

    private func setRemoteEditActivity(
        _ message: String,
        for sessionID: UUID,
        clearAfter delay: Double? = nil
    ) {
        remoteEditActivity[sessionID] = message
        guard let delay else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, remoteEditActivity[sessionID] == message else { return }
            remoteEditActivity[sessionID] = nil
        }
    }

    private func stopRemoteFileEditing(for sessionID: UUID) {
        let preparationKeys = remoteEditPreparationTasks.keys.filter { $0.sessionID == sessionID }
        for key in preparationKeys {
            remoteEditPreparationTasks[key]?.cancel()
            remoteEditPreparationTasks[key] = nil
        }

        let editKeys = remoteEditHandles.keys.filter { $0.sessionID == sessionID }
        for key in editKeys {
            remoteEditHandles[key]?.watcher.stop()
            remoteEditHandles[key] = nil
            reportedRemoteEditFailures.remove(key)
        }
        remoteEditActivity[sessionID] = nil
    }

    private func validateRemoteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }

    private func showInvalidRemoteNameNotice() {
        importNotice = ImportNotice(
            title: "名称无效",
            message: "名称不能为空，不能是 . 或 ..，也不能包含 /。"
        )
    }

    private func performRemoteFileMutation(
        command: String,
        sessionID: UUID,
        directory: String,
        successTitle: String
    ) {
        guard let controller = terminalControllers[sessionID],
              sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        let controllerID = controller.id
        let operationID = UUID()
        fileTransferTasks[sessionID]?.cancel()
        fileTransferIDs[sessionID] = operationID
        fileTransferActivity[sessionID] = "正在处理远程文件…"
        fileTransferTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await SSHCommandRunner.run(
                    context: controller.remoteCommandContext,
                    command: command
                )
                guard terminalControllers[sessionID]?.id == controllerID,
                      fileTransferIDs[sessionID] == operationID,
                      !Task.isCancelled else { return }
                fileTransferActivity[sessionID] = nil
                importNotice = ImportNotice(title: successTitle, message: "远程目录已刷新。")
                loadRemoteDirectory(for: sessionID, path: directory)
            } catch {
                guard fileTransferIDs[sessionID] == operationID,
                      !Task.isCancelled else { return }
                fileTransferActivity[sessionID] = nil
                importNotice = ImportNotice(title: "文件操作失败", message: error.localizedDescription)
            }
            if fileTransferIDs[sessionID] == operationID {
                fileTransferTasks[sessionID] = nil
                fileTransferIDs[sessionID] = nil
            }
        }
    }

    private func runPendingCommandAfterShellIsReady(for sessionID: UUID) {
        guard let command = pendingSessionCommands.removeValue(forKey: sessionID) else { return }
        pendingCommandTasks[sessionID]?.cancel()
        pendingCommandTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self,
                  !Task.isCancelled,
                  sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
            terminalControllers[sessionID]?.sendCommand(command.command)
            pendingCommandTasks[sessionID] = nil
        }
    }

    private func syncRemoteDirectory(sessionID: UUID, path: String) {
        guard path.hasPrefix("/"),
              directoryFollowEnabled[sessionID] ?? true,
              sessions.first(where: { $0.id == sessionID })?.state == .connected else { return }
        if case .loaded(let listing) = remoteDirectoryStates[sessionID], listing.path == path {
            return
        }

        directorySyncTasks[sessionID]?.cancel()
        directorySyncTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            loadRemoteDirectory(for: sessionID, path: path)
            directorySyncTasks[sessionID] = nil
        }
    }

    private func restoreWorkspaceIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "restoreWorkspace"
        let shouldRestore = defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        guard shouldRestore, let snapshot = workspaceStore.load() else { return }

        let profilesByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        let restoredSessions = snapshot.profileIDs.compactMap { profileID -> Session? in
            guard let profile = profilesByID[profileID] else { return nil }
            return Session(profile: profile, state: .disconnected)
        }
        guard !restoredSessions.isEmpty else { return }

        sessions = restoredSessions
        let selectedIndex = min(
            max(snapshot.selectedIndex ?? 0, 0),
            restoredSessions.count - 1
        )
        selectedSessionID = restoredSessions[selectedIndex].id
        isInspectorVisible = snapshot.isInspectorVisible
        isFilePanelVisible = snapshot.isFilePanelVisible
        focusMode = snapshot.focusMode
        route = .workspace
    }

    private func persistWorkspace() {
        let selectedIndex = selectedSessionID.flatMap { selectedID in
            sessions.firstIndex { $0.id == selectedID }
        }
        workspaceStore.save(
            WorkspaceSnapshot(
                profileIDs: sessions.map { $0.profile.id },
                selectedIndex: selectedIndex,
                isInspectorVisible: isInspectorVisible,
                isFilePanelVisible: isFilePanelVisible,
                focusMode: focusMode
            )
        )
    }

    private func refreshSessionProfiles(profileID: UUID) {
        guard let profile = servers.first(where: { $0.id == profileID }) else { return }
        for index in sessions.indices where sessions[index].profile.id == profileID {
            sessions[index].profile = profile
        }
        persistWorkspace()
    }

    private func uniqueServerName(base: String) -> String {
        let existing = Set(servers.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var index = 2
        while existing.contains("\(base) \(index)".lowercased()) {
            index += 1
        }
        return "\(base) \(index)"
    }

    private static func connectionIdentity(_ profile: ServerProfile) -> String {
        "\(profile.username.lowercased())@\(profile.host.lowercased()):\(profile.port)"
    }
}
