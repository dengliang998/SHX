import Foundation

struct ProfileStore {
    private var fileURL: URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return baseURL.appending(path: "KiteShell", directoryHint: .isDirectory)
            .appending(path: "servers.json", directoryHint: .notDirectory)
    }

    func load() -> [ServerProfile] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    func save(_ profiles: [ServerProfile]) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failures will be surfaced through the diagnostics layer later.
        }
    }
}
