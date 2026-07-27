import AppKit
import SwiftUI

struct ServerInspectorView: View {
    @EnvironmentObject private var model: AppModel
    let session: Session

    private var state: MonitorLoadState {
        model.monitorStates[session.id] ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.profile.name)
                        .font(.headline)
                    Text(session.profile.host)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    model.refreshMonitor(for: session.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(session.state != .connected)
                .help("刷新服务器监控")
                .pointingHandCursor(session.state == .connected)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if session.state != .connected {
                unavailableView
            } else {
                monitorContent
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.title) 服务器信息")
    }

    @ViewBuilder
    private var monitorContent: some View {
        switch state {
        case .idle:
            ContentUnavailableView(
                "监控已关闭",
                systemImage: "gauge.with.dots.needle.0percent",
                description: Text("可在设置中开启采样，或点击刷新读取一次。")
            )
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取服务器指标…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("无法读取监控", systemImage: "gauge.with.dots.needle.0percent")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("重试") { model.refreshMonitor(for: session.id) }
            }
        case .loaded(let data):
            MonitorDetailView(sessionID: session.id, data: data)
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label(unavailableTitle, systemImage: unavailableIcon)
        } description: {
            Text("SSH 连接可用后会自动显示真实服务器指标。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }

    private var unavailableTitle: String {
        switch session.state {
        case .connecting, .reconnecting: "等待连接"
        case .failed, .disconnected: "暂无监控数据"
        case .connected: "监控不可用"
        }
    }

    private var unavailableIcon: String {
        switch session.state {
        case .connecting, .reconnecting: "hourglass"
        case .failed, .disconnected: "network.slash"
        case .connected: "gauge.with.dots.needle.0percent"
        }
    }
}

private struct MonitorDetailView: View {
    private enum ProcessSort: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case memory = "内存"

        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    let sessionID: UUID
    let data: ServerMonitorData
    @State private var processSearch = ""
    @State private var processSort: ProcessSort = .cpu
    @State private var terminationCandidate: RemoteProcessInfo?

    private var visibleProcesses: [RemoteProcessInfo] {
        let searched = processSearch.isEmpty ? data.processes : data.processes.filter {
            $0.command.localizedCaseInsensitiveContains(processSearch)
                || $0.user.localizedCaseInsensitiveContains(processSearch)
                || String($0.id).contains(processSearch)
        }
        return searched.sorted {
            processSort == .cpu
                ? $0.cpuPercent > $1.cpuPercent
                : $0.memoryPercent > $1.memoryPercent
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 7) {
                    MetricCard(
                        title: "运行时间",
                        value: formatUptime(data.uptimeSeconds),
                        icon: "clock.fill",
                        tint: .cyan
                    )
                    MetricCard(
                        title: "系统负载",
                        value: data.loadAverage,
                        icon: "waveform.path.ecg",
                        tint: .orange
                    )
                }

                MonitorSection(title: "资源使用", icon: "gauge.with.dots.needle.67percent") {
                    ResourceUsageRow(
                        title: "CPU",
                        icon: "cpu",
                        value: data.cpuUsage,
                        detail: "处理器占用",
                        tint: .blue
                    )
                    ResourceUsageRow(
                        title: "内存",
                        icon: "memorychip",
                        value: data.memoryUsage,
                        detail: "\(bytes((data.memoryTotalKB - data.memoryAvailableKB) * 1024)) / \(bytes(data.memoryTotalKB * 1024))",
                        tint: .purple
                    )
                    if data.swapTotalKB > 0 {
                        ResourceUsageRow(
                            title: "交换空间",
                            icon: "arrow.left.arrow.right",
                            value: data.swapUsage,
                            detail: "\(bytes((data.swapTotalKB - data.swapFreeKB) * 1024)) / \(bytes(data.swapTotalKB * 1024))",
                            tint: .orange
                        )
                    }
                }

                MonitorSection(title: "网络", icon: "network") {
                    HStack(spacing: 7) {
                        NetworkMetric(
                            title: "实时接收",
                            value: rate(data.networkReceiveBytesPerSecond),
                            icon: "arrow.down",
                            tint: .teal
                        )
                        NetworkMetric(
                            title: "实时发送",
                            value: rate(data.networkTransmitBytesPerSecond),
                            icon: "arrow.up",
                            tint: .indigo
                        )
                    }
                    Text("累计接收 \(bytes(data.networkReceiveBytes)) · 发送 \(bytes(data.networkTransmitBytes))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if !data.disks.isEmpty {
                    MonitorSection(title: "磁盘", icon: "internaldrive") {
                        ForEach(data.disks) { disk in
                            ResourceUsageRow(
                                title: disk.mountPoint,
                                icon: "externaldrive.fill",
                                value: disk.usage,
                                detail: "\(bytes(disk.usedKB * 1024)) / \(bytes(disk.totalKB * 1024))",
                                tint: usageTint(disk.usage)
                            )
                        }
                    }
                }

                if !data.processes.isEmpty {
                    MonitorSection(title: "高负载进程", icon: "list.bullet.rectangle.portrait") {
                        HStack(spacing: 7) {
                            TextField("搜索进程、用户或 PID", text: $processSearch)
                                .textFieldStyle(.roundedBorder)
                            Picker("排序", selection: $processSort) {
                                ForEach(ProcessSort.allCases) { sort in
                                    Text(sort.rawValue).tag(sort)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 72)
                        }
                        ForEach(Array(visibleProcesses.enumerated()), id: \.element.id) { index, process in
                            ProcessUsageCard(
                                process: process,
                                accent: processColors[index % processColors.count],
                                requestTermination: { terminationCandidate = process }
                            )
                        }
                        if visibleProcesses.isEmpty {
                            Text("没有匹配的进程")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .padding(9)
        }
        .confirmationDialog(
            "结束远程进程？",
            isPresented: Binding(
                get: { terminationCandidate != nil },
                set: { if !$0 { terminationCandidate = nil } }
            ),
            presenting: terminationCandidate
        ) { process in
            Button("向 PID \(process.id) 发送 SIGTERM", role: .destructive) {
                model.terminateRemoteProcess(pid: process.id, in: sessionID)
                terminationCandidate = nil
            }
            Button("取消", role: .cancel) { terminationCandidate = nil }
        } message: { process in
            Text("进程 \(process.command) 可能正在处理请求或写入数据。KiteShell 只发送可被程序处理的 SIGTERM，不会直接使用 SIGKILL。")
        }
    }

    private var processColors: [Color] {
        [.blue, .teal, .orange, .pink, .indigo]
    }

    private func usageTint(_ value: Double) -> Color {
        if value >= 0.9 { return .red }
        if value >= 0.7 { return .orange }
        return .green
    }

    private func formatUptime(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)天 \(hours)小时" }
        if hours > 0 { return "\(hours)小时 \(minutes)分" }
        return "\(minutes)分钟"
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private func rate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file) + "/s"
    }
}

private struct MonitorSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
            VStack(spacing: 7) {
                content
            }
        }
        .padding(9)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct ResourceUsageRow: View {
    let title: String
    let icon: String
    let value: Double
    let detail: String
    let tint: Color

    private var clampedValue: Double { min(1, max(0, value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 17)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(clampedValue.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.12), in: Capsule())
            }
            ColoredProgressBar(value: clampedValue, tint: tint, height: 6)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ColoredProgressBar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.13))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("使用率")
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
    }
}

