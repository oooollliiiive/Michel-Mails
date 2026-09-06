import AppKit
import CryptoKit
import Foundation

enum PersistentThumbnailStore {
    static func existingThumbnailURL(
        for candidate: IndexedMailAttachmentCandidate,
        rootDirectory: URL? = nil
    ) -> URL? {
        guard let URL = try? thumbnailURL(for: candidate, rootDirectory: rootDirectory),
              isNonEmptyFile(at: URL) else { return nil }
        return URL
    }

    static func thumbnailURL(
        for candidate: IndexedMailAttachmentCandidate,
        rootDirectory: URL? = nil
    ) throws -> URL {
        let root = try rootDirectory ?? defaultRootDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let digest = SHA256.hash(data: Data(candidate.stableKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appendingPathComponent(digest + ".jpg")
    }

    @MainActor
    static func createThumbnail(
        from sourceURL: URL,
        candidate: IndexedMailAttachmentCandidate,
        rootDirectory: URL? = nil
    ) async -> URL? {
        guard AttachmentMaterializer.isCompleteFile(
            at: sourceURL,
            candidate: candidate
        ) else { return nil }

        let result = await GalleryThumbnailService.thumbnail(
            at: sourceURL,
            kind: candidate.kind,
            maximumDimension: 512
        )
        guard (!result.isFallback || candidate.kind != .image),
              let TIFFData = result.image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: TIFFData),
              let thumbnailData = representation.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.74]
              ),
              !thumbnailData.isEmpty,
              let destination = try? thumbnailURL(
                  for: candidate,
                  rootDirectory: rootDirectory
              ) else { return nil }
        do {
            try thumbnailData.write(to: destination, options: .atomic)
            return isNonEmptyFile(at: destination) ? destination : nil
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    static func clearAll() throws {
        let root = try defaultRootDirectory()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private static func defaultRootDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Michel Mails", isDirectory: true)
        .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private static func isNonEmptyFile(at URL: URL) -> Bool {
        guard let values = try? URL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
