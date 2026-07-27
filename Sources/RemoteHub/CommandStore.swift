import Foundation

struct CommandExecutionRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let commandName: String
    let profileName: String
    let submittedAt: Date
    let mode: CommandExecutionMode

    init(commandName: String, profileName: String, mode: CommandExecutionMode) {
        id = UUID()
        self.commandName = commandName
        self.profileName = profileName
        submittedAt = Date()
        self.mode = mode
    }
}

struct CommandStore {
    private let commandsKey = "globalQuickCommands.v1"
    private let historyKey = "commandExecutionHistory.v1"

    func loadCommands() -> [QuickCommand] { decode([QuickCommand].self, key: commandsKey) ?? [] }
    func saveCommands(_ commands: [QuickCommand]) { encode(commands, key: commandsKey) }
    func loadHistory() -> [CommandExecutionRecord] { decode([CommandExecutionRecord].self, key: historyKey) ?? [] }
    func saveHistory(_ history: [CommandExecutionRecord]) { encode(Array(history.prefix(100)), key: historyKey) }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
