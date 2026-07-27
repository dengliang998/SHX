import SwiftUI

struct RemoteTextDocument: Sendable {
    let content: String
    let remoteVersion: String?
    let usesCRLF: Bool
}

enum RemoteTextEditorError: LocalizedError {
    case tooLarge(Int64)
    case binary
    case changedRemotely
    case unavailable

    var errorDescription: String? {
        switch self {
        case .tooLarge(let size): "文件大小为 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))，内置编辑器最多打开 2 MB。"
        case .binary: "该文件不是有效的 UTF-8 文本，请使用下载或外部应用打开。"
        case .changedRemotely: "服务器上的文件已被其他操作修改。为避免覆盖新版本，本次保存已取消。"
        case .unavailable: "当前 SSH 会话不可用。"
        }
    }
}

struct RemoteTextEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let entry: RemoteFileEntry
    @State private var text = ""
    @State private var remoteVersion: String?
    @State private var usesCRLF = false
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasChanges = false

    private var matchCount: Int {
        guard !searchText.isEmpty else { return 0 }
        return text.components(separatedBy: searchText).count - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text("UTF-8 · \(usesCRLF ? "CRLF" : "LF") · 保存后上传到当前服务器")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("查找", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                if !searchText.isEmpty {
                    Text("\(matchCount) 处").font(.caption).foregroundStyle(.secondary)
                }
                Picker("换行符", selection: $usesCRLF) {
                    Text("LF").tag(false)
                    Text("CRLF").tag(true)
                }
                .frame(width: 105)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("保存") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(isLoading || isSaving || !hasChanges)
            }
            .padding(14)
            Divider()

            if isLoading {
                VStack(spacing: 12) { ProgressView(); Text("正在读取远程文件…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, text.isEmpty {
                ContentUnavailableView("无法打开文件", systemImage: "doc.badge.ellipsis", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: text) { hasChanges = true }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.orange.opacity(0.08))
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task { await load() }
    }

    private func load() async {
        do {
            let document = try await model.loadRemoteTextFile(entry, from: session.id)
            text = document.content.replacingOccurrences(of: "\r\n", with: "\n")
            usesCRLF = document.usesCRLF
            remoteVersion = document.remoteVersion
            hasChanges = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let normalized = usesCRLF ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
                remoteVersion = try await model.saveRemoteTextFile(
                    normalized,
                    entry: entry,
                    expectedVersion: remoteVersion,
                    in: session.id
                )
                hasChanges = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
