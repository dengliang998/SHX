import Foundation
import Darwin

final class TransferProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        if cancelled {
            lock.unlock()
            process.terminate()
            return
        }
        self.process = process
        lock.unlock()
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true {
            _ = Darwin.kill(runningProcess!.processIdentifier, SIGCONT)
            runningProcess?.terminate()
        }
    }

    func pause() {
        lock.lock()
        let runningProcess = process
        lock.unlock()
        if let runningProcess, runningProcess.isRunning {
            _ = Darwin.kill(runningProcess.processIdentifier, SIGSTOP)
        }
    }

    func resume() {
        lock.lock()
        let runningProcess = process
        lock.unlock()
        if let runningProcess, runningProcess.isRunning {
            _ = Darwin.kill(runningProcess.processIdentifier, SIGCONT)
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

struct RemoteCommandContext: Sendable {
    let controlSocketPath: String
    let destination: String
    let port: Int
}

enum RemoteCommandError: LocalizedError {
    case launchFailed(String)
    case commandFailed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): "无法启动 SSH 命令：\(detail)"
        case .commandFailed(let detail): detail.isEmpty ? "远程命令执行失败" : detail
        case .invalidOutput: "服务器返回的数据格式无法识别"
        }
    }
}

enum SSHCommandRunner {
    static func run(
        context: RemoteCommandContext,
        command: String
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-T",
                "-S", context.controlSocketPath,
                "-o", "ControlMaster=no",
                "-o", "BatchMode=yes",
                "-p", String(context.port),
                "--", context.destination,
                command
            ]
            process.standardOutput = output
            process.standardError = error

            do {
                try process.run()
            } catch {
                throw RemoteCommandError.launchFailed(error.localizedDescription)
            }

            process.waitUntilExit()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let standardError = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                throw RemoteCommandError.commandFailed(standardError)
            }
            return String(decoding: outputData, as: UTF8.self)
        }.value
    }
}

enum SSHControlService {
    static func setPortForward(
        _ configuration: PortForwardConfiguration,
        enabled: Bool,
        context: RemoteCommandContext
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-S", context.controlSocketPath,
                "-O", enabled ? "forward" : "cancel",
                configuration.kind.sshFlag,
                configuration.sshSpecification,
                "-p", String(context.port),
                "--", context.destination
            ]
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                throw RemoteCommandError.launchFailed(error.localizedDescription)
            }
            process.waitUntilExit()
            let detail = [
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw RemoteCommandError.commandFailed(detail)
            }
        }.value
    }
}

enum SFTPTransferService {
    static func upload(
        localURL: URL,
        remotePath: String,
        context: RemoteCommandContext,
        control: TransferProcessControl? = nil
    ) async throws {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        let action = isDirectory.boolValue ? "put -rp" : "put -p"
        try await run(
            context: context,
            batchCommand: "\(action) \(batchQuote(localURL.path)) \(batchQuote(remotePath))",
            control: control
        )
    }

    static func download(
        remotePath: String,
        localURL: URL,
        isDirectory: Bool = false,
        context: RemoteCommandContext,
        control: TransferProcessControl? = nil
    ) async throws {
        let action = isDirectory ? "get -rp" : "get -p"
        try await run(
            context: context,
            batchCommand: "\(action) \(batchQuote(remotePath)) \(batchQuote(localURL.path))",
            control: control
        )
    }

    private static func run(
        context: RemoteCommandContext,
        batchCommand: String,
        control: TransferProcessControl?
    ) async throws {
        let terminationBox = control ?? TransferProcessControl()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                let input = Pipe()
                let output = Pipe()
                let error = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
                process.arguments = [
                    "-b", "-",
                    "-P", String(context.port),
                    "-o", "ControlPath=\(context.controlSocketPath)",
                    "-o", "ControlMaster=no",
                    "-o", "BatchMode=yes",
                    "--", context.destination
                ]
                process.standardInput = input
                process.standardOutput = output
                process.standardError = error

                terminationBox.attach(process)
                defer { terminationBox.detach() }
                guard !terminationBox.isCancelled else { throw CancellationError() }

                do {
                    try process.run()
                } catch {
                    if terminationBox.isCancelled { throw CancellationError() }
                    throw RemoteCommandError.launchFailed(error.localizedDescription)
                }

                input.fileHandleForWriting.write(Data((batchCommand + "\n").utf8))
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                if terminationBox.isCancelled { throw CancellationError() }

                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = error.fileHandleForReading.readDataToEndOfFile()
                let standardError = [
                    String(decoding: errorData, as: UTF8.self),
                    String(decoding: outputData, as: UTF8.self)
                ]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    throw RemoteCommandError.commandFailed(standardError)
                }
            }.value
            try Task.checkCancellation()
        } onCancel: {
            terminationBox.cancel()
        }
    }

    private static func batchQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct RemoteProcessInfo: Identifiable, Sendable {
    let id: Int
    let user: String
    let command: String
    let cpuPercent: Double
    let memoryPercent: Double
}

