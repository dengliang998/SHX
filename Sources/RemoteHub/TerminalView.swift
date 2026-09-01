import SwiftUI

struct TerminalAndFilesView: View {
    @EnvironmentObject private var model: AppModel
    let session: Session

    var body: some View {
        if model.isFilePanelVisible && !model.focusMode {
            VSplitView {
                TerminalView(session: session)
                    .frame(minHeight: 300)
                RemoteFilePanel(session: session)
                    .frame(minHeight: 190, idealHeight: 280)
            }
        } else {
            TerminalView(session: session)
        }
    }
}

private struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    let session: Session
    @State private var isPresentingDiagnostics = false
    @State private var isSearchVisible = false
    @State private var searchText = ""
    @State private var searchFoundMatch: Bool?
    @FocusState private var isSearchFocused: Bool

    private var quickCommands: [QuickCommand] {
        model.quickCommands(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(session.profile.displayAddress, systemImage: "terminal")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(session.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !quickCommands.isEmpty {
                    Menu {
                        ForEach(quickCommands) { quickCommand in
                            Button {
                                model.runQuickCommand(quickCommand, in: session.id)
                            } label: {
                                Label(quickCommand.name, systemImage: "play.fill")
                            }
                        }
                    } label: {
                        Label("快捷命令", systemImage: "play.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(session.state != .connected)
                    .help("执行该服务器保存的一键命令")
                    .pointingHandCursor(session.state == .connected)
                }
                if session.profile.authentication == .password {
                    Menu {
                        Button("使用已保存密码重连") {
                            model.reconnectSelectedSession()
                        }
                        Button("重新输入密码…") {
                            model.reconnectSelectedSessionRequestingPassword()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .menuStyle(.borderlessButton)
                    .help("重新连接")
                    .pointingHandCursor()
                } else if session.profile.authentication == .privateKey,
                          PrivateKeyInspector.requiresPassphrase(at: session.profile.identityFilePath) {
                    Menu {
                        Button("使用已保存口令重连") {
                            model.reconnectSelectedSession()
                        }
                        Button("重新输入私钥口令…") {
                            model.reconnectSelectedSessionRequestingPrivateKeyPassphrase()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .menuStyle(.borderlessButton)
                    .help("重新连接")
                    .pointingHandCursor()
                } else {
                    Button {
                        model.reconnectSelectedSession()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("重新连接")
                    .pointingHandCursor()
                }
                Button {
                    isPresentingDiagnostics = true
                } label: {
                    Image(systemName: "stethoscope")
                }
                .buttonStyle(.plain)
                .help("连接诊断")
                .pointingHandCursor()
                Button {
                    isSearchVisible.toggle()
                    if isSearchVisible {
                        DispatchQueue.main.async { isSearchFocused = true }
                    } else {
                        model.terminalControllers[session.id]?.clearSearch()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [.command])
                .help("搜索终端内容")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.bar)
            .macOS26Glass(in: RoundedRectangle(cornerRadius: 10))

            Divider()

            if isSearchVisible {
                HStack(spacing: 8) {
                    TextField("搜索终端内容", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onSubmit { findNext() }
                    if searchFoundMatch == false {
                        Text("未找到")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button { findPrevious() } label: { Image(systemName: "chevron.up") }
                        .help("上一个匹配")
                    Button { findNext() } label: { Image(systemName: "chevron.down") }
                        .help("下一个匹配")
                    Button {
                        isSearchVisible = false
                        searchText = ""
                        searchFoundMatch = nil
                        model.terminalControllers[session.id]?.clearSearch()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("关闭搜索")
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(.bar)
                .macOS26Glass(in: RoundedRectangle(cornerRadius: 10))
                Divider()
            }

            if let controller = model.terminalControllers[session.id] {
                NativeTerminalHost(controller: controller)
                    .id(controller.id)
                    .background(Color(nsColor: controller.terminalBackgroundColor))
            } else {
                ContentUnavailableView {
                    Label("会话等待恢复", systemImage: "terminal.fill")
                } description: {
                    Text("为保护凭据，KiteShell 不会在启动时自动登录服务器。")
                } actions: {
                    Button("重新连接") {
                        model.selectSession(session)
                        model.reconnectSelectedSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.title) 终端")
        .sheet(isPresented: $isPresentingDiagnostics) {
            ConnectionDiagnosticsSheet(profile: session.profile)
        }
        .onChange(of: searchText) {
            if searchText.isEmpty {
                searchFoundMatch = nil
                model.terminalControllers[session.id]?.clearSearch()
            }
        }
    }

    private func findNext() {
        guard !searchText.isEmpty else { return }
        searchFoundMatch = model.terminalControllers[session.id]?.findNext(searchText) ?? false
    }

    private func findPrevious() {
        guard !searchText.isEmpty else { return }
        searchFoundMatch = model.terminalControllers[session.id]?.findPrevious(searchText) ?? false
    }
}
