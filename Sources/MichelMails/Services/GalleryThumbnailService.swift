import AppKit
import ImageIO
import PDFKit
import QuickLookThumbnailing

struct GalleryThumbnailResult {
    let image: NSImage
    let isFallback: Bool
}

enum GalleryThumbnailService {
    @MainActor
    static func thumbnail(
        at URL: URL,
        kind: MailAttachmentKind,
        maximumDimension: CGFloat = 512
    ) async -> GalleryThumbnailResult {
        if kind == .image,
           let image = await rasterThumbnail(at: URL, maximumDimension: maximumDimension) {
            return GalleryThumbnailResult(image: image, isFallback: false)
        }

        if kind == .pdf,
           let image = await firstPDFPage(at: URL, maximumDimension: maximumDimension) {
            return GalleryThumbnailResult(image: image, isFallback: false)
        }

        if let image = await quickLookThumbnail(at: URL, maximumDimension: maximumDimension) {
            return GalleryThumbnailResult(image: image, isFallback: false)
        }

        let icon = NSWorkspace.shared.icon(forFile: URL.path)
        icon.size = NSSize(width: 128, height: 128)
        return GalleryThumbnailResult(image: icon, isFallback: true)
    }

    @MainActor
    private static func rasterThumbnail(
        at URL: URL,
        maximumDimension: CGFloat
    ) async -> NSImage? {
        let data = await renderedData {
            guard let source = CGImageSourceCreateWithURL(URL as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maximumDimension)),
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        return data.flatMap(NSImage.init(data:))
    }

    @MainActor
    private static func firstPDFPage(
        at URL: URL,
        maximumDimension: CGFloat
    ) async -> NSImage? {
        let data = await renderedData {
            guard let document = PDFDocument(url: URL),
                  let page = document.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = min(maximumDimension / bounds.width, maximumDimension / bounds.height, 1)
            let size = NSSize(
                width: max(1, bounds.width * scale),
                height: max(1, bounds.height * scale)
            )
            let image = page.thumbnail(of: size, for: .cropBox)
            guard let TIFFData = image.tiffRepresentation,
                  let representation = NSBitmapImageRep(data: TIFFData) else { return nil }
            return representation.representation(using: .png, properties: [:])
        }
        return data.flatMap(NSImage.init(data:))
    }

    private static func renderedData(
        timeout: TimeInterval = 8,
        operation: @escaping @Sendable () -> Data?
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            let completion = OneShotCompletion(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                completion.finish(with: operation())
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                completion.finish(with: nil)
            }
        }
    }

    @MainActor
    private static func quickLookThumbnail(
        at URL: URL,
        maximumDimension: CGFloat
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: URL,
                size: NSSize(width: maximumDimension, height: maximumDimension),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            request.iconMode = false
            let completion = OneShotCompletion(continuation)

            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                completion.finish(with: representation?.nsImage)
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                completion.finish(with: nil)
            }
        }
    }
}

private final class OneShotCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func finish(with value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
