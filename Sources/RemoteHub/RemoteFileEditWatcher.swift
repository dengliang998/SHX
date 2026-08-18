import Foundation

struct RemoteFileSnapshot: Equatable, Sendable {
    let size: UInt64
    let modificationDate: Date
    let fileNumber: UInt64
    let contentSignature: UInt64

    static func read(from url: URL) -> RemoteFileSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return RemoteFileSnapshot(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: modificationDate,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            contentSignature: contentSignature(for: url)
        )
    }

    /// Editors may preserve both size and timestamps, or replace a file so
    /// quickly that metadata alone does not expose the change. Hashing small
    /// files completely and sampling large files makes save detection robust
    /// without repeatedly reading a large remote-edit cache file in full.
    private static func contentSignature(for url: URL) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var data = Data()
        if size <= 256 * 1_024 {
            try? handle.seek(toOffset: 0)
            data = (try? handle.readToEnd()) ?? Data()
        } else {
            try? handle.seek(toOffset: 0)
            data.append((try? handle.read(upToCount: 64 * 1_024)) ?? Data())
            try? handle.seek(toOffset: max(0, size / 2 - 32 * 1_024))
            data.append((try? handle.read(upToCount: 64 * 1_024)) ?? Data())
            try? handle.seek(toOffset: size - 64 * 1_024)
            data.append((try? handle.read(upToCount: 64 * 1_024)) ?? Data())
        }

        // Stable FNV-1a is sufficient here: this is change detection, not a
        // security boundary.
        return data.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

@MainActor
final class RemoteFileEditWatcher {
    typealias SyncAction = @MainActor @Sendable () async -> Bool

    private let localURL: URL
    private let syncAction: SyncAction
    private let pollInterval: Duration
    private let settleDelay: TimeInterval
    private let retryDelay: TimeInterval
    private var watchTask: Task<Void, Never>?
    private var lastSnapshot: RemoteFileSnapshot?
    private var needsSync = false
    private var nextSyncAttempt = Date.distantPast

    init(
        localURL: URL,
        pollInterval: Duration = .milliseconds(700),
        settleDelay: TimeInterval = 0.55,
        retryDelay: TimeInterval = 3,
        syncAction: @escaping SyncAction
    ) {
        self.localURL = localURL
        self.pollInterval = pollInterval
        self.settleDelay = settleDelay
        self.retryDelay = retryDelay
        self.syncAction = syncAction
        lastSnapshot = RemoteFileSnapshot.read(from: localURL)
    }

    func start() {
        stop()
        lastSnapshot = RemoteFileSnapshot.read(from: localURL)
        watchTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }

                let current = RemoteFileSnapshot.read(from: localURL)
                if current != lastSnapshot {
                    lastSnapshot = current
                    if current != nil {
                        needsSync = true
                        nextSyncAttempt = Date().addingTimeInterval(settleDelay)
                    }
                }

                guard needsSync, Date() >= nextSyncAttempt else { continue }
                let settled = RemoteFileSnapshot.read(from: localURL)
                if settled != lastSnapshot {
                    lastSnapshot = settled
                    nextSyncAttempt = Date().addingTimeInterval(settleDelay)
                    continue
                }

                let snapshotBeingSynced = lastSnapshot
                if await syncAction() {
                    let afterSync = RemoteFileSnapshot.read(from: localURL)
                    lastSnapshot = afterSync
                    if afterSync != snapshotBeingSynced {
                        // A second save landed while the first upload was in
                        // flight. Keep it pending instead of losing it.
                        needsSync = afterSync != nil
                        nextSyncAttempt = Date().addingTimeInterval(settleDelay)
                    } else {
                        needsSync = false
                    }
                } else {
                    nextSyncAttempt = Date().addingTimeInterval(retryDelay)
                }
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }
}
