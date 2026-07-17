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
        #expect(context.currentPermissions.contains(.storage))
        #expect(!context.grantedPermissionMatchPatterns.isEmpty)
        #expect(manager.controller.extensionContexts.contains(context))
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

        #expect(updateCount.withLock { $0 } == 1)
    }

    @available(macOS 15.4, *)
    @Test func actionWarmsBackgroundContentImmediatelyBeforeInvocation() async throws {
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

        let selector = NSSelectorFromString("loadBackgroundContentWithCompletionHandler:")
        let method = try #require(class_getInstanceMethod(WKWebExtensionContext.self, selector))
        let originalImplementation = method_getImplementation(method)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let replacement: @convention(block) (
            WKWebExtensionContext,
            @escaping (NSError?) -> Void
        ) -> Void = { _, completionHandler in
            loadCount.withLock { $0 += 1 }
            completionHandler(nil)
        }
        let replacementImplementation = imp_implementationWithBlock(replacement)
        method_setImplementation(method, replacementImplementation)
        defer {
            method_setImplementation(method, originalImplementation)
            imp_removeBlock(replacementImplementation)
        }

        let context = try #require(manager.loadedContexts.first)
        #expect(manager.performAction(
            uniqueIdentifier: context.uniqueIdentifier,
            in: panel,
            anchorView: nil
        ))
        #expect(loadCount.withLock { $0 } == 1)
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
    @Test func waitUntilLoadedTimesOutWhenLoadHangs() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        let hungLoad = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        defer { hungLoad.cancel() }
        manager.loadTask = hungLoad

        // Must return via the timeout even though the load task never finishes,
        // so a hung extension load cannot block panel navigation forever.
        await manager.waitUntilLoaded(timeout: .milliseconds(50))

        #expect(!manager.isLoaded)
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedKeepsEachWaiterTimeoutIndependent() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        manager.loadTask = Task {}

        let longClock = BrowserWebExtensionsTestClock()
        let shortClock = BrowserWebExtensionsTestClock()
        let longWaiter = Task { @MainActor in
            await manager.waitUntilLoaded(timeout: .seconds(2), clock: longClock)
        }
        await longClock.waitUntilSleepers()

        let shortWaiter = Task { @MainActor in
            await manager.waitUntilLoaded(timeout: .seconds(1), clock: shortClock)
        }
        await shortClock.waitUntilSleepers()
        shortClock.advance(by: .seconds(1))
        await shortWaiter.value
        await Task.yield()

        #expect(longClock.sleeperCount == 1)
        longClock.advance(by: .seconds(2))
        await longWaiter.value
    }

    @available(macOS 15.4, *)
    @Test func waitUntilLoadedReturnsPromptlyWhenCallerIsCancelled() async throws {
        let root = try Self.makeExtensionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = BrowserWebExtensionsManager(directory: root, controllerConfiguration: .nonPersistent())
        manager.loadTask = Task {}

        let clock = BrowserWebExtensionsTestClock()
        let waiter = Task { @MainActor in
            await manager.waitUntilLoaded(timeout: .seconds(1), clock: clock)
        }
        await clock.waitUntilSleepers()
        waiter.cancel()
        await Task.yield()

        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(1))
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

private final class BrowserWebExtensionsTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []

    var now: Instant {
        lock.withLock { currentInstant }
    }

    var minimumResolution: Duration { .zero }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    if cancelledSleeperIDs.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else if deadline <= currentInstant {
                        continuation.resume()
                    } else {
                        sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    }
                    let waiters = parkWaiters
                    parkWaiters.removeAll()
                    return waiters
                }
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                let sleeper = sleepers.removeValue(forKey: id)
                if sleeper == nil { cancelledSleeperIDs.insert(id) }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleepers() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard sleepers.isEmpty else { return true }
                parkWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            currentInstant = currentInstant.advanced(by: duration)
            let dueIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadline <= currentInstant ? id : nil
            }
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