struct RemoteDiskInfo: Identifiable, Sendable {
    var id: String { mountPoint }
    let mountPoint: String
    let totalKB: Int64
    let usedKB: Int64
    let availableKB: Int64

    var usage: Double {
        guard totalKB > 0 else { return 0 }
        return min(1, max(0, Double(usedKB) / Double(totalKB)))
    }
}

struct ServerMonitorData: Sendable {
    let sampledAt: Date
    let uptimeSeconds: Double
    let loadAverage: String
    let cpuUsage: Double
    let memoryTotalKB: Int64
    let memoryAvailableKB: Int64
    let swapTotalKB: Int64
    let swapFreeKB: Int64
    let networkReceiveBytes: Int64
    let networkTransmitBytes: Int64
    var networkReceiveBytesPerSecond: Double
    var networkTransmitBytesPerSecond: Double
    let processes: [RemoteProcessInfo]
    let disks: [RemoteDiskInfo]

    var memoryUsage: Double {
        guard memoryTotalKB > 0 else { return 0 }
        return min(1, max(0, Double(memoryTotalKB - memoryAvailableKB) / Double(memoryTotalKB)))
    }

    var swapUsage: Double {
        guard swapTotalKB > 0 else { return 0 }
        return min(1, max(0, Double(swapTotalKB - swapFreeKB) / Double(swapTotalKB)))
    }
}

enum MonitorLoadState: Sendable {
    case idle
    case loading
    case loaded(ServerMonitorData)
    case failed(String)
}

