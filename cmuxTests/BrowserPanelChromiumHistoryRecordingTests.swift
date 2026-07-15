import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserPanelChromiumHistoryRecordingTests {
    @Test
    func recordsEachCompletedNavigationOnceDespiteTitleUpdates() async throws {
        let url = try #require(URL(string: "https://example.com/chromium-history"))
        let profileStore = BrowserProfileStore.shared
        let profile = try #require(profileStore.createProfile(
            named: "Chromium-History-\(UUID().uuidString)"
        ))
        let historyStore = profileStore.historyStore(for: profile.id)
        historyStore.clearHistory()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: profile.id,
            renderInitialNavigation: false,
            engineSelection: BrowserEngineSelection(kind: .chromium)
        )

        panel.applyChromiumEngineState(BrowserEngineState(
            url: url,
            title: "Initial title",
            navigationCompletionRevision: 1
        ))
        panel.applyChromiumEngineState(BrowserEngineState(
            url: url,
            title: "Updated by the page",
            navigationCompletionRevision: 1
        ))

        #expect(historyStore.entries.first?.visitCount == 1)

        panel.applyChromiumEngineState(BrowserEngineState(
            url: url,
            title: "Reloaded title",
            navigationCompletionRevision: 2
        ))

        #expect(historyStore.entries.first?.visitCount == 2)
        panel.close()
        historyStore.clearHistory()
        let deletedProfile = await profileStore.deleteProfile(id: profile.id)
        #expect(deletedProfile?.id == profile.id)
    }
}
