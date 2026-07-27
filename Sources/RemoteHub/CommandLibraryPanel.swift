import SwiftUI
import UniformTypeIdentifiers

struct CommandLibraryPanel: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case connection = "当前服务器"
        case global = "全局"
        case history = "历史"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    let session: Session
    @State private var editingCommand: QuickCommand?
    @State private var deletionCandidate: QuickCommand?
    @State private var isImportingScript = false
    @State private var searchText = ""
    @State private var executionCommand: QuickCommand?
    @State private var scope: Scope = .connection

    private var commands: [QuickCommand] {
        let commands = scope == .global ? model.globalQuickCommands : model.quickCommands(for: session.id)
        guard !searchText.isEmpty else { return commands }
        return commands.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.command.localizedCaseInsensitiveContains(searchText)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                Text("\(commands.count) 条已保存命令")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("搜索命令", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button {
                    isImportingScript = true
                } label: {
                    Label("导入本地脚本", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .tint(.teal)
                .controlSize(.small)
                .pointingHandCursor()

                Button {
                    editingCommand = QuickCommand(name: "", command: "")
                } label: {
                    Label("新建命令", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
                .pointingHandCursor()
                .disabled(scope == .history)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            Divider()

            if scope == .history {
                commandHistory
            } else if commands.isEmpty {
                ContentUnavailableView {
                    Label("还没有命令或脚本", systemImage: "terminal")
                } description: {
                    Text("连接后可随时添加常用命令，也可以导入本地 Shell 脚本。")
                } actions: {
                    HStack {
                        Button("新建命令") {
                            editingCommand = QuickCommand(name: "", command: "")
                        }
                        Button("导入脚本") { isImportingScript = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(commands) { command in
                            CommandRow(
                                command: command,
                                isConnected: session.state == .connected,
                                run: { requestExecution(command) },
                                edit: { editingCommand = command },
                                delete: { deletionCandidate = command }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingScript,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importScript(from: url)
            case .failure(let error):
                model.importNotice = ImportNotice(title: "无法导入脚本", message: error.localizedDescription)
            }
        }
        .sheet(item: $editingCommand) { command in
            QuickCommandEditorSheet(command: command) { saved in
                if scope == .global { model.saveGlobalQuickCommand(saved) }
                else { model.saveQuickCommand(saved, for: session.id) }
            }
        }
        .sheet(item: $executionCommand) { command in
            CommandExecutionSheet(command: command) { resolved, mode in
                model.runResolvedQuickCommand(command, content: resolved, mode: mode, in: session.id)
            }
        }
        .confirmationDialog(
            "删除已保存命令？",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            presenting: deletionCandidate
        ) { command in
            Button("删除 \(command.name)", role: .destructive) {
                if scope == .global { model.deleteGlobalQuickCommand(command) }
                else { model.deleteQuickCommand(command, for: session.id) }
                deletionCandidate = nil
            }
            Button("取消", role: .cancel) { deletionCandidate = nil }
        } message: { _ in
            Text("只会删除 KiteShell 中保存的命令，不会删除服务器上的文件。")
        }
    }

    @ViewBuilder
    private var commandHistory: some View {
        if model.commandExecutionHistory.isEmpty {
            ContentUnavailableView("没有执行历史", systemImage: "clock.arrow.circlepath", description: Text("这里只记录命令名称、服务器名称和提交时间，不记录命令内容或输出。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("仅保留最近 100 条元数据，不保存命令内容或输出。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清除历史", role: .destructive) { model.clearCommandExecutionHistory() }
                        .controlSize(.small)
                }
                .padding(10)
                List(model.commandExecutionHistory) { record in
                    HStack {
                        Image(systemName: record.mode == .insert ? "text.cursor" : "play.circle")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.commandName)
                            Text(record.profileName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.submittedAt, style: .relative)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func importScript(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 512 * 1024 else {
                model.importNotice = ImportNotice(title: "脚本过大", message: "单个快捷脚本不能超过 512 KB。")
                return
            }
            guard let script = String(data: data, encoding: .utf8),
                  !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.importNotice = ImportNotice(title: "无法导入脚本", message: "文件不是有效的 UTF-8 文本，或内容为空。")
                return
            }
            let name = url.deletingPathExtension().lastPathComponent
            let command = QuickCommand(name: name.isEmpty ? "导入的脚本" : name, command: script)
            if scope == .global { model.saveGlobalQuickCommand(command) }
            else { model.saveQuickCommand(command, for: session.id) }
            model.importNotice = ImportNotice(title: "脚本已导入", message: "\(command.name) 已保存到\(scope == .global ? "全局命令库" : "当前服务器")。")
        } catch {
            model.importNotice = ImportNotice(title: "无法导入脚本", message: error.localizedDescription)
        }
    }

    private func requestExecution(_ command: QuickCommand) {
        guard session.state == .connected else { return }
        if command.executionMode == .direct,
           command.variableNames.isEmpty,
           !command.isPotentiallyDestructive {
            model.runQuickCommand(command, in: session.id)
        } else if command.executionMode == .insert, command.variableNames.isEmpty {
            model.runResolvedQuickCommand(command, content: command.command, mode: .insert, in: session.id)
        } else {
            executionCommand = command
        }
    }
}

private struct CommandRow: View {
    let command: QuickCommand
    let isConnected: Bool
    let run: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(command.name)
                    .font(.callout.weight(.medium))
                Text(command.command.replacingOccurrences(of: "\n", with: "  "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("编辑", action: edit)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
            Button(action: run) {
                Label("运行", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!isConnected)
            .pointingHandCursor(isConnected)
            Menu {
                Button("编辑…", action: edit)
                Button("运行", action: run)
                    .disabled(!isConnected)
                Divider()
                Button("删除…", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .pointingHandCursor()
        }
        .padding(.horizontal, 11)
        .frame(height: 54)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1 : 0.72),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isHovering
                        ? Color.accentColor.opacity(0.30)
                        : Color(nsColor: .separatorColor).opacity(0.35),
                    lineWidth: 0.5
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if isConnected { run() } }
        .onHover { isHovering = $0 }
        .pointingHandCursor(isConnected)
        .contextMenu {
            Button("运行", action: run).disabled(!isConnected)
            Button("编辑…", action: edit)
            Divider()
            Button("删除…", role: .destructive, action: delete)
        }
    }
}

private struct QuickCommandEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let original: QuickCommand
    let save: (QuickCommand) -> Void
    @State private var name: String
    @State private var command: String
    @State private var executionMode: CommandExecutionMode
    @State private var tags: String

    init(command: QuickCommand, save: @escaping (QuickCommand) -> Void) {
        original = command
        self.save = save
        _name = State(initialValue: command.name)
        _command = State(initialValue: command.command)
        _executionMode = State(initialValue: command.executionMode)
        _tags = State(initialValue: command.tags.joined(separator: ", "))
    }

    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original.command.isEmpty ? "新建命令或脚本" : "编辑命令或脚本")
                .font(.title2.weight(.semibold))
            TextField("显示名称", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("执行方式", selection: $executionMode) {
                    ForEach(CommandExecutionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                TextField("标签（逗号分隔）", text: $tags)
                    .textFieldStyle(.roundedBorder)
            }
            Text("命令或 Shell 脚本")
                .font(.callout.weight(.medium))
            TextEditor(text: $command)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5)
                }
            Text("可使用 ${变量名} 创建运行时变量。高风险命令即使设置为直接运行也会再次确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(QuickCommand(
                        id: original.id,
                        name: cleanedName.isEmpty ? "未命名命令" : cleanedName,
                        command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                        executionMode: executionMode,
                        tags: tags.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        }.filter { !$0.isEmpty }
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 600, height: 470)
    }
}

private struct CommandExecutionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let command: QuickCommand
    let execute: (String, CommandExecutionMode) -> Void
    @State private var variables: [String: String]

    init(
        command: QuickCommand,
        execute: @escaping (String, CommandExecutionMode) -> Void
    ) {
        self.command = command
        self.execute = execute
        _variables = State(initialValue: Dictionary(
            uniqueKeysWithValues: command.variableNames.map { ($0, "") }
        ))
    }

    private var resolvedCommand: String {
        command.resolving(variables: variables)
    }

    private var canExecute: Bool {
        variables.values.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.executionMode == .insert ? "插入命令" : "确认运行命令")
                        .font(.title2.weight(.semibold))
                    Text(command.name)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if command.isPotentiallyDestructive {
                    Label("高风险内容", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if !command.variableNames.isEmpty {
                GroupBox("运行变量") {
                    VStack(spacing: 10) {
                        ForEach(command.variableNames, id: \.self) { name in
                            TextField(name, text: Binding(
                                get: { variables[name, default: ""] },
                                set: { variables[name] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Text("最终内容")
                .font(.callout.weight(.medium))
            ScrollView {
                Text(resolvedCommand)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5) }

            if command.isPotentiallyDestructive {
                Text("该内容可能删除数据、停止服务或重启系统，请确认目标服务器和变量值。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(command.executionMode == .insert ? "插入终端" : "运行") {
                    let effectiveMode: CommandExecutionMode = command.executionMode == .insert ? .insert : .confirm
                    execute(resolvedCommand, effectiveMode)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canExecute)
            }
        }
        .padding(22)
        .frame(width: 620, height: command.variableNames.isEmpty ? 430 : 540)
    }
}
