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
        control: TransferProcessControl? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue {
            try await uploadRegularFile(
                localURL: localURL,
                remotePath: remotePath,
                context: context,
                control: control,
                progress: progress
            )
            return
        }
        try await run(
            context: context,
            batchCommand: "put -rp \(batchQuote(localURL.path)) \(batchQuote(remotePath))",
            control: control
        )
    }

    private static func uploadRegularFile(
        localURL: URL,
        remotePath: String,
        context: RemoteCommandContext,
        control: TransferProcessControl?,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        let terminationBox = control ?? TransferProcessControl()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                let input = Pipe()
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
                    "cat > \(RemoteFileService.shellQuote(remotePath))"
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

                do {
                    let source = try FileHandle(forReadingFrom: localURL)
                    defer { try? source.close() }
                    var transferred: Int64 = 0
                    var lastReport = ContinuousClock.now
                    progress?(0)
                    while !terminationBox.isCancelled {
                        let chunk = try source.read(upToCount: 512 * 1_024) ?? Data()
                        if chunk.isEmpty { break }
                        try input.fileHandleForWriting.write(contentsOf: chunk)
                        transferred += Int64(chunk.count)
                        let now = ContinuousClock.now
                        if now - lastReport >= .milliseconds(100) {
                            progress?(transferred)
                            lastReport = now
                        }
                    }
                    if terminationBox.isCancelled { throw CancellationError() }
                    progress?(transferred)
                    try input.fileHandleForWriting.close()
                } catch {
                    try? input.fileHandleForWriting.close()
                    if terminationBox.isCancelled { throw CancellationError() }
                    process.terminate()
                    throw error
                }

                process.waitUntilExit()
                if terminationBox.isCancelled { throw CancellationError() }
                let standardError = String(
                    decoding: error.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    throw RemoteCommandError.commandFailed(standardError)
                }
            }.value
            try Task.checkCancellation()
        } onCancel: {
            terminationBox.cancel()
        }
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
    let platform: String
    let uptimeSeconds: Double?
    let loadAverage: String?
    let cpuUsage: Double?
    let memoryTotalKB: Int64?
    let memoryAvailableKB: Int64?
    let swapTotalKB: Int64?
    let swapFreeKB: Int64?
    let networkReceiveBytes: Int64?
    let networkTransmitBytes: Int64?
    var networkReceiveBytesPerSecond: Double?
    var networkTransmitBytesPerSecond: Double?
    let processes: [RemoteProcessInfo]
    let disks: [RemoteDiskInfo]

    var memoryUsage: Double? {
        guard let memoryTotalKB, let memoryAvailableKB, memoryTotalKB > 0 else { return nil }
        return min(1, max(0, Double(memoryTotalKB - memoryAvailableKB) / Double(memoryTotalKB)))
    }

    var swapUsage: Double? {
        guard let swapTotalKB, let swapFreeKB, swapTotalKB > 0 else { return nil }
        return min(1, max(0, Double(swapTotalKB - swapFreeKB) / Double(swapTotalKB)))
    }

    var unavailableSections: [String] {
        var values: [String] = []
        if uptimeSeconds == nil { values.append(AppLanguage.text(chinese: "运行时间", english: "Uptime")) }
        if loadAverage == nil { values.append(AppLanguage.text(chinese: "系统负载", english: "Load Average")) }
        if cpuUsage == nil { values.append("CPU") }
        if memoryUsage == nil { values.append(AppLanguage.text(chinese: "内存", english: "Memory")) }
        if networkReceiveBytes == nil || networkTransmitBytes == nil {
            values.append(AppLanguage.text(chinese: "网络", english: "Network"))
        }
        return values
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
platform=$(uname -s 2>/dev/null || printf Unknown)
echo __PLATFORM__
printf '%s\n' "$platform"
if [ "$platform" = "Darwin" ]; then
echo __UPTIME__
boot=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
now=$(date +%s 2>/dev/null)
if [ -n "$boot" ] && [ -n "$now" ]; then expr "$now" - "$boot" 2>/dev/null; fi
echo __LOAD__
sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'
echo __CPU__
top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ {gsub("%","",$7); idle=$7} END {if (idle != "") printf "%.4f\n", (100-idle)/100}'
echo __MEM__
total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
page_size=$(vm_stat 2>/dev/null | awk 'NR==1 {gsub("[^0-9]","",$8); print $8}')
if [ -n "$total_bytes" ]; then printf 'MemTotal:\t%s\n' "$((total_bytes / 1024))"; fi
vm_stat 2>/dev/null | awk -v page="$page_size" '
    /Pages free:/ {gsub("\\.","",$3); free=$3}
    /Pages inactive:/ {gsub("\\.","",$3); inactive=$3}
    /Pages speculative:/ {gsub("\\.","",$3); speculative=$3}
    END {if (page > 0) printf "MemAvailable:\t%.0f\n", (free+inactive+speculative)*page/1024}'
echo __NET__
netstat -ibn 2>/dev/null | awk 'NR>1 && $1 != "lo0" && $7 ~ /^[0-9]+$/ && $10 ~ /^[0-9]+$/ {rx+=$7; tx+=$10} END {if (NR>1) print rx "\t" tx}'
echo __DISKS__
df -Pk 2>/dev/null | awk 'NR>1 && $2 ~ /^[0-9]+$/ {print $NF "\t" $2 "\t" $3 "\t" $4}'
echo __PROCESSES__
ps -Ao pid=,user=,comm=,%cpu=,%mem= -r 2>/dev/null | head -n 6
else
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
fi
echo __END__
"""#

    static func parse(_ output: String) throws -> ServerMonitorData {
        let sections = splitSections(output)
        let platform = sections["PLATFORM"]?.first ?? "Unknown"
        let uptimeSeconds = sections["UPTIME"]?.first.flatMap {
            Double($0.split(separator: " ").first ?? "")
        }
        let cpuUsage = sections["CPU"]?.first.flatMap(Double.init)
        let load = sections["LOAD"]?.first.map {
            $0.split(separator: " ").prefix(3).joined(separator: " ")
        }
        guard uptimeSeconds != nil || cpuUsage != nil || load != nil
                || sections["MEM"]?.isEmpty == false || sections["DISKS"]?.isEmpty == false
                || sections["PROCESSES"]?.isEmpty == false else {
            throw RemoteCommandError.invalidOutput
        }

        var memory: [String: Int64] = [:]
        for line in sections["MEM"] ?? [] {
            let parts = line.split(separator: "\t")
            if parts.count == 2 {
                memory[String(parts[0]).replacingOccurrences(of: ":", with: "")] = Int64(parts[1]) ?? 0
            }
        }

        let networkParts = sections["NET"]?.first?.split(separator: "\t") ?? []
        let receive = networkParts.count > 0 ? Int64(networkParts[0]) : nil
        let transmit = networkParts.count > 1 ? Int64(networkParts[1]) : nil

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
            guard parts.count >= 5,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[parts.count - 2]),
                  let memory = Double(parts[parts.count - 1]) else { return nil }
            return RemoteProcessInfo(
                id: pid,
                user: String(parts[1]),
                command: parts[2..<(parts.count - 2)].joined(separator: " "),
                cpuPercent: cpu,
                memoryPercent: memory
            )
        }

        return ServerMonitorData(
            sampledAt: Date(),
            platform: platform,
            uptimeSeconds: uptimeSeconds,
            loadAverage: load,
            cpuUsage: cpuUsage.map { min(1, max(0, $0)) },
            memoryTotalKB: memory["MemTotal"],
            memoryAvailableKB: memory["MemAvailable"],
            swapTotalKB: memory["SwapTotal"],
            swapFreeKB: memory["SwapFree"],
            networkReceiveBytes: receive,
            networkTransmitBytes: transmit,
            networkReceiveBytesPerSecond: receive == nil ? nil : 0,
            networkTransmitBytesPerSecond: transmit == nil ? nil : 0,
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
cd \#(quoted) || exit 2
printf '__PWD__\t%s\n' "$PWD"
platform=$(uname -s 2>/dev/null || printf Unknown)
if [ -n "$ZSH_VERSION" ]; then setopt local_options nonomatch; fi
for entry in ./* ./.[!.]* ./..?*; do
    if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then continue; fi
    name=${entry#./}
    name_hex=$(printf '%s' "$name" | od -An -tx1 | tr -d ' \n')
    if [ -d "$entry" ]; then kind=d; else kind=f; fi
    if [ "$platform" = "Darwin" ] || [ "$platform" = "FreeBSD" ]; then
        meta=$(stat -f '%z\t%Sm\t%Lp\t%Su' -t '%Y-%m-%d %H:%M' "$entry" 2>/dev/null) || meta='0\t—\t—\t—'
    else
        meta=$(stat -c '%s\t%.16y\t%a\t%U' -- "$entry" 2>/dev/null) || meta='0\t—\t—\t—'
    fi
    printf '__FILEHEX__\t%s\t%s\t%b\n' "$kind" "$name_hex" "$meta"
done
true
"""#
    }

    static func parse(_ output: String) throws -> RemoteDirectoryListing {
        var path: String?
        var entries: [RemoteFileEntry] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.first == "__PWD__", parts.count >= 2 {
                path = String(parts[1])
            } else if parts.first == "__FILEHEX__", parts.count >= 7,
                      let name = decodeHexName(String(parts[2])) {
                entries.append(
                    RemoteFileEntry(
                        name: name,
                        isDirectory: parts[1] == "d",
                        sizeBytes: Int64(parts[3]) ?? 0,
                        modifiedAt: String(parts[4]),
                        permissions: String(parts[5]),
                        owner: String(parts[6])
                    )
                )
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

    private static func decodeHexName(_ value: String) -> String? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return String(data: data, encoding: .utf8)
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
            return "if [ \"$(uname -s 2>/dev/null)\" = Darwin ]; then find \(quoted) -type f -exec stat -f '%z' {} \\; 2>/dev/null; else find \(quoted) -type f -printf '%s\\n' 2>/dev/null; fi | awk '{s+=$1} END {print s+0}'"
        }
        return "stat -f '%z' \(quoted) 2>/dev/null || stat -c '%s' -- \(quoted) 2>/dev/null || printf 0"
    }

    static func versionCommand(path: String) -> String {
        "stat -f '%z:%m' \(shellQuote(path)) 2>/dev/null || stat -c '%s:%Y' -- \(shellQuote(path)) 2>/dev/null || true"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
