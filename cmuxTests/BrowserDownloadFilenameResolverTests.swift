import Foundation
import CoreServices
import Testing
import UniformTypeIdentifiers
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserDownloadFilenameResolverTests {
    private let resolver = BrowserDownloadFilenameResolver()

    @Test func downloadPolicyForcesChromeDownloadTypes() {
        #expect(resolver.shouldForceDownload(mimeType: "text/csv", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "text/csv; charset=utf-8", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "application/zip", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "application/x-zip-compressed", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "application/octet-stream", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "application/gzip", contentDisposition: nil))
    }

    @Test func downloadPolicyKeepsInlineRenderableTypesInline() {
        #expect(!resolver.shouldForceDownload(mimeType: "text/html", contentDisposition: nil))
        #expect(!resolver.shouldForceDownload(mimeType: "image/png", contentDisposition: nil))
        #expect(!resolver.shouldForceDownload(mimeType: "application/pdf", contentDisposition: nil))
        #expect(!resolver.shouldForceDownload(mimeType: "application/json", contentDisposition: nil))
    }

    @Test func downloadPolicyHonorsAttachmentForAnyType() {
        #expect(resolver.shouldForceDownload(
            mimeType: "text/html",
            contentDisposition: "attachment; filename=index.html"
        ))
        #expect(resolver.shouldForceDownload(
            mimeType: "application/pdf",
            contentDisposition: "ATTACHMENT; filename=report.pdf"
        ))
    }

    @Test func navigationResponseClassifiesExplicitSubframeDownloads() {
        #expect(resolver.navigationResponseDownloadReason(
            mimeType: "text/html",
            canShowMIMEType: true,
            contentDisposition: "attachment; filename=index.html",
            isForMainFrame: false,
            allowsSubframeDownload: true
        ) == "content-disposition")
        #expect(resolver.navigationResponseDownloadReason(
            mimeType: "text/csv",
            canShowMIMEType: true,
            contentDisposition: nil,
            isForMainFrame: false,
            allowsSubframeDownload: true
        ) == "forceDownloadMIME")
    }

    @Test func navigationResponseRejectsUnactivatedSubframeDownloads() {
        #expect(resolver.navigationResponseDownloadReason(
            mimeType: "text/html",
            canShowMIMEType: true,
            contentDisposition: "attachment; filename=index.html",
            isForMainFrame: false
        ) == nil)
        #expect(resolver.navigationResponseDownloadReason(
            mimeType: "text/csv",
            canShowMIMEType: true,
            contentDisposition: nil,
            isForMainFrame: false
        ) == nil)
    }

    @Test func navigationResponseKeepsUnshowableSubframesInlineWithoutExplicitDownloadSignal() {
        #expect(resolver.navigationResponseDownloadReason(
            mimeType: "application/x-custom",
            canShowMIMEType: false,
            contentDisposition: nil,
            isForMainFrame: false
        ) == nil)
        #expect(resolver.navigationResponseDownloadReason(
            mimeType: "application/x-custom",
            canShowMIMEType: false,
            contentDisposition: nil,
            isForMainFrame: true
        ) == "cannotShowMIME")
    }

    @Test func pdfViewerToolbarDownloadAndPrintPolicies() throws {
        let renderedPDFURL = try #require(URL(string: "https://mail-attachment.example.test/report.pdf?token=1&disp=inline"))
        let toolbarPDFURL = try #require(URL(string: "https://mail-attachment.example.test/report.pdf?token=2&disp=download"))
        let printURL = try #require(URL(string: "https://docs-viewer.example.test/report.pdf?print=true"))
        #expect(resolver.navigationResponseDownloadReason(
            mimeType: "application/pdf", canShowMIMEType: true, contentDisposition: nil,
            isForMainFrame: false, isUserActivatedPreviouslyRenderedSubframePDF: true
        ) == "subframePDFUserAction")
        #expect(!resolver.shouldPrintPDFAfterLoad(mimeType: "application/pdf", responseURL: printURL, isForMainFrame: false))
        #expect(resolver.shouldPrintPDFAfterLoad(mimeType: "application/pdf", responseURL: printURL, isForMainFrame: true))
        let tracker = BrowserSubframeDownloadIntentTracker()
        tracker.recordUserActivatedSubframeNavigation(toolbarPDFURL)
        #expect(!tracker.consumeUserActivatedPreviouslyRenderedSubframePDF(
            responseURL: toolbarPDFURL, mimeType: "application/pdf", isForMainFrame: false
        ))
        tracker.markRenderedSubframePDFIfNeeded(responseURL: renderedPDFURL, mimeType: "application/pdf", isForMainFrame: false)
        tracker.recordUserActivatedSubframeNavigation(toolbarPDFURL)
        #expect(tracker.consumeUserActivatedPreviouslyRenderedSubframePDF(
            responseURL: toolbarPDFURL, mimeType: "application/pdf", isForMainFrame: false
        ))
    }

    @Test func subframeDownloadIntentTrackerTransfersRedirectIntent() throws {
        let tracker = BrowserSubframeDownloadIntentTracker()
        let source = try #require(URL(string: "https://mail.example.test/attachment?id=1#frag"))
        let redirected = try #require(URL(string: "https://cdn.example.test/attachment?id=1"))

        tracker.record(source)
        tracker.recordRedirectIfNeeded(from: source, to: redirected)

        #expect(tracker.consume(for: redirected))
        #expect(!tracker.consume(for: source))
    }

    @Test func subframeDownloadIntentTrackerFailsClosedForUnrelatedRedirect() throws {
        let tracker = BrowserSubframeDownloadIntentTracker()
        let source = try #require(URL(string: "https://mail.example.test/attachment?id=1"))
        let unrelated = try #require(URL(string: "https://mail.example.test/attachment?id=2"))
        let redirected = try #require(URL(string: "https://cdn.example.test/attachment?id=2"))

        tracker.record(source)
        tracker.recordRedirectIfNeeded(from: unrelated, to: redirected)

        #expect(!tracker.consume(for: redirected))
        #expect(tracker.consume(for: source))
    }

    @Test func uniqueDownloadDestinationDedupesExistingFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-download-resolver-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("report.pdf", isDirectory: false)
        try Data("existing".utf8).write(to: existing)

        let destination = resolver.uniqueDownloadDestination(
            suggestedFilename: "report.pdf",
            in: directory,
            fileManager: fileManager
        )

        #expect(destination.deletingLastPathComponent().path == directory.path)
        #expect(destination.lastPathComponent == "report (1).pdf")
    }

    @Test func uniqueDownloadDestinationFallsBackAfterBoundedCollisionScan() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-download-resolver-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: directory) }

        try Data("existing".utf8).write(to: directory.appendingPathComponent("report.pdf", isDirectory: false))
        for index in 1...100 {
            try Data("existing".utf8).write(
                to: directory.appendingPathComponent("report (\(index)).pdf", isDirectory: false)
            )
        }

        let destination = resolver.uniqueDownloadDestination(
            suggestedFilename: "report.pdf",
            in: directory,
            fileManager: fileManager
        )

        #expect(destination.deletingLastPathComponent().path == directory.path)
        #expect(destination.lastPathComponent.hasPrefix("report-"))
        #expect(destination.pathExtension == "pdf")
    }

    @Test func webDownloadQuarantineMetadataMarksRemoteDownloads() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-download-quarantine-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("report.csv", isDirectory: false)
        try Data("download".utf8).write(to: fileURL)
        let sourceURL = try #require(URL(string: "https://user:pass@example.test/report.csv?token=secret#section"))

        try fileURL.cmuxApplyWebDownloadQuarantine(sourceURL: sourceURL)

        let properties = try #require(
            fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        )
        #expect(properties[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String != nil)
        #expect(properties[kLSQuarantineTimeStampKey as String] is Date)
        #expect((properties[kLSQuarantineDataURLKey as String] as? URL)?.absoluteString == "https://example.test/report.csv")
        #expect((properties[kLSQuarantineOriginURLKey as String] as? URL)?.absoluteString == "https://example.test/report.csv")
    }

    @Test func webDownloadQuarantineMetadataSkipsLocalFileSources() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-download-quarantine-local-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("local-copy.txt", isDirectory: false)
        try Data("download".utf8).write(to: fileURL)

        try fileURL.cmuxApplyWebDownloadQuarantine(sourceURL: URL(fileURLWithPath: "/tmp/source.txt"))

        let properties = try fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(properties == nil)
    }

    @MainActor
    @Test func scriptedDownloadInterceptionKeepsFullHookOutOfSubframes() throws {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let scripts = webView.configuration.userContentController.userScripts

        let mainFrameScript = try #require(
            scripts.first {
                $0.source.contains("__cmuxScriptedDownloadInstalled")
            }
        )
        #expect(mainFrameScript.isForMainFrameOnly)

        let subframeScript = try #require(
            scripts.first {
                $0.source.contains("subframeDownloadIntent")
                    && !$0.source.contains("__cmuxScriptedDownloadInstalled")
            }
        )
        #expect(!subframeScript.isForMainFrameOnly)
        #expect(!subframeScript.source.contains("createObjectURL"))
        #expect(!subframeScript.source.contains("revokeObjectURL"))
    }

    @MainActor
    @Test func promptedDownloadCompletionCallbacksPostFinalEvents() throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        let delegate = try #require(panel.downloadDelegate)
        let capture = BrowserDownloadEventCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: panel,
            queue: nil
        ) { notification in
            capture.append(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let savedURL = URL(fileURLWithPath: "/tmp/cmux-download-report.csv")
        delegate.onDownloadSaved?("report.csv", savedURL, false, "download-1")
        delegate.onDownloadCancelled?("cancelled.txt", false, "download-1")
        delegate.onDownloadFailed?(
            NSError(domain: "cmux.download.test", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "disk full"
            ]),
            false,
            "download-1"
        )

        let events = capture.snapshot()
        try #require(events.count == 3)
        #expect(events.map { $0["type"] as? String } == ["saved", "cancelled", "failed"])
        #expect(events.map { $0["download_id"] as? String } == ["download-1", "download-1", "download-1"])
        #expect(events[0]["filename"] as? String == "report.csv")
        #expect(events[0]["path"] as? String == savedURL.path)
        #expect(events[1]["filename"] as? String == "cancelled.txt")
        #expect(events[2]["error"] as? String == "disk full")
    }

    @MainActor
    @Test func sessionDownloadBridgePostsAutomationEvents() throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        let capture = BrowserDownloadEventCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: panel,
            queue: nil
        ) { notification in
            capture.append(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.webView.onSessionDownloadEvent?([
            "type": "saved",
            "download_id": "session-download-1",
            "filename": "report.csv",
            "path": "/tmp/report.csv",
        ])

        let events = capture.snapshot()
        try #require(events.count == 1)
        #expect(events[0]["type"] as? String == "saved")
        #expect(events[0]["download_id"] as? String == "session-download-1")
        #expect(events[0]["path"] as? String == "/tmp/report.csv")
    }

    @MainActor
    @Test func promptedDownloadSavePanelSkipsHiddenPreloadWindow() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: try #require(URL(string: "about:blank")),
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        #expect(panel.hasBackgroundPreloadHost)
        #expect(browserInteractiveModalHostWindow(for: panel.webView) == nil)
        let delegate = try #require(panel.downloadDelegate)

        #expect(delegate.savePanelParentWindow?() == nil)
    }

    @Test func rejectsNonSuccessHTTPStatusBeforeSavePanelNaming() throws {
        let url = try #require(URL(string: "https://example.test/logo.jpg"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml"]
        ))

        #expect(resolver.httpStatusDecision(for: response) == .reject(statusCode: 403))
    }

    @Test func detectsPNGBytesForImageFilenameDerivation() throws {
        let imageType = try #require(resolver.imageType(forImageData: Self.onePixelPNG))

        #expect(imageType.conforms(to: .png))
    }

    @Test func imageBytesServedAsTextKeepImagePathExtension() throws {
        let url = try #require(URL(string: "https://example.test/logo.png"))
        let response = URLResponse(
            url: url,
            mimeType: "text/plain",
            expectedContentLength: Self.onePixelPNG.count,
            textEncodingName: nil
        )

        let filename = resolver.suggestedFilename(
            suggestedFilename: nil,
            response: response,
            sourceURL: url,
            imageType: .png
        )

        #expect(filename == "logo.png")
    }

    @Test func imageBytesStripServerMIMEExtensionFromSuggestedFilename() throws {
        let url = try #require(URL(string: "https://cdn.example.test/assets/logo"))
        let response = URLResponse(
            url: url,
            mimeType: "text/plain",
            expectedContentLength: Self.onePixelPNG.count,
            textEncodingName: nil
        )

        let filename = resolver.suggestedFilename(
            suggestedFilename: "logo.png.txt",
            response: response,
            sourceURL: url,
            imageType: .png
        )

        #expect(filename == "logo.png")
    }

    @Test func imageBytesPreserveExplicitSuggestedFilenameBase() throws {
        let url = try #require(URL(string: "https://cdn.example.test/assets/hash.png"))

        let filename = resolver.suggestedFilename(
            suggestedFilename: "avatar",
            response: nil,
            sourceURL: url,
            imageType: .png
        )

        #expect(filename == "avatar.png")
    }

    @Test func imageBytesReplaceExplicitNonImageSuggestedExtension() throws {
        let url = try #require(URL(string: "https://cdn.example.test/assets/hash.png"))

        let filename = resolver.suggestedFilename(
            suggestedFilename: "avatar.txt",
            response: nil,
            sourceURL: url,
            imageType: .png
        )

        #expect(filename == "avatar.png")
    }

    @Test func downloadCookiesMatchRequestDomainAndPath() throws {
        let url = try #require(URL(string: "https://sub.example.test/reports/2026/export.csv"))
        let cookies = [
            try Self.cookie(name: "parent", domain: ".example.test", path: "/reports"),
            try Self.cookie(name: "host", domain: "sub.example.test", path: "/reports/2026"),
            try Self.cookie(name: "wrong-domain", domain: ".other.test", path: "/reports"),
            try Self.cookie(name: "wrong-path", domain: ".example.test", path: "/admin"),
        ]

        let names = Set(CmuxWebView.cookiesForDownloadRequest(cookies, url: url).map(\.name))

        #expect(names == ["parent", "host"])
    }

    @Test func downloadCookiesRejectSecureCookiesForHTTPAndExpiredCookies() throws {
        let url = try #require(URL(string: "http://example.test/report.csv"))
        let cookies = [
            try Self.cookie(name: "plain", domain: "example.test"),
            try Self.cookie(name: "secure", domain: "example.test", secure: true),
            try Self.cookie(name: "expired", domain: "example.test", expires: Date(timeIntervalSince1970: 0)),
            try Self.cookie(name: "future", domain: "example.test", expires: Date(timeIntervalSince1970: 4_102_444_800)),
        ]

        let names = Set(CmuxWebView.cookiesForDownloadRequest(cookies, url: url).map(\.name))

        #expect(names == ["plain", "future"])
    }

    private static func cookie(
        name: String,
        domain: String,
        path: String = "/",
        secure: Bool = false,
        expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: "1",
            .domain: domain,
            .path: path,
        ]
        if secure {
            properties[.secure] = "TRUE"
        }
        if let expires {
            properties[.expires] = expires
        }
        return try #require(HTTPCookie(properties: properties))
    }

    private final class BrowserDownloadEventCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [[String: Any]] = []

        func append(_ notification: Notification) {
            guard let event = notification.userInfo?["event"] as? [String: Any] else { return }
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [[String: Any]] {
            lock.lock()
            let result = events
            lock.unlock()
            return result
        }
    }

    private static let onePixelPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x02,
        0x00, 0x01, 0x00, 0xFF, 0xFF, 0x03, 0x00, 0x00,
        0x06, 0x00, 0x05, 0x57, 0xBF, 0xAB, 0x7D, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])
}
