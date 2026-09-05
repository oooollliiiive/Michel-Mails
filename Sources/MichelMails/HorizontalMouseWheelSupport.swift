import AppKit
import SwiftUI

/// Makes a conventional vertical mouse wheel move a horizontal SwiftUI grid.
/// Native horizontal trackpad gestures keep their normal behavior.
struct HorizontalMouseWheelSupport: NSViewRepresentable {
    func makeNSView(context: Context) -> HorizontalMouseWheelView {
        HorizontalMouseWheelView()
    }

    func updateNSView(_ NSView: HorizontalMouseWheelView, context: Context) {}
}

final class HorizontalMouseWheelView: NSView {
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.redirectVerticalWheel(event) ?? event
        }
    }

    deinit {
        removeMonitor()
    }

    private func redirectVerticalWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window === window,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              abs(event.scrollingDeltaY) > 0,
              let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else {
            return event
        }

        let eventPoint = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(eventPoint) else { return event }

        let visibleWidth = scrollView.contentView.bounds.width
        let maximumX = max(0, documentView.bounds.width - visibleWidth)
        guard maximumX > 0 else { return event }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 28
        let currentX = scrollView.contentView.bounds.origin.x
        let proposedX = currentX - (event.scrollingDeltaY * multiplier)
        let targetX = min(max(0, proposedX), maximumX)
        guard abs(targetX - currentX) > 0.01 else { return event }

        scrollView.contentView.scroll(
            to: NSPoint(x: targetX, y: scrollView.contentView.bounds.origin.y)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return nil
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