enum LinuxMonitorService {
    static let command = #"""
LC_ALL=C
echo __UPTIME__
cat /proc/uptime 2>/dev/null
echo __LOAD__
cat /proc/loadavg 2>/dev/null
echo __CPU__
awk 'BEGIN { getline < "/proc/stat"; u=$2+$3+$4+$6+$7+$8; t=u+$5; close("/proc/stat"); system("sleep 0.2"); getline < "/proc/stat"; u2=$2+$3+$4+$6+$7+$8; t2=u2+$5; if (t2>t) printf "%.4f\n", (u2-u)/(t2-t); }'
echo __MEM__
awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ {print $1 "\t" $2}' /proc/meminfo 2>/dev/null
echo __NET__
awk -F'[: ]+' 'NR>2 && $2!="lo" {rx+=$3; tx+=$11} END {print rx "\t" tx}' /proc/net/dev 2>/dev/null
echo __DISKS__
df -Pk -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 {print $6 "\t" $2 "\t" $3 "\t" $4}'
echo __PROCESSES__
ps -eo pid=,user=,comm=,%cpu=,%mem= --sort=-%cpu 2>/dev/null | head -n 6
echo __END__
"""#

    static func parse(_ output: String) throws -> ServerMonitorData {
        let sections = splitSections(output)
        guard let uptimeLine = sections["UPTIME"]?.first,
              let uptimeSeconds = Double(uptimeLine.split(separator: " ").first ?? ""),
              let cpuLine = sections["CPU"]?.first,
              let cpuUsage = Double(cpuLine) else {
            throw RemoteCommandError.invalidOutput
        }

        let load = sections["LOAD"]?.first?
            .split(separator: " ")
            .prefix(3)
            .joined(separator: " ") ?? "—"

        var memory: [String: Int64] = [:]
        for line in sections["MEM"] ?? [] {
            let parts = line.split(separator: "\t")
            if parts.count == 2 {
                memory[String(parts[0]).replacingOccurrences(of: ":", with: "")] = Int64(parts[1]) ?? 0
            }
        }

        let networkParts = sections["NET"]?.first?.split(separator: "\t") ?? []
        let receive = networkParts.count > 0 ? Int64(networkParts[0]) ?? 0 : 0
        let transmit = networkParts.count > 1 ? Int64(networkParts[1]) ?? 0 : 0

        let disks = (sections["DISKS"] ?? []).compactMap { line -> RemoteDiskInfo? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            return RemoteDiskInfo(
                mountPoint: String(parts[0]),
                totalKB: Int64(parts[1]) ?? 0,
                usedKB: Int64(parts[2]) ?? 0,
                availableKB: Int64(parts[3]) ?? 0
            )
        }

        let processes = (sections["PROCESSES"] ?? []).compactMap { line -> RemoteProcessInfo? in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 5, let pid = Int(parts[0]) else { return nil }
            return RemoteProcessInfo(
                id: pid,
                user: String(parts[1]),
                command: String(parts[2]),
                cpuPercent: Double(parts[3]) ?? 0,
                memoryPercent: Double(parts[4]) ?? 0
            )
        }

        return ServerMonitorData(
            sampledAt: Date(),
            uptimeSeconds: uptimeSeconds,
            loadAverage: load,
            cpuUsage: min(1, max(0, cpuUsage)),
            memoryTotalKB: memory["MemTotal"] ?? 0,
            memoryAvailableKB: memory["MemAvailable"] ?? 0,
            swapTotalKB: memory["SwapTotal"] ?? 0,
            swapFreeKB: memory["SwapFree"] ?? 0,
            networkReceiveBytes: receive,
            networkTransmitBytes: transmit,
            networkReceiveBytesPerSecond: 0,
            networkTransmitBytesPerSecond: 0,
            processes: processes,
            disks: disks
        )
    }

    private static func splitSections(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var section: String?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("__"), line.hasSuffix("__") {
                section = String(line.dropFirst(2).dropLast(2))
                continue
            }
            if let section, !line.isEmpty {
                result[section, default: []].append(line)
            }
        }
        return result
    }
}

struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(name)\t\(isDirectory)" }
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let modifiedAt: String
    let permissions: String
    let owner: String
}

struct RemoteDirectoryListing: Sendable {
    let path: String
    let entries: [RemoteFileEntry]
}

enum RemoteDirectoryState: Sendable {
    case idle
    case loading(path: String?)
    case loaded(RemoteDirectoryListing)
    case failed(String)
}

enum RemoteFileService {
    static func command(path: String?) -> String {
        let requestedPath = path ?? "."
        let quoted = shellQuote(requestedPath)
        return #"""
LC_ALL=C
cd -- \#(quoted) || exit 2
printf '__PWD__\t%s\n' "$PWD"
find . -mindepth 1 -maxdepth 1 -printf '__FILE__\t%y\t%f\t%s\t%TY-%Tm-%Td %TH:%TM\t%m\t%u\n' 2>/dev/null
"""#
    }

    static func parse(_ output: String) throws -> RemoteDirectoryListing {
        var path: String?
        var entries: [RemoteFileEntry] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.first == "__PWD__", parts.count >= 2 {
                path = String(parts[1])
            } else if parts.first == "__FILE__", parts.count >= 7 {
                entries.append(
                    RemoteFileEntry(
                        name: String(parts[2]),
                        isDirectory: parts[1] == "d",
                        sizeBytes: Int64(parts[3]) ?? 0,
                        modifiedAt: String(parts[4]),
                        permissions: String(parts[5]),
                        owner: String(parts[6])
                    )
                )
            }
        }

        guard let path else { throw RemoteCommandError.invalidOutput }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return RemoteDirectoryListing(path: path, entries: entries)
    }

    static func childPath(parent: String, name: String) -> String {
        URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(name)
            .path
    }

    static func parentPath(of path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    static func createDirectoryCommand(parent: String, name: String) -> String {
        "mkdir -- \(shellQuote(childPath(parent: parent, name: name)))"
    }

    static func createFileCommand(parent: String, name: String) -> String {
        "touch -- \(shellQuote(childPath(parent: parent, name: name)))"
    }

    static func renameCommand(parent: String, oldName: String, newName: String) -> String {
        let oldPath = childPath(parent: parent, name: oldName)
        let newPath = childPath(parent: parent, name: newName)
        return "mv -- \(shellQuote(oldPath)) \(shellQuote(newPath))"
    }

    static func moveCommand(parent: String, entry: RemoteFileEntry, destinationPath: String) -> String {
        let source = childPath(parent: parent, name: entry.name)
        return "mv -- \(shellQuote(source)) \(shellQuote(destinationPath))"
    }

    static func deleteCommand(parent: String, entry: RemoteFileEntry) -> String {
        let path = shellQuote(childPath(parent: parent, name: entry.name))
        return entry.isDirectory ? "rm -rf -- \(path)" : "rm -f -- \(path)"
    }

    static func duplicateCommand(parent: String, entry: RemoteFileEntry, newName: String) -> String {
        let source = shellQuote(childPath(parent: parent, name: entry.name))
        let destination = shellQuote(childPath(parent: parent, name: newName))
        return entry.isDirectory
            ? "cp -R -- \(source) \(destination)"
            : "cp -p -- \(source) \(destination)"
    }

    static func changePermissionsCommand(parent: String, entry: RemoteFileEntry, mode: String) -> String {
        "chmod -- \(mode) \(shellQuote(childPath(parent: parent, name: entry.name)))"
    }

    static func transferSizeCommand(path: String, isDirectory: Bool) -> String {
        let quoted = shellQuote(path)
        if isDirectory {
            return "find \(quoted) -type f -printf '%s\\n' 2>/dev/null | awk '{s+=$1} END {print s+0}'"
        }
        return "stat -c %s -- \(quoted) 2>/dev/null || printf 0"
    }

    static func versionCommand(path: String) -> String {
        "stat -c '%s:%Y' -- \(shellQuote(path)) 2>/dev/null || true"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
