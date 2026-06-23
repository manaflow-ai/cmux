import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the editor view-state sidecar round-trip on
/// ``CmuxEditorSaveRegistry``: scroll/cursor/selection/folding persisted before
/// a webview unload must come back byte-for-byte on the next mount, including
/// for read-only files (the sidecar is keyed by the scheme token, not the write
/// capability). A temp trusted root keeps the test off the shared /tmp dir.
struct EditorViewStateSidecarTests {
    private let validToken = "abcdef0123456789token"

    private func makeRegistry() throws -> (CmuxEditorSaveRegistry, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-viewstate-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (CmuxEditorSaveRegistry(trustedRootURL: dir), dir)
    }

    /// Marks `token` as a real served page by writing its manifest, which the
    /// registry requires before it will read/write view state.
    private func writeManifest(forToken token: String, in dir: URL) throws {
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".manifest-\(token).json"))
    }

    @Test func roundTripsViewState() throws {
        let (registry, dir) = try makeRegistry()
        try writeManifest(forToken: validToken, in: dir)
        let payload = #"{"cursorState":[],"viewState":{"scrollTop":420,"scrollLeft":0}}"#
        let data = Data(payload.utf8)

        #expect(registry.loadViewState(forToken: validToken) == nil)
        #expect(registry.storeViewState(data, forToken: validToken) == true)

        let loaded = try #require(registry.loadViewState(forToken: validToken))
        let object = try #require(try JSONSerialization.jsonObject(with: loaded) as? [String: Any])
        let inner = object["viewState"] as? [String: Any]
        #expect(inner?["scrollTop"] as? Int == 420)
    }

    @Test func overwritesPreviousViewState() throws {
        let (registry, dir) = try makeRegistry()
        try writeManifest(forToken: validToken, in: dir)
        registry.storeViewState(Data(#"{"scrollTop":10}"#.utf8), forToken: validToken)
        registry.storeViewState(Data(#"{"scrollTop":99}"#.utf8), forToken: validToken)
        let loaded = try #require(registry.loadViewState(forToken: validToken))
        let object = try #require(try JSONSerialization.jsonObject(with: loaded) as? [String: Any])
        #expect(object["scrollTop"] as? Int == 99)
    }

    @Test func rejectsInvalidToken() throws {
        let (registry, _) = try makeRegistry()
        // Too short for CmuxDiffViewerURLSchemeHandler.isValidToken.
        #expect(registry.storeViewState(Data("{}".utf8), forToken: "short") == false)
        #expect(registry.loadViewState(forToken: "short") == nil)
    }

    @Test func sidecarIsOwnerOnly() throws {
        let (registry, dir) = try makeRegistry()
        try writeManifest(forToken: validToken, in: dir)
        registry.storeViewState(Data("{}".utf8), forToken: validToken)
        let url = dir.appendingPathComponent(".viewstate-\(validToken).json")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func rejectsTokenWithoutServedManifest() throws {
        let (registry, _) = try makeRegistry()
        // No manifest written: the token never served a real page, so view
        // state must not be persisted or read (capability gate).
        #expect(registry.storeViewState(Data(#"{"scrollTop":1}"#.utf8), forToken: validToken) == false)
        #expect(registry.loadViewState(forToken: validToken) == nil)
    }
}
