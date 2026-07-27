import SwiftUI

struct TransferCenterView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var sessionsWithTransfers: [Session] {
        model.sessions.filter {
            model.uploadBatches[$0.id] != nil || model.fileTransferActivity[$0.id] != nil || model.remoteEditActivity[$0.id] != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("传输中心").font(.title2.weight(.semibold))
                    Text("集中查看所有会话的上传、下载和编辑回传任务")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            if sessionsWithTransfers.isEmpty {
                ContentUnavailableView(
                    "没有传输任务",
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text("从远程文件面板上传或下载后，任务会显示在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sessionsWithTransfers) { session in
                        Section {
                            if let batch = model.uploadBatches[session.id] {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Label("上传", systemImage: "arrow.up.circle.fill")
                                            .foregroundStyle(.tint)
                                        Text("\(batch.completedCount)/\(batch.items.count)")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        if batch.isFinished {
                                            if batch.failedCount + batch.cancelledCount > 0 {
                                                Button("重试未完成") { model.retryFailedUploads(for: session.id) }
                                            }
                                            Button("清除") { model.clearUploadBatch(for: session.id) }
                                        } else {
                                            Button(batch.isPaused ? "继续" : "暂停") {
                                                if batch.isPaused { model.resumeUploadBatch(for: session.id) }
                                                else { model.pauseUploadBatch(for: session.id) }
                                            }
                                            Button("取消", role: .destructive) { model.cancelUploadBatch(for: session.id) }
                                        }
                                    }
                                    ProgressView(value: batch.overallFraction)
                                    ForEach(batch.items) { item in
                                        HStack {
                                            Image(systemName: icon(for: item.status))
                                                .foregroundStyle(color(for: item.status))
                                                .frame(width: 18)
                                            Text(item.name).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Text(detail(for: item))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            if let activity = model.fileTransferActivity[session.id] {
                                Label(activity, systemImage: "arrow.down.circle")
                            }
                            if let activity = model.remoteEditActivity[session.id] {
                                Label(activity, systemImage: "arrow.triangle.2.circlepath")
                            }
                        } header: {
                            HStack {
                                Text(session.title)
                                Spacer()
                                Text(session.profile.displayAddress)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    private func detail(for item: UploadItemProgress) -> String {
        switch item.status {
        case .waiting: "等待"
        case .preparing: "准备"
        case .uploading:
            item.fractionCompleted.map { "\(Int($0 * 100))%" } ?? "上传中"
        case .paused: "已暂停"
        case .completed: "完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    private func icon(for status: UploadItemStatus) -> String {
        switch status {
        case .waiting: "clock"
        case .preparing, .uploading: "arrow.up.circle"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    private func color(for status: UploadItemStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed: .orange
        case .preparing, .uploading: .accentColor
        case .waiting, .paused, .cancelled: .secondary
        }
    }
}
