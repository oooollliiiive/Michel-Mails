import Foundation
import Testing
@testable import MichelMails

@Test("IMAP protocol responses expose mailboxes, search UIDs, and literals")
func IMAPProtocolParsing() throws {
    let mailbox = try #require(IMAPProtocolParser.mailbox(
        fromListLine: "* LIST (\\HasNoChildren \\All) \"/\" \"[Gmail]/All Mail\""
    ))
    #expect(mailbox.name == "[Gmail]/All Mail")
    #expect(mailbox.attributes.contains("\\all"))
    #expect(mailbox.isSelectable)
    #expect(IMAPProtocolParser.lastSearchUID(in: ["* SEARCH 21 34 55"]) == "55")
    #expect(IMAPProtocolParser.trailingLiteralByteCount(in: "* 1 FETCH (BODY[] {98304}") == 98_304)
}

@Test("Raw IMAP email data can produce the requested attachment")
func rawIMAPAttachmentExtraction() throws {
    let raw = Data("""
    From: sender@example.com\r
    Message-ID: <direct-test@example.com>\r
    MIME-Version: 1.0\r
    Content-Type: multipart/mixed; boundary=\"direct-boundary\"\r
    \r
    --direct-boundary\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    Hello\r
    --direct-boundary\r
    Content-Type: image/png; name=\"photo.png\"\r
    Content-Disposition: attachment; filename=\"photo.png\"\r
    Content-Transfer-Encoding: base64\r
    \r
    AQIDBAU=\r
    --direct-boundary--\r
    """.utf8)

    let attachment = try #require(try DirectEmlxReader.extractAttachment(
        identifier: "index-1",
        preferredName: "photo.png",
        fromMessageData: raw
    ))
    #expect(attachment == Data([1, 2, 3, 4, 5]))
}

@Test("Gmail and mac.com accounts derive the expected IMAP login")
func directMailLoginNames() {
    let Gmail = DirectMailAccountConfiguration(
        provider: .gmail,
        emailAddress: "olivier@gmail.com",
        appPassword: "abcd efgh ijkl mnop"
    )
    let iCloud = DirectMailAccountConfiguration(
        provider: .iCloud,
        emailAddress: "michel@mac.com",
        appPassword: "abcd-efgh-ijkl-mnop"
    )
    #expect(Gmail.loginName == "olivier@gmail.com")
    #expect(iCloud.loginName == "michel")
    #expect(Gmail.isUsable)
    #expect(iCloud.isUsable)
}

@Test("Direct download failures never silently control Apple Mail")
func directMailFailurePolicy() {
    #expect(DirectIMAPDownloadError.authenticationFailed("Gmail").requiresConfiguration)
    #expect(DirectIMAPDownloadError.noConfiguredAccount.requiresConfiguration)
    #expect(!DirectIMAPDownloadError.messageNotFound.requiresConfiguration)
    #expect(DirectIMAPDownloadError.timedOut.isTransient)
}
