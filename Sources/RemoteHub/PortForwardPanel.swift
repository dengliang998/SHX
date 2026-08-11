import AppKit
import SwiftUI

struct PortForwardPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var editingForward: PortForwardConfiguration?
    @State private var deletionCandidate: PortForwardConfiguration?

    private var forwards: [PortForwardConfiguration] {
        model.portForwards(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("端口转发")
                        .font(.title2.weight(.semibold))
                    Text(session.profile.displayAddress)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editingForward = PortForwardConfiguration(
                        name: "",
                        kind: .local,
                        bindAddress: "127.0.0.1",
                        listenPort: 8080,
                        targetHost: "127.0.0.1",
                        targetPort: 80,
                        isEnabled: false
                    )
                } label: {
                    Label("新建转发", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(22)

            Divider()

            if forwards.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("还没有端口转发")
                        .font(.headline)
                    Text("可以创建本地转发、远程转发或动态 SOCKS5 代理。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("新建转发") {
                        editingForward = PortForwardConfiguration(
                            name: "",
                            kind: .local,
                            bindAddress: "127.0.0.1",
                            listenPort: 8080,
                            targetHost: "127.0.0.1",
                            targetPort: 80,
                            isEnabled: false
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(24)
            } else {
                List(forwards) { forward in
                    HStack(spacing: 12) {
                        Image(systemName: icon(forward.kind))
                            .foregroundStyle(forward.isEnabled ? Color.green : Color.secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                (forward.isEnabled ? Color.green : Color.secondary).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(forward.name).font(.body.weight(.medium))
                                Text(forward.kind.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(forward.sshSpecification)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if forward.bindAddress == "0.0.0.0" || forward.bindAddress == "::" {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("该端口会监听所有网络接口")
                        }
                        Toggle("运行", isOn: Binding(
                            get: { forward.isEnabled },
                            set: { _ in model.togglePortForward(forward, for: session.id) }
                        ))
                        .labelsHidden()
                        .help(forward.isEnabled ? "停止转发" : "启动转发")
                        Button("编辑") { editingForward = forward }
                            .disabled(forward.isEnabled)
                        Menu {
                            Button("编辑…") { editingForward = forward }
                                .disabled(forward.isEnabled)
                            Button("复制规格") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(forward.sshSpecification, forType: .string)
                            }
                            Divider()
                            Button("删除…", role: .destructive) { deletionCandidate = forward }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .padding(.vertical, 5)
                }
            }

            Divider()
            HStack {
                Text(session.state == .connected ? "切换开关会立即通过当前 SSH 会话启动或停止转发。" : "离线时启用的转发将在下次连接时启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 500, alignment: .top)
        .sheet(item: $editingForward) { configuration in
            PortForwardEditor(configuration: configuration) { saved in
                model.savePortForward(saved, for: session.id)
            }
        }
        .confirmationDialog(
            "删除端口转发？",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            presenting: deletionCandidate
        ) { forward in
            Button("删除 \(forward.name)", role: .destructive) {
                model.deletePortForward(forward, for: session.id)
                deletionCandidate = nil
            }
            Button("取消", role: .cancel) { deletionCandidate = nil }
        } message: { forward in
            Text(forward.isEnabled ? "运行中的转发会先停止，然后删除配置。" : "该操作只删除保存的转发配置。")
        }
    }

    private func icon(_ kind: PortForwardKind) -> String {
        switch kind {
        case .local: "arrow.right.circle"
        case .remote: "arrow.left.circle"
        case .dynamic: "network.badge.shield.half.filled"
        }
    }
}

private struct PortForwardEditor: View {
    @Environment(\.dismiss) private var dismiss
    let save: (PortForwardConfiguration) -> Void
    @State private var configuration: PortForwardConfiguration

    init(
        configuration: PortForwardConfiguration,
        save: @escaping (PortForwardConfiguration) -> Void
    ) {
        _configuration = State(initialValue: configuration)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(configuration.name.isEmpty ? "新建端口转发" : "编辑端口转发")
                .font(.title2.weight(.semibold))

            Form {
                TextField("名称", text: $configuration.name)
                Picker("类型", selection: $configuration.kind) {
                    ForEach(PortForwardKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                TextField("监听地址", text: $configuration.bindAddress)
                TextField("监听端口", value: $configuration.listenPort, format: .number)
                if configuration.kind != .dynamic {
                    TextField("目标主机", text: $configuration.targetHost)
                    TextField("目标端口", value: $configuration.targetPort, format: .number)
                }
            }
            .formStyle(.grouped)

            if configuration.bindAddress == "0.0.0.0" || configuration.bindAddress == "::" {
                Label("监听所有网络接口可能向局域网或公网开放该端口。", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Text("SSH 参数：\(configuration.kind.sshFlag) \(configuration.sshSpecification)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save(configuration)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!configuration.isValid)
            }
        }
        .padding(22)
        .frame(width: 560, height: 510)
    }
}
