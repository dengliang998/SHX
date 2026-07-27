import Foundation

enum AuthenticationMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password = "密码"
    case privateKey = "私钥"
    case sshAgent = "SSH Agent"

    var id: String { rawValue }
}

enum ReconnectPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case once
    case threeTimes
    case continuous

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: "不自动重连"
        case .once: "重试 1 次"
        case .threeTimes: "重试 3 次"
        case .continuous: "持续重试"
        }
    }

    var maximumAttempts: Int? {
        switch self {
        case .disabled: 0
        case .once: 1
        case .threeTimes: 3
        case .continuous: nil
        }
    }
}

enum PortForwardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local = "本地转发"
    case remote = "远程转发"
    case dynamic = "动态 SOCKS5"

    var id: String { rawValue }

    var sshFlag: String {
        switch self {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
    }
}

enum UpstreamProxyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "不使用"
    case socks5 = "SOCKS5"
    case httpConnect = "HTTP CONNECT"
    var id: String { rawValue }
}

struct UpstreamProxyConfiguration: Codable, Hashable, Sendable {
    var kind: UpstreamProxyKind = .none
    var host: String = ""
    var port: Int = 1080

    var isValid: Bool {
        if kind == .none { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        return !host.isEmpty && host.unicodeScalars.allSatisfy(allowed.contains) && (1...65_535).contains(port)
    }

    var proxyCommand: String? {
        guard kind != .none, isValid else { return nil }
        let protocolName = kind == .socks5 ? "5" : "connect"
        return "/usr/bin/nc -x \(host):\(port) -X \(protocolName) %h %p"
    }
}

struct PortForwardConfiguration: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: PortForwardKind
    var bindAddress: String
    var listenPort: Int
    var targetHost: String
    var targetPort: Int
    var isEnabled: Bool

    var sshSpecification: String {
        switch kind {
        case .local, .remote:
            "\(bindAddress):\(listenPort):\(targetHost):\(targetPort)"
        case .dynamic:
            "\(bindAddress):\(listenPort)"
        }
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bindAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(listenPort)
            && (kind == .dynamic || (
                !targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (1...65_535).contains(targetPort)
            ))
    }
}

enum CommandExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case insert = "插入终端"
    case confirm = "确认后运行"
    case direct = "直接运行"

    var id: String { rawValue }
}

