import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ConnectionFilter: Hashable, Identifiable {
    case all
    case favorites
    case recent
    case group(String)

    static let primaryFilters: [ConnectionFilter] = [.all, .favorites, .recent]

    var id: String {
        switch self {
        case .all: "all"
        case .favorites: "favorites"
        case .recent: "recent"
        case .group(let name): "group:\(name)"
        }
    }

    var title: String {
        switch self {
        case .all: AppLanguage.text(chinese: "所有服务器", english: "All Servers")
        case .favorites: AppLanguage.text(chinese: "收藏", english: "Favorites")
        case .recent: AppLanguage.text(chinese: "最近连接", english: "Recent")
        case .group(let name): ConnectionOrganization.displayName(forGroup: name)
        }
    }

    var systemImage: String {
        switch self {
        case .all: "server.rack"
        case .favorites: "star"
        case .recent: "clock"
        case .group: "folder"
        }
    }
}

private enum ConnectionSortOrder: String, CaseIterable, Identifiable {
    case recent
    case name
    case created
    case state

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: AppLanguage.text(chinese: "最近连接", english: "Recent")
        case .name: AppLanguage.text(chinese: "名称", english: "Name")
        case .created: AppLanguage.text(chinese: "创建时间", english: "Created")
        case .state: AppLanguage.text(chinese: "连接状态", english: "Connection Status")
        }
    }
}

private struct GroupEditRequest: Identifiable {
    let id = UUID()
    let originalName: String?
}

