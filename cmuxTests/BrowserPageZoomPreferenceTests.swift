import Foundation
import CmuxBrowser
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserPageZoomPreferenceTests {
    @Test
    func savedZoomBecomesDefaultForNewBrowserPanels() throws {
        let suiteName = "cmux.browserPageZoomPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstPanel = BrowserPanel(workspaceId: UUID(), pageZoomDefaults: defaults)
        defer { firstPanel.close() }

        #expect(abs(firstPanel.currentPageZoomFactor() - 1.0) < 0.0001)
        #expect(firstPanel.setPageZoomFactor(0.8))
        #expect(abs(defaults.double(forKey: BrowserPageZoomPreference.storageKey) - 0.8) < 0.0001)

        let secondPanel = BrowserPanel(workspaceId: UUID(), pageZoomDefaults: defaults)
        defer { secondPanel.close() }

        #expect(abs(secondPanel.currentPageZoomFactor() - 0.8) < 0.0001)
    }

    @Test
    func noOpZoomDoesNotOverwriteAnotherPanelsLastUsedDefault() throws {
        let suiteName = "cmux.browserPageZoomPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstPanel = BrowserPanel(workspaceId: UUID(), pageZoomDefaults: defaults)
        defer { firstPanel.close() }
        let secondPanel = BrowserPanel(workspaceId: UUID(), pageZoomDefaults: defaults)
        defer { secondPanel.close() }
        let preference = BrowserPageZoomPreference(defaults: defaults)

        #expect(firstPanel.setPageZoomFactor(0.8))
        #expect(abs(preference.currentZoom() - 0.8) < 0.0001)

        #expect(!secondPanel.resetZoom())
        #expect(abs(preference.currentZoom() - 0.8) < 0.0001)
    }

    @Test
    func restoredSessionZoomDoesNotOverwriteLastUsedDefault() throws {
        let suiteName = "cmux.browserPageZoomPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preference = BrowserPageZoomPreference(defaults: defaults)
        preference.save(0.8)

        let panel = BrowserPanel(workspaceId: UUID(), pageZoomDefaults: defaults)
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: "https://example.com/restored",
            profileID: nil,
            shouldRenderWebView: false,
            pageZoom: 1.4,
            developerToolsVisible: false,
            backHistoryURLStrings: nil,
            forwardHistoryURLStrings: nil
        ))

        #expect(abs(panel.currentPageZoomFactor() - 1.4) < 0.0001)
        #expect(abs(preference.currentZoom() - 0.8) < 0.0001)

        let nextPanel = BrowserPanel(workspaceId: UUID(), pageZoomDefaults: defaults)
        defer { nextPanel.close() }

        #expect(abs(nextPanel.currentPageZoomFactor() - 0.8) < 0.0001)
    }

    @Test
    func storedZoomIsNormalizedIntoSupportedRange() throws {
        let suiteName = "cmux.browserPageZoomPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(99.0, forKey: BrowserPageZoomPreference.storageKey)
        let preference = BrowserPageZoomPreference(defaults: defaults)

        #expect(abs(preference.currentZoom() - BrowserPageZoomPreference.maximumZoom) < 0.0001)
        #expect(abs(preference.normalizeStoredZoom() - BrowserPageZoomPreference.maximumZoom) < 0.0001)
        #expect(abs(defaults.double(forKey: BrowserPageZoomPreference.storageKey) - Double(BrowserPageZoomPreference.maximumZoom)) < 0.0001)

        defaults.set("not-a-number", forKey: BrowserPageZoomPreference.storageKey)

        #expect(abs(preference.currentZoom() - BrowserPageZoomPreference.defaultZoom) < 0.0001)
        #expect(abs(preference.normalizeStoredZoom() - BrowserPageZoomPreference.defaultZoom) < 0.0001)
        #expect(abs(defaults.double(forKey: BrowserPageZoomPreference.storageKey) - Double(BrowserPageZoomPreference.defaultZoom)) < 0.0001)
    }
}
