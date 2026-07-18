import AppKit
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

    @Test func verifiedCatalogUsesUniqueHTTPSVersionPinnedPackages() throws {
        let entries = BrowserWebExtensionCatalog.verifiedEntries

        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.allSatisfy { $0.packageURL.scheme == "https" })
        #expect(entries.allSatisfy { !$0.version.isEmpty })
        #expect(entries.allSatisfy { $0.packageSHA256.count == 64 })
    }

    @Test func verifiedCatalogPinsPortableOnePasswordPackage() throws {
        let entry = try #require(BrowserWebExtensionCatalog.entry(id: "1password"))

        #expect(entry.version == "8.12.28.25")
        #expect(entry.packageURL.absoluteString
            == "https://addons.mozilla.org/firefox/downloads/file/4899098/1password_x_password_manager-8.12.28.25.xpi")
        #expect(entry.packageSHA256
            == "fc369b5ee7958a57c519aa37e7ba540ebe08d58b4bc976fab1ba2e91bc01bc25")
    }

    @Test func toolbarExtensionIconMatchesBrowserChromeScale() {
        #expect(BrowserExtensionIconMetrics.toolbarContentSize(iconPointSize: 11) == 13)
        #expect(BrowserExtensionIconMetrics.toolbarContentSize(iconPointSize: 16) == 18)
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
        #expect(context.uniqueIdentifier == "cmux-browser-extension-sample")
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
            == "cmux-browser-extension-com.example.password-manager.safari")
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
            == "cmux-browser-extension-com.example.password-manager.safari")
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
        let identifier = "cmux-browser-extension-pinned-action"
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
        #expect(manager.loadTask == nil)
    }

    @Test func installedSafariAppsAreOptInSuggestions() {
        let applicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let installedPaths = Set([
            applicationsDirectory.appendingPathComponent("Bitwarden.app").path,
            applicationsDirectory.appendingPathComponent("1Password for Safari.app").path,
            applicationsDirectory.appendingPathComponent("uBlock Origin Lite.app").path,
        ])

        let items = BrowserExtensionsManagerPage.availableLocalApps(
            applicationsDirectories: [applicationsDirectory],
            fileExists: { installedPaths.contains($0) }
        )

        #expect(items.map(\.id) == [
            "bitwarden-safari-app",
            "ublock-origin-lite-safari-app",
        ])
        #expect(items.map(\.installedIdentifierPrefix) == [
            "cmux-browser-extension-com.bitwarden.desktop.safari",
            "cmux-browser-extension-net.raymondhill.uBlock-Origin-Lite.Extension",
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
                == "Version/18.4 Safari/605.1.15 cmux"
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
        let alternateManager = services.webExtensionsManager(for: alternateProfile.id)
        alternateManager.loadTask = Task {}
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: try #require(URL(string: "https://example.com/profile-restore")),
            browserServices: services
        )
        defer { panel.close() }

        #expect(panel.switchToProfile(alternateProfile.id))
        #expect(panel.isWaitingForWebExtensionsBeforeNavigation)

        await alternateManager.loadExtensions()
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
        let manager = try #require(services.webExtensionsManager)
        manager.loadTask = Task {}
        let panel = BrowserPanel(workspaceId: UUID(), browserServices: services)
        defer { panel.close() }
        var deferredNavigationCount = 0

        panel.runWhenWebExtensionsLoaded {
            deferredNavigationCount += 1
        }
        panel.navigate(to: try #require(URL(string: "https://example.com/newer")))
        await manager.loadExtensions()
        for _ in 0..<4 { await Task.yield() }

        #expect(deferredNavigationCount == 0)
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
    @Test func repeatedActionMutationsCoalesceIntoOneToolbarUpdate() async throws {
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
        let updateCount = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .browserWebExtensionActionDidChange,
            object: context.uniqueIdentifier,
            queue: nil
        ) { _ in
            updateCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        manager.webExtensionController(manager.controller, didUpdate: action, forExtensionContext: context)
        for _ in 0..<4 { await Task.yield() }

        #expect(updateCount.withLock { $0 } == 0)
        try await Task.sleep(for: .milliseconds(100))

        #expect(updateCount.withLock { $0 } == 1)
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
    @Test func userPopupActionPresentsWithoutWaitingForWebKitDelegate() async throws {
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
        #expect(popover.isShown)
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

        _ = try await services.installWebExtension(from: source, profileID: profileID)

        let profileDirectory = BrowserServices.extensionDirectory(
            for: profileID,
            defaultProfileID: BrowserProfileStore.shared.builtInDefaultProfileID,
            root: managedRoot
        )
        #expect(FileManager.default.fileExists(
            atPath: profileDirectory.appendingPathComponent(source.lastPathComponent).path
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

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        manager.loadTask = Task {}

        let waiter = Task { @MainActor in
            await manager.waitUntilLoaded()
        }
        await Task.yield()
        waiter.cancel()
        await waiter.value
    }

    @available(macOS 15.4, *)
    @Test func runtimePermissionPromptsDenyOptionalManifestPermissionsWithoutAlert() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = Self.minimalManifest
        manifest["optional_permissions"] = ["cookies"]
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: manifest)
        try "// no-op".write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
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
    }

    @available(macOS 15.4, *)
    @Test func runtimePermissionCallbacksNeverGrantOrPresentDeclaredAccess() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.writeExtension(named: "sample", in: root, manifest: Self.minimalManifest)
        try "// no-op".write(
            to: dir.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )
        let manager = BrowserWebExtensionsManager(
            directory: root,
            controllerConfiguration: .nonPersistent()
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
        #expect(snapshot.directoryPath == root.path)
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

        #expect(manager.loadedContexts.map(\.uniqueIdentifier) == ["cmux-browser-extension-healthy"])
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
