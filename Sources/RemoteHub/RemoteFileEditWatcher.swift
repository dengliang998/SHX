import Foundation

struct RemoteFileSnapshot: Equatable, Sendable {
    let size: UInt64
    let modificationDate: Date
    let fileNumber: UInt64

    static func read(from url: URL) -> RemoteFileSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return RemoteFileSnapshot(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: modificationDate,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        )
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

                if await syncAction() {
                    needsSync = false
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
