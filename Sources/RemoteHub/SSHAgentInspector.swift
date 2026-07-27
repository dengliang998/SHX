import Foundation

struct SSHAgentStatus: Sendable, Equatable {
    let isAvailable: Bool
    let identities: [String]
    let detail: String

    var summary: String {
        if !isAvailable { return "SSH Agent 不可用" }
        if identities.isEmpty { return "Agent 可用，但没有已加载的密钥" }
        return "Agent 可用，已加载 \(identities.count) 个身份"
    }
}

enum SSHAgentInspector {
    static func inspect() async -> SSHAgentStatus {
        await Task.detached(priority: .utility) {
            guard let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
                  !socket.isEmpty else {
                return SSHAgentStatus(isAvailable: false, identities: [], detail: "环境中没有 SSH_AUTH_SOCK。")
            }
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            process.arguments = ["-l"]
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return SSHAgentStatus(isAvailable: false, identities: [], detail: error.localizedDescription)
            }
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identities = stdout.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if process.terminationStatus == 0 {
                return SSHAgentStatus(isAvailable: true, identities: identities, detail: identities.joined(separator: "\n"))
            }
            if process.terminationStatus == 1, stderr.localizedCaseInsensitiveContains("no identities") {
                return SSHAgentStatus(isAvailable: true, identities: [], detail: stderr)
            }
            return SSHAgentStatus(isAvailable: false, identities: [], detail: stderr.isEmpty ? "ssh-add 返回状态 \(process.terminationStatus)" : stderr)
        }.value
    }
}
