import AppKit
import Testing
@testable import MichelMails

@Test("The gallery renders PNG files and the first page of PDFs")
@MainActor
func galleryNativeThumbnails() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let PNGURL = directory.appendingPathComponent("preview.png")
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 8,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    if let pixels = bitmap.bitmapData {
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = (y * bitmap.bytesPerRow) + (x * 4)
                pixels[offset] = 120
                pixels[offset + 1] = 60
                pixels[offset + 2] = 220
                pixels[offset + 3] = 255
            }
        }
    }
    let PNGData = try #require(bitmap.representation(using: .png, properties: [:]))
    try PNGData.write(to: PNGURL)

    let PDFURL = directory.appendingPathComponent("preview.pdf")
    var pageBounds = CGRect(x: 0, y: 0, width: 320, height: 180)
    let consumer = try #require(CGDataConsumer(url: PDFURL as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &pageBounds, nil))
    context.beginPDFPage(nil)
    context.setFillColor(red: 1, green: 0.45, blue: 0, alpha: 1)
    context.fill(pageBounds)
    context.endPDFPage()
    context.closePDF()

    let PNGThumbnail = await GalleryThumbnailService.thumbnail(at: PNGURL, kind: .image)
    let PDFThumbnail = await GalleryThumbnailService.thumbnail(at: PDFURL, kind: .pdf)

    #expect(PNGThumbnail.isFallback == false)
    #expect(PNGThumbnail.image.size.width > 0)
    #expect(PDFThumbnail.isFallback == false)
    #expect(PDFThumbnail.image.size.width > 0)
}

@Test("Image and video formats are classified for the universal grid")
func universalGalleryFileClassification() {
    #expect(MailAttachmentKind.classify(name: "scan.PNG", MIMEType: "") == .image)
    #expect(MailAttachmentKind.classify(name: "camera.CR3", MIMEType: "") == .image)
    #expect(MailAttachmentKind.classify(name: "drawing.svg", MIMEType: "") == .image)
    #expect(MailAttachmentKind.classify(name: "clip.MOV", MIMEType: "") == .video)
    #expect(MailAttachmentKind.classify(name: "film.mkv", MIMEType: "") == .video)
    #expect(MailAttachmentKind.classify(name: "report.pdf", MIMEType: "") == .pdf)
}