struct QuickCommand: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var command: String
    var executionMode: CommandExecutionMode = .confirm
    var tags: [String] = []

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        executionMode: CommandExecutionMode = .confirm,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.executionMode = executionMode
        self.tags = tags
    }

    var variableNames: [String] {
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        var seen: Set<String> = []
        return expression.matches(in: command, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: command) else { return nil }
            let name = String(command[range])
            return seen.insert(name).inserted ? name : nil
        }
    }

    func resolving(variables: [String: String]) -> String {
        variables.reduce(command) { partial, item in
            partial.replacingOccurrences(of: "${\(item.key)}", with: item.value)
        }
    }

    var isPotentiallyDestructive: Bool {
        let lowercased = command.lowercased()
        return ["rm -", "shutdown", "reboot", "mkfs", "kill -9", "systemctl stop"]
            .contains { lowercased.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, executionMode, tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        executionMode = try container.decodeIfPresent(CommandExecutionMode.self, forKey: .executionMode) ?? .confirm
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authentication: AuthenticationMethod
    var group: String
    var tags: [String]
    var notes: String
    var isFavorite: Bool
    var lastConnectedAt: Date?
    var quickCommands: [QuickCommand]
    var identityFilePath: String
    var identityFileBookmark: Data?
    var connectionTimeout: Int
    var keepAliveInterval: Int
    var startupDirectory: String
    var initializationCommand: String
    var runsInitializationCommand: Bool
    var reconnectPolicy: ReconnectPolicy
    var jumpHostID: UUID?
    var upstreamProxy: UpstreamProxyConfiguration
    var portForwards: [PortForwardConfiguration]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authentication: AuthenticationMethod = .privateKey,
        group: String = "默认分组",
        tags: [String] = [],
        notes: String = "",
        isFavorite: Bool = false,
        lastConnectedAt: Date? = nil,
        quickCommands: [QuickCommand] = [],
        identityFilePath: String = "",
        identityFileBookmark: Data? = nil,
        connectionTimeout: Int = 10,
        keepAliveInterval: Int = 15,
        startupDirectory: String = "",
        initializationCommand: String = "",
        runsInitializationCommand: Bool = false,
        reconnectPolicy: ReconnectPolicy = .threeTimes,
        jumpHostID: UUID? = nil,
        upstreamProxy: UpstreamProxyConfiguration = UpstreamProxyConfiguration(),
        portForwards: [PortForwardConfiguration] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.group = group
        self.tags = tags
        self.notes = notes
        self.isFavorite = isFavorite
        self.lastConnectedAt = lastConnectedAt
        self.quickCommands = quickCommands
        self.identityFilePath = identityFilePath
        self.identityFileBookmark = identityFileBookmark
        self.connectionTimeout = connectionTimeout
        self.keepAliveInterval = keepAliveInterval
        self.startupDirectory = startupDirectory
        self.initializationCommand = initializationCommand
        self.runsInitializationCommand = runsInitializationCommand
        self.reconnectPolicy = reconnectPolicy
        self.jumpHostID = jumpHostID
        self.upstreamProxy = upstreamProxy
        self.portForwards = portForwards
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayAddress: String {
        port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authentication, group, tags, notes
        case isFavorite, lastConnectedAt, quickCommands
        case identityFilePath, identityFileBookmark, connectionTimeout, keepAliveInterval
        case startupDirectory, initializationCommand, runsInitializationCommand
        case reconnectPolicy, createdAt, updatedAt
        case jumpHostID, upstreamProxy, portForwards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        authentication = try container.decodeIfPresent(AuthenticationMethod.self, forKey: .authentication) ?? .privateKey
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? "默认分组"
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        quickCommands = try container.decodeIfPresent([QuickCommand].self, forKey: .quickCommands) ?? []
        identityFilePath = try container.decodeIfPresent(String.self, forKey: .identityFilePath) ?? ""
        identityFileBookmark = try container.decodeIfPresent(Data.self, forKey: .identityFileBookmark)
        connectionTimeout = try container.decodeIfPresent(Int.self, forKey: .connectionTimeout) ?? 10
        keepAliveInterval = try container.decodeIfPresent(Int.self, forKey: .keepAliveInterval) ?? 15
        startupDirectory = try container.decodeIfPresent(String.self, forKey: .startupDirectory) ?? ""
        initializationCommand = try container.decodeIfPresent(String.self, forKey: .initializationCommand) ?? ""
        runsInitializationCommand = try container.decodeIfPresent(Bool.self, forKey: .runsInitializationCommand) ?? false
        reconnectPolicy = try container.decodeIfPresent(ReconnectPolicy.self, forKey: .reconnectPolicy) ?? .threeTimes
        jumpHostID = try container.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        upstreamProxy = try container.decodeIfPresent(UpstreamProxyConfiguration.self, forKey: .upstreamProxy) ?? UpstreamProxyConfiguration()
        portForwards = try container.decodeIfPresent([PortForwardConfiguration].self, forKey: .portForwards) ?? []
        let fallbackDate = lastConnectedAt ?? Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? fallbackDate
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? fallbackDate
    }
}

enum ConnectionState: String, Codable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected
    case failed

    var label: String {
        switch self {
        case .connecting: "连接中"
        case .connected: "已连接"
        case .reconnecting: "正在重连"
        case .disconnected: "已断开"
        case .failed: "连接失败"
        }
    }
}

struct Session: Identifiable, Hashable, Sendable {
    var id = UUID()
    var profile: ServerProfile
    var state: ConnectionState = .connecting
    var openedAt = Date()
    var title: String { profile.name }
}
