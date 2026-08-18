import AppKit
import SwiftUI

struct ConnectionFormSubmission {
    let profile: ServerProfile
    let password: String?
    let rememberPassword: Bool
    let shouldConnect: Bool
}

struct NewConnectionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let existingProfile: ServerProfile?
    private let onSave: ((ConnectionFormSubmission) -> Void)?

    @State private var name: String
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var authentication: AuthenticationMethod
    @State private var group: String
    @State private var selectedTags: Set<String>
    @State private var notes: String
    @State private var identityFilePath: String
    @State private var identityFileBookmark: Data?
    @State private var connectionTimeout: Int
    @State private var keepAliveInterval: Int
    @State private var startupDirectory: String
    @State private var initializationCommand: String
    @State private var runsInitializationCommand: Bool
    @State private var reconnectPolicy: ReconnectPolicy
    @State private var jumpHostID: UUID?
    @State private var upstreamProxy: UpstreamProxyConfiguration
    @State private var isAdvancedExpanded = false
    @State private var isTesting = false
    @State private var testResult: ConnectionProbeResult?
    @State private var agentStatus: SSHAgentStatus?
    @State private var isInspectingAgent = false
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var isPasswordVisible = false

    init(
        profile: ServerProfile? = nil,
        onSave: ((ConnectionFormSubmission) -> Void)? = nil
    ) {
        existingProfile = profile
        self.onSave = onSave
        _name = State(initialValue: profile?.name ?? "")
        _host = State(initialValue: profile?.host ?? "")
        _port = State(initialValue: profile?.port ?? 22)
        _username = State(initialValue: profile?.username ?? "")
        _authentication = State(initialValue: profile?.authentication ?? .password)
        _group = State(initialValue: profile?.group ?? "默认分组")
        _selectedTags = State(initialValue: Set(profile?.tags ?? []))
        _notes = State(initialValue: profile?.notes ?? "")
        _identityFilePath = State(initialValue: profile?.identityFilePath ?? "")
        _identityFileBookmark = State(initialValue: profile?.identityFileBookmark)
        _connectionTimeout = State(initialValue: profile?.connectionTimeout ?? 10)
        _keepAliveInterval = State(initialValue: profile?.keepAliveInterval ?? 15)
        _startupDirectory = State(initialValue: profile?.startupDirectory ?? "")
        _initializationCommand = State(initialValue: profile?.initializationCommand ?? "")
        _runsInitializationCommand = State(initialValue: profile?.runsInitializationCommand ?? false)
        _reconnectPolicy = State(initialValue: profile?.reconnectPolicy ?? .threeTimes)
        _jumpHostID = State(initialValue: profile?.jumpHostID)
        _upstreamProxy = State(initialValue: profile?.upstreamProxy ?? UpstreamProxyConfiguration())
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(port)
            && (1...60).contains(connectionTimeout)
            && (0...300).contains(keepAliveInterval)
            && (startupDirectory.isEmpty || startupDirectory.hasPrefix("/"))
            && upstreamProxy.isValid
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(existingProfile == nil ? "新建连接" : "编辑连接"))
                        .font(.title2.weight(.semibold))
                    Text("密码保存在当前 Mac 的本地加密凭据库，不调用系统钥匙串。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)

            Form {
                Section("连接信息") {
                    TextField("名称", text: $name)
                    TextField("主机", text: $host)
                        .textContentType(.URL)
                    TextField("端口", value: $port, format: .number)
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                    Picker("认证方式", selection: $authentication) {
                        ForEach(AuthenticationMethod.allCases) { method in
                            Text(LocalizedStringKey(method.rawValue)).tag(method)
                        }
                    }
                    Picker("分组", selection: $group) {
                        ForEach(model.groups, id: \.self) { groupName in
                            Text(ConnectionOrganization.displayName(forGroup: groupName)).tag(groupName)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("分组只能在连接中心左侧新增和管理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if authentication == .password {
                    Section("密码") {
                        HStack {
                            Group {
                                if isPasswordVisible {
                                    TextField("SSH 密码", text: $password)
                                } else {
                                    SecureField("SSH 密码", text: $password)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)

                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .help(isPasswordVisible ? "隐藏密码" : "显示密码")
                            .pointingHandCursor()
                        }
                        Toggle("保存到本地凭据库", isOn: $rememberPassword)
                        LabeledContent("保存状态") {
                            Text(LocalizedStringKey(
                                existingProfile.map(model.hasSavedPassword(for:)) == true
                                    ? "已有保存密码；留空则继续使用"
                                    : "尚未保存"
                            ))
                                .foregroundStyle(.secondary)
                        }
                        Text("勾选后加密存放在 ~/Library/Application Support/KiteShell/Credentials，仅当前用户可读；不会写入连接配置、导出文件或日志。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if authentication == .privateKey {
                    Section("私钥") {
                        HStack {
                            TextField("使用 OpenSSH 默认密钥", text: $identityFilePath)
                                .textFieldStyle(.roundedBorder)
                            Button("选择…") { chooseIdentityFile() }
                                .pointingHandCursor()
                        }
                        if !identityFilePath.isEmpty {
                            Label(
                                FileManager.default.isReadableFile(atPath: identityFilePath)
                                    ? "私钥文件可读取"
                                    : "当前无法读取该文件，请重新选择",
                                systemImage: FileManager.default.isReadableFile(atPath: identityFilePath)
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(FileManager.default.isReadableFile(atPath: identityFilePath) ? .green : .orange)
                        }
                    }
                } else {
                    Section("SSH Agent") {
                        HStack {
                            if isInspectingAgent {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: agentStatus?.isAvailable == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(agentStatus?.isAvailable == true ? .green : .orange)
                            }
                            Text(agentStatus?.summary ?? "尚未检查 SSH Agent")
                            Spacer()
                            Button("重新检查") { inspectAgent() }
                                .controlSize(.small)
                        }
                        if let identities = agentStatus?.identities, !identities.isEmpty {
                            ForEach(identities, id: \.self) { identity in
                                Text(identity)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                        Text("将使用当前用户环境中的 SSH Agent 和已加载密钥；KiteShell 不会复制私钥内容。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    DisclosureGroup("高级设置", isExpanded: $isAdvancedExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            ConnectionTagSelector(
                                selectedTags: $selectedTags,
                                availableTags: model.availableConnectionTags
                            )
                            TextField("启动目录（例如 /srv/app）", text: $startupDirectory)
                            Toggle("连接成功后运行初始化命令", isOn: $runsInitializationCommand)
                            if runsInitializationCommand {
                                TextField("初始化命令", text: $initializationCommand, axis: .vertical)
                                    .lineLimit(2...5)
                                    .font(.body.monospaced())
                                Label("初始化命令会在每次成功建立 Shell 后自动执行，请勿填写一次性或高风险操作。", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Picker("自动重连", selection: $reconnectPolicy) {
                                ForEach(ReconnectPolicy.allCases) { policy in
                                    Text(LocalizedStringKey(policy.label)).tag(policy)
                                }
                            }
                            Picker("跳板机", selection: $jumpHostID) {
                                Text("不使用").tag(Optional<UUID>.none)
                                ForEach(model.servers.filter { $0.id != existingProfile?.id }) { server in
                                    Text("\(server.name) · \(server.displayAddress)")
                                        .tag(Optional(server.id))
                                }
                            }
                            Picker("上游代理", selection: $upstreamProxy.kind) {
                                ForEach(UpstreamProxyKind.allCases) { kind in
                                    Text(LocalizedStringKey(kind.rawValue)).tag(kind)
                                }
                            }
                            if upstreamProxy.kind != .none {
                                HStack {
                                    TextField("代理主机", text: $upstreamProxy.host)
                                    TextField("代理端口", value: $upstreamProxy.port, format: .number)
                                        .frame(width: 110)
                                }
                                Text("当前支持无需认证的 SOCKS5/HTTP CONNECT 代理。配置跳板机时优先使用跳板机。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("跳板机首期建议使用私钥或 SSH Agent；首次主机密钥由 OpenSSH 在后台自动记录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Stepper("连接超时：\(connectionTimeout) 秒", value: $connectionTimeout, in: 1...60)
                            Stepper("心跳间隔：\(keepAliveInterval) 秒", value: $keepAliveInterval, in: 0...300, step: 5)
                            TextField("备注", text: $notes, axis: .vertical)
                                .lineLimit(2...5)
                        }
                        .padding(.top, 8)
                    }
                }

                Section("连接测试") {
                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("测试地址与端口", systemImage: "network")
                            }
                        }
                        .disabled(!canSave || isTesting)
                        .pointingHandCursor(canSave && !isTesting)

                        if let testResult {
                            Label(
                                testResult.summary,
                                systemImage: testResult.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .font(.callout)
                            .foregroundStyle(testResult.isReachable ? .green : .red)
                            .textSelection(.enabled)
                        }
                    }
                    Text("此测试检查 DNS 和 SSH 端口；保存后建立 SSH 会话时完成身份认证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .controlSize(.small)
            .environment(\.defaultMinListRowHeight, 28)
            .padding(.horizontal, 4)

            Divider()

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existingProfile == nil ? "仅保存" : "保存修改") {
                    save(connectAfterSave: false)
                }
                .buttonStyle(.bordered)
                .disabled(!canSave)
                Button(existingProfile == nil ? "保存并连接" : "保存并新建会话") {
                    save(connectAfterSave: true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .controlSize(.regular)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .frame(width: 620, height: 680)
        .onChange(of: host) { testResult = nil }
        .onChange(of: port) { testResult = nil }
        .onChange(of: authentication) {
            if authentication == .sshAgent { inspectAgent() }
        }
        .task {
            if !model.groups.contains(group) {
                group = ConnectionOrganization.defaultGroup
            }
            if authentication == .sshAgent { inspectAgent() }
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.prompt = "选择私钥"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        identityFilePath = url.path
        identityFileBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func testConnection() {
        let testedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let testedPort = port
        let timeout = connectionTimeout
        isTesting = true
        testResult = nil
        Task {
            let result = await ConnectionProbe.test(host: testedHost, port: testedPort, timeout: timeout)
            guard testedHost == host.trimmingCharacters(in: .whitespacesAndNewlines), testedPort == port else { return }
            testResult = result
            isTesting = false
        }
    }

    private func inspectAgent() {
        guard !isInspectingAgent else { return }
        isInspectingAgent = true
        Task {
            agentStatus = await SSHAgentInspector.inspect()
            isInspectingAgent = false
        }
    }

    private func save(connectAfterSave: Bool) {
        let now = Date()
        let profile = ServerProfile(
            id: existingProfile?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authentication: authentication,
            group: model.groups.contains(group) ? group : ConnectionOrganization.defaultGroup,
            tags: ConnectionOrganization.normalizeTags(selectedTags),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            isFavorite: existingProfile?.isFavorite ?? false,
            lastConnectedAt: existingProfile?.lastConnectedAt,
            quickCommands: existingProfile?.quickCommands ?? [],
            identityFilePath: authentication == .privateKey ? identityFilePath : "",
            identityFileBookmark: authentication == .privateKey ? identityFileBookmark : nil,
            connectionTimeout: connectionTimeout,
            keepAliveInterval: keepAliveInterval,
            startupDirectory: startupDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            initializationCommand: initializationCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            runsInitializationCommand: runsInitializationCommand && !initializationCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            reconnectPolicy: reconnectPolicy,
            jumpHostID: jumpHostID,
            upstreamProxy: upstreamProxy,
            portForwards: existingProfile?.portForwards ?? [],
            createdAt: existingProfile?.createdAt ?? now,
            updatedAt: now
        )
        let submittedPassword = authentication == .password && !password.isEmpty ? password : nil
        let submission = ConnectionFormSubmission(
            profile: profile,
            password: submittedPassword,
            rememberPassword: rememberPassword,
            shouldConnect: connectAfterSave
        )
        password = ""
        if let onSave {
            onSave(submission)
        } else if existingProfile == nil {
            model.addServer(profile, password: submittedPassword, rememberPassword: rememberPassword)
        } else {
            model.updateServer(profile, password: submittedPassword, rememberPassword: rememberPassword)
        }
        dismiss()
        guard onSave == nil, connectAfterSave else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            model.requestOpenSession(for: profile, oneTimeCredential: submittedPassword)
        }
    }
}
