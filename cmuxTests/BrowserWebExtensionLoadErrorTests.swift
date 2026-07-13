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
