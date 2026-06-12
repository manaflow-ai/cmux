import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for ``CmuxEditorSaveRegistry`` capability lifetime: the
/// sliding TTL reaps clean, abandoned registrations, but a buffer with unsaved
/// changes is pinned so a long-idle dirty editor never loses its save
/// capability (and then refuses the user's save).
struct EditorSaveRegistryExpiryTests {
    private let validToken = "abcdef0123456789token"
    private let origin = "cmux-diff-viewer://abcdef0123456789token"

    /// Creates a real on-disk file so `register` (which requires the target to
    /// exist and not be a directory) accepts it. Returned URL is in a unique
    /// temp dir the caller need not clean up for the test to be valid.
    private func makeTempFile() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-editor-save-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("doc.txt", isDirectory: false)
        try "hello".data(using: .utf8)!.write(to: file)
        return file
    }

    @Test func cleanRegistrationReapedAfterTTL() throws {
        let registry = CmuxEditorSaveRegistry()
        let file = try makeTempFile()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try registry.register(token: validToken, fileURL: file, expectedOrigin: origin, now: t0)

        // Within the TTL: resolves.
        #expect(registry.fileURL(forToken: validToken, requestOrigin: origin, now: t0.addingTimeInterval(60)) != nil)
        // Past the 24h TTL with no unsaved changes: reaped.
        #expect(registry.fileURL(forToken: validToken, requestOrigin: origin, now: t0.addingTimeInterval(25 * 60 * 60)) == nil)
    }

    @Test func dirtyBufferPinnedPastTTL() throws {
        let registry = CmuxEditorSaveRegistry()
        let file = try makeTempFile()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        try registry.register(token: validToken, fileURL: file, expectedOrigin: origin, now: t0)

        // Page reports unsaved changes shortly after open.
        registry.setUnsavedChanges(true, forToken: validToken, requestOrigin: origin, now: t0.addingTimeInterval(60))
        // Even far past the TTL, the capability survives because it is pinned:
        // this is the case a plain sliding TTL would have silently reaped.
        #expect(registry.fileURL(forToken: validToken, requestOrigin: origin, now: t0.addingTimeInterval(72 * 60 * 60)) != nil)
    }

    @Test func savedBufferUnpinsAndReapsAfterTTL() throws {
        let registry = CmuxEditorSaveRegistry()
        let file = try makeTempFile()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        try registry.register(token: validToken, fileURL: file, expectedOrigin: origin, now: t0)

        registry.setUnsavedChanges(true, forToken: validToken, requestOrigin: origin, now: t0.addingTimeInterval(60))
        // Buffer is saved (clean): unpin and re-baseline the TTL.
        let savedAt = t0.addingTimeInterval(120)
        registry.setUnsavedChanges(false, forToken: validToken, requestOrigin: origin, now: savedAt)
        // Still live just after the save.
        #expect(registry.fileURL(forToken: validToken, requestOrigin: origin, now: savedAt.addingTimeInterval(60)) != nil)
        // Reaped once the TTL lapses from the clean baseline.
        #expect(registry.fileURL(forToken: validToken, requestOrigin: origin, now: savedAt.addingTimeInterval(25 * 60 * 60)) == nil)
    }

    @Test func originMismatchNeverResolves() throws {
        let registry = CmuxEditorSaveRegistry()
        let file = try makeTempFile()
        let t0 = Date(timeIntervalSince1970: 4_000_000)
        try registry.register(token: validToken, fileURL: file, expectedOrigin: origin, now: t0)

        #expect(registry.fileURL(forToken: validToken, requestOrigin: "cmux-diff-viewer://someone-else", now: t0) == nil)
        // A pin attempt from the wrong origin is a no-op: the real origin still resolves.
        registry.setUnsavedChanges(true, forToken: validToken, requestOrigin: "cmux-diff-viewer://someone-else", now: t0)
        #expect(registry.fileURL(forToken: validToken, requestOrigin: origin, now: t0.addingTimeInterval(60)) != nil)
    }
}
