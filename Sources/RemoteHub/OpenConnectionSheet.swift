import SwiftUI

struct OpenConnectionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isCreatingServer = false

    private var visibleServers: [ServerProfile] {
        guard !searchText.isEmpty else { return model.servers }
        return model.servers.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.host.localizedCaseInsensitiveContains(searchText)
                || $0.username.localizedCaseInsensitiveContains(searchText)
                || $0.group.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("打开连接")
                        .font(.title2.weight(.semibold))
                    Text("选择已保存的服务器，或创建新的服务器配置。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isCreatingServer = true
                } label: {
                    Label("新建服务器", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .pointingHandCursor()
            }
            .padding(22)

            Divider()

            TextField("搜索名称、地址、用户或分组", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)

            if visibleServers.isEmpty {
                ContentUnavailableView {
                    Label(model.servers.isEmpty ? "还没有保存的服务器" : "没有匹配的服务器", systemImage: "server.rack")
                } description: {
                    Text(model.servers.isEmpty ? "先创建一个服务器配置，然后会立即打开连接。" : "尝试调整搜索内容。")
                } actions: {
                    Button("新建服务器") { isCreatingServer = true }
                        .pointingHandCursor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleServers) { profile in
                            Button {
                                open(profile)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.tint)
                                        .frame(width: 34, height: 34)
                                        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.name)
                                            .font(.body.weight(.medium))
                                        Text(profile.displayAddress)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(profile.group)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 13)
                                .frame(height: 58)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11)
                                        .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .contextMenu {
                                Button("打开连接") { open(profile) }
                                Button(profile.isFavorite ? "取消收藏" : "收藏") {
                                    model.toggleFavorite(profile)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
            }

            Divider()
            HStack {
                Text("双击或单击服务器即可打开新会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 600)
        .onAppear {
            DispatchQueue.main.async { clearTextFocus() }
        }
        .sheet(isPresented: $isCreatingServer) {
            NewConnectionSheet { submission in
                let profile = submission.profile
                model.addServer(
                    profile,
                    password: submission.password,
                    rememberPassword: submission.rememberPassword
                )
                guard submission.shouldConnect else {
                    isCreatingServer = false
                    return
                }
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    model.requestOpenSession(for: profile, oneTimeCredential: submission.password)
                }
            }
        }
    }

    private func open(_ profile: ServerProfile) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            model.requestOpenSession(for: profile)
        }
    }
}
