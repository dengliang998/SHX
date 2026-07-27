import AppKit
import SwiftUI

private struct PointingHandCursorModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(enabled: enabled))
    }
}

@MainActor
func clearTextFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}
