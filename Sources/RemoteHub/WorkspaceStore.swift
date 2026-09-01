import Foundation

struct WorkspaceSnapshot: Codable, Sendable {
    let profileIDs: [UUID]
    let selectedIndex: Int?
    let isInspectorVisible: Bool
    let isFilePanelVisible: Bool
    let focusMode: Bool
}

struct WorkspaceStore {
    private var fileURL: URL? {
        guard let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return baseURL
            .appending(path: "SHX", directoryHint: .isDirectory)
            .appending(path: "workspace.json", directoryHint: .notDirectory)
    }

    func load() -> WorkspaceSnapshot? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    func save(_ snapshot: WorkspaceSnapshot) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // Workspace recovery is best effort and must not interrupt active sessions.
        }
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
