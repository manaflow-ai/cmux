import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserPDFPreviewActionUnitTests {
    @Test func saveRoutesPDFPreviewBytesToRecentDownloadRecordFileAndQuarantine() async throws {
        let harness = try BrowserPDFPreviewDownloadHarness()
        defer { harness.cleanUp() }
        let panel = BrowserPanel(workspaceId: UUID())
        let delegate = try #require(panel.webView.uiDelegate as? BrowserPDFPreviewActionUIDelegate)
        let capture = BrowserPDFPreviewDownloadEventCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: panel,
            queue: nil
        ) { notification in
            capture.append(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        delegate.downloadsFileManager = harness.fileManager
        delegate.downloadsDefaults = harness.defaults
        let sourceURL = try #require(URL(string: "https://example.com/dummy.pdf"))
        let data = Data("%PDF-1.4\n%cmux\n".utf8)

        try Self.invokeSave(
            on: delegate,
            webView: panel.webView,
            data: data,
            suggestedFilename: "dummy.pdf",
            mimeType: "application/pdf",
            sourceURL: sourceURL
        )

        let savedEvents = await Self.waitForSavedDownloadEvents(in: capture, count: 1)
        let event = try #require(savedEvents.first)
        #expect(event["filename"] as? String == "dummy.pdf")
        let path = try #require(event["path"] as? String)
        let fileURL = URL(fileURLWithPath: path)
        #expect(fileURL.deletingLastPathComponent().path == harness.downloadsDirectory.path)
        #expect(try Data(contentsOf: fileURL) == data)
        let resourceKeys: Set<URLResourceKey> = [.quarantinePropertiesKey]
        let quarantine = try fileURL.resourceValues(forKeys: resourceKeys).quarantineProperties
        #expect(quarantine != nil)
    }

    @Test func repeatedPDFPreviewSavesUseCollisionUniqueFilenames() async throws {
        let harness = try BrowserPDFPreviewDownloadHarness()
        defer { harness.cleanUp() }
        let panel = BrowserPanel(workspaceId: UUID())
        let delegate = try #require(panel.webView.uiDelegate as? BrowserPDFPreviewActionUIDelegate)
        let capture = BrowserPDFPreviewDownloadEventCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: panel,
            queue: nil
        ) { notification in
            capture.append(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        delegate.downloadsFileManager = harness.fileManager
        delegate.downloadsDefaults = harness.defaults
        let sourceURL = try #require(URL(string: "https://example.com/dummy.pdf"))
        let data = Data("%PDF-1.4\n%cmux\n".utf8)

        try Self.invokeSave(
            on: delegate,
            webView: panel.webView,
            data: data,
            suggestedFilename: "dummy.pdf",
            mimeType: "application/pdf",
            sourceURL: sourceURL
        )
        #expect(await Self.waitForSavedDownloadEvents(in: capture, count: 1).count == 1)

        try Self.invokeSave(
            on: delegate,
            webView: panel.webView,
            data: data,
            suggestedFilename: "dummy.pdf",
            mimeType: "application/pdf",
            sourceURL: sourceURL
        )
        let savedEvents = await Self.waitForSavedDownloadEvents(in: capture, count: 2)
        #expect(savedEvents.count == 2)

        let destinationNames = Set(savedEvents.compactMap { event -> String? in
            guard let path = event["path"] as? String else { return nil }
            return URL(fileURLWithPath: path).lastPathComponent
        })
        #expect(destinationNames == ["dummy.pdf", "dummy (1).pdf"])
        for event in savedEvents {
            let path = try #require(event["path"] as? String)
            let fileURL = URL(fileURLWithPath: path)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test func emptyPDFPreviewDataDoesNotCreateARecordOrFile() throws {
        let harness = try BrowserPDFPreviewDownloadHarness()
        defer { harness.cleanUp() }
        let panel = BrowserPanel(workspaceId: UUID())
        let delegate = try #require(panel.webView.uiDelegate as? BrowserPDFPreviewActionUIDelegate)
        let capture = BrowserPDFPreviewDownloadEventCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: panel,
            queue: nil
        ) { notification in
            capture.append(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        delegate.downloadsFileManager = harness.fileManager
        delegate.downloadsDefaults = harness.defaults
        let sourceURL = try #require(URL(string: "https://example.com/empty.pdf"))

        try Self.invokeSave(
            on: delegate,
            webView: panel.webView,
            data: Data(),
            suggestedFilename: "empty.pdf",
            mimeType: "application/pdf",
            sourceURL: sourceURL
        )

        #expect(capture.snapshot().isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: harness.downloadsDirectory.path))?.isEmpty != false)
    }

    @Test func printSelectorForwardsToInjectedRunnerAndPropagatesCompletion() throws {
        let delegate = BrowserPDFPreviewActionUIDelegate()
        let runner = RecordingPDFPrintOperationRunner()
        delegate.printOperationRunner = runner
        let webView = WKWebView()
        let frameHandle = NSObject()
        let size = CGSize(width: 612, height: 792)
        var didComplete = false

        try Self.invokePrint(
            on: delegate,
            webView: webView,
            frameHandle: frameHandle,
            pdfFirstPageSize: size
        ) {
            didComplete = true
        }

        #expect(runner.webView === webView)
        #expect(runner.frameHandle === frameHandle)
        #expect(runner.pdfFirstPageSize == size)
        #expect(!didComplete)
        runner.completion?()
        #expect(didComplete)
    }

    @Test func defaultPrintRunnerCallsCompletionWhenNoHostWindowExists() {
        let runner = BrowserPDFPrintOperationRunner()
        runner.hostWindowResolver = { _ in nil }
        let webView = WKWebView()
        var didComplete = false

        runner.runPrintOperation(
            for: webView,
            frameHandle: nil,
            pdfFirstPageSize: .zero
        ) {
            didComplete = true
        }

        #expect(didComplete)
    }

    private static func invokeSave(
        on delegate: BrowserPDFPreviewActionUIDelegate,
        webView: WKWebView,
        data: Data,
        suggestedFilename: String,
        mimeType: String,
        sourceURL: URL
    ) throws {
        let selector = NSSelectorFromString("_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:")
        #expect(delegate.responds(to: selector))
        let implementation = try #require(delegate.method(for: selector))
        typealias SaveFunction = @convention(c) (
            AnyObject,
            Selector,
            WKWebView,
            NSData,
            NSString,
            NSString,
            NSURL
        ) -> Void
        let function = unsafeBitCast(implementation, to: SaveFunction.self)
        function(
            delegate,
            selector,
            webView,
            data as NSData,
            suggestedFilename as NSString,
            mimeType as NSString,
            sourceURL as NSURL
        )
    }

    private static func invokePrint(
        on delegate: BrowserPDFPreviewActionUIDelegate,
        webView: WKWebView,
        frameHandle: NSObject,
        pdfFirstPageSize: CGSize,
        completion: @escaping () -> Void
    ) throws {
        let selector = NSSelectorFromString("_webView:printFrame:pdfFirstPageSize:completionHandler:")
        #expect(delegate.responds(to: selector))
        let implementation = try #require(delegate.method(for: selector))
        typealias PrintFunction = @convention(c) (
            AnyObject,
            Selector,
            WKWebView,
            NSObject,
            CGSize,
            @convention(block) () -> Void
        ) -> Void
        let function = unsafeBitCast(implementation, to: PrintFunction.self)
        let completionBlock: @convention(block) () -> Void = {
            completion()
        }
        function(delegate, selector, webView, frameHandle, pdfFirstPageSize, completionBlock)
    }

    private static func waitForSavedDownloadEvents(
        in capture: BrowserPDFPreviewDownloadEventCapture,
        count: Int,
        timeout: TimeInterval = 3.0
    ) async -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let savedEvents = capture.savedEvents()
            if savedEvents.count >= count {
                return savedEvents
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return capture.savedEvents()
    }
}

private final class BrowserPDFPreviewDownloadEventCapture: @unchecked Sendable {
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

    func savedEvents() -> [[String: Any]] {
        snapshot().filter { $0["type"] as? String == "saved" }
    }
}

private final class BrowserPDFPreviewDownloadHarness {
    let rootDirectory: URL
    let downloadsDirectory: URL
    let fileManager: BrowserPDFPreviewDownloadFileManager
    let defaults: UserDefaults
    private let defaultsSuiteName: String

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-pdf-preview-\(UUID().uuidString)",
            isDirectory: true
        )
        downloadsDirectory = rootDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        fileManager = BrowserPDFPreviewDownloadFileManager(downloadsDirectory: downloadsDirectory)
        defaultsSuiteName = "cmux.pdf.preview.\(UUID().uuidString)"
        guard let scopedDefaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defaults = scopedDefaults
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

private final class BrowserPDFPreviewDownloadFileManager: FileManager {
    private let downloadsDirectory: URL

    init(downloadsDirectory: URL) {
        self.downloadsDirectory = downloadsDirectory
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        if directory == .downloadsDirectory, domainMask.contains(.userDomainMask) {
            return [downloadsDirectory]
        }
        return super.urls(for: directory, in: domainMask)
    }
}

@MainActor
private final class RecordingPDFPrintOperationRunner: BrowserPDFPrintOperationRunning {
    var webView: WKWebView?
    var frameHandle: NSObject?
    var pdfFirstPageSize: CGSize?
    var completion: (() -> Void)?

    func runPrintOperation(
        for webView: WKWebView,
        frameHandle: NSObject?,
        pdfFirstPageSize: CGSize,
        completion: @escaping () -> Void
    ) {
        self.webView = webView
        self.frameHandle = frameHandle
        self.pdfFirstPageSize = pdfFirstPageSize
        self.completion = completion
    }
}
