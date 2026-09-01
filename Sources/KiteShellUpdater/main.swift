import Darwin
import Foundation

private struct Arguments {
    let source: URL
    let destination: URL
    let pid: pid_t
    let mountPoint: URL
    let workspace: URL

    init?(_ values: [String]) {
        func value(after flag: String) -> String? {
            guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else { return nil }
            return values[index + 1]
        }
        guard let source = value(after: "--source"),
              let destination = value(after: "--destination"),
              let pidValue = value(after: "--pid").flatMap(Int32.init),
              let mountPoint = value(after: "--mount-point"),
              let workspace = value(after: "--workspace") else { return nil }
        self.source = URL(fileURLWithPath: source, isDirectory: true)
        self.destination = URL(fileURLWithPath: destination, isDirectory: true)
        pid = pidValue
        self.mountPoint = URL(fileURLWithPath: mountPoint, isDirectory: true)
        self.workspace = URL(fileURLWithPath: workspace, isDirectory: true)
    }
}

private enum Installer {
    static func run(_ arguments: Arguments) throws {
        defer {
            _ = try? runProcess("/usr/bin/hdiutil", ["detach", arguments.mountPoint.path])
            try? FileManager.default.removeItem(at: arguments.workspace)
        }
        try waitForExit(pid: arguments.pid)
        let fileManager = FileManager.default
        let backup = arguments.destination.deletingLastPathComponent()
            .appending(path: ".SHX-update-backup-\(UUID().uuidString).app", directoryHint: .isDirectory)
        let hadExistingApp = fileManager.fileExists(atPath: arguments.destination.path)
        if hadExistingApp {
            try fileManager.moveItem(at: arguments.destination, to: backup)
        }

        do {
            try runProcess("/usr/bin/ditto", [arguments.source.path, arguments.destination.path])
            try runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", arguments.destination.path])
            if hadExistingApp { try? fileManager.removeItem(at: backup) }
        } catch {
            try? fileManager.removeItem(at: arguments.destination)
            if hadExistingApp { try? fileManager.moveItem(at: backup, to: arguments.destination) }
            _ = try? runProcess("/usr/bin/open", [arguments.destination.path])
            throw error
        }

        try runProcess("/usr/bin/open", [arguments.destination.path])
    }

    private static func waitForExit(pid: pid_t) throws {
        for _ in 0..<600 where kill(pid, 0) == 0 {
            usleep(100_000)
        }
        guard kill(pid, 0) != 0 else {
            throw CocoaError(.executableRuntimeMismatch)
        }
    }

    @discardableResult
    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableRuntimeMismatch)
        }
        return process.terminationStatus
    }
}

guard let arguments = Arguments(Array(CommandLine.arguments.dropFirst())) else {
    exit(64)
}

do {
    try Installer.run(arguments)
} catch {
    exit(1)
}
