import Darwin
import Foundation

enum EmailDownloadMetadata {
    static let downloadedAtAttribute = "com.michelos.downloaded-at"
    static let receivedAtAttribute = "com.michelos.email-received-at"

    static func markDownloaded(
        _ fileURL: URL,
        emailReceivedAt: Date?,
        downloadedAt: Date = Date()
    ) throws {
        try? write(downloadedAt, attribute: downloadedAtAttribute, to: fileURL)
        if let emailReceivedAt {
            try? write(emailReceivedAt, attribute: receivedAtAttribute, to: fileURL)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: downloadedAt],
            ofItemAtPath: fileURL.path
        )
    }

    static func downloadedAt(for fileURL: URL) -> Date? {
        read(attribute: downloadedAtAttribute, from: fileURL)
    }

    static func emailReceivedAt(for fileURL: URL) -> Date? {
        read(attribute: receivedAtAttribute, from: fileURL)
    }

    private static func write(_ date: Date, attribute: String, to fileURL: URL) throws {
        let data = Data(String(date.timeIntervalSince1970).utf8)
        let result = data.withUnsafeBytes { bytes in
            setxattr(fileURL.path, attribute, bytes.baseAddress, data.count, 0, 0)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func read(attribute: String, from fileURL: URL) -> Date? {
        let size = getxattr(fileURL.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let readSize = data.withUnsafeMutableBytes { bytes in
            getxattr(fileURL.path, attribute, bytes.baseAddress, size, 0, 0)
        }
        guard readSize == size,
              let value = String(data: data, encoding: .utf8),
              let timestamp = TimeInterval(value) else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}
