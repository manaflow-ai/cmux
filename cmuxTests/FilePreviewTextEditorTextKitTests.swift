import AppKit
import Testing
import struct CmuxSettings.AppCatalogSection
import struct CmuxSettings.FileRouteSettingsStore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the note / file-preview editor TextKit hang (issue #5255,
/// same root-cause family as #4576).
///
/// The freeze is an AppKit modal mouse-tracking loop: `NSTextView.mouseDown` ->
/// `_bellerophonTrackMouseWithMouseDownEvent` -> `NSTextSelectionNavigation`
/// `.textSelectionsInteractingAtPoint` (TextKit 2) -> recursive O(N)
/// `synchronizeTextLayoutManagers`, which pegs the main thread at 100% CPU and freezes
/// the whole app. That TextKit 2 selection path is taken whenever the view has a live
/// `textLayoutManager`.
///
/// The previous mitigation only *read* `.layoutManager`, which merely puts the view in
/// TextKit 2 *compatibility* mode — `textLayoutManager` stays non-nil and the slow
/// selection path remains active (proven by live `sample` captures of the hung process).
/// The structural invariant that actually prevents the hang is that the editor must be a
/// **pure TextKit 1** view, i.e. `textLayoutManager == nil`.
///
/// Note: the existing timing test (`testLargeFileSelectionHitTestStaysResponsive`)
/// exercises `characterIndexForInsertion`, which uses the fast `NSLayoutManager` path
/// even in compatibility mode, so it cannot detect a regression back to the TextKit 2
/// selection path. This invariant test can, with no UI or timing dependency.
@MainActor
@Suite("File preview editor TextKit backing")
struct FilePreviewTextEditorTextKitTests {
    @Test("makeFilePreviewTextView is a pure TextKit 1 view (no TextKit 2 selection path)")
    func editorIsPureTextKit1() {
        let textView = SavingTextView.makeFilePreviewTextView()

        // Primary invariant. A TextKit 2 view — or one only dropped to TextKit 2
        // compatibility mode by reading `.layoutManager` — exposes a non-nil
        // `textLayoutManager`, and its selection runs through NSTextSelectionNavigation:
        // the O(N)-per-hit-test main-thread hang. A pure TextKit 1 view has nil here.
        #expect(textView.textLayoutManager == nil)

        // The TextKit 1 stack must be live, with lazy (non-contiguous) glyph layout so
        // multi-hundred-thousand-line documents still open instantly.
        #expect(textView.layoutManager != nil)
        #expect(textView.layoutManager?.allowsNonContiguousLayout == true)
    }

    @Test
    func cmdShiftClickSupportedFileRouteUsesDefaultApplicationOnlyWhenCmuxWouldRoute() throws {
        let suiteName = "cmux.file-preview-routing-bypass.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = FileRouteSettingsStore(defaults: defaults)
        #expect(CommandClickFileOpenRouter.route(path: fileURL.path, modifierFlags: [.command], routeSettings: store) == .cmux)
        #expect(CommandClickFileOpenRouter.route(path: fileURL.path, modifierFlags: [.command, .shift], routeSettings: store) == .defaultApplication)
        #expect(CommandClickFileOpenRouter.route(path: fileURL.path, modifierFlags: [.command, .shift, .option], routeSettings: store) == .cmux)
        #expect(CommandClickFileOpenRouter.route(path: directoryURL.path, modifierFlags: [.command, .shift], routeSettings: store) == .fallback)

        defaults.set(false, forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey)
        #expect(CommandClickFileOpenRouter.route(path: fileURL.path, modifierFlags: [.command, .shift], routeSettings: store) == .fallback)
    }

    private func temporaryTextFile() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try "preview me".write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
