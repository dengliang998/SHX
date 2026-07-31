import AppKit
import SwiftUI

@MainActor
private enum ApplicationIconInstaller {
    static func apply() {
        guard let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let resourceURL = Bundle.main.resourceURL,
              let icon = NSImage(contentsOf: resourceURL.appending(path: iconFile)) else {
            return
        }
        NSApplication.shared.applicationIconImage = icon
    }
}

private final class KiteShellApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ApplicationIconInstaller.apply()
    }
}

@main
struct KiteShellApp: App {
    @NSApplicationDelegateAdaptor(KiteShellApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage("accentColorOption") private var accentColorOption = AccentColorOption.blue.rawValue
    @AppStorage("customAccentHex") private var customAccentHex = "#3478F6"
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.chinese.rawValue

    init() {
        ApplicationIconInstaller.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(
                    AppearanceMode(rawValue: appearanceMode)?.colorScheme
                )
                .tint(
                    (AccentColorOption(rawValue: accentColorOption) ?? .blue)
                        .color(customHex: customAccentHex)
                )
                .environment(\.locale, selectedLanguage.locale)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1380, height: 860)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(AppLanguage.text(chinese: "打开连接…", english: "Open Connection…")) {
                    model.isPresentingConnectionLauncher = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button(AppLanguage.text(chinese: "快速连接…", english: "Quick Connect…")) {
                    model.isPresentingQuickConnect = true
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button(AppLanguage.text(chinese: "打开连接中心", english: "Open Connection Center")) {
                    model.showConnectionCenter()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandGroup(after: .appInfo) {
                Button(AppLanguage.text(chinese: "检查更新…", english: "Check for Updates…")) {
                    model.checkForUpdates()
                }
                .disabled(model.softwareUpdateState.isBusy)
            }

            CommandMenu(AppLanguage.text(chinese: "会话", english: "Session")) {
                Button(AppLanguage.text(chinese: "重新连接", english: "Reconnect")) {
                    model.reconnectSelectedSession()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedSession == nil)

                Divider()

                Button(AppLanguage.text(chinese: "关闭当前会话", english: "Close Current Session")) {
                    model.closeSelectedSession()
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(model.selectedSession == nil)
            }

            CommandMenu(AppLanguage.text(chinese: "显示", english: "View")) {
                Button(model.focusMode
                    ? AppLanguage.text(chinese: "退出专注终端", english: "Exit Focus Terminal")
                    : AppLanguage.text(chinese: "专注终端", english: "Focus Terminal")) {
                    model.toggleFocusMode()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button(model.isInspectorVisible
                    ? AppLanguage.text(chinese: "隐藏服务器检查器", english: "Hide Server Inspector")
                    : AppLanguage.text(chinese: "显示服务器检查器", english: "Show Server Inspector")) {
                    model.toggleInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button(model.isFilePanelVisible
                    ? AppLanguage.text(chinese: "隐藏文件工作区", english: "Hide File Workspace")
                    : AppLanguage.text(chinese: "显示文件工作区", english: "Show File Workspace")) {
                    model.toggleFilePanel()
                }
                .keyboardShortcut("j", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environment(\.locale, selectedLanguage.locale)
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .chinese
    }

}
