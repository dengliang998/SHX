import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.route {
            case .connectionCenter:
                ConnectionCenterView()
            case .workspace:
                WorkspaceView()
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.route)
        .sheet(isPresented: $model.isPresentingNewConnection) {
            NewConnectionSheet()
        }
        .sheet(isPresented: $model.isPresentingConnectionLauncher) {
            OpenConnectionSheet()
        }
        .sheet(isPresented: $model.isPresentingQuickConnect) {
            QuickConnectSheet()
        }
        .sheet(item: $model.passwordRequest) { request in
            PasswordPromptSheet(request: request)
        }
        .alert(item: $model.importNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}
