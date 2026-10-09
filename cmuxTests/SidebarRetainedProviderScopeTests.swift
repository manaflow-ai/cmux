import Foundation
import Testing
@testable import cmux_DEV

/// Which sidebar providers keep the native table retained while hidden.
/// Moved out of `SidebarHiddenPresentationTests` unchanged.
@MainActor
@Suite(.serialized, .exclusiveAppContext)
struct SidebarRetainedProviderScopeTests {
    @Test
    func persistenceIsScopedToDefaultProvider() throws {
        #expect(
            ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
            )
        )
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: CmuxExtensionSidebarSelection.hostedExtensionsProviderId
            )
        )
        let bundledProviderId = try #require(CmuxExtensionSidebarSelection.providers.first?.descriptor.id)
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: bundledProviderId
            )
        )

        let customSidebarsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-visibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: customSidebarsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customSidebarsDirectory) }
        let customProviderId = CmuxExtensionSidebarSelection.customSidebarProviderPrefix + "lifecycle-test"
        try Data().write(to: customSidebarsDirectory.appendingPathComponent("lifecycle-test.swift"))
        CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(customSidebarsDirectory) {
            #expect(
                !ContentView.retainsDefaultAppKitSidebar(
                    appKitListEnabled: true,
                    effectiveProviderId: customProviderId
                )
            )
        }
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: false,
                effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
            )
        )
    }
}
