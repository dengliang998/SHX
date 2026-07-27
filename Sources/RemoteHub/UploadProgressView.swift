import SwiftUI

struct UploadProgressControl: View {
    @EnvironmentObject private var model: AppModel
    let sessionID: UUID
    let batchID: UUID
    @State private var isPresented = true

    private var batch: UploadBatchProgress? {
        guard let batch = model.uploadBatches[sessionID], batch.id == batchID else { return nil }
        return batch
    }

    var body: some View {
        if let batch {
            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 7) {
                    if batch.isFinished {
                        Image(systemName: batch.failedCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(batch.failedCount > 0 ? Color.orange : Color.green)
                    } else {
                        ProgressView(value: batch.overallFraction)
                            .progressViewStyle(.linear)
                            .frame(width: 58)
                    }
                    Text(batch.isFinished ? finishedLabel(batch) : "上传 \(batch.completedCount)/\(batch.items.count)")
                        .font(.caption.monospacedDigit())
                }
            }
            .buttonStyle(.plain)
            .help("查看多文件上传进度")
            .pointingHandCursor()
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                UploadProgressPopover(sessionID: sessionID, batchID: batchID)
                    .environmentObject(model)
            }
        }
    }

    private func finishedLabel(_ batch: UploadBatchProgress) -> String {
        batch.failedCount + batch.cancelledCount > 0
            ? "\(batch.failedCount + batch.cancelledCount) 个未完成"
            : "\(batch.completedCount) 个已完成"
    }
}

private struct UploadProgressPopover: View {
    @EnvironmentObject private var model: AppModel
    let sessionID: UUID
    let batchID: UUID

    private var batch: UploadBatchProgress? {
        guard let batch = model.uploadBatches[sessionID], batch.id == batchID else { return nil }
        return batch
    }

    var body: some View {
        if let batch {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上传进度")
                                .font(.headline)
                            Text(summary(batch))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if batch.isFinished {
                            if batch.failedCount + batch.cancelledCount > 0 {
                                Button("重试未完成") {
                                    model.retryFailedUploads(for: sessionID)
                                }
                                .controlSize(.small)
                                .pointingHandCursor()
                            }
                            Button("完成") {
                                model.clearUploadBatch(for: sessionID)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .pointingHandCursor()
                        } else {
                            Button(batch.isPaused ? "继续" : "暂停") {
                                if batch.isPaused { model.resumeUploadBatch(for: sessionID) }
                                else { model.pauseUploadBatch(for: sessionID) }
                            }
                            .controlSize(.small)
                            Button("取消", role: .destructive) {
                                model.cancelUploadBatch(for: sessionID)
                            }
                            .controlSize(.small)
                            .pointingHandCursor()
                        }
                    }
                    ProgressView(value: batch.overallFraction)
                        .progressViewStyle(.linear)
                }
                .padding(14)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(batch.items) { item in
                            UploadProgressRow(item: item)
                            if item.id != batch.items.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 330)
            }
            .frame(width: 440)
        }
    }

    private func summary(_ batch: UploadBatchProgress) -> String {
        if batch.isFinished {
            var parts = ["完成 \(batch.completedCount) 个"]
            if batch.failedCount > 0 { parts.append("失败 \(batch.failedCount) 个") }
            if batch.cancelledCount > 0 { parts.append("取消 \(batch.cancelledCount) 个") }
            return parts.joined(separator: "，")
        }
        return "共 \(batch.items.count) 个项目，已完成 \(batch.completedCount) 个"
    }
}

private struct UploadProgressRow: View {
    let item: UploadItemProgress

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

                if item.status == .uploading || item.status == .paused {
                    if let fraction = item.fractionCompleted {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(byteDetail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if case .failed(let message) = item.status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if item.status == .completed, let total = item.totalBytes {
                    Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .preparing:
            ProgressView().controlSize(.small)
        case .uploading:
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.tint)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .waiting: "等待中"
        case .preparing: "正在计算"
        case .uploading: item.fractionCompleted?.formatted(.percent.precision(.fractionLength(0))) ?? "上传中"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: .green
        case .failed: .orange
        case .cancelled: .secondary
        case .uploading: .accentColor
        case .waiting, .preparing, .paused: .secondary
        }
    }

    private var byteDetail: String {
        let transferred = ByteCountFormatter.string(fromByteCount: item.transferredBytes, countStyle: .file)
        guard let total = item.totalBytes, total > 0 else { return transferred }
        var detail = "\(transferred) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        if item.bytesPerSecond > 0 {
            let speed = ByteCountFormatter.string(
                fromByteCount: Int64(item.bytesPerSecond),
                countStyle: .file
            )
            let remainingBytes = max(0, Double(total - item.transferredBytes))
            let remainingSeconds = remainingBytes / item.bytesPerSecond
            detail += " · \(speed)/s"
            if remainingSeconds.isFinite, remainingSeconds > 0 {
                let seconds = Int(remainingSeconds.rounded())
                detail += seconds >= 60
                    ? " · 约 \(seconds / 60)分\(seconds % 60)秒"
                    : " · 约 \(seconds)秒"
            }
        }
        return detail
    }
}
