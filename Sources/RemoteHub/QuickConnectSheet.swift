import SwiftUI

struct QuickConnectionAddress: Equatable, Sendable {
    let username: String
    let host: String
    let port: Int
}

enum QuickConnectionParser {
    static func parse(_ value: String) -> QuickConnectionAddress? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let username = String(trimmed[..<at])
        let hostPort = String(trimmed[trimmed.index(after: at)...])
        guard !username.isEmpty, !hostPort.isEmpty else { return nil }

        if hostPort.hasPrefix("["), let closing = hostPort.firstIndex(of: "]") {
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closing])
            let remainder = hostPort[hostPort.index(after: closing)...]
            if remainder.isEmpty { return QuickConnectionAddress(username: username, host: host, port: 22) }
            guard remainder.first == ":", let port = Int(remainder.dropFirst()), (1...65_535).contains(port) else {
                return nil
            }
            return QuickConnectionAddress(username: username, host: host, port: port)
        }

        let colonCount = hostPort.filter { $0 == ":" }.count
        if colonCount == 1, let colon = hostPort.lastIndex(of: ":") {
            let host = String(hostPort[..<colon])
            guard !host.isEmpty,
                  let port = Int(hostPort[hostPort.index(after: colon)...]),
                  (1...65_535).contains(port) else { return nil }
            return QuickConnectionAddress(username: username, host: host, port: port)
        }
        return QuickConnectionAddress(username: username, host: hostPort, port: 22)
    }
}

struct QuickConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var authentication: AuthenticationMethod = .privateKey
    @State private var saveConnection = false

    private var parsed: QuickConnectionAddress? {
        QuickConnectionParser.parse(address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("快速连接")
                .font(.title2.weight(.semibold))
            Text("输入 user@host 或 user@host:port，直接打开临时 SSH 会话。")
                .foregroundStyle(.secondary)

            TextField("deploy@example.com:22", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(connect)

            Picker("认证方式", selection: $authentication) {
                ForEach(AuthenticationMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }

            Toggle("同时保存到连接中心", isOn: $saveConnection)

            if let parsed {
                Label("将连接到 \(parsed.username)@\(parsed.host):\(parsed.port)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else if !address.isEmpty {
                Label("地址格式无效", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("连接", action: connect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func connect() {
        guard let parsed else { return }
        let profile = ServerProfile(
            name: parsed.host,
            host: parsed.host,
            port: parsed.port,
            username: parsed.username,
            authentication: authentication,
            group: saveConnection ? "默认分组" : "临时连接"
        )
        if saveConnection { model.addServer(profile) }
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            model.requestOpenSession(for: profile)
        }
    }
}
