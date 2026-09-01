import SwiftUI

struct PasswordPromptSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: PasswordRequest

    @State private var password = ""
    @State private var rememberPassword = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.kind.title)
                        .font(.title2.weight(.semibold))
                    Text(request.profile.displayAddress)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            SecureField(request.kind.fieldLabel, text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
                .accessibilityLabel(request.kind.fieldLabel)

            Toggle("保存到本地凭据库", isOn: $rememberPassword)

            Text("凭据加密存放在当前 Mac 的 SHX 本地数据目录，不调用系统钥匙串，也不会写入连接配置或日志。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    model.passwordRequest = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("连接", action: connect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func connect() {
        guard !password.isEmpty else { return }
        let submittedPassword = password
        password = ""
        model.submitPassword(
            submittedPassword,
            remember: rememberPassword,
            for: request
        )
        dismiss()
    }
}
