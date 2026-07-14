import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserWebExtensionLoadErrorTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func toolbarVisibilityWriteFailurePublishesAnExtensionError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-toolbar-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: root.appendingPathComponent("cmux.json"))
        let entry = BrowserWebExtensionEntry(
            id: "toolbar-error-\(UUID().uuidString)",
            kind: .unpackedDirectory,
            path: "/nonexistent/toolbar-error",
            enabled: false
        )
        try await store.set([entry], for: catalog.browser.webExtensions)

        try FileManager.default.removeItem(at: root)
        try Data("not a directory".utf8).write(to: root)
        let support = BrowserWebExtensionSupport()
        support.settingsStore = store
        support.settingsKey = catalog.browser.webExtensions

        await support.persistToolbarButtonVisibility(false, entryID: entry.id)

        #expect(support.loadErrorsByEntryID[entry.id] != nil)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func removingInvalidConfiguredEntryPrunesItsLoadError() async {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let entry = BrowserWebExtensionEntry(
            id: "invalid-extension-\(UUID().uuidString)",
            kind: .unpackedDirectory,
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .path,
            enabled: true
        )
        let support = BrowserWebExtensionSupport()

        await support.apply(entries: [entry])
        #expect(support.loadErrorsByEntryID[entry.id] != nil)

        await support.apply(entries: [])
        #expect(support.loadErrorsByEntryID.isEmpty)
    }
}
