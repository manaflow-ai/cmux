import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Changing `sidebar.hiddenStatusKeys` must reach already-cached workspace
/// rows. `SidebarRowSnapshotCache` reuses a cached row while its
/// `PresentationKey` is unchanged, so the hidden set has to be part of the key.
@Suite(.serialized)
@MainActor
struct SidebarHiddenStatusKeysTests {
    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarHiddenStatusKeysTests.\(UUID().uuidString)")!
    }

    @Test
    func hidingAKeyInvalidatesCachedRowSnapshots() {
        let plain = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        #expect(plain.details.hiddenStatusKeys.isEmpty)

        let hidingDefaults = Self.makeDefaults()
        hidingDefaults.set(["claude_code"], forKey: SidebarCatalogSection().hiddenStatusKeys.userDefaultsKey)
        let hiding = SidebarTabItemSettingsSnapshot(defaults: hidingDefaults)
        #expect(hiding.details.hiddenStatusKeys == ["claude_code"])

        #expect(
            SidebarWorkspaceSnapshotFactory.presentationKey(settings: plain, showsAgentActivity: true, customColorHex: nil)
                != SidebarWorkspaceSnapshotFactory.presentationKey(settings: hiding, showsAgentActivity: true, customColorHex: nil)
        )
    }
}
