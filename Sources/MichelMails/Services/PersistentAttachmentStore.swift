import CryptoKit
import Foundation

enum PersistentAttachmentStore {
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static let defaultSizeLimitGigabytes = 1.0
    static let minimumSizeLimitGigabytes = 0.25
    static let maximumSizeLimitGigabytes = 100.0
    private static let sizeLimitDefaultsKey = "MichelMailsOriginalCacheLimitGB"

    static var configuredSizeLimitGigabytes: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: sizeLimitDefaultsKey) != nil else {
            return defaultSizeLimitGigabytes
        }
        return clampedGigabytes(defaults.double(forKey: sizeLimitDefaultsKey))
    }

    static func setConfiguredSizeLimitGigabytes(_ value: Double) {
        UserDefaults.standard.set(clampedGigabytes(value), forKey: sizeLimitDefaultsKey)
    }

    static func existingOriginalURL(
        for candidate: IndexedMailAttachmentCandidate,
        rootDirectory: URL? = nil
    ) -> URL? {
        guard let URL = try? originalURL(for: candidate, rootDirectory: rootDirectory),
              AttachmentMaterializer.isCompleteFile(at: URL, candidate: candidate) else {
            return nil
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: URL.path
        )
        return URL
    }

    static func store(
        _ sourceURL: URL,
        candidate: IndexedMailAttachmentCandidate,
        rootDirectory: URL? = nil
    ) throws -> URL {
        guard AttachmentMaterializer.isCompleteFile(at: sourceURL, candidate: candidate) else {
            throw AttachmentMaterializerError.incomplete
        }
        if let existing = existingOriginalURL(for: candidate, rootDirectory: rootDirectory) {
            return existing
        }

        let destination = try originalURL(for: candidate, rootDirectory: rootDirectory)
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).download",
            isDirectory: false
        )
        try? manager.removeItem(at: temporary)
        do {
            try manager.copyItem(at: sourceURL, to: temporary)
            guard AttachmentMaterializer.isCompleteFile(at: temporary, candidate: candidate) else {
                throw AttachmentMaterializerError.incomplete
            }
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
            try? manager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: destination.path
            )
            guard AttachmentMaterializer.isCompleteFile(at: destination, candidate: candidate) else {
                try? manager.removeItem(at: destination)
                throw AttachmentMaterializerError.incomplete
            }
            return destination
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func originalURL(
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
        let originalExtension = URL(fileURLWithPath: candidate.attachmentName)
            .pathExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let suffix = originalExtension.isEmpty ? "" : ".\(String(originalExtension.prefix(12)))"
        return root.appendingPathComponent(digest + suffix)
    }

    static func cleanupExpired(
        now: Date = Date(),
        rootDirectory: URL? = nil,
        maximumBytes: Int64? = nil
    ) throws {
        let root = try rootDirectory ?? defaultRootDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let URLs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for URL in URLs {
            let values = try? URL.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: URL)
        }
        try enforceSizeLimit(
            rootDirectory: root,
            maximumBytes: maximumBytes
        )
    }

    static func enforceSizeLimit(
        rootDirectory: URL? = nil,
        maximumBytes: Int64? = nil,
        preserving preservedURL: URL? = nil
    ) throws {
        let root = try rootDirectory ?? defaultRootDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let limit = max(0, maximumBytes ?? configuredSizeLimitBytes)
        let URLs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
        var entries = URLs.compactMap { URL -> (URL, Int64, Date)? in
            guard let values = try? URL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]), values.isRegularFile == true else { return nil }
            return (
                URL,
                Int64(values.fileSize ?? 0),
                values.contentModificationDate ?? .distantPast
            )
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > limit {
            if let preservedURL, entry.0.standardizedFileURL == preservedURL.standardizedFileURL {
                continue
            }
            do {
                try FileManager.default.removeItem(at: entry.0)
                total -= entry.1
            } catch {
                continue
            }
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
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("com.michelos.michelmails", isDirectory: true)
        .appendingPathComponent("Temporary Originals", isDirectory: true)
    }

    private static var configuredSizeLimitBytes: Int64 {
        Int64(configuredSizeLimitGigabytes * 1_000_000_000)
    }

    private static func clampedGigabytes(_ value: Double) -> Double {
        min(max(value.isFinite ? value : defaultSizeLimitGigabytes, minimumSizeLimitGigabytes),
            maximumSizeLimitGigabytes)
    }
}
