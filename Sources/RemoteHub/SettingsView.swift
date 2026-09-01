import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("monitorInterval") private var monitorInterval = 3.0
    @AppStorage("restoreWorkspace") private var restoreWorkspace = true
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage("accentColorOption") private var accentColorOption = AccentColorOption.blue.rawValue
    @AppStorage("customAccentHex") private var customAccentHex = "#3478F6"
    @AppStorage("terminalTheme") private var terminalTheme = TerminalThemeOption.midnight.rawValue
    @AppStorage("terminalLineSpacing") private var terminalLineSpacing = 1.0
    @AppStorage("terminalScrollback") private var terminalScrollback = 5_000
    @AppStorage("terminalCursorStyle") private var terminalCursorStyle = TerminalCursorStyleOption.block.rawValue
    @AppStorage("terminalOptionAsMeta") private var terminalOptionAsMeta = true
    @AppStorage("confirmRiskyPaste") private var confirmRiskyPaste = true
    @AppStorage("taskNotifications") private var taskNotifications = false
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.chinese.rawValue

    var body: some View {
        Form {
            Section("语言 / Language") {
                Picker("应用语言", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("切换后主窗口与设置会立即使用所选语言。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外观") {
                Picker("模式", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("强调色", selection: $accentColorOption) {
                    ForEach(AccentColorOption.allCases) { option in
                        Text(LocalizedStringKey(option.rawValue)).tag(option.rawValue)
                    }
                }

                if accentColorOption == AccentColorOption.custom.rawValue {
                    ColorPicker("自定义颜色", selection: customAccentBinding, supportsOpacity: false)
                }
            }

            Section("启动") {
                Toggle("恢复上次工作区", isOn: $restoreWorkspace)
                Button("清除已保存的工作区") {
                    model.clearSavedWorkspace()
                }
            }

            Section("终端") {
                Picker("终端主题", selection: $terminalTheme) {
                    ForEach(TerminalThemeOption.allCases) { option in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(nsColor: option.definition.background))
                                .overlay {
                                    Circle().stroke(.secondary.opacity(0.4), lineWidth: 0.5)
                                }
                                .frame(width: 12, height: 12)
                            Text(LocalizedStringKey(option.rawValue))
                        }
                        .tag(option.rawValue)
                    }
                }

                Slider(value: $terminalFontSize, in: 10...24, step: 1) {
                    Text("字号")
                } minimumValueLabel: {
                    Text("10")
                } maximumValueLabel: {
                    Text("24")
                }
                LabeledContent("当前字号", value: "\(Int(terminalFontSize)) pt")
                Slider(value: $terminalLineSpacing, in: 0.9...1.5, step: 0.05) {
                    Text("行距")
                }
                LabeledContent("当前行距", value: "\(Int(terminalLineSpacing * 100))%")
                Picker("光标", selection: $terminalCursorStyle) {
                    ForEach(TerminalCursorStyleOption.allCases) { option in
                        Text(LocalizedStringKey(option.rawValue)).tag(option.rawValue)
                    }
                }
                Picker("滚动历史", selection: $terminalScrollback) {
                    Text("1,000 行").tag(1_000)
                    Text("5,000 行").tag(5_000)
                    Text("10,000 行").tag(10_000)
                    Text("50,000 行").tag(50_000)
                }
                Toggle("Option 键作为 Meta", isOn: $terminalOptionAsMeta)
                Toggle("粘贴多行或高风险内容前确认", isOn: $confirmRiskyPaste)
            }

            Section("监控") {
                Picker("采样周期", selection: $monitorInterval) {
                    Text("1 秒").tag(1.0)
                    Text("3 秒").tag(3.0)
                    Text("5 秒").tag(5.0)
                    Text("关闭").tag(0.0)
                }
            }

            Section("通知") {
                Toggle("后台任务完成或失败时通知", isOn: $taskNotifications)
            }

            Section("软件更新") {
                HStack(spacing: 10) {
                    if model.softwareUpdateState.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.canInstallSoftwareUpdate ? "arrow.down.circle.fill" : "checkmark.circle")
                            .foregroundStyle(model.canInstallSoftwareUpdate ? .blue : .secondary)
                    }
                    Text(model.softwareUpdateState.localizedSummary)
                        .foregroundStyle(model.softwareUpdateState.isBusy ? .primary : .secondary)
                    Spacer()
                }
                HStack {
                    Button("检查更新") { model.checkForUpdates() }
                        .disabled(model.softwareUpdateState.isBusy)
                    if model.canInstallSoftwareUpdate {
                        Button("查看发布页面") { model.openAvailableSoftwareRelease() }
                        Button("下载并安装") { model.installAvailableSoftwareUpdate() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text("更新来自 GitHub Releases。替换当前应用前，SHX 会校验 Ed25519 清单签名和 DMG SHA-256。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("诊断") {
                Button("导出脱敏诊断报告…") { exportDiagnostics() }
                Button("在 Finder 中显示日志") { DiagnosticsCenter.revealLog() }
                Button("清除诊断日志", role: .destructive) {
                    DiagnosticsCenter.clearLog()
                    model.importNotice = ImportNotice(title: "已清除日志", message: "SHX 诊断日志已删除。")
                }
            }

            Section("存储与卸载") {
                Button("清理远程编辑缓存…", role: .destructive) { model.clearRemoteEditCache() }
                Text("卸载应用不会自动删除连接配置和本地凭据。若需彻底清理，请先逐项删除连接，再删除 ~/Library/Application Support/SHX 与 ~/Library/Caches/SHX。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("关于") {
                LabeledContent("SHX", value: AppVersion.display)
                LabeledContent(
                    "运行环境",
                    value: AppLanguage.text(
                        chinese: "macOS 原生 · Apple Silicon",
                        english: "Native macOS · Apple Silicon"
                    )
                )
                LabeledContent("签名", value: AppVersion.signingType)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 780)
        .navigationTitle("设置")
        .onChange(of: monitorInterval) {
            model.refreshMonitorPolling()
        }
        .onChange(of: terminalTheme) {
            model.applyTerminalAppearance()
        }
        .onChange(of: terminalFontSize) {
            model.applyTerminalAppearance()
        }
        .onChange(of: terminalLineSpacing) { model.applyTerminalAppearance() }
        .onChange(of: terminalScrollback) { model.applyTerminalAppearance() }
        .onChange(of: terminalCursorStyle) { model.applyTerminalAppearance() }
        .onChange(of: terminalOptionAsMeta) { model.applyTerminalAppearance() }
        .onChange(of: taskNotifications) {
            if taskNotifications { UserNotificationService.requestAuthorization() }
        }
    }

    private var customAccentBinding: Binding<Color> {
        Binding(
            get: { Color(hex: customAccentHex) ?? .blue },
            set: { customAccentHex = $0.hexRGB ?? customAccentHex }
        )
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "导出 SHX 诊断报告"
        panel.nameFieldStringValue = "SHX-Diagnostics.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsCenter.exportReport(to: url)
            model.importNotice = ImportNotice(
                title: "诊断报告已导出",
                message: "报告已脱敏，不包含凭据、终端内容、服务器地址或远程文件。"
            )
        } catch {
            model.importNotice = ImportNotice(title: "无法导出诊断报告", message: error.localizedDescription)
        }
    }

}
