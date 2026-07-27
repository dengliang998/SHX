import AppKit
import Foundation
import SwiftUI

enum DiagnosticStepStatus: Sendable {
    case passed
    case warning
    case failed
}

struct ConnectionDiagnosticStep: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
    let status: DiagnosticStepStatus
}

struct ConnectionDiagnosticReport: Sendable {
    let createdAt: Date
    let steps: [ConnectionDiagnosticStep]

    var canReachSSHPort: Bool {
        steps.first(where: { $0.title == "网络与端口" })?.status == .passed
    }
}

enum ConnectionDiagnosticService {
    static func run(profile: ServerProfile) async -> ConnectionDiagnosticReport {
        var steps: [ConnectionDiagnosticStep] = []

        let configurationIssues = validate(profile)
        steps.append(
            ConnectionDiagnosticStep(
                title: "连接配置",
                detail: configurationIssues.isEmpty ? "主机、端口和用户配置有效。" : configurationIssues.joined(separator: "；"),
                status: configurationIssues.isEmpty ? .passed : .failed
            )
        )

        switch profile.authentication {
        case .password:
            steps.append(
                ConnectionDiagnosticStep(
                    title: "认证方式",
                    detail: "使用密码认证；完整认证将在连接时通过应用内密码框完成。",
                    status: .passed
                )
            )
        case .privateKey:
            let path = profile.identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty {
                steps.append(
                    ConnectionDiagnosticStep(
                        title: "私钥",
                        detail: "未指定私钥，将由 OpenSSH 查找 ~/.ssh 下的默认密钥。",
                        status: .warning
                    )
                )
            } else {
                let readable = FileManager.default.isReadableFile(atPath: path)
                steps.append(
                    ConnectionDiagnosticStep(
                        title: "私钥",
                        detail: readable ? "私钥文件可读取：\(path)" : "无法读取私钥文件：\(path)",
                        status: readable ? .passed : .failed
                    )
                )
            }
        case .sshAgent:
            let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            steps.append(
                ConnectionDiagnosticStep(
                    title: "SSH Agent",
                    detail: socket == nil ? "当前应用环境中没有 SSH_AUTH_SOCK。" : "已检测到 SSH Agent。",
                    status: socket == nil ? .warning : .passed
                )
            )
        }

        let probe = await ConnectionProbe.test(
            host: profile.host,
            port: profile.port,
            timeout: profile.connectionTimeout
        )
        steps.append(
            ConnectionDiagnosticStep(
                title: "网络与端口",
                detail: probe.technicalDetail.isEmpty
                    ? probe.summary
                    : "\(probe.summary)\n\(probe.technicalDetail)",
                status: probe.isReachable ? .passed : .failed
            )
        )

        steps.append(
            ConnectionDiagnosticStep(
                title: "下一步",
                detail: probe.isReachable
                    ? "SSH 端口可访问。请开始连接以完成主机指纹和身份认证；若仍失败，可复制本报告和终端中的 SSH 错误。"
                    : "请检查地址、端口、VPN/局域网权限、防火墙和服务器 sshd 状态。",
                status: probe.isReachable ? .passed : .warning
            )
        )

        return ConnectionDiagnosticReport(createdAt: Date(), steps: steps)
    }

    static func validate(_ profile: ServerProfile) -> [String] {
        var issues: [String] = []
        if profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("主机为空")
        }
        if !(1...65_535).contains(profile.port) {
            issues.append("端口不在 1–65535 范围内")
        }
        if profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("用户名为空")
        }
        if !profile.startupDirectory.isEmpty && !profile.startupDirectory.hasPrefix("/") {
            issues.append("启动目录不是绝对路径")
        }
        return issues
    }
}

struct ConnectionDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile
    @State private var report: ConnectionDiagnosticReport?
    @State private var isRunning = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("连接诊断")
                        .font(.title2.weight(.semibold))
                    Text(profile.displayAddress)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检查") { run() }
                    .disabled(isRunning)
            }
            .padding(22)

            Divider()

            if isRunning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在检查配置、凭据环境和 SSH 端口…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(report.steps) { step in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: icon(for: step.status))
                                    .foregroundStyle(color(for: step.status))
                                    .font(.title3)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(step.title).font(.headline)
                                    Text(step.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                            }
                            .padding(13)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                    .padding(18)
                }
            }

            Divider()
            HStack {
                Button("复制报告") { copyReport() }
                    .disabled(report == nil)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 620)
        .task { await performRun() }
    }

    private func run() {
        isRunning = true
        report = nil
        Task { await performRun() }
    }

    @MainActor
    private func performRun() async {
        let result = await ConnectionDiagnosticService.run(profile: profile)
        report = result
        isRunning = false
    }

    private func copyReport() {
        guard let report else { return }
        let text = ([
            "KiteShell 连接诊断",
            profile.displayAddress,
            report.createdAt.formatted()
        ] + report.steps.flatMap { ["", "[\($0.title)]", $0.detail] })
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func icon(for status: DiagnosticStepStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func color(for status: DiagnosticStepStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}