struct ConnectionCenterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: ConnectionFilter? = .all
    @State private var searchText = ""
    @State private var isImportingFinalShell = false
    @State private var isImportingKiteShell = false
    @State private var isImportingOpenSSH = false
    @State private var sortOrder: ConnectionSortOrder = .recent
    @State private var editingProfile: ServerProfile?
    @State private var diagnosticProfile: ServerProfile?
    @State private var deletionCandidate: ServerProfile?
    @State private var groupEditor: GroupEditRequest?
    @State private var groupDeletionCandidate: String?
    @State private var isSelectionMode = false
    @State private var selectedProfileIDs: Set<UUID> = []
    @State private var isConfirmingBatchDeletion = false
    @State private var isPresentingBatchCustomTag = false
    @State private var isPresentingGettingStarted = false
    @FocusState private var isSearchFocused: Bool

    private var visibleServers: [ServerProfile] {
        let filtered: [ServerProfile]
        switch filter ?? .all {
        case .all:
            filtered = model.servers
        case .favorites:
            filtered = model.servers.filter(\.isFavorite)
        case .recent:
            filtered = model.servers.filter { $0.lastConnectedAt != nil }
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        case .group(let group):
            filtered = model.servers.filter { $0.group == group }
        }

        let searched: [ServerProfile]
        if searchText.isEmpty {
            searched = filtered
        } else {
            searched = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.host.localizedCaseInsensitiveContains(searchText)
                    || $0.username.localizedCaseInsensitiveContains(searchText)
                    || $0.group.localizedCaseInsensitiveContains(searchText)
                    || $0.notes.localizedCaseInsensitiveContains(searchText)
                    || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        switch sortOrder {
        case .recent:
            return searched.sorted {
                ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
            }
        case .name:
            return searched.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .created:
            return searched.sorted { $0.createdAt > $1.createdAt }
        case .state:
            func rank(_ state: ConnectionState?) -> Int {
                switch state {
                case .connected: 0
                case .connecting, .reconnecting: 1
                case .failed, .disconnected: 2
                case nil: 3
                }
            }
            return searched.sorted { lhs, rhs in
                let leftRank = model.sessions
                    .filter { $0.profile.id == lhs.id }
                    .map { rank($0.state) }
                    .min() ?? rank(nil)
                let rightRank = model.sessions
                    .filter { $0.profile.id == rhs.id }
                    .map { rank($0.state) }
                    .min() ?? rank(nil)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var selectedProfiles: [ServerProfile] {
        model.servers.filter { selectedProfileIDs.contains($0.id) }
    }

    private var selectedTagUnion: [String] {
        ConnectionOrganization.normalizeTags(selectedProfiles.flatMap(\.tags))
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $filter) {
                    Section("连接") {
                        ForEach(ConnectionFilter.primaryFilters) { item in
                            Label(item.title, systemImage: item.systemImage)
                                .tag(item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    filter = item
                                    dismissSearchFocus()
                                }
                                .pointingHandCursor()
                        }
                    }

                    Section {
                        ForEach(model.groups, id: \.self) { group in
                            Label(ConnectionOrganization.displayName(forGroup: group), systemImage: "folder")
                                .tag(ConnectionFilter.group(group))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    filter = .group(group)
                                    dismissSearchFocus()
                                }
                                .pointingHandCursor()
                                .dropDestination(for: String.self) { values, _ in
                                    guard let value = values.first, let profileID = UUID(uuidString: value) else { return false }
                                    model.moveServer(profileID, toGroup: group)
                                    filter = .group(group)
                                    return true
                                }
                                .contextMenu {
                                    Button("重命名分组…") { groupEditor = GroupEditRequest(originalName: group) }
                                    Button("删除分组…", role: .destructive) { groupDeletionCandidate = group }
                                        .disabled(group == "默认分组")
                                }
                        }
                    } header: {
                        HStack {
                            Text("分组")
                            Spacer()
                            Button {
                                groupEditor = GroupEditRequest(originalName: nil)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("新建分组")
                            .pointingHandCursor()
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()
                HStack(spacing: 7) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(.tint)
                    Text("KiteShell")
                    Spacer()
                    Text("v\(AppVersion.short)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .accessibilityLabel("KiteShell \(AppVersion.display)")
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                ConnectionCenterHeader(
                    title: filter?.title ?? "所有服务器",
                    count: visibleServers.count,
                    searchText: $searchText,
                    searchFocused: $isSearchFocused,
                    sortOrder: $sortOrder,
                    hasActiveSession: model.selectedSession != nil,
                    returnToSession: { model.showWorkspace() },
                    importFinalShell: { isImportingFinalShell = true },
                    importKiteShell: { isImportingKiteShell = true },
                    importOpenSSH: { isImportingOpenSSH = true },
                    exportKiteShell: exportKiteShellConfiguration,
                    quickConnect: { model.isPresentingQuickConnect = true },
                    newConnection: { model.isPresentingNewConnection = true },
                    isSelectionMode: isSelectionMode,
                    toggleSelectionMode: toggleSelectionMode
                )

                if isSelectionMode {
                    batchActionBar
                    Divider()
                }

                if visibleServers.isEmpty {
                    ContentUnavailableView {
                        Label("没有匹配的服务器", systemImage: "server.rack")
                    } description: {
                        Text("新建连接，或尝试调整搜索条件。")
                    } actions: {
                        VStack(spacing: 10) {
                            HStack {
                            Button("新建连接") {
                                model.isPresentingNewConnection = true
                            }
                            .buttonStyle(.borderedProminent)
                            Button("导入 FinalShell") {
                                isImportingFinalShell = true
                            }
                            .buttonStyle(.bordered)
                            Button("导入 KiteShell") { isImportingKiteShell = true }
                                .buttonStyle(.bordered)
                            }
                            Button("打开使用说明") { isPresentingGettingStarted = true }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { dismissSearchFocus() }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 270, maximum: 360), spacing: 14)],
                            alignment: .leading,
                            spacing: 14
                        ) {
                            ForEach(visibleServers) { profile in
                                ServerRow(
                                    profile: profile,
                                    isSelectionMode: isSelectionMode,
                                    isSelected: selectedProfileIDs.contains(profile.id),
                                    toggleSelection: { toggleSelection(for: profile.id) },
                                    connect: { model.requestOpenSession(for: profile) },
                                    edit: { editingProfile = profile },
                                    diagnose: { diagnosticProfile = profile },
                                    delete: { deletionCandidate = profile }
                                )
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                guard !isSelectionMode else {
                                    toggleSelection(for: profile.id)
                                    return
                                }
                                dismissSearchFocus()
                                model.requestOpenSession(for: profile)
                            }
                            .onTapGesture {
                                if isSelectionMode {
                                    toggleSelection(for: profile.id)
                                }
                            }
                            .contextMenu {
                                if isSelectionMode {
                                    Button(selectedProfileIDs.contains(profile.id) ? "取消选择" : "选择") {
                                        toggleSelection(for: profile.id)
                                    }
                                    Divider()
                                }
                                Button("连接") { model.requestOpenSession(for: profile) }
                                    .disabled(isSelectionMode)
                                Button("编辑…") { editingProfile = profile }
                                    .disabled(isSelectionMode)
                                Button("复制连接") { model.duplicateServer(profile) }
                                Button("连接诊断…") { diagnosticProfile = profile }
                                Button(profile.isFavorite ? "取消收藏" : "收藏") {
                                    model.toggleFavorite(profile)
                                }
                                if profile.authentication == .password {
                                    Button("忘记已保存密码") {
                                        model.forgetPassword(for: profile)
                                    }
                                }
                                if profile.authentication == .privateKey {
                                    Button("忘记已保存私钥口令") {
                                        model.forgetPrivateKeyPassphrase(for: profile)
                                    }
                                }
                                if !profile.quickCommands.isEmpty {
                                    Menu("快捷命令") {
                                        ForEach(profile.quickCommands) { quickCommand in
                                            Button(quickCommand.name) {
                                                model.requestRunQuickCommand(quickCommand, for: profile)
                                            }
                                        }
                                    }
                                }
                                Divider()
                                Button("删除…", role: .destructive) {
                                    deletionCandidate = profile
                                }
                                .disabled(isSelectionMode)
                            }
                            .draggable(profile.id.uuidString)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 4)
                        .padding(.bottom, 22)
                    }
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { dismissSearchFocus() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("KiteShell")
        .onAppear {
            DispatchQueue.main.async { dismissSearchFocus() }
        }
        .onChange(of: model.servers.map(\.id)) {
            selectedProfileIDs.formIntersection(Set(model.servers.map(\.id)))
            if model.servers.isEmpty {
                isSelectionMode = false
            }
        }
        .fileImporter(
            isPresented: $isImportingFinalShell,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await model.importFinalShellFiles(urls)
                }
            case .failure(let error):
                model.importNotice = ImportNotice(
                    title: "无法选择文件",
                    message: error.localizedDescription
                )
            }
        }
        .fileImporter(
            isPresented: $isImportingKiteShell,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importKiteShellFiles(urls) }
            case .failure(let error):
                model.importNotice = ImportNotice(
                    title: "无法选择文件",
                    message: error.localizedDescription
                )
            }
        }
        .fileImporter(
            isPresented: $isImportingOpenSSH,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importOpenSSHConfigFiles(urls) }
            case .failure(let error):
                model.importNotice = ImportNotice(
                    title: "无法选择文件",
                    message: error.localizedDescription
                )
            }
        }
        .sheet(item: $editingProfile) { profile in
            NewConnectionSheet(profile: profile)
        }
        .sheet(item: $diagnosticProfile) { profile in
            ConnectionDiagnosticsSheet(profile: profile)
        }
        .sheet(isPresented: $isPresentingGettingStarted) {
            GettingStartedSheet()
        }
        .sheet(item: $groupEditor) { request in
            GroupEditorSheet(originalName: request.originalName) { name in
                if let originalName = request.originalName {
                    model.renameGroup(originalName, to: name)
                    filter = .group(name.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    model.createGroup(named: name)
                    filter = .group(name.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        .sheet(isPresented: $isPresentingBatchCustomTag) {
            BatchCustomTagSheet { tag in
                model.addTag(tag, toServers: selectedProfileIDs)
            }
        }
        .confirmationDialog(
            "删除分组？",
            isPresented: Binding(
                get: { groupDeletionCandidate != nil },
                set: { if !$0 { groupDeletionCandidate = nil } }
            ),
            presenting: groupDeletionCandidate
        ) { group in
            Button(AppLanguage.text(chinese: "删除 \(group)", english: "Delete \(group)"), role: .destructive) {
                model.deleteGroup(group)
                filter = .all
                groupDeletionCandidate = nil
            }
            Button("取消", role: .cancel) { groupDeletionCandidate = nil }
        } message: { group in
            Text("分组中的连接将移动到“默认分组”，不会删除服务器配置。")
        }
        .confirmationDialog(
            "删除连接？",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            presenting: deletionCandidate
        ) { profile in
            Button(AppLanguage.text(chinese: "删除 \(profile.name)", english: "Delete \(profile.name)"), role: .destructive) {
                model.deleteServer(profile)
                deletionCandidate = nil
            }
            Button("取消", role: .cancel) {
                deletionCandidate = nil
            }
        } message: { profile in
            Text(AppLanguage.text(
                chinese: "将删除 \(profile.displayAddress) 的保存配置；相关活动会话也会关闭。",
                english: "The saved configuration for \(profile.displayAddress) will be deleted, and related active sessions will be closed."
            ))
        }
        .confirmationDialog(
            "删除所选连接？",
            isPresented: $isConfirmingBatchDeletion
        ) {
            Button(AppLanguage.text(
                chinese: "删除 \(selectedProfileIDs.count) 条连接",
                english: "Delete \(selectedProfileIDs.count) Connections"
            ), role: .destructive) {
                model.deleteServers(withIDs: selectedProfileIDs)
                selectedProfileIDs = []
                isSelectionMode = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存的连接和对应本地凭据将被删除；相关活动会话也会关闭。")
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: 12) {
            Text(AppLanguage.text(
                chinese: "已选择 \(selectedProfileIDs.count) 项",
                english: "\(selectedProfileIDs.count) Selected"
            ))
                .font(.callout.weight(.medium))

            Button(selectedProfileIDs.count == visibleServers.count && !visibleServers.isEmpty ? "取消全选" : "全选当前列表") {
                let visibleIDs = Set(visibleServers.map(\.id))
                if selectedProfileIDs.isSuperset(of: visibleIDs), !visibleIDs.isEmpty {
                    selectedProfileIDs.subtract(visibleIDs)
                } else {
                    selectedProfileIDs.formUnion(visibleIDs)
                }
            }
            .buttonStyle(.bordered)

            Divider().frame(height: 20)

            Menu {
                ForEach(model.groups, id: \.self) { group in
                    Button(ConnectionOrganization.displayName(forGroup: group)) {
                        model.moveServers(selectedProfileIDs, toGroup: group)
                    }
                }
            } label: {
                Label("设置分组", systemImage: "folder")
            }
            .disabled(selectedProfileIDs.isEmpty)

            Menu {
                Section("添加标签") {
                    ForEach(model.availableConnectionTags, id: \.self) { tag in
                        Button(ConnectionOrganization.displayName(forTag: tag)) {
                            model.addTag(tag, toServers: selectedProfileIDs)
                        }
                    }
                    Button("自定义标签…") {
                        isPresentingBatchCustomTag = true
                    }
                }
                if !selectedTagUnion.isEmpty {
                    Section("移除标签") {
                        ForEach(selectedTagUnion, id: \.self) { tag in
                            Button(ConnectionOrganization.displayName(forTag: tag)) {
                                model.removeTag(tag, fromServers: selectedProfileIDs)
                            }
                        }
                        Button("清除全部标签", role: .destructive) {
                            model.clearTags(fromServers: selectedProfileIDs)
                        }
                    }
                }
            } label: {
                Label("标签", systemImage: "tag")
            }
            .disabled(selectedProfileIDs.isEmpty)

            Menu {
                Button("添加收藏") {
                    model.setFavorite(true, forServers: selectedProfileIDs)
                }
                Button("取消收藏") {
                    model.setFavorite(false, forServers: selectedProfileIDs)
                }
            } label: {
                Label("收藏", systemImage: "star")
            }
            .disabled(selectedProfileIDs.isEmpty)

            Spacer()

            Button("删除", role: .destructive) {
                isConfirmingBatchDeletion = true
            }
            .buttonStyle(.bordered)
            .disabled(selectedProfileIDs.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode {
            selectedProfileIDs = []
        }
    }

    private func toggleSelection(for profileID: UUID) {
        if selectedProfileIDs.contains(profileID) {
            selectedProfileIDs.remove(profileID)
        } else {
            selectedProfileIDs.insert(profileID)
        }
    }

    private func dismissSearchFocus() {
        isSearchFocused = false
        clearTextFocus()
    }

    private func exportKiteShellConfiguration() {
        let panel = NSSavePanel()
        panel.title = "导出 KiteShell 连接"
        panel.nameFieldStringValue = "KiteShell-Connections.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportKiteShellConfiguration(to: url)
            model.importNotice = ImportNotice(
                title: "导出完成",
                message: "已导出 \(model.servers.count) 条连接。文件不包含密码或本地凭据数据。"
            )
        } catch {
            model.importNotice = ImportNotice(
                title: "无法导出连接",
                message: error.localizedDescription
            )
        }
    }
}

private struct GettingStartedSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("开始使用 KiteShell").font(.title2.weight(.semibold))
                    Text("所有服务器数据都来自真实 SSH 会话，不会创建示例服务器或模拟负载。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            HelpStep(number: 1, title: "添加连接", detail: "新建连接，或导入 FinalShell、KiteShell 与 ~/.ssh/config。")
            HelpStep(number: 2, title: "直接连接", detail: "首次主机密钥由系统 OpenSSH 在后台记录；后续密钥变化时仍会阻止连接。")
            HelpStep(number: 3, title: "输入凭据", detail: "密码与私钥口令可保存在本机加密凭据库，普通配置和导出文件不包含凭据。")
            HelpStep(number: 4, title: "进入工作区", detail: "连接后可同时使用真实终端、服务器监控、远程文件、命令脚本和端口转发。")
            GroupBox("连接不上怎么办") {
                Text("在连接卡片的右键菜单中选择“连接诊断”，依次检查地址、DNS、端口和本机 SSH。内网首次访问时，macOS 可能请求本地网络权限。")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(width: 620, height: 460)
    }
}

private struct HelpStep: View {
    let number: Int
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.tint, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectionCenterHeader: View {
    let title: String
    let count: Int
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    @Binding var sortOrder: ConnectionSortOrder
    let hasActiveSession: Bool
    let returnToSession: () -> Void
    let importFinalShell: () -> Void
    let importKiteShell: () -> Void
    let importOpenSSH: () -> Void
    let exportKiteShell: () -> Void
    let quickConnect: () -> Void
    let newConnection: () -> Void
    let isSelectionMode: Bool
    let toggleSelectionMode: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(AppLanguage.text(
                    chinese: "\(count) 台服务器",
                    english: "\(count) Servers"
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                searchFocused.wrappedValue = false
                clearTextFocus()
            }

            Spacer()

            if hasActiveSession {
                Button {
                    searchFocused.wrappedValue = false
                    clearTextFocus()
                    returnToSession()
                } label: {
                    Label("返回会话", systemImage: "arrow.left.to.line")
                }
                .buttonStyle(.bordered)
                .help("返回当前终端会话")
                .pointingHandCursor()
            }

            TextField("搜索名称、地址或用户", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 190, idealWidth: 250, maxWidth: 300)
                .accessibilityLabel("搜索服务器")
                .focused(searchFocused)
                .onExitCommand {
                    searchFocused.wrappedValue = false
                    clearTextFocus()
                }

            Menu {
                Button {
                    importFinalShell()
                } label: {
                    Label("导入 FinalShell…", systemImage: "square.and.arrow.down")
                }
                Button {
                    importKiteShell()
                } label: {
                    Label("导入 KiteShell…", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    importOpenSSH()
                } label: {
                    Label("导入 OpenSSH Config…", systemImage: "terminal")
                }
                Divider()
                Button {
                    exportKiteShell()
                } label: {
                    Label("导出 KiteShell 配置…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("导入与导出", systemImage: "arrow.up.arrow.down.square")
            }
            .buttonStyle(.bordered)
            .help("导入或导出连接配置，不导出密码")
            .pointingHandCursor()

            Menu {
                Picker("排序", selection: $sortOrder) {
                    ForEach(ConnectionSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .help("连接排序")

            Button(action: toggleSelectionMode) {
                Label {
                    Text(LocalizedStringKey(isSelectionMode ? "完成" : "批量管理"))
                } icon: {
                    Image(systemName: isSelectionMode ? "checkmark" : "checklist")
                }
            }
            .buttonStyle(.bordered)
            .help("批量设置分组、标签、收藏或删除连接")

            Button {
                searchFocused.wrappedValue = false
                clearTextFocus()
                quickConnect()
            } label: {
                Label("快速连接", systemImage: "bolt.fill")
            }
            .buttonStyle(.bordered)
            .help("输入 user@host 快速打开临时会话（⌘K）")
            .pointingHandCursor()

            Button {
                searchFocused.wrappedValue = false
                clearTextFocus()
                newConnection()
            } label: {
                Label("新建连接", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .pointingHandCursor()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

private struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let originalName: String?
    let save: (String) -> Void
    @State private var name: String

    init(originalName: String?, save: @escaping (String) -> Void) {
        self.originalName = originalName
        self.save = save
        _name = State(initialValue: originalName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(LocalizedStringKey(originalName == nil ? "新建分组" : "重命名分组"))
                .font(.title2.weight(.semibold))
            TextField("分组名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: commit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func commit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value)
        dismiss()
    }
}

private struct BatchCustomTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String) -> Void
    @State private var tag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加自定义标签")
                .font(.title2.weight(.semibold))
            TextField("标签名称", text: $tag)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("添加", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func commit() {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value)
        dismiss()
    }
}

private struct ServerRow: View {
    @EnvironmentObject private var model: AppModel
    let profile: ServerProfile
    let isSelectionMode: Bool
    let isSelected: Bool
    let toggleSelection: () -> Void
    let connect: () -> Void
    let edit: () -> Void
    let diagnose: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    private var profileSessions: [Session] {
        model.sessions
            .filter { $0.profile.id == profile.id }
            .sorted { $0.openedAt < $1.openedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                if isSelectionMode {
                    Button(action: toggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isSelected ? "取消选择" : "选择")
                }

                Image(systemName: "server.rack")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(profile.displayAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if profile.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("已收藏")
                }
            }

            HStack(spacing: 8) {
                Label(ConnectionOrganization.displayName(forGroup: profile.group), systemImage: "folder")
                    .lineLimit(1)
                Label {
                    Text(LocalizedStringKey(profile.authentication.rawValue))
                } icon: {
                    Image(systemName: "key")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !profile.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(profile.tags.prefix(3), id: \.self) { tag in
                        Text(ConnectionOrganization.displayName(forTag: tag))
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.10), in: Capsule())
                    }
                    if profile.tags.count > 3 {
                        Text("+\(profile.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !profileSessions.isEmpty {
                Divider()
                SessionStateSummary(sessions: profileSessions)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Label {
                    Text(profile.lastConnectedAt.map {
                        $0.formatted(
                            .relative(presentation: .named)
                                .locale(AppLanguage.current.locale)
                        )
                    } ?? AppLanguage.text(chinese: "从未连接", english: "Never Connected"))
                    .lineLimit(1)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if !isSelectionMode {
                    Group {
                        if !profile.quickCommands.isEmpty {
                            Menu {
                                ForEach(profile.quickCommands) { quickCommand in
                                    Button {
                                        model.requestRunQuickCommand(quickCommand, for: profile)
                                    } label: {
                                        Label(quickCommand.name, systemImage: "play.fill")
                                    }
                                }
                            } label: {
                                Image(systemName: "bolt.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .controlSize(.small)
                            .help("连接并执行快捷命令")
                            .pointingHandCursor()
                        }
                        Button("连接", action: connect)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .pointingHandCursor()

                        Menu {
                            Button("编辑…", action: edit)
                            Button("复制连接") { model.duplicateServer(profile) }
                            Button("连接诊断…", action: diagnose)
                            Button(profile.isFavorite ? "取消收藏" : "收藏") {
                                model.toggleFavorite(profile)
                            }
                            if profile.authentication == .password {
                                Button("忘记已保存密码") {
                                    model.forgetPassword(for: profile)
                                }
                            }
                            if profile.authentication == .privateKey {
                                Button("忘记已保存私钥口令") {
                                    model.forgetPrivateKeyPassphrase(for: profile)
                                }
                            }
                            Divider()
                            Button("删除…", role: .destructive, action: delete)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .help("更多操作")
                        .pointingHandCursor()
                    }
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    isHovering
                        ? Color.accentColor.opacity(0.42)
                        : Color(nsColor: .separatorColor).opacity(0.70),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(isHovering ? 0.10 : 0.055), radius: isHovering ? 9 : 4, y: 2)
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "连接") {
            connect()
        }
    }
}

private struct SessionStateSummary: View {
    let sessions: [Session]

    private let displayOrder: [ConnectionState] = [
        .connected,
        .connecting,
        .reconnecting,
        .failed
    ]

    private var summary: String {
        displayOrder.compactMap { state in
            let count = sessions.lazy.filter { $0.state == state }.count
            guard count > 0 else { return nil }
            return sessions.count == 1 ? state.label : "\(state.label) \(count)"
        }
        .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(
                AppLanguage.text(
                    chinese: "\(sessions.count) 个会话",
                    english: "\(sessions.count) Sessions"
                ),
                systemImage: "rectangle.stack"
            )
            .foregroundStyle(.secondary)

            if !summary.isEmpty {
                Spacer(minLength: 6)

                Text(summary)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.caption)
        .help(summary.isEmpty ? "\(sessions.count) 个会话" : summary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.isEmpty ? "\(sessions.count) 个会话" : "\(sessions.count) 个会话，\(summary)")
    }
}
