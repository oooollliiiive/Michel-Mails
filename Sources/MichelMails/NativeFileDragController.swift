import AppKit

final class NativeFileDragController: NSObject, NSDraggingSource {
    static let shared = NativeFileDragController()

    private var dragEnded: (() -> Void)?

    private override init() {
        super.init()
    }

    @MainActor
    func beginDragging(
        URLs: [URL],
        previewURL: URL?,
        onEnded: @escaping () -> Void
    ) -> Bool {
        let uniqueURLs = URLs.reduce(into: [URL]()) { result, URL in
            guard !result.contains(where: { $0.standardizedFileURL == URL.standardizedFileURL }) else {
                return
            }
            result.append(URL)
        }
        guard !uniqueURLs.isEmpty,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged,
              let sourceView = event.window?.contentView else {
            return false
        }

        let location = sourceView.convert(event.locationInWindow, from: nil)
        let preview = dragPreview(
            URL: previewURL ?? uniqueURLs[0],
            count: uniqueURLs.count
        )
        let draggingItems = uniqueURLs.enumerated().map { index, URL in
            let item = NSDraggingItem(pasteboardWriter: URL as NSURL)
            let offset = CGFloat(min(index, 3)) * 3
            item.setDraggingFrame(
                NSRect(
                    x: location.x - 34 + offset,
                    y: location.y - 34 - offset,
                    width: 68,
                    height: 68
                ),
                contents: preview
            )
            return item
        }

        dragEnded = onEnded
        let session = sourceView.beginDraggingSession(
            with: draggingItems,
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let completion = dragEnded
        dragEnded = nil
        completion?()
    }

    private func dragPreview(URL: URL, count: Int) -> NSImage {
        let source = NSImage(contentsOf: URL) ?? NSWorkspace.shared.icon(forFile: URL.path)
        let image = NSImage(size: NSSize(width: 68, height: 68))
        image.lockFocus()
        source.draw(
            in: NSRect(x: 4, y: 4, width: 60, height: 60),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        if count > 1 {
            let label = "\(count)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = label.size(withAttributes: attributes)
            let badgeWidth = max(22, size.width + 10)
            let badgeRect = NSRect(x: 68 - badgeWidth, y: 68 - 22, width: badgeWidth, height: 20)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 10, yRadius: 10).fill()
            label.draw(
                at: NSPoint(
                    x: badgeRect.midX - size.width / 2,
                    y: badgeRect.midY - size.height / 2
                ),
                withAttributes: attributes
            )
        }
        image.unlockFocus()
        return image
    }
}
