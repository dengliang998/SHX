import SwiftUI

enum WorkspacePanelLayout {
    static let sessionTabBarHeight: CGFloat = 40
    static let inspectorExpandedWidth: CGFloat = 292
    static let filePanelExpandedHeight: CGFloat = 280

    static func inspectorWidth(isVisible: Bool) -> CGFloat {
        isVisible ? inspectorExpandedWidth : 0
    }

    static func filePanelHeight(isVisible: Bool) -> CGFloat {
        isVisible ? filePanelExpandedHeight : 0
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresentingPortForwards = false
    @State private var isPresentingTransferCenter = false

    var body: some View {
        VStack(spacing: 0) {
            SessionTabBar()
                .frame(maxWidth: .infinity, height: WorkspacePanelLayout.sessionTabBarHeight,
                       alignment: .center)
                .clipped()
            Divider()

            if let session = model.selectedSession {
                HStack(spacing: 0) {
                    TerminalAndFilesView(session: session)
                        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)

                    let inspectorVisible = model.isInspectorVisible && !model.focusMode
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                        .opacity(inspectorVisible ? 1 : 0)
                    Group {
                        ServerInspectorView(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: WorkspacePanelLayout.inspectorWidth(isVisible: inspectorVisible))
                    .opacity(inspectorVisible ? 1 : 0)
                    .clipped()
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.32, extraBounce: 0.04),
                           value: model.isInspectorVisible && !model.focusMode)
            } else {
                ContentUnavailableView("没有活动会话", systemImage: "terminal")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.showConnectionCenter()
                } label: {
                    Label("连接中心", systemImage: "sidebar.left")
                }
                .help("打开连接中心")
                .pointingHandCursor()

                Button {
                    model.isPresentingConnectionLauncher = true
                } label: {
                    Label("打开连接", systemImage: "plus")
                }
                .help("从已保存服务器中打开连接，或新建服务器")
                .pointingHandCursor()

                Button {
                    model.isPresentingQuickConnect = true
                } label: {
                    Label("快速连接", systemImage: "bolt.fill")
                }
                .help("快速打开临时 SSH 会话（⌘K）")
                .pointingHandCursor()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isPresentingTransferCenter = true
                } label: {
                    Label("传输中心", systemImage: "arrow.up.arrow.down.circle")
                }
                .help("查看所有会话的文件传输")
                .pointingHandCursor()

                Button {
                    isPresentingPortForwards = true
                } label: {
                    Label("端口转发", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(model.selectedSession == nil)
                .help("管理当前服务器的端口转发")
                .pointingHandCursor(model.selectedSession != nil)

                Button {
                    model.toggleFilePanel()
                } label: {
                    Label("文件工作区", systemImage: "folder")
                }
                .help(model.isFilePanelVisible ? "隐藏文件工作区" : "显示文件工作区")
                .pointingHandCursor()

                Button {
                    model.toggleInspector()
                } label: {
                    Label("服务器检查器", systemImage: "sidebar.right")
                }
                .help(model.isInspectorVisible ? "隐藏服务器检查器" : "显示服务器检查器")
                .pointingHandCursor()

                Button {
                    model.toggleFocusMode()
                } label: {
                    Label("专注终端", systemImage: model.focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(model.focusMode ? "退出专注终端" : "专注终端")
                .pointingHandCursor()
            }
        }
        .navigationTitle(model.selectedSession?.title ?? "KiteShell")
        .macOS26GlassToolbar()
        .sheet(isPresented: $isPresentingPortForwards) {
            if let session = model.selectedSession {
                PortForwardPanel(session: session)
            }
        }
        .sheet(isPresented: $isPresentingTransferCenter) {
            TransferCenterView()
        }
    }
}

private struct SessionTabBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    model.showConnectionCenter()
                } label: {
                    Image(systemName: "rectangle.grid.1x2")
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("连接中心")
                .pointingHandCursor()

                ForEach(model.sessions) { session in
                    SessionTab(
                        session: session,
                        isSelected: model.selectedSessionID == session.id,
                        select: { model.selectSession(session) },
                        close: { model.closeSession(session) },
                        moveSessionBefore: { sourceID in
                            model.moveSession(sourceID, before: session.id)
                        }
                    )
                }

                Button {
                    model.isPresentingConnectionLauncher = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("打开已保存连接或新建服务器")
                .pointingHandCursor()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .macOS26Glass(in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity)
    }
}

private struct SessionTab: View {
    let session: Session
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let moveSessionBefore: (UUID) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(session.state.tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(session.title)
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("关闭 \(session.title)")
            .pointingHandCursor()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            isSelected
                ? AnyShapeStyle(.selection)
                : AnyShapeStyle(isHovering ? Color.primary.opacity(0.07) : .clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .macOS26Glass(in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .draggable(session.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let sourceID = UUID(uuidString: value) else { return false }
            moveSessionBefore(sourceID)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title)，\(session.state.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension ConnectionState {
    var tint: Color {
        switch self {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected, .failed: .red
        }
    }
}
