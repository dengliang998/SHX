import AppKit
import Foundation

enum DiagnosticsCenter {
    private static let lock = NSLock()

    static var logURL: URL? {
        guard let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "SHX", directoryHint: .isDirectory)
            .appending(path: "SHX.log", directoryHint: .notDirectory)
    }

    static func record(_ category: String, _ message: String) {
        guard let logURL else { return }
        let safeCategory = sanitize(category)
        let safeMessage = sanitize(message)
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [\(safeCategory)] \(safeMessage)\n"

        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try Data(line.utf8).write(to: logURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            }
            trimIfNeeded(logURL)
        } catch {
            // Diagnostics must never interfere with the user's active SSH session.
        }
    }

    static func exportReport(to url: URL) throws {
        let logText: String
        lock.lock()
        logText = logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "暂无诊断日志。"
        lock.unlock()

        let report = """
        SHX 诊断报告
        生成时间：\(Date().formatted())
        应用版本：\(AppVersion.display)
        系统版本：\(ProcessInfo.processInfo.operatingSystemVersionString)
        处理器：\(machineArchitecture)

        隐私说明：本报告不包含密码、私钥、终端输入输出、服务器地址、远程路径或文件内容。

        ===== 运行日志 =====
        \(logText)
        """
        try report.write(to: url, atomically: true, encoding: .utf8)
    }

    static func revealLog() {
        guard let logURL else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
        }
    }

    static func clearLog() {
        guard let logURL else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: logURL)
    }

    private static var machineArchitecture: String {
        #if arch(arm64)
        "Apple Silicon (arm64)"
        #else
        "未知"
        #endif
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(500)
            .description
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return }
        let suffix = data.suffix(1024 * 1024)
        try? Data(suffix).write(to: url, options: .atomic)
    }
}
