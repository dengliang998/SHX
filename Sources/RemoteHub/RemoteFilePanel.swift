import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RemoteFilePanel: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case files = "远程文件"
        case commands = "命令与脚本"

        var id: String { rawValue }
    }

    private enum FileSortOrder: String, CaseIterable, Identifiable {
        case name = "名称"
        case size = "大小"
        case modified = "修改时间"
        case type = "类型"

        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    let session: Session
    @State private var selectedPane: Pane = .files
    @State private var isImportingFiles = false
    @State private var nameRequest: RemoteNameRequest?
    @State private var permissionRequest: RemotePermissionRequest?
    @State private var deletionCandidate: RemoteFileEntry?
    @State private var textEditorEntry: RemoteFileEntry?
    @State private var isDropTargeted = false
    @State private var isEditingPath = false
    @State private var pathDraft = ""
    @State private var searchText = ""
    @State private var showHiddenFiles = false
    @State private var sortOrder: FileSortOrder = .name
    @State private var navigationHistory: [String] = []
    @State private var navigationIndex = -1
    @State private var isNavigatingHistory = false
    @State private var renamingEntryID: String?
    @State private var renameDraft = ""
    @FocusState private var isPathFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedRenameEntryID: String?

    private var state: RemoteDirectoryState {
        model.remoteDirectoryStates[session.id] ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            panelToolbar

            Divider()

            if selectedPane == .commands {
                CommandLibraryPanel(session: session)
            } else if session.state != .connected {
                connectionUnavailable
            } else {
                directoryContent
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.title) 文件工作区")
        .dropDestination(for: URL.self) { urls, _ in
            guard selectedPane == .files, session.state == .connected, hasLoadedDirectory, !urls.isEmpty else { return false }
            model.uploadFiles(urls, to: session.id)
            return true
        } isTargeted: { targeted in
            isDropTargeted = selectedPane == .files && targeted && session.state == .connected && hasLoadedDirectory
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.tint.opacity(0.10))
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    Label("上传到当前远程目录", systemImage: "arrow.up.doc.fill")
                        .font(.headline)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .contextMenu {
            if selectedPane == .files {
                Button {
                    model.refreshRemoteDirectory(for: session.id)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(session.state != .connected)

                Button {
                    if let directory = currentDirectory { beginPathEditing(directory) }
                } label: {
                    Label("前往文件夹…", systemImage: "arrow.right.to.line")
                }
                .disabled(!hasLoadedDirectory)

                Button {
                    copyCurrentDirectory()
                } label: {
                    Label("复制当前路径", systemImage: "doc.on.doc")
                }
                .disabled(!hasLoadedDirectory)

                Button {
                    openCurrentDirectoryInTerminal()
                } label: {
                    Label("在终端中进入当前目录", systemImage: "terminal")
                }
                .disabled(!hasLoadedDirectory || session.state != .connected)

                Divider()

                Button {
                    uploadClipboardFiles()
                } label: {
                    Label("粘贴并上传", systemImage: "doc.on.clipboard")
                }
                .disabled(!hasLoadedDirectory || clipboardFileURLs.isEmpty)

                Button {
                    isImportingFiles = true
                } label: {
                    Label("上传…", systemImage: "arrow.up.doc")
                }
                .disabled(!hasLoadedDirectory)

                Menu("新建") {
                    Button("文件…") {
                        nameRequest = RemoteNameRequest(kind: .createFile, initialValue: "新建文件")
                    }
                    Button("文件夹…") {
                        nameRequest = RemoteNameRequest(kind: .createDirectory, initialValue: "新建文件夹")
                    }
                }
                .disabled(!hasLoadedDirectory)
            }
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.uploadFiles(urls, to: session.id)
            case .failure(let error):
                model.importNotice = ImportNotice(title: "无法选择文件", message: error.localizedDescription)
            }
        }
        .sheet(item: $nameRequest) { request in
            RemoteNameSheet(request: request) { value in
                switch request.kind {
                case .createDirectory:
                    model.createRemoteDirectory(named: value, in: session.id)
                case .createFile:
                    model.createRemoteFile(named: value, in: session.id)
                case .rename(let entry):
                    model.renameRemoteEntry(entry, to: value, in: session.id)
                case .duplicate(let entry):
                    model.duplicateRemoteEntry(entry, as: value, in: session.id)
                case .move(let entry):
                    model.moveRemoteEntry(entry, to: value, in: session.id)
                }
            }
        }
        .sheet(item: $permissionRequest) { request in
            RemotePermissionSheet(request: request) { value in
                model.changeRemotePermissions(request.entry, mode: value, in: session.id)
            }
        }
        .sheet(item: $textEditorEntry) { entry in
            RemoteTextEditorSheet(session: session, entry: entry)
        }
        .confirmationDialog(
            "删除远程项目？",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            presenting: deletionCandidate
        ) { entry in
            Button("删除 \(entry.name)", role: .destructive) {
                model.deleteRemoteEntry(entry, in: session.id)
                deletionCandidate = nil
            }
            Button("取消", role: .cancel) { deletionCandidate = nil }
        } message: { entry in
            Text(entry.isDirectory ? "该文件夹及其中全部内容会被永久删除。" : "该远程文件会被永久删除。")
        }
        .onChange(of: currentDirectory) { _, newPath in
            if let newPath { recordHistory(newPath) }
        }
        .onChange(of: isPathFocused) { _, focused in
            if !focused, isEditingPath { cancelPathEditing() }
        }
        .onChange(of: focusedRenameEntryID) { previous, current in
            guard let previous,
                  current != previous,
                  renamingEntryID == previous else { return }
            commitInlineRename()
        }
    }

    private var panelToolbar: some View {
        HStack(spacing: 9) {
            Picker("工作区", selection: $selectedPane) {
                Label("远程文件", systemImage: "folder").tag(Pane.files)
                Label("命令与脚本", systemImage: "terminal").tag(Pane.commands)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .pointingHandCursor()

            if selectedPane == .files {
                fileNavigationControls
            }
            Spacer()
            if selectedPane == .files {
                fileStatusControls
                fileActionControls
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
    }

    @ViewBuilder
    private var fileNavigationControls: some View {
        Button {
            model.toggleTerminalDirectoryFollowing(for: session.id)
        } label: {
            Image(systemName: model.isFollowingTerminalDirectory(for: session.id) ? "link" : "lock.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.isFollowingTerminalDirectory(for: session.id) ? Color.secondary : Color.accentColor)
        .help(model.isFollowingTerminalDirectory(for: session.id) ? "跟随终端目录；点击锁定" : "路径已锁定；点击恢复跟随")

        Button { navigateHistory(by: -1) } label: { Image(systemName: "chevron.left") }
            .buttonStyle(.plain)
            .disabled(navigationIndex <= 0)
            .help("后退")
        Button { navigateHistory(by: 1) } label: { Image(systemName: "chevron.right") }
            .buttonStyle(.plain)
            .disabled(navigationIndex < 0 || navigationIndex >= navigationHistory.count - 1)
            .help("前进")

        if case .loaded(let listing) = state {
            if isEditingPath {
                TextField("远程路径", text: $pathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .focused($isPathFocused)
                    .frame(minWidth: 130, maxWidth: 300)
                    .onSubmit(openDraftPath)
                    .onExitCommand { finishPathEditing() }
            } else {
                Text(listing.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginPathEditing(listing.path) }
                    .help("双击输入路径并直接跳转")
                    .pointingHandCursor()
            }
        }
    }

    @ViewBuilder
    private var fileStatusControls: some View {
        if let batch = model.uploadBatches[session.id] {
            UploadProgressControl(sessionID: session.id, batchID: batch.id)
                .id(batch.id)
        }
        if let activity = model.remoteEditActivity[session.id]
            ?? model.fileTransferActivity[session.id] {
            ProgressView().controlSize(.small)
            Text(activity)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var fileActionControls: some View {
        TextField("筛选文件", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 125)
            .focused($isSearchFocused)
        Menu {
            Picker("排序", selection: $sortOrder) {
                ForEach(FileSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            Divider()
            Toggle("显示隐藏文件", isOn: $showHiddenFiles)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .tint(.purple)
        .help("筛选、排序和隐藏文件")

        Menu {
            Button("上传文件…") { isImportingFiles = true }
            Button("新建文件…") {
                nameRequest = RemoteNameRequest(kind: .createFile, initialValue: "新建文件")
            }
            Button("新建文件夹…") {
                nameRequest = RemoteNameRequest(kind: .createDirectory, initialValue: "新建文件夹")
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .tint(.blue)
        .disabled(session.state != .connected || !hasLoadedDirectory)
        .help("上传或新建")

        Button { model.openParentRemoteDirectory(for: session.id) } label: {
            Image(systemName: "arrow.up")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.indigo)
        .disabled(!canOpenParent)
        .help("上一级目录")

        Button { model.refreshRemoteDirectory(for: session.id) } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.teal)
        .disabled(session.state != .connected)
        .help("刷新远程目录")
    }

    private var hasLoadedDirectory: Bool {
        if case .loaded = state { return true }
        return false
    }

    private var currentDirectory: String? {
        guard case .loaded(let listing) = state else { return nil }
        return listing.path
    }

    private var clipboardFileURLs: [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? []
    }

    private var canOpenParent: Bool {
        guard session.state == .connected,
              case .loaded(let listing) = state else { return false }
        return listing.path != "/"
    }

    @ViewBuilder
    private var directoryContent: some View {
        switch state {
        case .idle:
            ContentUnavailableView(
                "等待远程目录",
                systemImage: "folder",
                description: Text("连接完成后会自动读取用户主目录。")
            )
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取远程目录…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("无法读取目录", systemImage: "folder.badge.questionmark")
            } description: {
                Text(message)
                    .textSelection(.enabled)
            } actions: {
                Button("重试") { model.refreshRemoteDirectory(for: session.id) }
            }
        case .loaded(let listing):
            let entries = visibleEntries(in: listing)
            if entries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "文件夹为空" : "没有匹配的文件",
                    systemImage: searchText.isEmpty ? "folder" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? listing.path : "尝试调整筛选内容或显示隐藏文件。")
                )
            } else {
                VStack(spacing: 0) {
                    FileHeaderRow()
                    Divider()
                    List(entries) { entry in
                        RemoteFileRow(
                            entry: entry,
                            open: {
                                if entry.isDirectory {
                                    model.openRemoteDirectory(for: session.id, entry: entry)
                                } else {
                                    model.openRemoteFileForEditing(entry, from: session.id)
                                }
                            },
                            isRenaming: renamingEntryID == entry.id,
                            renameText: $renameDraft,
                            renameFocus: $focusedRenameEntryID,
                            commitRename: commitInlineRename,
                            cancelRename: cancelInlineRename
                        )
                        .contextMenu {
                            if entry.isDirectory {
                                Button {
                                    model.openRemoteDirectory(for: session.id, entry: entry)
                                } label: {
                                    Label("打开", systemImage: "folder")
                                }

                                Button {
                                    openEntryInTerminal(entry)
                                } label: {
                                    Label("在终端中进入", systemImage: "terminal")
                                }

                                Button {
                                    chooseDownloadLocation(for: entry)
                                } label: {
                                    Label("下载文件夹…", systemImage: "arrow.down.folder")
                                }
                            } else {
                                Button {
                                    textEditorEntry = entry
                                } label: {
                                    Label("使用内置编辑器…", systemImage: "doc.text")
                                }

                                Button {
                                    model.openRemoteFileForEditing(entry, from: session.id)
                                } label: {
                                    Label("下载并打开编辑", systemImage: "square.and.pencil")
                                }

                                Button {
                                    chooseDownloadLocation(for: entry)
                                } label: {
                                    Label("下载…", systemImage: "arrow.down.doc")
                                }
                            }

                            Button {
                                copyRemotePath(for: entry)
                            } label: {
                                Label("复制路径", systemImage: "doc.on.doc")
                            }

                            Button {
                                copyName(for: entry)
                            } label: {
                                Label("复制名称", systemImage: "textformat")
                            }

                            Divider()

                            Button {
                                isImportingFiles = true
                            } label: {
                                Label("上传到当前目录…", systemImage: "arrow.up.doc")
                            }

                            Menu("新建") {
                                Button("文件…") {
                                    nameRequest = RemoteNameRequest(kind: .createFile, initialValue: "新建文件")
                                }
                                Button("文件夹…") {
                                    nameRequest = RemoteNameRequest(kind: .createDirectory, initialValue: "新建文件夹")
                                }
                            }

                            Divider()

                            Button {
                                nameRequest = RemoteNameRequest(
                                    kind: .duplicate(entry),
                                    initialValue: duplicateName(for: entry)
                                )
                            } label: {
                                Label("创建副本…", systemImage: "plus.square.on.square")
                            }

                            Button {
                                let source = RemoteFileService.childPath(parent: listing.path, name: entry.name)
                                nameRequest = RemoteNameRequest(kind: .move(entry), initialValue: source)
                            } label: {
                                Label("移动到…", systemImage: "folder.badge.plus")
                            }

                            Button {
                                beginInlineRename(entry)
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }

                            Button {
                                permissionRequest = RemotePermissionRequest(
                                    entry: entry,
                                    initialValue: entry.permissions
                                )
                            } label: {
                                Label("文件权限…", systemImage: "lock")
                            }

                            Button(role: .destructive) {
                                deletionCandidate = entry
                            } label: {
                                Label("删除…", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private var connectionUnavailable: some View {
        ContentUnavailableView {
            Label(unavailableTitle, systemImage: unavailableIcon)
        } description: {
            Text("SSH 连接可用后会自动显示真实目录和文件。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var unavailableTitle: String {
        switch session.state {
        case .connecting, .reconnecting: "等待连接"
        case .failed, .disconnected: "暂无远程文件"
        case .connected: "远程文件不可用"
        }
    }

    private var unavailableIcon: String {
        switch session.state {
        case .connecting, .reconnecting: "hourglass"
        case .failed, .disconnected: "network.slash"
        case .connected: "folder.badge.questionmark"
        }
    }

    private func chooseDownloadLocation(for entry: RemoteFileEntry) {
        if entry.isDirectory {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = "选择文件夹下载位置"
            panel.prompt = "下载到这里"
            panel.begin { response in
                guard response == .OK, let directory = panel.url else { return }
                model.downloadRemoteFile(
                    entry,
                    from: session.id,
                    to: directory.appending(path: entry.name, directoryHint: .isDirectory)
                )
            }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.title = "下载远程文件"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.downloadRemoteFile(entry, from: session.id, to: url)
        }
    }

    private func copyRemotePath(for entry: RemoteFileEntry) {
        guard case .loaded(let listing) = state else { return }
        let path = RemoteFileService.childPath(parent: listing.path, name: entry.name)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func copyName(for entry: RemoteFileEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.name, forType: .string)
    }

    private func copyCurrentDirectory() {
        guard let currentDirectory else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentDirectory, forType: .string)
    }

    private func uploadClipboardFiles() {
        let urls = clipboardFileURLs
        guard !urls.isEmpty else { return }
        model.uploadFiles(urls, to: session.id)
    }

    private func beginPathEditing(_ path: String) {
        pathDraft = path
        isEditingPath = true
        DispatchQueue.main.async { isPathFocused = true }
    }

    private func finishPathEditing() {
        isPathFocused = false
        isEditingPath = false
        clearTextFocus()
    }

    private func cancelPathEditing() {
        pathDraft = currentDirectory ?? ""
        isEditingPath = false
    }

    private func openDraftPath() {
        let path = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            model.importNotice = ImportNotice(title: "路径无效", message: "请输入以 / 开头的绝对路径。")
            return
        }
        finishPathEditing()
        model.openRemoteDirectory(for: session.id, path: path)
    }

    private func visibleEntries(in listing: RemoteDirectoryListing) -> [RemoteFileEntry] {
        var entries = listing.entries.filter { entry in
            (showHiddenFiles || !entry.name.hasPrefix("."))
                && (searchText.isEmpty || entry.name.localizedCaseInsensitiveContains(searchText))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sortOrder {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            case .modified:
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            case .type:
                let left = URL(fileURLWithPath: lhs.name).pathExtension.lowercased()
                let right = URL(fileURLWithPath: rhs.name).pathExtension.lowercased()
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    private func recordHistory(_ path: String) {
        if isNavigatingHistory {
            isNavigatingHistory = false
            return
        }
        if navigationIndex >= 0, navigationHistory[navigationIndex] == path { return }
        if navigationIndex + 1 < navigationHistory.count {
            navigationHistory.removeSubrange((navigationIndex + 1)..<navigationHistory.count)
        }
        navigationHistory.append(path)
        if navigationHistory.count > 100 {
            navigationHistory.removeFirst(navigationHistory.count - 100)
        }
        navigationIndex = navigationHistory.count - 1
    }

    private func navigateHistory(by offset: Int) {
        let target = navigationIndex + offset
        guard navigationHistory.indices.contains(target) else { return }
        navigationIndex = target
        isNavigatingHistory = true
        model.openRemoteDirectory(for: session.id, path: navigationHistory[target])
    }

    private func openCurrentDirectoryInTerminal() {
        guard let currentDirectory else { return }
        model.sendTerminalCommand(
            "cd -- \(RemoteFileService.shellQuote(currentDirectory))",
            in: session.id
        )
    }

    private func openEntryInTerminal(_ entry: RemoteFileEntry) {
        guard entry.isDirectory, let currentDirectory else { return }
        let path = RemoteFileService.childPath(parent: currentDirectory, name: entry.name)
        model.sendTerminalCommand("cd -- \(RemoteFileService.shellQuote(path))", in: session.id)
    }

    private func duplicateName(for entry: RemoteFileEntry) -> String {
        if entry.isDirectory { return entry.name + " 副本" }
        let url = URL(fileURLWithPath: entry.name)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(base) 副本" : "\(base) 副本.\(ext)"
    }

    private func beginInlineRename(_ entry: RemoteFileEntry) {
        renamingEntryID = entry.id
        renameDraft = entry.name
        DispatchQueue.main.async { focusedRenameEntryID = entry.id }
    }

    private func commitInlineRename() {
        guard let entryID = renamingEntryID,
              case .loaded(let listing) = state,
              let entry = listing.entries.first(where: { $0.id == entryID }) else {
            cancelInlineRename()
            return
        }
        let value = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        cancelInlineRename()
        guard value != entry.name else { return }
        model.renameRemoteEntry(entry, to: value, in: session.id)
    }

    private func cancelInlineRename() {
        renamingEntryID = nil
        renameDraft = ""
        focusedRenameEntryID = nil
    }
}

private struct RemoteNameRequest: Identifiable {
    enum Kind {
        case createDirectory
        case createFile
        case rename(RemoteFileEntry)
        case duplicate(RemoteFileEntry)
        case move(RemoteFileEntry)
    }

    let id = UUID()
    let kind: Kind
    let initialValue: String

    var title: String {
        switch kind {
        case .createDirectory: "新建文件夹"
        case .createFile: "新建文件"
        case .rename: "重命名"
        case .duplicate: "创建副本"
        case .move: "移动远程项目"
        }
    }

    var fieldLabel: String {
        switch kind {
        case .move: "目标绝对路径"
        case .createDirectory, .createFile, .rename, .duplicate: "名称"
        }
    }
}

private struct RemotePermissionRequest: Identifiable {
    let id = UUID()
    let entry: RemoteFileEntry
    let initialValue: String
}

private struct RemotePermissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: RemotePermissionRequest
    let submit: (String) -> Void
    @State private var value: String

    init(request: RemotePermissionRequest, submit: @escaping (String) -> Void) {
        self.request = request
        self.submit = submit
        _value = State(initialValue: request.initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("文件权限")
                .font(.title2.weight(.semibold))
            Text(request.entry.name)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            TextField("例如 644 或 755", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            Text("使用八进制 chmod 权限。文件常用 644，目录或可执行脚本常用 755。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("应用", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func confirm() {
        submit(value)
        dismiss()
    }
}

private struct RemoteNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: RemoteNameRequest
    let submit: (String) -> Void
    @State private var value: String

    init(request: RemoteNameRequest, submit: @escaping (String) -> Void) {
        self.request = request
        self.submit = submit
        _value = State(initialValue: request.initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.title)
                .font(.title2.weight(.semibold))
            TextField(request.fieldLabel, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确定", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func confirm() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submit(trimmed)
        dismiss()
    }
}

private struct FileHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("名称")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("大小")
                .frame(width: 90, alignment: .trailing)
            Text("修改时间")
                .frame(width: 128, alignment: .leading)
            Text("权限")
                .frame(width: 70, alignment: .leading)
            Text("所有者")
                .frame(width: 90, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: 28)
    }
}

private struct RemoteFileRow: View {
    let entry: RemoteFileEntry
    let open: () -> Void
    let isRenaming: Bool
    @Binding var renameText: String
    let renameFocus: FocusState<String?>.Binding
    let commitRename: () -> Void
    let cancelRename: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                if isRenaming {
                    TextField("名称", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .focused(renameFocus, equals: entry.id)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .help("回车或点击空白处保存，Esc 取消")
                } else {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.isDirectory ? "—" : formattedSize)
                .frame(width: 90, alignment: .trailing)
            Text(entry.modifiedAt)
                .frame(width: 128, alignment: .leading)
            Text(entry.permissions)
                .font(.caption.monospaced())
                .frame(width: 70, alignment: .leading)
            Text(entry.owner)
                .frame(width: 90, alignment: .leading)

            if entry.isDirectory {
                Button(action: open) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .help("打开 \(entry.name)")
                .pointingHandCursor()
            } else {
                Color.clear.frame(width: 12)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !isRenaming { open() }
        }
        .help(
            entry.isDirectory
                ? "双击打开文件夹"
                : "双击下载并使用本地应用打开；保存后自动同步到服务器"
        )
        .pointingHandCursor(!isRenaming)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)
    }
}
