import Foundation

enum UploadItemStatus: Sendable, Equatable {
    case waiting
    case preparing
    case uploading
    case paused
    case completed
    case failed(String)
    case cancelled
}

struct UploadItemProgress: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let localURL: URL?
    var isDirectory: Bool
    var totalBytes: Int64?
    var transferredBytes: Int64
    var status: UploadItemStatus
    var startedAt: Date?
    var bytesPerSecond: Double

    init(id: UUID = UUID(), name: String, localURL: URL? = nil) {
        self.id = id
        self.name = name
        self.localURL = localURL
        isDirectory = false
        totalBytes = nil
        transferredBytes = 0
        status = .waiting
        startedAt = nil
        bytesPerSecond = 0
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return status == .completed ? 1 : nil
        }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }
}

struct UploadBatchProgress: Identifiable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    var items: [UploadItemProgress]

    init(id: UUID = UUID(), urls: [URL]) {
        self.id = id
        startedAt = Date()
        items = urls.map { UploadItemProgress(name: $0.lastPathComponent, localURL: $0) }
    }

    var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }

    var failedCount: Int {
        items.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
    }

    var cancelledCount: Int {
        items.filter { $0.status == .cancelled }.count
    }

    var isFinished: Bool {
        !items.isEmpty && items.allSatisfy {
            switch $0.status {
            case .completed, .failed, .cancelled: true
            case .waiting, .preparing, .uploading, .paused: false
            }
        }
    }

    var overallFraction: Double {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(0.0) { partial, item in
            switch item.status {
            case .completed, .failed, .cancelled:
                partial + 1
            case .waiting, .preparing:
                partial
            case .uploading, .paused:
                partial + (item.fractionCompleted ?? 0.08)
            }
        }
        return min(1, max(0, sum / Double(items.count)))
    }

    var isPaused: Bool { items.contains { $0.status == .paused } }
}

struct LocalUploadMetrics: Sendable, Equatable {
    let isDirectory: Bool
    let totalBytes: Int64

    static func measure(_ url: URL) -> LocalUploadMetrics {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return LocalUploadMetrics(isDirectory: false, totalBytes: 0)
        }
        guard isDirectory.boolValue else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return LocalUploadMetrics(
                isDirectory: false,
                totalBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            )
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        )
        var total: Int64 = 0
        while let child = enumerator?.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return LocalUploadMetrics(isDirectory: true, totalBytes: total)
    }
}
