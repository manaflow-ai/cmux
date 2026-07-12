import AppKit
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
        let allowTitle = String(
            localized: "browser.webExtension.permissionPrompt.allow",
            defaultValue: "Allow"
        )
        let alertObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                Self.button(in: window.contentView, titled: allowTitle)?.performClick(nil)
            }
        }
        defer { NotificationCenter.default.removeObserver(alertObserver) }

        let support = BrowserWebExtensionSupport()
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
    }

    @MainActor
    private static func button(in view: NSView?, titled title: String) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = button(in: subview, titled: title) {
                return button
            }
        }
        return nil
    }
}
