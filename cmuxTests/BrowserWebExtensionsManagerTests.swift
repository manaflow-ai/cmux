import AppKit
import CmuxBrowser
import CryptoKit
import Foundation
import ObjectiveC.runtime
import os
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@MainActor
struct BrowserWebExtensionsManagerTests {
    private final class RuntimeLoadGate {
        private var bufferedOutcome: BrowserWebExtensionLoadOutcome?
        private var continuation: CheckedContinuation<BrowserWebExtensionLoadOutcome, Never>?

        func wait() async -> BrowserWebExtensionLoadOutcome {
            if let bufferedOutcome {
                self.bufferedOutcome = nil
                return bufferedOutcome
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(_ outcome: BrowserWebExtensionLoadOutcome = .ready) {
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: outcome)
            } else {
                bufferedOutcome = outcome
            }
        }
    }

    private final class RuntimeDeadlineGate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async throws {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor InstallCommitGate {
        private var isEntered = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?

        func pauseAfterCommit() async throws {
            isEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            try await Task.sleep(for: .seconds(3600))
        }

        func waitUntilEntered() async {
            guard !isEntered else { return }
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }
    }

    private final class WebViewLoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?

        func load(_ html: String, in webView: WKWebView) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(.failure(error))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(.failure(error))
        }

        private func finish(_ result: Result<Void, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private final class RejectingCreateTabDelegate: BonsplitDelegate {
        func splitTabBar(
            _ controller: BonsplitController,
            shouldCreateTab tab: Bonsplit.Tab,
            inPane pane: PaneID
        ) -> Bool {
            false
        }
    }

    private final class RejectingSplitPaneDelegate: BonsplitDelegate {
        func splitTabBar(
            _ controller: BonsplitController,
            shouldSplitPane pane: PaneID,
            orientation: SplitOrientation
        ) -> Bool {
            false
        }
    }

    private static func makeExtensionsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-extensions-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeExtension(
        named name: String,
        in root: URL,
        manifest: [String: Any]
    ) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private static func writeSafariExtensionFixture(
        in root: URL,
        bundleIdentifier: String
    ) throws -> (app: URL, appex: URL, resources: URL, trustMarker: URL) {
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let appex = app.appendingPathComponent(
            "Contents/PlugIns/Fixture.appex",
            isDirectory: true
        )
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "XPC!",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
            ],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: appex.appendingPathComponent("Contents/Info.plist"))
        var manifest = minimalManifest
        manifest["name"] = "Safari lifecycle fixture"
        manifest["action"] = ["default_title": "Fixture"]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: resources.appendingPathComponent("manifest.json"))
        try "// no-op".write(
            to: resources.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let trustMarker = app.appendingPathComponent("Contents/trust-marker")
        try "trusted".write(to: trustMarker, atomically: true, encoding: .utf8)
        return (app, appex, resources, trustMarker)
    }

    private static func assertFailedSafariAppLifecycle(tamper: Bool) async throws {
        let managedRoot = try makeExtensionsRoot()
        let appRoot = try makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: managedRoot)
            try? FileManager.default.removeItem(at: appRoot)
        }
        let bundleIdentifier = "com.example.lifecycle.safari"
        let fixture = try writeSafariExtensionFixture(
            in: appRoot,
            bundleIdentifier: bundleIdentifier
        )
        let identity = BrowserWebExtensionSafariAppIdentity(
            id: "lifecycle-fixture",
            appBundleIdentifier: "com.example.lifecycle",
            extensionBundleIdentifier: bundleIdentifier,
            teamIdentifier: "TESTTEAM"
        )
        let reference = BrowserWebExtensionAppExtensionReference(
            bundleURL: fixture.appex,
            bundleIdentifier: bundleIdentifier,
            installationName: bundleIdentifier
        )
        let record = BrowserWebExtensionManagedRecord(
            id: bundleIdentifier,
            displayName: "Safari lifecycle fixture",
            version: "1.0",
            source: .safariApp(reference),
            isEnabled: true,
            isToolbarPinned: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        try await repository.upsertManagedRecord(record, in: managedRoot)
        let verify: BrowserWebExtensionsManager.SafariAppVerifier = { _ in
            guard (try? String(contentsOf: fixture.trustMarker, encoding: .utf8)) == "trusted" else {
                throw BrowserWebExtensionInstallError.integrityMismatch
            }
            return identity
        }
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            verifySafariAppExtension: verify,
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: fixture.resources)
            }
        )
        await manager.loadExtensions()
        #expect(manager.loadedContexts.count == 1)
        manager.shutdown()

        if tamper {
            try "tampered".write(
                to: fixture.trustMarker,
                atomically: true,
                encoding: .utf8
            )
        } else {
            try FileManager.default.removeItem(at: fixture.app)
        }

        let relaunchedManager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            verifySafariAppExtension: verify,
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: fixture.resources)
            }
        )
        await relaunchedManager.loadExtensions()
        let snapshot = relaunchedManager.presentationSnapshot()
        let failedItem = try #require(snapshot.extensions.first)
        #expect(relaunchedManager.loadedContexts.isEmpty)
        #expect(snapshot.extensions.count == 1)
        #expect(snapshot.failures.isEmpty)
        #expect(failedItem.managementID == bundleIdentifier)
        #expect(!failedItem.isEnabled)
        #expect(!failedItem.hasAction)
        #expect(failedItem.loadFailure != nil)

        if tamper {
            try "trusted".write(
                to: fixture.trustMarker,
                atomically: true,
                encoding: .utf8
            )
            try await relaunchedManager.setExtensionEnabled(
                managementID: bundleIdentifier,
                isEnabled: true
            )
            #expect(relaunchedManager.loadedContexts.count == 1)
            #expect(relaunchedManager.presentationSnapshot().extensions.first?.loadFailure == nil)
        } else {
            try await relaunchedManager.removeExtension(managementID: bundleIdentifier)
            #expect(relaunchedManager.presentationSnapshot().extensions.isEmpty)
            let ledger = try await repository.managementLedger(in: managedRoot)
            #expect(ledger.records.isEmpty)
        }
    }

    private static let minimalManifest: [String: Any] = [
        "manifest_version": 3,
        "name": "cmux test extension",
        "version": "1.0",
        "description": "Test fixture",
        "permissions": ["storage"],
        "host_permissions": ["*://example.com/*"],
        "content_scripts": [
            [
                "matches": ["*://example.com/*"],
                "js": ["content.js"],
            ]
        ],
    ]

    private static func makeIconPNG(color: NSColor = .systemBlue) throws -> Data {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private static func centerColor(in pngData: Data) throws -> NSColor {
        let bitmap = try #require(NSBitmapImageRep(data: pngData))
        let color = try #require(bitmap.colorAt(
            x: bitmap.pixelsWide / 2,
            y: bitmap.pixelsHigh / 2
        ))
        return try #require(color.usingColorSpace(.sRGB))
    }

    @available(macOS 15.4, *)
    @Test func candidateDiscoveryFindsDirectoriesAndZipsOnly() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        FileManager.default.createFile(atPath: root.appendingPathComponent("archive.zip").path, contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent("notes.txt").path, contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent(".DS_Store").path, contents: Data())

        let names = BrowserWebExtensionsManager.candidateURLs(in: root).map(\.lastPathComponent)
        #expect(names == ["archive.zip", "sample"])
    }

    @Test func productionCatalogPublishesNoUnverifiedPortablePackages() {
        #expect(BrowserWebExtensionCatalog.production.verifiedEntries.isEmpty)
    }

    @Test func managerHidesEmptyCatalogSection() {
        #expect(!BrowserExtensionsManagerPage.shouldShowCatalog(entryCount: 0))
        #expect(BrowserExtensionsManagerPage.shouldShowCatalog(entryCount: 1))
    }

    @Test func installedRecommendationsUseManagementIdentityInsteadOfContextShape() {
        let managementID = "com.example.safari-extension"
        let item = BrowserWebExtensionPresentationItem(
            id: BrowserWebExtensionsManager.contextIdentifier(for: managementID),
            managementID: managementID,
            name: "Fixture",
            hasAction: true,
            isToolbarPinned: false,
            isActionEnabled: true,
            isAwaitingPopup: false,
            badgeText: "",
            iconData: nil
        )
        let snapshot = BrowserWebExtensionsPresentationSnapshot(
            state: .ready,
            extensions: [item],
            failures: []
        )

        #expect(BrowserExtensionsManagerPage.isInstalled(
            managementID: managementID,
            in: snapshot
        ))
        #expect(!BrowserExtensionsManagerPage.isInstalled(
            managementID: "cmux-browser-extension-com.example.safari-extension",
            in: snapshot
        ))
    }

    @Test func contextIdentifiersAreDeterministicAndCollisionResistant() {
        let spaced = BrowserWebExtensionsManager.contextIdentifier(for: "a b")
        let dashed = BrowserWebExtensionsManager.contextIdentifier(for: "a-b")

        #expect(spaced != dashed)
        #expect(spaced == BrowserWebExtensionsManager.contextIdentifier(for: "a b"))
        #expect(spaced.hasPrefix(BrowserWebExtensionsManager.managedContextIdentifierPrefix))
    }

    @available(macOS 15.4, *)
    @Test func collidingLegacyLogicalIDsRemainDistinctAcrossRelaunch() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a b", "a-b"] {
            let extensionDirectory = try Self.writeExtension(
                named: name,
                in: root,
                manifest: Self.minimalManifest.merging(["name": name]) { _, new in new }
            )
            try "// no-op".write(
                to: extensionDirectory.appendingPathComponent("content.js"),
                atomically: true,
                encoding: .utf8
            )
        }
        let expected = Set(["a b", "a-b"].map {
            BrowserWebExtensionsManager.contextIdentifier(for: $0)
        })
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        for name in ["a b", "a-b"] {
            try await manager.approveInstalledCandidate(
                root.appendingPathComponent(name, isDirectory: true)
            )
        }
        await manager.loadExtensions()

        #expect(Set(manager.loadedContexts.map(\.uniqueIdentifier)) == expected)
        manager.shutdown()

        let relaunchedManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        await relaunchedManager.loadExtensions()
        #expect(Set(relaunchedManager.loadedContexts.map(\.uniqueIdentifier)) == expected)
    }

    @Test func toolbarExtensionIconStaysInsideArtworkBoxAtEveryChromeScale() {
        let minimum = BrowserChromeMetrics(tabBarFontSize: 0.001)
        let standard = BrowserChromeMetrics(tabBarFontSize: BrowserChromeMetrics.referenceFontSize)
        let maximum = BrowserChromeMetrics(tabBarFontSize: 10_000)

        #expect(BrowserExtensionIconMetrics.toolbarContentSize(
            iconPointSize: minimum.navigationIconFontSize
        ) == 8)
        #expect(BrowserExtensionIconMetrics.toolbarContentSize(
            iconPointSize: standard.navigationIconFontSize
        ) == 14)
        #expect(BrowserExtensionIconMetrics.toolbarContentSize(
            iconPointSize: maximum.navigationIconFontSize
        ) == BrowserExtensionIconMetrics.maximumToolbarArtworkSize)
    }

    @available(macOS 15.4, *)
    @Test func extensionActionPopoversPreferBelowTheToolbar() {
        #expect(BrowserExtensionPopoverMetrics.managerArrowEdge == .top)
        #expect(BrowserWebExtensionsManager.actionPopupPreferredEdge == .minY)
    }

    @Test func packageVerifierAcceptsPinnedDigestAndRejectsChangedBytes() throws {
        let data = Data("cmux".utf8)
        let digest = "548d4fabc56e7b556bbd7d01c3bcb6288fc8de3078dcb38fc3698fb3c26508c9"

        try BrowserWebExtensionPackageVerifier.verify(data, expectedSHA256: digest)
        #expect(throws: BrowserWebExtensionCatalogInstallError.integrityMismatch) {
            try BrowserWebExtensionPackageVerifier.verify(data + Data([0]), expectedSHA256: digest)
        }
    }

    @Test func catalogPackageSessionRejectsDeclaredOversizedResponseBeforeBuffering() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeclaredOversizedWebExtensionURLProtocol.self]
        let session = BrowserWebExtensionPackageSession(
            configuration: configuration,
            maximumResponseByteCount: 8
        )
        let url = try #require(URL(string: "https://extensions.example/package.zip"))

        await confirmation("declared oversized package transfer was cancelled") { cancelled in
            DeclaredOversizedWebExtensionURLProtocol.observeCancellation {
                cancelled()
            }
            await #expect(throws: BrowserWebExtensionCatalogInstallError.packageTooLarge) {
                _ = try await session.data(from: url)
            }
        }
    }

    @Test func catalogPackageCollectorRejectsFirstBytePastLimitAndCancels() async throws {
        let state = CountingByteSequenceState()
        let bytes = CountingByteSequence(bytes: Array(Data("ninebytes".utf8)), state: state)

        await #expect(throws: BrowserWebExtensionCatalogInstallError.packageTooLarge) {
            _ = try await BrowserWebExtensionPackageSession.collect(
                bytes,
                maximumByteCount: 8,
                cancel: { state.recordCancellation() }
            )
        }

        #expect(state.snapshot == (nextCount: 9, cancellationCount: 1))
    }

    @Test func catalogPackageCollectorAcceptsResponseExactlyAtLimit() async throws {
        let state = CountingByteSequenceState()
        let bytes = CountingByteSequence(bytes: Array(Data("8-bytes!".utf8)), state: state)

        let data = try await BrowserWebExtensionPackageSession.collect(
            bytes,
            maximumByteCount: 8,
            cancel: { state.recordCancellation() }
        )

        #expect(data == Data("8-bytes!".utf8))
        #expect(state.snapshot == (nextCount: 9, cancellationCount: 0))
    }

    @Test func catalogPackageRedirectsRemainHTTPS() throws {
        let source = try #require(URL(string: "https://extensions.example/package.zip"))
        let insecureDestination = try #require(URL(string: "http://cdn.example/package.zip"))
        let secureDestination = try #require(URL(string: "https://cdn.example/package.zip"))
        let response = try #require(HTTPURLResponse(
            url: source,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        ))
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: source)
        let delegate = BrowserWebExtensionHTTPSRedirectDelegate()

        var acceptedRequest: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: insecureDestination)
        ) { acceptedRequest = $0 }
        #expect(acceptedRequest == nil)

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: secureDestination)
        ) { acceptedRequest = $0 }
        #expect(acceptedRequest?.url == secureDestination)
    }

    @available(macOS 15.4, *)
    @Test func unapprovedDirectoryEntryDoesNotLoad() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "unapproved",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        await manager.loadExtensions()

        #expect(manager.loadedContexts.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func freshProfileDoesNotInstallExtensionsByDefault() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        await manager.loadExtensions()

        #expect(manager.loadedContexts.isEmpty)
        #expect(manager.loadErrors.isEmpty)
        #expect(BrowserWebExtensionsManager.candidateURLs(in: root).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func loadsUnpackedExtensionAndGrantsRequestedPermissions() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()

        #expect(manager.loadErrors.isEmpty)
        #expect(manager.loadedContexts.count == 1)
        let context = try #require(manager.loadedContexts.first)
        #expect(context.uniqueIdentifier == BrowserWebExtensionsManager.contextIdentifier(for: "sample"))
        #expect(context.unsupportedAPIs.contains("browser.runtime.sendNativeMessage"))
        #expect(context.unsupportedAPIs.contains("browser.runtime.connectNative"))
        #expect(context.currentPermissions.contains(.storage))
        #expect(!context.grantedPermissionMatchPatterns.isEmpty)
        #expect(manager.controller.extensionContexts.contains(context))
    }

    @available(macOS 15.4, *)
    @Test func extensionPageConfigurationIsScopedToItsOrigin() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "page-configuration",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let extensionPage = context.baseURL.appendingPathComponent("options.html")

        #expect(manager.pageConfiguration(for: extensionPage) != nil)
        #expect(manager.pageConfiguration(for: URL(string: "https://example.com")!) == nil)
    }

    @Test func baseWebViewConfigurationPreservesItsWebsiteDataStore() {
        let extensionDataStore = WKWebsiteDataStore.nonPersistent()
        let profileDataStore = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = extensionDataStore
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "window.extensionOwned = true",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = BrowserPanel.makeWebView(
            profileID: UUID(),
            websiteDataStore: profileDataStore,
            baseConfiguration: configuration
        )

        #expect(webView.configuration.websiteDataStore === extensionDataStore)
        #expect(webView.configuration.userContentController.userScripts.count == 1)
    }

    @available(macOS 15.4, *)
    @Test func approvalLedgerRemainsReadableAcrossAppRestarts() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "restart-readable",
            in: root,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        try await manager.approveInstalledCandidate(directory)

        let ledger = root.appendingPathComponent(".cmux-approved-extensions.json")
        let values = try ledger.resourceValues(forKeys: [.fileProtectionKey])
        #expect(values.fileProtection != .complete)
        #expect(try Data(contentsOf: ledger).isEmpty == false)
    }

    @available(macOS 15.4, *)
    @Test func standardLimitsAcceptLargeUnpackedExtension() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = root.appendingPathComponent("large-extension", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        let payload = extensionDirectory.appendingPathComponent("background.js")
        try Data().write(to: payload)
        let handle = try FileHandle(forWritingTo: payload)
        try handle.truncate(atOffset: 80 * 1024 * 1024)
        try handle.close()
        let repository = BrowserWebExtensionDirectoryRepository()

        try await repository.validatePackageSize(at: extensionDirectory)
    }

    @available(macOS 15.4, *)
    @Test func oversizedArchiveIsRejectedBeforeApprovalHashing() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("oversized.zip")
        try Data().write(to: archive)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(
            atOffset: UInt64(256 * 1024 * 1024 + 1)
        )
        try handle.close()
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            try await manager.approveInstalledCandidate(archive)
        }
    }

    @available(macOS 15.4, *)
    @Test func unpackedInstallRejectsCumulativeBytesBeforeCreatingDestination() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = sourceRoot.appendingPathComponent("oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 6).write(to: source.appendingPathComponent("first.js"))
        try Data(repeating: 0x42, count: 6).write(to: source.appendingPathComponent("second.js"))
        let repository = BrowserWebExtensionDirectoryRepository(packageLimits: .init(
            maximumByteCount: 10,
            maximumFileCount: 10
        ))

        do {
            _ = try await repository.installCandidate(from: source, into: managedRoot)
            Issue.record("Expected cumulative unpacked bytes to reject installation")
        } catch let error as BrowserWebExtensionInstallError {
            guard case .packageTooLarge = error else {
                Issue.record("Expected packageTooLarge, got \(error)")
                return
            }
        }

        #expect(!FileManager.default.fileExists(
            atPath: managedRoot.appendingPathComponent("oversized").path
        ))
        #expect(try FileManager.default.contentsOfDirectory(atPath: managedRoot.path).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func unpackedInstallCountsDirectoriesTowardEntryLimit() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = sourceRoot.appendingPathComponent("entry-heavy", isDirectory: true)
        for name in ["first", "second", "third"] {
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let repository = BrowserWebExtensionDirectoryRepository(packageLimits: .init(
            maximumByteCount: 10,
            maximumFileCount: 2
        ))

        do {
            _ = try await repository.installCandidate(from: source, into: managedRoot)
            Issue.record("Expected unpacked entry count to reject installation")
        } catch let error as BrowserWebExtensionInstallError {
            guard case .packageContainsTooManyFiles = error else {
                Issue.record("Expected packageContainsTooManyFiles, got \(error)")
                return
            }
        }

        #expect(!FileManager.default.fileExists(
            atPath: managedRoot.appendingPathComponent("entry-heavy").path
        ))
        #expect(try FileManager.default.contentsOfDirectory(atPath: managedRoot.path).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func unpackedInstallAcceptsExactCumulativeLimits() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = sourceRoot.appendingPathComponent("exact-limit", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 6).write(to: source.appendingPathComponent("first.js"))
        try Data(repeating: 0x42, count: 6).write(to: source.appendingPathComponent("second.js"))
        let repository = BrowserWebExtensionDirectoryRepository(packageLimits: .init(
            maximumByteCount: 12,
            maximumFileCount: 2
        ))

        let installed = try await repository.installCandidate(from: source, into: managedRoot)

        #expect(try Data(contentsOf: installed.appendingPathComponent("first.js")).count == 6)
        #expect(try Data(contentsOf: installed.appendingPathComponent("second.js")).count == 6)
    }

    @available(macOS 15.4, *)
    @Test func unpackedInstallRevalidatesSymlinksAfterPreflight() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = sourceRoot.appendingPathComponent("replaced", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let script = source.appendingPathComponent("content.js")
        try Data("safe".utf8).write(to: script)
        let repository = BrowserWebExtensionDirectoryRepository()
        try await repository.validatePackageSize(at: source)
        try FileManager.default.removeItem(at: script)
        try FileManager.default.createSymbolicLink(
            at: script,
            withDestinationURL: sourceRoot.appendingPathComponent("outside.js")
        )

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            _ = try await repository.installCandidate(from: source, into: managedRoot)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: managedRoot.path).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func installsValidExtensionIntoManagedDirectoryAndLoadsItImmediately() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(named: "sample", in: sourceRoot, manifest: Self.minimalManifest)
        try "// no-op".write(to: source.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        let manager = BrowserWebExtensionsManager(directory: managedRoot, controllerConfiguration: .nonPersistent())

        let receipt = try await manager.installExtension(from: source)

        #expect(receipt.name == "cmux test extension")
        #expect(FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("sample/manifest.json").path))
        #expect(manager.loadedContexts.count == 1)
        #expect(manager.presentationSnapshot().extensions.map(\.name) == ["cmux test extension"])
    }

    @available(macOS 15.4, *)
    @Test func sourceMutationAfterReviewFailsBeforeLedgerCommit() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(
            named: "reviewed-source",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        let script = source.appendingPathComponent("content.js")
        try "// reviewed".write(to: script, atomically: true, encoding: .utf8)
        let repository = BrowserWebExtensionDirectoryRepository()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository
        )
        let preview = try await manager.prepareInstall(from: source)
        try "// replaced after review".write(
            to: script,
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            _ = try await manager.confirmPreparedInstall(id: preview.id)
        }
        let ledger = try await repository.managementLedger(in: managedRoot)
        #expect(ledger.records.isEmpty)
        #expect(manager.loadedContexts.isEmpty)
        #expect(manager.presentationSnapshot().extensions.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func cancellationAfterLedgerCommitReturnsCommittedInstall() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(
            named: "commit-cancellation",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let repository = BrowserWebExtensionDirectoryRepository()
        let gate = InstallCommitGate()
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            directoryRepository: repository,
            postManagementCommitHook: {
                try await gate.pauseAfterCommit()
            }
        )
        let preview = try await manager.prepareInstall(from: source)
        let installTask = Task { @MainActor in
            try await manager.confirmPreparedInstall(id: preview.id)
        }
        await gate.waitUntilEntered()
        installTask.cancel()

        let receipt = try await installTask.value
        #expect(receipt.name == "cmux test extension")
        let ledger = try await repository.managementLedger(in: managedRoot)
        #expect(ledger.records["commit-cancellation"] != nil)
        #expect(manager.loadedContexts.count == 1)
        let item = try #require(manager.presentationSnapshot().extensions.first)
        #expect(item.managementID == "commit-cancellation")
        #expect(item.isEnabled)
    }

    @available(macOS 15.4, *)
    @Test func installsSafariAppExtensionAsBundleBackedReference() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let app = sourceRoot.appendingPathComponent("Password Manager.app", isDirectory: true)
        let appex = app.appendingPathComponent(
            "Contents/PlugIns/Password Manager Safari.appex",
            isDirectory: true
        )
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.password-manager.safari",
            "CFBundleShortVersionString": "2.3.4",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "XPC!",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
            ],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: appex.appendingPathComponent("Contents/Info.plist"))
        let manifest = Self.minimalManifest.merging(["name": "Safari container fixture"]) { _, new in new }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: resources.appendingPathComponent("manifest.json"))
        try "// no-op".write(
            to: resources.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: resources)
            }
        )

        let receipt = try await manager.installExtension(from: app)

        #expect(receipt.name == "Safari container fixture")
        #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent(
            "com.example.password-manager.safari",
            isDirectory: true
        ).path))
        let referenceLedger = managedRoot.appendingPathComponent(
            ".cmux-app-extension-bundles.json"
        )
        let references = try JSONDecoder().decode(
            [BrowserWebExtensionAppExtensionReference].self,
            from: Data(contentsOf: referenceLedger)
        )
        #expect(references == [.init(
            bundleURL: appex.standardizedFileURL,
            bundleIdentifier: "com.example.password-manager.safari",
            installationName: "com.example.password-manager.safari"
        )])
        #expect(manager.loadedContexts.first?.uniqueIdentifier
            == BrowserWebExtensionsManager.contextIdentifier(
                for: "com.example.password-manager.safari"
            ))
        #expect(manager.loadedContexts.first?.unsupportedAPIs
            .contains("browser.runtime.sendNativeMessage") == false)
        #expect(manager.loadedContexts.first?.unsupportedAPIs
            .contains("browser.runtime.connectNative") == false)

        manager.shutdown()
        let relaunchedManager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent(),
            appExtensionLoader: { _ in
                try await WKWebExtension(resourceBaseURL: resources)
            }
        )
        await relaunchedManager.loadExtensions()

        #expect(relaunchedManager.loadErrors.isEmpty)
        #expect(relaunchedManager.loadedContexts.first?.uniqueIdentifier
            == BrowserWebExtensionsManager.contextIdentifier(
                for: "com.example.password-manager.safari"
            ))
    }

    @available(macOS 15.4, *)
    @Test func removedSafariAppRelaunchKeepsAUsableRemovalRow() async throws {
        try await Self.assertFailedSafariAppLifecycle(tamper: false)
    }

    @available(macOS 15.4, *)
    @Test func tamperedSafariAppRelaunchCanRetryAfterTrustIsRestored() async throws {
        try await Self.assertFailedSafariAppLifecycle(tamper: true)
    }

    @available(macOS 15.4, *)
    @Test func presentationSnapshotIncludesDeclaredExtensionIcon() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["icons"] = ["16": "icon.png"]
        manifest["action"] = ["default_icon": ["16": "icon.png"]]
        let directory = try Self.writeExtension(named: "sample", in: root, manifest: manifest)
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try Self.makeIconPNG().write(to: directory.appendingPathComponent("icon.png"))
        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())

        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()

        let item = try #require(manager.presentationSnapshot().extensions.first)
        let iconData = try #require(item.iconData)
        #expect(NSImage(data: iconData) != nil)
    }

    @available(macOS 15.4, *)
    @Test func presentationSnapshotRecognizesEveryManifestActionKind() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        for actionKey in ["action", "browser_action", "page_action"] {
            var manifest = Self.minimalManifest
            manifest["name"] = actionKey
            manifest[actionKey] = [
                "default_title": actionKey,
                "default_popup": "popup.html",
            ]
            let directory = try Self.writeExtension(
                named: actionKey,
                in: root,
                manifest: manifest
            )
            try "// no-op".write(
                to: directory.appendingPathComponent("content.js"),
                atomically: true,
                encoding: .utf8
            )
            try "<main>Popup for \(actionKey)</main>".write(
                to: directory.appendingPathComponent("popup.html"),
                atomically: true,
                encoding: .utf8
            )
            try await manager.approveInstalledCandidate(directory)
        }

        await manager.loadExtensions()

        let items = manager.presentationSnapshot().extensions
        #expect(items.map(\.name) == ["action", "browser_action", "page_action"])
        #expect(items.allSatisfy(\.hasAction))
        #expect(manager.loadedContexts.allSatisfy { context in
            context.action(for: nil)?.presentsPopup == true
        })
    }

    @available(macOS 15.4, *)
    @Test func toolbarActionPinningPersistsAcrossManagerRelaunch() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Pinned action"]
        let directory = try Self.writeExtension(
            named: "pinned-action",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let identifier = BrowserWebExtensionsManager.contextIdentifier(for: "pinned-action")
        let firstManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await firstManager.approveInstalledCandidate(directory)
        await firstManager.loadExtensions()

        #expect(firstManager.presentationSnapshot().extensions.first?.isToolbarPinned == false)
        try await firstManager.setToolbarActionPinned(true, uniqueIdentifier: identifier)
        #expect(firstManager.presentationSnapshot().extensions.first?.isToolbarPinned == true)
        firstManager.shutdown()

        let relaunchedManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        await relaunchedManager.loadExtensions()

        #expect(relaunchedManager.presentationSnapshot().extensions.first?.isToolbarPinned == true)
        try await relaunchedManager.setToolbarActionPinned(false, uniqueIdentifier: identifier)
        #expect(relaunchedManager.presentationSnapshot().extensions.first?.isToolbarPinned == false)
    }

    @available(macOS 15.4, *)
    @Test func catalogArchiveInstallationPreservesPinnedRawDigestAndStaysCurrent() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let archive = sourceRoot.appendingPathComponent("fixture.zip")
        let archiveBytes = Data("verified catalog archive".utf8)
        try archiveBytes.write(to: archive)
        let pinnedDigest = SHA256.hash(data: archiveBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let repository = BrowserWebExtensionDirectoryRepository()

        let installed = try await repository.installImmutableCandidate(
            from: archive,
            into: managedRoot
        )

        #expect(installed.digest == pinnedDigest)
        let entry = BrowserWebExtensionCatalogEntry(
            id: "fixture",
            version: "1.0",
            packageURL: URL(string: "https://example.com/fixture.zip")!,
            packageSHA256: pinnedDigest
        )
        let record = BrowserWebExtensionManagedRecord(
            id: entry.installedManagementID,
            displayName: "Fixture",
            version: entry.version,
            source: .catalogArchive(
                filename: installed.url.lastPathComponent,
                digest: installed.digest,
                catalogID: entry.id
            ),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        let catalog = BrowserWebExtensionCatalog(
            verifiedEntries: [entry],
            safariAppIdentities: []
        )

        #expect(!BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: record,
            loadedVersion: entry.version,
            catalog: catalog
        ))
    }

    @available(macOS 15.4, *)
    @Test func trustedUpdateAvailabilityDistinguishesCurrentCatalogNewCatalogAndSignedApp() {
        let currentEntry = BrowserWebExtensionCatalogEntry(
            id: "fixture",
            version: "1.0",
            packageURL: URL(string: "https://example.com/fixture-1.zip")!,
            packageSHA256: String(repeating: "1", count: 64)
        )
        let currentCatalog = BrowserWebExtensionCatalog(
            verifiedEntries: [currentEntry],
            safariAppIdentities: []
        )
        let catalogRecord = BrowserWebExtensionManagedRecord(
            id: "catalog:fixture",
            displayName: "Fixture",
            version: "1.0",
            source: .catalogArchive(
                filename: "fixture.zip",
                digest: currentEntry.packageSHA256,
                catalogID: currentEntry.id
            ),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: catalogRecord,
            loadedVersion: "1.0",
            catalog: currentCatalog
        ) == false)

        let newerCatalog = BrowserWebExtensionCatalog(
            verifiedEntries: [BrowserWebExtensionCatalogEntry(
                id: "fixture",
                version: "2.0",
                packageURL: URL(string: "https://example.com/fixture-2.zip")!,
                packageSHA256: String(repeating: "2", count: 64)
            )],
            safariAppIdentities: []
        )
        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: catalogRecord,
            loadedVersion: "1.0",
            catalog: newerCatalog
        ) == true)

        let appRecord = BrowserWebExtensionManagedRecord(
            id: "com.example.safari",
            displayName: "Signed App Fixture",
            version: "3.0",
            source: .safariApp(BrowserWebExtensionAppExtensionReference(
                bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app/Contents/PlugIns/Fixture.appex"),
                bundleIdentifier: "com.example.safari",
                installationName: "Fixture.appex"
            )),
            isEnabled: true,
            grantedPermissions: [],
            grantedMatchPatterns: []
        )
        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: appRecord,
            loadedVersion: "3.0",
            catalog: currentCatalog
        ) == false)
        #expect(BrowserWebExtensionsManager.trustedUpdateAvailable(
            for: appRecord,
            loadedVersion: "3.1",
            catalog: currentCatalog
        ) == true)
    }

    @available(macOS 15.4, *)
    @Test func toolbarPinLedgerFailureIsVisibleAndDoesNotMutatePinState() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Pin failure probe"]
        let directory = try Self.writeExtension(
            named: "pin-failure-probe",
            in: root,
            manifest: manifest
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let identifier = try #require(manager.loadedContexts.first?.uniqueIdentifier)
        let ledgerURL = root.appendingPathComponent(".cmux-extension-management.json")
        let symlinkTarget = root.appendingPathComponent("ledger-target.json")
        try Data("{}".utf8).write(to: symlinkTarget)
        try FileManager.default.removeItem(at: ledgerURL)
        try FileManager.default.createSymbolicLink(
            at: ledgerURL,
            withDestinationURL: symlinkTarget
        )

        await #expect(throws: BrowserWebExtensionInstallError.symbolicLinksNotAllowed) {
            try await manager.setToolbarActionPinned(true, uniqueIdentifier: identifier)
        }

        let item = try #require(manager.presentationSnapshot().extensions.first)
        #expect(!item.isToolbarPinned)
        #expect(item.actionFailure == .toolbarPinFailed)
    }

    @available(macOS 15.4, *)
    @Test func presentationSnapshotUsesEachPackageManifestIconWithoutNameMapping() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var alphaManifest = Self.minimalManifest
        alphaManifest["name"] = "Arbitrary Alpha"
        alphaManifest["icons"] = ["16": "extension-icon.png"]
        alphaManifest["action"] = ["default_icon": ["16": "action-icon.png"]]
        let alphaDirectory = try Self.writeExtension(
            named: "arbitrary-alpha",
            in: root,
            manifest: alphaManifest
        )
        try "// no-op".write(
            to: alphaDirectory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try Self.makeIconPNG(color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            .write(to: alphaDirectory.appendingPathComponent("extension-icon.png"))
        try Self.makeIconPNG(color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .write(to: alphaDirectory.appendingPathComponent("action-icon.png"))

        var betaManifest = Self.minimalManifest
        betaManifest["name"] = "Arbitrary Beta"
        betaManifest["icons"] = ["16": "extension-icon.png"]
        let betaDirectory = try Self.writeExtension(
            named: "arbitrary-beta",
            in: root,
            manifest: betaManifest
        )
        try "// no-op".write(
            to: betaDirectory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try Self.makeIconPNG(color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            .write(to: betaDirectory.appendingPathComponent("extension-icon.png"))

        var iconlessManifest = Self.minimalManifest
        iconlessManifest["name"] = "Arbitrary Iconless"
        let iconless = try Self.writeExtension(
            named: "arbitrary-iconless",
            in: root,
            manifest: iconlessManifest
        )
        try "// no-op".write(
            to: iconless.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )

        try await manager.approveInstalledCandidate(alphaDirectory)
        try await manager.approveInstalledCandidate(betaDirectory)
        try await manager.approveInstalledCandidate(iconless)
        await manager.loadExtensions()

        let itemsByName = Dictionary(
            uniqueKeysWithValues: manager.presentationSnapshot().extensions.map { ($0.name, $0) }
        )
        let alpha = try #require(itemsByName["Arbitrary Alpha"]?.iconData)
        let beta = try #require(itemsByName["Arbitrary Beta"]?.iconData)
        let alphaColor = try Self.centerColor(in: alpha)
        let betaColor = try Self.centerColor(in: beta)
        #expect(abs(alphaColor.redComponent) < 0.05)
        #expect(abs(alphaColor.greenComponent) < 0.05)
        #expect(abs(alphaColor.blueComponent - 1) < 0.05)
        #expect(abs(betaColor.redComponent) < 0.05)
        #expect(abs(betaColor.greenComponent - 1) < 0.05)
        #expect(abs(betaColor.blueComponent) < 0.05)
        #expect(itemsByName["Arbitrary Iconless"]?.iconData == nil)
    }

    @available(macOS 15.4, *)
    @Test func duplicateInstallPreservesExistingExtension() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(named: "sample", in: sourceRoot, manifest: Self.minimalManifest)
        try "// no-op".write(to: source.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        let manager = BrowserWebExtensionsManager(directory: managedRoot, controllerConfiguration: .nonPersistent())
        _ = try await manager.installExtension(from: source)

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            _ = try await manager.installExtension(from: source)
        }
        #expect(manager.loadedContexts.count == 1)
    }

    @available(macOS 15.4, *)
    @Test func rejectedSymlinkPackageNeverActivatesAContext() async throws {
        let sourceRoot = try Self.makeExtensionsRoot()
        let managedRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        let source = try Self.writeExtension(
            named: "symlink-package",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked-resource.js"),
            withDestinationURL: source.appendingPathComponent("content.js")
        )
        let manager = BrowserWebExtensionsManager(
            directory: managedRoot,
            controllerConfiguration: .nonPersistent()
        )

        await #expect(throws: BrowserWebExtensionInstallError.self) {
            _ = try await manager.installExtension(from: source)
        }

        #expect(manager.loadedContexts.isEmpty)
        #expect(manager.controller.extensionContexts.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func contentScriptOnlyMatchPatternsAreGranted() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "cmux content script only test",
            "version": "1.0",
            "description": "Test fixture",
            "content_scripts": [
                [
                    "matches": ["*://content-only.example/*"],
                    "js": ["content.js"],
                ]
            ],
        ]
        let dir = try Self.writeExtension(named: "content-only", in: root, manifest: manifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()

        #expect(manager.loadErrors.isEmpty)
        let context = try #require(manager.loadedContexts.first)
        let url = try #require(URL(string: "https://content-only.example/page"))
        #expect(context.grantedPermissionMatchPatterns.keys.contains { $0.matches(url) })
    }

    @available(macOS 15.4, *)
    @Test func webViewConfigurationUsesInjectedController() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let configuration = WKWebViewConfiguration()

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )

        #expect(configuration.webExtensionController === services.webExtensionsManager?.controller)
    }

    @available(macOS 15.4, *)
    @Test func webViewConfigurationDoesNotStartExtensionsBeforeWebViewExists() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let profileID = UUID()
        let manager = services.webExtensionsManager(for: profileID)
        let configuration = WKWebViewConfiguration()

        BrowserPanel.configureWebViewConfiguration(
            configuration,
            profileID: profileID,
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )

        #expect(configuration.webExtensionController === manager.controller)
        #expect(manager.profileRuntime.phase == .idle)
    }

    @Test func trustedSafariAppsAreOptInSuggestions() {
        #expect(BrowserWebExtensionCatalog.production.safariAppIdentities.map(\.id) == [
            "bitwarden-safari-app",
            "onepassword-safari-app",
            "ublock-origin-lite-safari-app",
        ])
    }

    @available(macOS 15.4, *)
    @Test func extensionControllerInstallsWebKitNotificationCompatibility() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WKWebExtensionController.Configuration.nonPersistent()

        _ = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: configuration
        )

        let scripts = configuration.webViewConfiguration.userContentController.userScripts
        #expect(scripts.contains { script in
            script.source == BrowserWebExtensionsManager.notificationsCompatibilityScriptSource
                && script.injectionTime == .atDocumentStart
                && script.isForMainFrameOnly == false
        })
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "chrome.notifications"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "onClicked"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "onCreatedNavigationTarget"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "readystatechange"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "onCreatedNavigationTarget', {\n                configurable: false"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "connectNative"
        ))
        #expect(BrowserWebExtensionsManager.notificationsCompatibilityScriptSource.contains(
            "No such native application"
        ))
    }

    @available(macOS 15.4, *)
    @Test func compatibilityAPIsSurviveNestedNamespaceWrapperChurn() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: "globalThis.chrome = { webNavigation: {}, runtime: {} };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserWebExtensionsManager.notificationsCompatibilityScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        let waiter = WebViewLoadWaiter()
        webView.navigationDelegate = waiter

        try await waiter.load("<html><body>fixture</body></html>", in: webView)
        try await Task.sleep(for: .milliseconds(150))
        let rawResult = try await webView.callAsyncJavaScript(
            #"""
            const initialNavigation = chrome.webNavigation;
            const initialRuntime = chrome.runtime;
            for (let index = 0; index < 10000; index += 1) {
              const churn = { index, bytes: new Uint8Array(64) };
              if (churn.index < 0) throw new Error('unreachable');
            }
            await new Promise(resolve => setTimeout(resolve, 10));
            return {
              navigationIdentityStable: initialNavigation === chrome.webNavigation,
              runtimeIdentityStable: initialRuntime === chrome.runtime,
              navigationEventType: typeof chrome.webNavigation.onCreatedNavigationTarget,
              connectNativeType: typeof chrome.runtime.connectNative,
              notificationsType: typeof chrome.notifications,
              navigationConfigurable: Object.getOwnPropertyDescriptor(chrome, 'webNavigation')?.configurable,
              runtimeConfigurable: Object.getOwnPropertyDescriptor(chrome, 'runtime')?.configurable
            };
            """#,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let result = try #require(rawResult as? [String: Any])

        #expect(result["navigationIdentityStable"] as? Bool == true)
        #expect(result["runtimeIdentityStable"] as? Bool == true)
        #expect(result["navigationEventType"] as? String == "object")
        #expect(result["connectNativeType"] as? String == "function")
        #expect(result["notificationsType"] as? String == "object")
        #expect(result["navigationConfigurable"] as? Bool == false)
        #expect(result["runtimeConfigurable"] as? Bool == false)
    }

    @available(macOS 15.4, *)
    @Test func safariCompatibleApplicationNameUsesProviderAndSafeFallback() {
        let fallback = OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 3,
            patchVersion: 1
        )

        #expect(BrowserWebExtensionsManager.safariCompatibleApplicationName(
            safariVersionProvider: { "26.5" },
            operatingSystemVersion: fallback
        ) == "Version/26.5 Safari/605.1.15 cmux")
        #expect(BrowserWebExtensionsManager.safariCompatibleApplicationName(
            safariVersionProvider: { nil },
            operatingSystemVersion: fallback
        ) == "Version/27.3 Safari/605.1.15 cmux")
        #expect(BrowserWebExtensionsManager.safariCompatibleApplicationName(
            safariVersionProvider: { "invalid token" },
            operatingSystemVersion: fallback
        ) == "Version/27.3 Safari/605.1.15 cmux")
    }

    @available(macOS 15.4, *)
    @Test func extensionControllerUsesSafariCompatibleApplicationName() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WKWebExtensionController.Configuration.nonPersistent()

        _ = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: configuration
        )

        #expect(
            configuration.webViewConfiguration.applicationNameForUserAgent
                == BrowserWebExtensionsManager.safariCompatibleApplicationName()
        )
    }

    @available(macOS 15.4, *)
    @Test func profileManagersUseSeparateControllersAndInstallDirectories() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let alternateProfileID = UUID()
        let defaultManager = try #require(services.webExtensionsManager)
        let alternateManager = services.webExtensionsManager(for: alternateProfileID)

        #expect(defaultManager.directory == root)
        #expect(alternateManager.directory == root
            .appendingPathComponent(".profiles", isDirectory: true)
            .appendingPathComponent(alternateProfileID.uuidString.lowercased(), isDirectory: true))
        #expect(defaultManager.controller !== alternateManager.controller)
        #expect(BrowserServices.extensionDirectory(
            for: defaultProfileID,
            defaultProfileID: defaultProfileID,
            root: root
        ) == root)

        let defaultConfiguration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            defaultConfiguration,
            profileID: defaultProfileID,
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )
        let alternateConfiguration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            alternateConfiguration,
            profileID: alternateProfileID,
            websiteDataStore: .nonPersistent(),
            browserServices: services
        )

        #expect(defaultConfiguration.webExtensionController === defaultManager.controller)
        #expect(alternateConfiguration.webExtensionController === alternateManager.controller)
    }

    @available(macOS 15.4, *)
    @Test func switchingProfileTransfersPanelBetweenExtensionRegistries() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternateProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension isolation \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: alternateProfile.id) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let panel = BrowserPanel(workspaceId: workspace.id, browserServices: services)
        services.registerBrowserPanel(panel, workspace: workspace)
        defer {
            services.unregisterBrowserPanel(id: panel.id)
            panel.close()
        }
        let extensionDirectory = try Self.writeExtension(
            named: "registry-probe",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: extensionDirectory)
        )
        let defaultManager = try #require(services.webExtensionsManager)
        let alternateManager = services.webExtensionsManager(for: alternateProfile.id)

        #expect(defaultManager
            .webExtensionController(defaultManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })
        #expect(!alternateManager
            .webExtensionController(alternateManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })

        #expect(panel.switchToProfile(alternateProfile.id))

        #expect(panel.webView.configuration.webExtensionController === alternateManager.controller)
        #expect(!defaultManager
            .webExtensionController(defaultManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })
        #expect(alternateManager
            .webExtensionController(alternateManager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
            .contains { $0.webView?(for: extensionContext) === panel.webView })
    }

    @available(macOS 15.4, *)
    @Test func switchingProfileDefersRestoreUntilNewProfileExtensionsLoad() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternateProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Deferred extension restore \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: alternateProfile.id) }
        let services = BrowserServices(extensionDirectory: root)
        await services.webExtensionsManager?.loadExtensions()
        let loadGate = RuntimeLoadGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: alternateProfile.id,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        runtime.start { await loadGate.wait() }
        let alternateManager = BrowserWebExtensionsManager(
            directory: BrowserServices.extensionDirectory(
                for: alternateProfile.id,
                defaultProfileID: BrowserProfileStore.shared.builtInDefaultProfileID,
                root: root
            ),
            controllerIdentifier: alternateProfile.id,
            controllerConfiguration: .nonPersistent(),
            profileID: alternateProfile.id,
            profileRuntime: runtime
        )
        services.installWebExtensionsManagerForTesting(alternateManager, profileID: alternateProfile.id)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: try #require(URL(string: "https://example.com/profile-restore")),
            browserServices: services
        )
        defer { panel.close() }

        #expect(panel.switchToProfile(alternateProfile.id))
        #expect(panel.isWaitingForWebExtensionsBeforeNavigation)

        loadGate.resume()
        for _ in 0..<4 { await Task.yield() }
        #expect(!panel.isWaitingForWebExtensionsBeforeNavigation)
    }

    @available(macOS 15.4, *)
    @Test func extensionControllersUseTheOwningProfileWebsiteDataStore() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension cookies A \(UUID().uuidString.prefix(6))"
        ))
        let secondProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension cookies B \(UUID().uuidString.prefix(6))"
        ))
        defer {
            _ = BrowserProfileStore.shared.deleteProfile(id: firstProfile.id)
            _ = BrowserProfileStore.shared.deleteProfile(id: secondProfile.id)
        }
        let services = BrowserServices(extensionDirectory: root)
        let defaultProfileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let defaultManager = services.webExtensionsManager(for: defaultProfileID)
        let firstManager = services.webExtensionsManager(for: firstProfile.id)
        let secondManager = services.webExtensionsManager(for: secondProfile.id)
        let defaultStore = BrowserProfileStore.shared.websiteDataStore(for: defaultProfileID)
        let firstStore = BrowserProfileStore.shared.websiteDataStore(for: firstProfile.id)
        let secondStore = BrowserProfileStore.shared.websiteDataStore(for: secondProfile.id)

        #expect(defaultManager.controller.configuration.defaultWebsiteDataStore === defaultStore)
        #expect(firstManager.controller.configuration.defaultWebsiteDataStore === firstStore)
        #expect(secondManager.controller.configuration.defaultWebsiteDataStore === secondStore)
        #expect(firstManager.controller.configuration.defaultWebsiteDataStore !== secondStore)
        #expect(secondManager.controller.configuration.defaultWebsiteDataStore !== firstStore)
    }

    @available(macOS 15.4, *)
    @Test func nestedPopupKeepsTheProfileContextCapturedByItsParent() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternateProfile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Popup isolation \(UUID().uuidString.prefix(6))"
        ))
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: alternateProfile.id) }
        let services = BrowserServices(extensionDirectory: root)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            browserServices: services
        )
        defer { panel.close() }
        let defaultManager = try #require(services.webExtensionsManager)
        let originalStore = panel.webView.configuration.websiteDataStore
        let parent = BrowserPopupWindowController(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures(),
            browserContext: panel.popupBrowserContext,
            openerPanel: panel
        )
        defer { parent.closePopup() }

        #expect(parent.webView.configuration.webExtensionController === defaultManager.controller)
        #expect(panel.switchToProfile(alternateProfile.id))
        let alternateManager = services.webExtensionsManager(for: alternateProfile.id)
        let child = try #require(parent.createNestedPopup(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures()
        ))

        #expect(child.configuration.websiteDataStore === originalStore)
        #expect(child.configuration.webExtensionController === defaultManager.controller)
        #expect(child.configuration.webExtensionController !== alternateManager.controller)

        let freshPopup = try #require(panel.createFloatingPopup(
            configuration: WKWebViewConfiguration(),
            windowFeatures: WKWindowFeatures()
        ))
        #expect(freshPopup.configuration.websiteDataStore === panel.webView.configuration.websiteDataStore)
        #expect(freshPopup.configuration.webExtensionController === alternateManager.controller)
    }

    @available(macOS 15.4, *)
    @Test func newerNavigationCancelsDeferredStartupNavigation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let profileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let loadGate = RuntimeLoadGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        runtime.start { await loadGate.wait() }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID,
            profileRuntime: runtime
        )
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let panel = BrowserPanel(workspaceId: UUID(), browserServices: services)
        defer { panel.close() }
        var deferredNavigationCount = 0

        panel.runWhenWebExtensionsLoaded {
            deferredNavigationCount += 1
        }
        panel.navigate(to: try #require(URL(string: "https://example.com/newer")))
        loadGate.resume()
        for _ in 0..<4 { await Task.yield() }

        #expect(deferredNavigationCount == 0)
    }

    @available(macOS 15.4, *)
    @Test func browserServicesExecutesOnlyLatestNavigationAndHonorsCancellation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let loadGate = RuntimeLoadGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        runtime.start { await loadGate.wait() }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID,
            profileRuntime: runtime
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let ownerID = UUID()
        var executions: [Int] = []

        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/old"),
            reason: .initial
        ) { executions.append(1) }
        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/latest"),
            reason: .userInitiated
        ) { executions.append(2) }
        loadGate.resume()
        for await update in runtime.updates() {
            if update == .phaseChanged(.ready) { break }
        }
        for _ in 0..<20 where services.isWebExtensionNavigationPending(ownerID: ownerID) {
            await Task.yield()
        }
        #expect(executions == [2])

        runtime.start { await loadGate.wait() }
        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/cancelled"),
            reason: .restore
        ) { executions.append(3) }
        services.cancelWebExtensionNavigation(ownerID: ownerID)
        loadGate.resume()
        for await update in runtime.updates() {
            if update == .phaseChanged(.ready) { break }
        }
        await Task.yield()
        #expect(executions == [2])
    }

    @available(macOS 15.4, *)
    @Test func browserServicesReleasesAtDeadlineWithoutLateReplayAndRecovers() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let loadGate = RuntimeLoadGate()
        let deadlineGate = RuntimeDeadlineGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await deadlineGate.wait() }
        )
        runtime.start { await loadGate.wait() }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID,
            profileRuntime: runtime
        )
        let services = BrowserServices(extensionDirectory: root)
        services.installWebExtensionsManagerForTesting(manager, profileID: profileID)
        let ownerID = UUID()
        var executionCount = 0
        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/degraded"),
            reason: .initial
        ) { executionCount += 1 }

        deadlineGate.resume()
        for await update in runtime.updates() {
            if update == .phaseChanged(.degraded(.loadDeadlineExceeded)) { break }
        }
        for _ in 0..<20 where executionCount == 0 { await Task.yield() }
        #expect(executionCount == 1)

        loadGate.resume()
        for await update in runtime.updates() {
            if update == .phaseChanged(.ready) { break }
        }
        await Task.yield()
        #expect(executionCount == 1)

        services.scheduleWebExtensionNavigation(
            ownerID: ownerID,
            profileID: profileID,
            targetURL: URL(string: "https://example.com/recovered"),
            reason: .recovery
        ) { executionCount += 1 }
        for _ in 0..<20 where executionCount == 1 { await Task.yield() }
        #expect(executionCount == 2)
    }

    @available(macOS 15.4, *)
    @Test func extensionTabOrderAndIndicesFollowVisibleWorkspaceOrder() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = try Self.writeExtension(
            named: "tab-order",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: extensionDirectory)
        )
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let managerPage = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        managerPage.showBrowserExtensionsManager()
        let second = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let secondTabID = try #require(workspace.surfaceIdFromPanelId(second.id))
        #expect(workspace.bonsplitController.reorderTab(secondTabID, toIndex: 0))

        let manager = try #require(services.webExtensionsManager)
        let window = try #require(manager
            .webExtensionController(manager.controller, openWindowsFor: extensionContext)
            .first { window in
                (window.tabs?(for: extensionContext) ?? []).contains {
                    $0.webView?(for: extensionContext) === first.webView
                }
            })
        let visibleTabs = window.tabs?(for: extensionContext) ?? []
        #expect(visibleTabs.compactMap { $0.webView?(for: extensionContext) } == [second.webView, first.webView])
        let secondAdapter = try #require(visibleTabs.first as? BrowserWebExtensionTabAdapter)
        let firstAdapter = try #require(visibleTabs.last as? BrowserWebExtensionTabAdapter)
        #expect(secondAdapter.indexInWindow(for: extensionContext) == 0)
        #expect(firstAdapter.indexInWindow(for: extensionContext) == 1)

        workspace.focusPanel(managerPage.id)
        #expect(window.activeTab?(for: extensionContext) == nil)
    }

    @available(macOS 15.4, *)
    @Test func managerPaneReturnsToExtensionTabRegistryAfterNavigation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionDirectory = try Self.writeExtension(
            named: "manager-registry",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: extensionDirectory)
        )
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let source = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let managerPage = try #require(workspace.openBrowserExtensionsManager(from: source.id))
        let manager = try #require(services.webExtensionsManager)

        let registeredWebViews = {
            manager.webExtensionController(manager.controller, openWindowsFor: extensionContext)
                .flatMap { $0.tabs?(for: extensionContext) ?? [] }
                .compactMap { $0.webView?(for: extensionContext) }
        }
        #expect(!registeredWebViews().contains(managerPage.webView))

        managerPage.navigate(to: try #require(URL(string: "https://example.com")))

        #expect(registeredWebViews().contains(managerPage.webView))
    }

    @available(macOS 15.4, *)
    @Test func rejectedBrowserTabCreationDoesNotRegisterOrRetainPanel() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let originalPanelCount = workspace.panels.count
        let rejectingDelegate = RejectingCreateTabDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate

        let created = workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        )

        #expect(created == nil)
        #expect(workspace.panels.count == originalPanelCount)
        #expect(services.registeredBrowserPanelCount == 0)
    }

    @available(macOS 15.4, *)
    @Test func rejectedManagerSplitKeepsOnlySourcePanelRegistered() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let tabManager = TabManager(autoWelcomeIfNeeded: false, browserServices: services)
        let workspace = try #require(tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let source = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let originalPanelCount = workspace.panels.count
        #expect(services.registeredBrowserPanelCount == 1)
        let rejectingDelegate = RejectingSplitPaneDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate

        let manager = workspace.openBrowserExtensionsManager(from: source.id)

        #expect(manager == nil)
        #expect(workspace.panels.count == originalPanelCount)
        #expect(services.registeredBrowserPanelCount == 1)
    }

    @available(macOS 15.4, *)
    @Test func extensionControllerReportsNoFocusedWindowWithoutAKeyCmuxWindow() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(
            named: "focus-probe",
            in: root,
            manifest: Self.minimalManifest
        )
        let extensionContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: directory)
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }

        #expect(manager.webExtensionController(
            manager.controller,
            focusedWindowFor: extensionContext
        ) == nil)
    }

    @available(macOS 15.4, *)
    @Test func extensionControllerPrefersTheAuthoritativeFocusedOwner() {
        let manager = BrowserWebExtensionsManager(
            directory: FileManager.default.temporaryDirectory,
            controllerConfiguration: .nonPersistent()
        )
        let fallbackOwnerID = UUID()
        let focusedOwnerID = UUID()
        let fallbackPanel = BrowserPanel(workspaceId: fallbackOwnerID)
        let focusedPanel = BrowserPanel(workspaceId: focusedOwnerID)
        defer {
            manager.unregister(panelID: fallbackPanel.id)
            manager.unregister(panelID: focusedPanel.id)
            fallbackPanel.close()
            focusedPanel.close()
        }
        manager.register(
            panel: fallbackPanel,
            ownerID: fallbackOwnerID,
            activePanelID: { fallbackPanel.id },
            focusPriority: { 1 },
            focusPanel: { _ in }
        )
        manager.register(
            panel: focusedPanel,
            ownerID: focusedOwnerID,
            activePanelID: { focusedPanel.id },
            focusPriority: { 2 },
            focusPanel: { _ in }
        )

        #expect(manager.debugPreferredFocusedWindowOwnerID == focusedOwnerID)
    }

    @available(macOS 15.4, *)
    @Test func deletingProfileReleasesItsExtensionRuntime() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try #require(BrowserProfileStore.shared.createProfile(
            named: "Extension teardown \(UUID().uuidString.prefix(6))"
        ))
        let services = BrowserServices(extensionDirectory: root)
        var manager: BrowserWebExtensionsManager? = services.webExtensionsManager(for: profile.id)
        weak var weakManager = manager
        manager = nil

        #expect(BrowserProfileStore.shared.deleteProfile(id: profile.id) != nil)
        for _ in 0..<8 { await Task.yield() }

        #expect(weakManager == nil)
    }

    @available(macOS 15.4, *)
    @Test func shutdownIsTerminalForExtensionLoadingAndInstallation() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try Self.writeExtension(
            named: "shutdown-probe",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )

        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        manager.shutdown()

        await manager.loadExtensions()
        await #expect(throws: CancellationError.self) {
            _ = try await manager.installExtension(from: source)
        }

        #expect(manager.loadedContexts.isEmpty)
        #expect(BrowserWebExtensionsManager.candidateURLs(in: root).isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func actionMutationsCoalesceIntoTypedToolbarUpdateWithoutTimerSynchronization() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Action probe"]
        let directory = try Self.writeExtension(named: "action-probe", in: root, manifest: manifest)
        let context = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: directory)
        )
        context.uniqueIdentifier = "cmux-action-probe"
        let action = try #require(context.action(for: nil))
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        let updates = manager.profileRuntime.updates()
        let collector = Task { @MainActor in
            for await update in updates {
                if case .actionChanged(let actionUpdate) = update,
                   let item = actionUpdate.item {
                    return [item]
                }
            }
            return []
        }

        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        let items = await collector.value
        #expect(items.count == 1)
        #expect(items.allSatisfy { $0.id == context.uniqueIdentifier })
    }

    @available(macOS 15.4, *)
    @Test func loadingExtensionDoesNotEagerlyStartBackgroundContent() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["background"] = ["service_worker": "background.js"]
        let directory = try Self.writeExtension(
            named: "background-load-probe",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("background.js"),
            atomically: true,
            encoding: .utf8
        )

        let backgroundSelector = NSSelectorFromString("loadBackgroundContentWithCompletionHandler:")
        let backgroundMethod = try #require(class_getInstanceMethod(
            WKWebExtensionContext.self,
            backgroundSelector
        ))
        let originalBackgroundImplementation = method_getImplementation(backgroundMethod)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let backgroundReplacement: @convention(block) (
            WKWebExtensionContext,
            @escaping (NSError?) -> Void
        ) -> Void = { _, _ in
            loadCount.withLock { $0 += 1 }
        }
        let backgroundReplacementImplementation = imp_implementationWithBlock(backgroundReplacement)
        method_setImplementation(backgroundMethod, backgroundReplacementImplementation)
        defer {
            method_setImplementation(backgroundMethod, originalBackgroundImplementation)
            imp_removeBlock(backgroundReplacementImplementation)
        }

        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()

        #expect(manager.loadedContexts.count == 1)
        #expect(loadCount.withLock { $0 } == 0)
    }

    @available(macOS 15.4, *)
    @Test func actionInvocationDoesNotWaitForBackgroundLoadCallback() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["background"] = ["service_worker": "background.js"]
        manifest["action"] = ["default_title": "Background probe"]
        let directory = try Self.writeExtension(
            named: "background-action-probe",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("background.js"),
            atomically: true,
            encoding: .utf8
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )

        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }

        let backgroundSelector = NSSelectorFromString("loadBackgroundContentWithCompletionHandler:")
        let backgroundMethod = try #require(class_getInstanceMethod(
            WKWebExtensionContext.self,
            backgroundSelector
        ))
        let originalBackgroundImplementation = method_getImplementation(backgroundMethod)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let backgroundReplacement: @convention(block) (
            WKWebExtensionContext,
            @escaping (NSError?) -> Void
        ) -> Void = { _, _ in
            loadCount.withLock { $0 += 1 }
        }
        let backgroundReplacementImplementation = imp_implementationWithBlock(backgroundReplacement)
        method_setImplementation(backgroundMethod, backgroundReplacementImplementation)

        let actionSelector = NSSelectorFromString("performActionForTab:")
        let actionMethod = try #require(class_getInstanceMethod(
            WKWebExtensionContext.self,
            actionSelector
        ))
        let originalActionImplementation = method_getImplementation(actionMethod)
        let performCount = OSAllocatedUnfairLock(initialState: 0)
        let actionReplacement: @convention(block) (WKWebExtensionContext, AnyObject?) -> Void = { _, _ in
            performCount.withLock { $0 += 1 }
        }
        let actionReplacementImplementation = imp_implementationWithBlock(actionReplacement)
        method_setImplementation(actionMethod, actionReplacementImplementation)
        defer {
            method_setImplementation(backgroundMethod, originalBackgroundImplementation)
            imp_removeBlock(backgroundReplacementImplementation)
            method_setImplementation(actionMethod, originalActionImplementation)
            imp_removeBlock(actionReplacementImplementation)
        }

        let context = try #require(manager.loadedContexts.first)
        #expect(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: nil
        ))
        #expect(loadCount.withLock { $0 } == 0)
        #expect(performCount.withLock { $0 } == 1)
    }

    @available(macOS 15.4, *)
    @Test func extensionCanOpenTabFromToolbarAction() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        let selector = NSSelectorFromString(
            "webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:"
        )

        #expect(manager.responds(to: selector))
    }

    @available(macOS 15.4, *)
    @Test func staleTabActionSurfacesVisibleUnavailableFailure() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_title": "Stale tab probe"]
        let directory = try Self.writeExtension(
            named: "stale-tab-action-probe",
            in: root,
            manifest: manifest
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        let context = try #require(manager.loadedContexts.first)

        manager.unregister(panelID: panel.id)
        #expect(!manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: nil
        ))

        let item = try #require(manager.presentationSnapshot(for: panel.id).extensions.first)
        #expect(item.actionFailure == .actionUnavailable)
        #expect(!item.isAwaitingPopup)
    }

    @available(macOS 15.4, *)
    @Test func popupWaitsForWebKitReadyCallbackAndPresentsOnceFromUserAnchor() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["action"] = ["default_popup": "popup.html"]
        let directory = try Self.writeExtension(
            named: "direct-popup-probe",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        try "<main>Popup ready</main>".write(
            to: directory.appendingPathComponent("popup.html"),
            atomically: true,
            encoding: .utf8
        )

        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = NSButton(frame: NSRect(x: 20, y: 20, width: 40, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.close() }

        let actionSelector = NSSelectorFromString("performActionForTab:")
        let actionMethod = try #require(class_getInstanceMethod(
            WKWebExtensionContext.self,
            actionSelector
        ))
        let originalActionImplementation = method_getImplementation(actionMethod)
        let performCount = OSAllocatedUnfairLock(initialState: 0)
        let actionReplacement: @convention(block) (WKWebExtensionContext, AnyObject?) -> Void = { _, _ in
            performCount.withLock { $0 += 1 }
        }
        let actionReplacementImplementation = imp_implementationWithBlock(actionReplacement)
        method_setImplementation(actionMethod, actionReplacementImplementation)
        defer {
            method_setImplementation(actionMethod, originalActionImplementation)
            imp_removeBlock(actionReplacementImplementation)
        }

        let context = try #require(manager.loadedContexts.first)
        let tab = try #require(manager
            .webExtensionController(manager.controller, openWindowsFor: context)
            .flatMap { $0.tabs?(for: context) ?? [] }
            .first)
        let action = try #require(context.action(for: tab))
        let popover = try #require(action.popupPopover)

        #expect(!popover.isShown)
        #expect(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: anchor
        ))
        #expect(performCount.withLock { $0 } == 1)
        #expect(!popover.isShown)

        var presentationError: (any Error)?
        manager.webExtensionController(
            manager.controller,
            presentActionPopup: action,
            for: context
        ) { error in
            presentationError = error
        }

        #expect(presentationError == nil)
        #expect(popover.isShown)
        #expect(popover.positioningView === anchor)
        #expect(popover.positioningRect == anchor.bounds)
        #expect(performCount.withLock { $0 } == 1)
    }

    @available(macOS 15.4, *)
    @Test func mv2DefaultActionUpdateHandsFirstClickToDynamicPopupExactlyOnce() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialDirectory = try Self.writeExtension(
            named: "mv2-dynamic-initial",
            in: root,
            manifest: [
                "manifest_version": 2,
                "name": "Dynamic popup fixture",
                "version": "1.0",
                "browser_action": [:],
            ]
        )
        let updatedDirectory = try Self.writeExtension(
            named: "mv2-dynamic-updated",
            in: root,
            manifest: [
                "manifest_version": 2,
                "name": "Dynamic popup fixture",
                "version": "1.0",
                "browser_action": ["default_popup": "popup.html"],
            ]
        )
        try "<main>Dynamic popup ready</main>".write(
            to: updatedDirectory.appendingPathComponent("popup.html"),
            atomically: true,
            encoding: .utf8
        )

        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(initialDirectory)
        await manager.loadExtensions()
        let initialContext = try #require(manager.loadedContexts.first)
        let updatedContext = WKWebExtensionContext(
            for: try await WKWebExtension(resourceBaseURL: updatedDirectory)
        )
        updatedContext.uniqueIdentifier = initialContext.uniqueIdentifier

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        manager.register(
            panel: panel,
            ownerID: UUID(),
            activePanelID: { panel.id },
            focusPanel: { _ in }
        )
        defer { manager.unregister(panelID: panel.id) }
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = NSButton(frame: NSRect(x: 120, y: 160, width: 40, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.close() }

        let actionSelector = NSSelectorFromString("performActionForTab:")
        let actionMethod = try #require(class_getInstanceMethod(
            WKWebExtensionContext.self,
            actionSelector
        ))
        let originalActionImplementation = method_getImplementation(actionMethod)
        let performCount = OSAllocatedUnfairLock(initialState: 0)
        let actionReplacement: @convention(block) (WKWebExtensionContext, AnyObject?) -> Void = { _, _ in
            performCount.withLock { $0 += 1 }
        }
        let actionReplacementImplementation = imp_implementationWithBlock(actionReplacement)
        method_setImplementation(actionMethod, actionReplacementImplementation)
        defer {
            method_setImplementation(actionMethod, originalActionImplementation)
            imp_removeBlock(actionReplacementImplementation)
        }

        let initialTab = try #require(manager
            .webExtensionController(manager.controller, openWindowsFor: initialContext)
            .flatMap { $0.tabs?(for: initialContext) ?? [] }
            .first)
        let initialAction = try #require(initialContext.action(for: initialTab))
        #expect(!initialAction.presentsPopup)
        #expect(manager.performAction(
            uniqueIdentifier: initialContext.uniqueIdentifier,
            in: panel,
            anchorView: anchor
        ))
        #expect(performCount.withLock { $0 } == 1)

        let defaultUpdatedAction = try #require(updatedContext.action(for: nil))
        #expect(defaultUpdatedAction.associatedTab == nil)
        manager.webExtensionController(
            manager.controller,
            didUpdate: defaultUpdatedAction,
            forExtensionContext: updatedContext
        )
        manager.webExtensionController(
            manager.controller,
            didUpdate: defaultUpdatedAction,
            forExtensionContext: updatedContext
        )
        #expect(performCount.withLock { $0 } == 2)

        let updatedAction = try #require(updatedContext.action(for: initialTab))
        #expect(updatedAction.presentsPopup)
        var presentationError: (any Error)?
        manager.webExtensionController(
            manager.controller,
            presentActionPopup: updatedAction,
            for: updatedContext
        ) { presentationError = $0 }

        #expect(presentationError == nil)
        #expect(updatedAction.popupPopover?.isShown == true)
        #expect(updatedAction.popupPopover?.positioningView === anchor)
        #expect(performCount.withLock { $0 } == 2)

        manager.webExtensionController(
            manager.controller,
            didUpdate: defaultUpdatedAction,
            forExtensionContext: updatedContext
        )
        #expect(performCount.withLock { $0 } == 2)
    }

    @available(macOS 15.4, *)
    @Test func nativeInstallTargetsRequestedProfileDirectory() async throws {
        let managedRoot = try Self.makeExtensionsRoot()
        let sourceRoot = try Self.makeExtensionsRoot()
        defer {
            try? FileManager.default.removeItem(at: managedRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let source = try Self.writeExtension(
            named: "profile-install",
            in: sourceRoot,
            manifest: Self.minimalManifest
        )
        try "// no-op".write(
            to: source.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let services = BrowserServices(extensionDirectory: managedRoot)
        let profileID = UUID()

        let preview = try await services.prepareWebExtensionInstall(
            from: source,
            profileID: profileID
        )
        _ = try await services.confirmPreparedWebExtensionInstall(
            id: preview.id,
            grantedOptionalPermissions: [],
            grantedOptionalHosts: [],
            profileID: profileID
        )

        let profileDirectory = BrowserServices.extensionDirectory(
            for: profileID,
            defaultProfileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            root: managedRoot
        )
        let ledger = try await BrowserWebExtensionDirectoryRepository()
            .managementLedger(in: profileDirectory)
        let record = try #require(ledger.records[source.lastPathComponent])
        guard case .directory(let filename, _) = record.source else {
            Issue.record("Expected an immutable managed directory")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: profileDirectory.appendingPathComponent(filename).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: managedRoot.appendingPathComponent(source.lastPathComponent).path
        ))
        #expect(services.webExtensionsManager(for: profileID).directory == profileDirectory)
    }

    @available(macOS 15.4, *)
    @Test func replacementWebViewPreservesInjectedController() throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = BrowserServices(extensionDirectory: root)
        let panel = BrowserPanel(workspaceId: UUID(), browserServices: services)

        let replacement = panel.makeReplacementWebView(
            profileID: panel.profileID,
            websiteDataStore: .nonPersistent()
        )

        #expect(replacement.configuration.webExtensionController === services.webExtensionsManager?.controller)
    }

    @available(macOS 15.4, *)
    @Test func dockBrowserUsesDockWindowOwnershipAndUnregisters() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let services = BrowserServices(extensionDirectory: root)
        let manager = try #require(services.webExtensionsManager)
        let extensionContext = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: directory))
        let store = DockSplitStore(
            workspaceId: UUID(),
            browserServices: services,
            baseDirectoryProvider: { root.path },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let firstPanelID = try #require(store.newSurface(
            kind: .browser,
            inPane: rootPane,
            url: URL(string: "https://example.com"),
            focus: false
        ))
        let secondPanelID = try #require(store.newSurface(
            kind: .browser,
            inPane: rootPane,
            url: URL(string: "https://example.com/second"),
            focus: false
        ))
        let firstPanel = try #require(store.browserPanel(for: firstPanelID))
        let secondPanel = try #require(store.browserPanel(for: secondPanelID))
        store.focusPanel(firstPanelID)

        let windows = manager.webExtensionController(manager.controller, openWindowsFor: extensionContext)
        let dockWindow = try #require(windows.first(where: { window in
            (window.tabs?(for: extensionContext) ?? []).contains {
                $0.webView?(for: extensionContext) === firstPanel.webView
            }
        }))
        let registeredTabs = dockWindow.tabs?(for: extensionContext) ?? []
        #expect(registeredTabs.contains { $0.webView?(for: extensionContext) === firstPanel.webView })
        #expect(registeredTabs.contains { $0.webView?(for: extensionContext) === secondPanel.webView })
        #expect(dockWindow.activeTab?(for: extensionContext)?.webView?(for: extensionContext) === firstPanel.webView)

        let secondTab = try #require(registeredTabs.first {
            $0.webView?(for: extensionContext) === secondPanel.webView
        })
        let activate = try #require(secondTab.activate)
        await confirmation("Dock-owned extension tab activated") { activated in
            activate(extensionContext) { error in
                #expect(error == nil)
                activated()
            }
        }
        #expect(store.focusedPanelId == secondPanelID)

        let managerPage = try #require(store.openBrowserExtensionsManager(from: secondPanelID))
        #expect(managerPage !== secondPanel)
        #expect(managerPage.internalPage == .extensions)
        #expect(secondPanel.internalPage == nil)
        #expect(store.browserPanel(for: managerPage.id) === managerPage)
        #expect(store.openBrowserExtensionsManager(from: secondPanelID) === managerPage)

        #expect(store.closePanel(firstPanelID, force: true))
        let remainingTabs = manager
            .webExtensionController(manager.controller, openWindowsFor: extensionContext)
            .flatMap { $0.tabs?(for: extensionContext) ?? [] }
        #expect(!remainingTabs.contains { $0.webView?(for: extensionContext) === firstPanel.webView })
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedAwaitsStartedLoadTask() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        try await manager.approveInstalledCandidate(dir)
        manager.startLoading()
        await manager.waitUntilLoaded()

        #expect(manager.isLoaded)
        #expect(manager.loadErrors.isEmpty)
        #expect(manager.loadedContexts.count == 1)
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedReturnsPromptlyWhenCallerIsCancelled() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let profileID = UUID()
        let loadGate = RuntimeLoadGate()
        let runtime = BrowserWebExtensionProfileRuntime(
            profileID: profileID,
            waitForDeadline: { try await Task.sleep(for: .seconds(3600)) }
        )
        runtime.start { await loadGate.wait() }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            profileID: profileID,
            profileRuntime: runtime
        )

        let waiter = Task { @MainActor in
            await manager.waitUntilLoaded()
        }
        await Task.yield()
        waiter.cancel()
        await waiter.value
        loadGate.resume()
    }

    @available(macOS 15.4, *)
    @Test func mixedDeclaredAndUndeclaredPermissionRequestFailsClosedWithoutPresenting() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["optional_permissions"] = ["cookies"]
        manifest["optional_host_permissions"] = ["https://optional.example/*"]
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: manifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let promptCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            permissionPromptPresenter: { _, _ in
                promptCount.withLock { $0 += 1 }
                return .grant
            }
        )
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)

        let granted = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissions: [.cookies, .nativeMessaging],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        #expect(granted.isEmpty)
        let optionalURL = try #require(URL(string: "https://optional.example/page"))
        let undeclaredURL = try #require(URL(string: "https://undeclared.example/page"))
        let grantedURLs = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionToAccess: [optionalURL, undeclaredURL],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let optionalPattern = try #require(
            context.webExtension.optionalPermissionMatchPatterns.first
        )
        let undeclaredPattern = try WKWebExtension.MatchPattern(
            string: "https://undeclared.example/*"
        )
        let grantedPatterns = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionMatchPatterns: [optionalPattern, undeclaredPattern],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        #expect(grantedURLs.isEmpty)
        #expect(grantedPatterns.isEmpty)
        #expect(promptCount.withLock { $0 } == 0)
    }

    @available(macOS 15.4, *)
    @Test func optionalPermissionCanBeRequestedGrantedRelaunchedAndRevoked() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["optional_permissions"] = ["cookies"]
        manifest["optional_host_permissions"] = ["https://optional.example/*"]
        let directory = try Self.writeExtension(
            named: "optional-lifecycle",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let promptCount = OSAllocatedUnfairLock(initialState: 0)
        let firstManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            permissionPromptPresenter: { _, _ in
                promptCount.withLock { $0 += 1 }
                return .grant
            }
        )
        try await firstManager.approveInstalledCandidate(directory)
        await firstManager.loadExtensions()
        let firstContext = try #require(firstManager.loadedContexts.first)
        let optionalPattern = try #require(
            firstContext.webExtension.optionalPermissionMatchPatterns.first
        )
        #expect(firstContext.permissionStatus(for: .cookies) != .deniedExplicitly)
        #expect(firstContext.permissionStatus(for: optionalPattern) != .deniedExplicitly)
        #expect(firstContext.deniedPermissions[.cookies] == nil)
        #expect(firstContext.deniedPermissionMatchPatterns[optionalPattern] == nil)

        let grantedPermissions = await withCheckedContinuation { continuation in
            firstManager.webExtensionController(
                firstManager.controller,
                promptForPermissions: [.cookies],
                in: nil,
                for: firstContext
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let grantedPatterns = await withCheckedContinuation { continuation in
            firstManager.webExtensionController(
                firstManager.controller,
                promptForPermissionMatchPatterns: [optionalPattern],
                in: nil,
                for: firstContext
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let optionalURL = try #require(URL(string: "https://optional.example/page"))
        let grantedURLs = await withCheckedContinuation { continuation in
            firstManager.webExtensionController(
                firstManager.controller,
                promptForPermissionToAccess: [optionalURL],
                in: nil,
                for: firstContext
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        #expect(grantedPermissions == [.cookies])
        #expect(grantedPatterns == [optionalPattern])
        #expect(grantedURLs == [optionalURL])
        #expect(promptCount.withLock { $0 } == 3)

        let repository = BrowserWebExtensionDirectoryRepository()
        let grantedRecord = try #require(
            try await repository.managementLedger(in: root).records["optional-lifecycle"]
        )
        #expect(grantedRecord.grantedPermissions[WKWebExtension.Permission.cookies.rawValue] != nil)
        #expect(grantedRecord.grantedMatchPatterns[optionalPattern.string] != nil)
        #expect(grantedRecord.deniedPermissions.isEmpty)
        #expect(grantedRecord.deniedMatchPatterns.isEmpty)
        firstManager.shutdown()

        let relaunchedManager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        await relaunchedManager.loadExtensions()
        let relaunchedContext = try #require(relaunchedManager.loadedContexts.first)
        let relaunchedPattern = try #require(
            relaunchedContext.webExtension.optionalPermissionMatchPatterns.first
        )
        #expect(relaunchedContext.permissionStatus(for: .cookies) == .grantedExplicitly)
        #expect(relaunchedContext.permissionStatus(for: relaunchedPattern) == .grantedExplicitly)

        try await relaunchedManager.revokeOptionalPermissions(
            managementID: "optional-lifecycle"
        )
        #expect(relaunchedContext.permissionStatus(for: .cookies) != .grantedExplicitly)
        #expect(relaunchedContext.permissionStatus(for: relaunchedPattern) != .grantedExplicitly)
        let revokedRecord = try #require(
            try await repository.managementLedger(in: root).records["optional-lifecycle"]
        )
        #expect(revokedRecord.grantedPermissions[WKWebExtension.Permission.cookies.rawValue] == nil)
        #expect(revokedRecord.grantedMatchPatterns[relaunchedPattern.string] == nil)
        #expect(revokedRecord.deniedPermissions.isEmpty)
        #expect(revokedRecord.deniedMatchPatterns.isEmpty)
    }

    @available(macOS 15.4, *)
    @Test func allHostsOptionalPermissionCoversURLAndNarrowerPattern() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["optional_host_permissions"] = ["<all_urls>"]
        let directory = try Self.writeExtension(
            named: "optional-all-hosts",
            in: root,
            manifest: manifest
        )
        try "// no-op".write(
            to: directory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let promptCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            permissionPromptPresenter: { _, _ in
                promptCount.withLock { $0 += 1 }
                return .grant
            }
        )
        try await manager.approveInstalledCandidate(directory)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let requestedURL = try #require(URL(string: "https://narrow.example/page"))
        let requestedPattern = try WKWebExtension.MatchPattern(
            string: "https://narrow.example/*"
        )

        let grantedURLs = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionToAccess: [requestedURL],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let grantedPatterns = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionMatchPatterns: [requestedPattern],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }

        #expect(grantedURLs == [requestedURL])
        #expect(grantedPatterns == [requestedPattern])
        #expect(promptCount.withLock { $0 } == 2)
    }

    @available(macOS 15.4, *)
    @Test func requiredRuntimeRequestsFailClosedEvenWithGrantPresenter() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(
            to: dir.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let promptCount = OSAllocatedUnfairLock(initialState: 0)
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent(),
            permissionPromptPresenter: { _, _ in
                promptCount.withLock { $0 += 1 }
                return .grant
            }
        )
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()
        let context = try #require(manager.loadedContexts.first)
        let pageURL = try #require(URL(string: "https://example.com/page"))
        let matchPattern = try #require(context.webExtension.allRequestedMatchPatterns.first)

        let permissions = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissions: [.storage],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let urls = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionToAccess: [pageURL],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
        let patterns = await withCheckedContinuation { continuation in
            manager.webExtensionController(
                manager.controller,
                promptForPermissionMatchPatterns: [matchPattern],
                in: nil,
                for: context
            ) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }

        #expect(permissions.isEmpty)
        #expect(urls.isEmpty)
        #expect(patterns.isEmpty)
        #expect(promptCount.withLock { $0 } == 0)
    }

    @available(macOS 15.4, *)
    @Test func recordsErrorForInvalidManifestAndKeepsLoadingOthers() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        try await manager.approveInstalledCandidate(broken)
        try await manager.approveInstalledCandidate(dir)
        await manager.loadExtensions()

        #expect(manager.loadErrors.count == 1)
        #expect(manager.loadErrors.first?.url.lastPathComponent == "broken")
        #expect(manager.loadedContexts.count == 1)

        let snapshot = manager.presentationSnapshot()
        #expect(snapshot.state == .ready)
        #expect(snapshot.extensions.map(\.name) == ["cmux test extension"])
        #expect(snapshot.failures.map(\.entryName) == ["broken"])
    }

    @available(macOS 15.4, *)
    @Test func userFacingAndDiagnosticLoadFailuresDoNotExposeRawErrorDetails() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("private-package-name", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(broken)

        await manager.loadExtensions()

        let failure = try #require(manager.presentationSnapshot().failures.first)
        #expect(failure.message == String(
            localized: "browser.extensions.load.failed",
            defaultValue: "The extension could not be loaded."
        ))
        let payload = manager.diagnosticPayload()
        let loadErrors = try #require(payload["load_errors"] as? [[String: Any]])
        let loadError = try #require(loadErrors.first)
        #expect(loadError["message"] == nil)
        let error = try #require(loadError["error"] as? [String: Any])
        #expect(error["domain"] is String)
        #expect(error["code"] is Int)
        #expect(error["message"] == nil)
        #expect(error["user_info"] == nil)
    }

    @available(macOS 15.4, *)
    @Test func invalidApprovedPackageDoesNotBlockHealthyExtensions() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = try Self.writeExtension(
            named: "healthy",
            in: root,
            manifest: Self.minimalManifest
        )
        let damaged = try Self.writeExtension(
            named: "damaged",
            in: root,
            manifest: Self.minimalManifest
        )
        for directory in [healthy, damaged] {
            try "// no-op".write(
                to: directory.appendingPathComponent("content.js"),
                atomically: true,
                encoding: .utf8
            )
        }
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
        )
        try await manager.approveInstalledCandidate(healthy)
        try await manager.approveInstalledCandidate(damaged)
        try FileManager.default.createSymbolicLink(
            at: damaged.appendingPathComponent("post-approval-link"),
            withDestinationURL: healthy.appendingPathComponent("content.js")
        )

        await manager.loadExtensions()

        #expect(manager.loadedContexts.map(\.uniqueIdentifier) == [
            BrowserWebExtensionsManager.contextIdentifier(for: "healthy"),
        ])
        #expect(manager.loadErrors.map { $0.url.lastPathComponent } == ["damaged"])
    }
}

private final class DeclaredOversizedWebExtensionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let cancellationObserver = WebExtensionURLProtocolCancellationObserver()

    static func observeCancellation(_ observer: @escaping @Sendable () -> Void) {
        cancellationObserver.install(observer)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "9"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {
        Self.cancellationObserver.fire()
    }
}

private final class WebExtensionURLProtocolCancellationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (@Sendable () -> Void)?

    func install(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { self.observer = observer }
    }

    func fire() {
        let observer = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.observer = nil }
            return self.observer
        }
        observer?()
    }
}

private struct CountingByteSequence: AsyncSequence, Sendable {
    typealias Element = UInt8

    struct AsyncIterator: AsyncIteratorProtocol {
        let bytes: [UInt8]
        let state: CountingByteSequenceState
        var index = 0

        mutating func next() async -> UInt8? {
            state.recordNext()
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }
    }

    let bytes: [UInt8]
    let state: CountingByteSequenceState

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes, state: state)
    }
}

private final class CountingByteSequenceState: @unchecked Sendable {
    private let lock = NSLock()
    private var nextCount = 0
    private var cancellationCount = 0

    var snapshot: (nextCount: Int, cancellationCount: Int) {
        lock.withLock { (nextCount, cancellationCount) }
    }

    func recordNext() {
        lock.withLock { nextCount += 1 }
    }

    func recordCancellation() {
        lock.withLock { cancellationCount += 1 }
    }
}
