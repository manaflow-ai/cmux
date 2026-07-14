import CmuxSettings
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserWebExtensionInitialPermissionTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func approvedFirstLoadGrantsRequiredManifestAccess() async throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let extensionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: extensionDirectory) }

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Permission Test Extension",
          "version": "1.0",
          "permissions": ["tabs"],
          "host_permissions": ["https://*.example.com/*"]
        }
        """
        try Data(manifest.utf8).write(
            to: extensionDirectory.appendingPathComponent("manifest.json")
        )

        let entry = BrowserWebExtensionEntry(
            id: "permission-test-\(UUID().uuidString)",
            kind: .unpackedDirectory,
            path: extensionDirectory.path,
            enabled: true
        )
        let support = BrowserWebExtensionSupport(permissionConfirmation: { _ in true })
        defer { _ = support.unloadAllWebExtensions() }
        defer {
            support.permissionStateStore.removeState(
                for: entry.id,
                standardizedPath: entry.standardizedResourceRootPath
            )
        }

        await support.apply(entries: [entry])

        let context = try #require(support.context(forActionID: entry.id))
        let permissions = context.webExtension.requestedPermissions
        let matchPatterns = context.webExtension.requestedPermissionMatchPatterns
        #expect(!permissions.isEmpty)
        #expect(!matchPatterns.isEmpty)
        #expect(permissions.allSatisfy {
            context.permissionStatus(for: $0) == .grantedExplicitly
        })
        #expect(matchPatterns.allSatisfy {
            context.permissionStatus(for: $0) == .grantedExplicitly
        })
        #expect(support.actionSnapshots(for: UUID()).isEmpty)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func declaredActionProducesToolbarSnapshot() async throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let extensionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-action-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: extensionDirectory) }

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Action Test Extension",
          "version": "1.0",
          "action": { "default_title": "Run Action" }
        }
        """
        try Data(manifest.utf8).write(
            to: extensionDirectory.appendingPathComponent("manifest.json")
        )

        let entry = BrowserWebExtensionEntry(
            id: "action-test-\(UUID().uuidString)",
            kind: .unpackedDirectory,
            path: extensionDirectory.path,
            enabled: true
        )
        let support = BrowserWebExtensionSupport()
        defer { _ = support.unloadAllWebExtensions() }

        await support.apply(entries: [entry])

        let snapshot = try #require(support.actionSnapshots(for: UUID()).first)
        #expect(snapshot.id == entry.id)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func permissionPromptReentrancyDoesNotCommitAStaleLoadGeneration() async throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let extensionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-stale-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: extensionDirectory) }

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Stale Load Test Extension",
          "version": "1.0",
          "permissions": ["tabs"]
        }
        """
        try Data(manifest.utf8).write(
            to: extensionDirectory.appendingPathComponent("manifest.json")
        )

        let entry = BrowserWebExtensionEntry(
            id: "stale-load-test-\(UUID().uuidString)",
            kind: .unpackedDirectory,
            path: extensionDirectory.path,
            enabled: true
        )
        let generationChangeNotification = Notification.Name(
            "cmuxTests.browserWebExtension.staleLoadGeneration"
        )
        let support = BrowserWebExtensionSupport(permissionConfirmation: { _ in
            NotificationCenter.default.post(name: generationChangeNotification, object: nil)
            return true
        })
        let generationChangeObserver = NotificationCenter.default.addObserver(
            forName: generationChangeNotification,
            object: nil,
            queue: .main
        ) { [weak support] _ in
            MainActor.assumeIsolated {
                support?.settingsLoadGeneration &+= 1
            }
        }
        defer { NotificationCenter.default.removeObserver(generationChangeObserver) }
        defer { _ = support.unloadAllWebExtensions() }
        defer {
            support.permissionStateStore.removeState(
                for: entry.id,
                standardizedPath: entry.standardizedResourceRootPath
            )
        }

        await support.apply(entries: [entry])

        #expect(support.context(forActionID: entry.id) == nil)
        #expect(support.controller.extensionContexts.isEmpty)
    }

}
