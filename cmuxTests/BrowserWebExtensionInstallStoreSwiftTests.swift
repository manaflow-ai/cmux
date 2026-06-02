import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Browser web extension install store")
struct BrowserWebExtensionInstallStoreSwiftTests {
    @Test("revalidated direct app extension requires current Developer Mode")
    func revalidatedDirectAppExtensionRequiresCurrentDeveloperMode() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BrowserWebExtensionInstallStore(
            registryURL: root.appendingPathComponent("registry.json")
        )
        let appexURL = root.appendingPathComponent("Bitwarden.appex", isDirectory: true)
        try createAppExtension(at: appexURL, bundleIdentifier: "com.example.Bitwarden.Extension")
        let record = try await store.installRecord(
            from: try store.discoverSource(from: appexURL, developerModeEnabled: true),
            displayName: "Bitwarden",
            displayVersion: "1.0",
            grantedPermissions: ["storage"],
            grantedPermissionMatchPatterns: [],
            profileID: try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )

        do {
            _ = try store.revalidatedSource(for: record, developerModeEnabled: false)
            Issue.record("Expected Developer Mode to be required for direct .appex revalidation.")
        } catch BrowserWebExtensionInstallError.developerModeRequired(let url) {
            #expect(url == appexURL.standardizedFileURL)
        } catch {
            Issue.record("Expected developerModeRequired, got \(error).")
        }
    }

    @Test("revalidated embedded app extension keeps stored appex when containing app has another extension")
    func revalidatedEmbeddedAppExtensionKeepsStoredAppExtensionWhenContainingAppHasAnotherExtension() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("Passwords.app", isDirectory: true)
        let pluginsURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
        let appexURL = pluginsURL
            .appendingPathComponent("Passwords.appex", isDirectory: true)
        try createAppExtension(at: appexURL, bundleIdentifier: "com.example.Passwords.Extension")
        let store = BrowserWebExtensionInstallStore(
            registryURL: root.appendingPathComponent("registry.json")
        )
        let source = try store.discoverSource(from: appURL, developerModeEnabled: true)
        let record = try await store.installRecord(
            from: source,
            displayName: "Passwords",
            displayVersion: "1.0",
            grantedPermissions: ["storage"],
            grantedPermissionMatchPatterns: [],
            profileID: try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
        try createAppExtension(
            at: pluginsURL.appendingPathComponent("PasswordsHelper.appex", isDirectory: true),
            bundleIdentifier: "com.example.Passwords.HelperExtension"
        )

        let revalidated = try store.revalidatedSource(for: record, developerModeEnabled: true)

        #expect(revalidated.url == appexURL.standardizedFileURL)
        #expect(revalidated.containingAppURL == appURL.standardizedFileURL)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-browser-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createAppExtension(
        at appexURL: URL,
        bundleIdentifier: String,
        extensionPointIdentifier: String = "com.apple.Safari.web-extension"
    ) throws {
        let contentsURL = appexURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try Data("""
        {
          "manifest_version": 3,
          "name": "Safari Extension",
          "version": "1.0"
        }
        """.utf8).write(to: resourcesURL.appendingPathComponent("manifest.json"))

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": appexURL.deletingPathExtension().lastPathComponent,
            "NSExtension": [
                "NSExtensionPointIdentifier": extensionPointIdentifier,
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }
}
