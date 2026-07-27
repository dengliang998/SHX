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
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1380, height: 860)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开连接…") {
                    model.isPresentingConnectionLauncher = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("快速连接…") {
                    model.isPresentingQuickConnect = true
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("打开连接中心") {
                    model.showConnectionCenter()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    model.checkForUpdates()
                }
                .disabled(model.softwareUpdateState.isBusy)
            }

            CommandMenu("会话") {
                Button("重新连接") {
                    model.reconnectSelectedSession()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedSession == nil)

                Divider()

                Button("关闭当前会话") {
                    model.closeSelectedSession()
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(model.selectedSession == nil)
            }

            CommandMenu("显示") {
                Button(model.focusMode ? "退出专注终端" : "专注终端") {
                    model.toggleFocusMode()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button(model.isInspectorVisible ? "隐藏服务器检查器" : "显示服务器检查器") {
                    model.toggleInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button(model.isFilePanelVisible ? "隐藏文件工作区" : "显示文件工作区") {
                    model.toggleFilePanel()
                }
                .keyboardShortcut("j", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

}
