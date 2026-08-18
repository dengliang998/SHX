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

    /// Makes macOS text controls resign first responder when the user clicks
    /// anywhere that is not another text control. SwiftUI does not do this
    /// consistently for custom rows, split views, and representable views.
    func dismissesTextFocusOnOutsideClick() -> some View {
        modifier(TextFocusDismissalModifier())
    }
}

private struct TextFocusDismissalModifier: ViewModifier {
    @State private var eventMonitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { installMonitorIfNeeded() }
            .onDisappear { removeMonitor() }
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let contentView = window.contentView else { return event }
            let location = contentView.convert(event.locationInWindow, from: nil)
            guard let hitView = contentView.hitTest(location),
                  !hitView.isInsideEditableTextControl else { return event }

            // Resign before AppKit dispatches the click so the clicked control
            // can still become first responder normally.
            if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}

private extension NSView {
    var isInsideEditableTextControl: Bool {
        var view: NSView? = self
        while let current = view {
            if let textField = current as? NSTextField, textField.isEditable { return true }
            if let textView = current as? NSTextView, textView.isEditable { return true }
            view = current.superview
        }
        return false
    }
}

@MainActor
func clearTextFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}