private struct NetworkMetric: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 27, height: 27)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProcessUsageCard: View {
    let process: RemoteProcessInfo
    let accent: Color
    let requestTermination: () -> Void

    private var cpuValue: Double { min(1, max(0, process.cpuPercent / 100)) }
    private var memoryValue: Double { min(1, max(0, process.memoryPercent / 100)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "terminal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 25, height: 25)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(process.command)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(process.user) · PID \(process.id)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ProcessResourceLine(
                label: "CPU",
                text: String(format: "%.1f%%", process.cpuPercent),
                value: cpuValue,
                tint: .blue
            )
            ProcessResourceLine(
                label: "内存",
                text: String(format: "%.1f%%", process.memoryPercent),
                value: memoryValue,
                tint: .purple
            )
        }
        .padding(8)
        .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("复制进程信息") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "PID \(process.id) · \(process.user) · \(process.command) · CPU \(process.cpuPercent)% · MEM \(process.memoryPercent)%",
                    forType: .string
                )
            }
            Divider()
            Button("结束进程…", role: .destructive, action: requestTermination)
        }
    }
}

private struct ProcessResourceLine: View {
    let label: String
    let text: String
    let value: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 30, alignment: .leading)
            ColoredProgressBar(value: value, tint: tint, height: 5)
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .frame(width: 43, alignment: .trailing)
        }
    }
}

struct ConnectionStateBadge: View {
    let state: ConnectionState

    var body: some View {
        Label(state.label, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("连接状态：\(state.label)")
    }

    private var systemImage: String {
        switch state {
        case .connecting, .reconnecting: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .disconnected: "minus.circle"
        case .failed: "xmark.circle.fill"
        }
    }
}
