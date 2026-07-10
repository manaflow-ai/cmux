import AppKit
import CmuxSettings
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserWebExtensionSupportTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func keyWindowSwitchRestoresThatWindowsActiveExtensionTab() {
        let support = BrowserWebExtensionSupport()
        let firstPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://first.example"),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let secondPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://second.example"),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        firstWindow.contentView = firstPanel.webView
        secondWindow.contentView = secondPanel.webView
        defer {
            firstPanel.close()
            secondPanel.close()
            firstWindow.close()
            secondWindow.close()
        }

        support.register(panel: firstPanel)
        support.register(panel: secondPanel)
        support.noteActivated(panelID: firstPanel.id)
        support.noteActivated(panelID: secondPanel.id)
        #expect(support.activePanelID == secondPanel.id)

        support.noteWindowBecameKey(firstWindow)

        #expect(support.activePanelID == firstPanel.id)
        #expect((support.webExtensionWindow(for: firstWindow) as AnyObject?) === support.windowAdapter)
        let unrelatedWindow = NSWindow()
        #expect(support.webExtensionWindow(for: unrelatedWindow) == nil)
        #expect((support.focusedWebExtensionWindow(for: firstWindow) as AnyObject?) === support.windowAdapter)
        #expect(support.focusedWebExtensionWindow(for: unrelatedWindow) == nil)
        #expect(support.focusedWebExtensionWindow(for: nil) == nil)
    }

    @Test
    func reconciliationSkipsEnvPathWhenSettingsEntryIsDisabled() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: false
                ),
            ],
            environmentPaths: [appexPath],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.isEmpty)
        #expect(plan.loadEntries.isEmpty)
        #expect(plan.unloadEntryIDs.isEmpty)
    }

    @Test
    func reconciliationSkipsEnvResourceRootWhenSettingsEntryIsDisabled() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let resourcePath = "\(appexPath)/Contents/Resources"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: false
                ),
            ],
            environmentPaths: [resourcePath],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.isEmpty)
        #expect(plan.loadEntries.isEmpty)
        #expect(plan.unloadEntryIDs.isEmpty)
    }

    @Test
    func reconciliationDoesNotLoadSamePathTwice() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: true
                ),
            ],
            environmentPaths: [appexPath],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.map(\.id) == ["com.bitwarden.desktop.safari"])
        #expect(plan.loadEntries.map(\.id) == ["com.bitwarden.desktop.safari"])
    }

    @Test
    func reconciliationDoesNotLoadBundleAndResourceRootTwice() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let resourcePath = "\(appexPath)/Contents/Resources"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: true
                ),
                BrowserWebExtensionEntry(
                    id: resourcePath,
                    kind: .unpackedDirectory,
                    path: resourcePath,
                    enabled: true
                ),
            ],
            environmentPaths: [],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.map(\.id) == ["com.bitwarden.desktop.safari"])
        #expect(plan.loadEntries.map(\.id) == ["com.bitwarden.desktop.safari"])
    }

    @Test
    func reconciliationKeepsLoadedSafariExtensionWhenResourceRootMatches() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let resourcePath = BrowserWebExtensionEntry.standardizedSafariAppExtensionResourceRootPath(appexPath)
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: true
                ),
            ],
            environmentPaths: [],
            loadedEntries: [
                BrowserWebExtensionReconciliationPlanner.LoadedEntry(
                    id: "com.bitwarden.desktop.safari",
                    standardizedPath: resourcePath
                ),
            ]
        )

        #expect(plan.unloadEntryIDs.isEmpty)
        #expect(plan.loadEntries.isEmpty)
    }

    @Test
    func reconciliationDeduplicatesRepeatedEnvironmentPaths() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let extensionPath = "/tmp/cmux-web-extensions/../cmux-web-extensions/Example"
        let standardizedPath = BrowserWebExtensionReconciliationPlanner.standardizedPath(extensionPath)
        let plan = planner.plan(
            settingsEntries: [],
            environmentPaths: [
                extensionPath,
                standardizedPath,
            ],
            loadedEntries: []
        )

        #expect(plan.desiredEntries.map(\.id) == [extensionPath])
        #expect(plan.desiredEntries.map(\.path) == [extensionPath])
        #expect(plan.loadEntries.map(\.id) == [extensionPath])
        #expect(plan.unloadEntryIDs.isEmpty)
    }

    @Test
    func reconciliationReloadsWhenPathChangesForSameEntryID() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let oldPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let newPath = "/Applications/Bitwarden Beta.app/Contents/PlugIns/safari.appex"
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: newPath,
                    enabled: true
                ),
            ],
            environmentPaths: [],
            loadedEntries: [
                BrowserWebExtensionReconciliationPlanner.LoadedEntry(
                    id: "com.bitwarden.desktop.safari",
                    standardizedPath: BrowserWebExtensionReconciliationPlanner.standardizedPath(oldPath)
                ),
            ]
        )

        #expect(plan.unloadEntryIDs == ["com.bitwarden.desktop.safari"])
        #expect(plan.unloadEntries == [
            BrowserWebExtensionReconciliationPlanner.UnloadEntry(
                id: "com.bitwarden.desktop.safari",
                preservePermissionState: false
            ),
        ])
        #expect(plan.loadEntries.map(\.path) == [newPath])
    }

    @Test
    func reconciliationPreservesPermissionStateWhenConfiguredEntryIsDisabled() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let appexPath = "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
        let resourcePath = BrowserWebExtensionReconciliationPlanner.standardizedResourceRootPath(
            for: BrowserWebExtensionEntry(
                id: "com.bitwarden.desktop.safari",
                kind: .safariAppExtension,
                path: appexPath,
                enabled: true
            )
        )
        let plan = planner.plan(
            settingsEntries: [
                BrowserWebExtensionEntry(
                    id: "com.bitwarden.desktop.safari",
                    kind: .safariAppExtension,
                    path: appexPath,
                    enabled: false
                ),
            ],
            environmentPaths: [],
            loadedEntries: [
                BrowserWebExtensionReconciliationPlanner.LoadedEntry(
                    id: "com.bitwarden.desktop.safari",
                    standardizedPath: resourcePath
                ),
            ]
        )

        #expect(plan.unloadEntries == [
            BrowserWebExtensionReconciliationPlanner.UnloadEntry(
                id: "com.bitwarden.desktop.safari",
                preservePermissionState: true
            ),
        ])
        #expect(plan.loadEntries.isEmpty)
    }

    @Test
    func failedUnloadRollbackRestoresTheLoadedEntryAsEnabled() {
        let planner = BrowserWebExtensionReconciliationPlanner()
        let loadedEntry = BrowserWebExtensionEntry(
            id: "com.example.extension",
            kind: .safariAppExtension,
            path: "/Applications/Example.app/Contents/PlugIns/Example.appex",
            enabled: true,
            displayName: "Example"
        )

        let restored = planner.rollbackEntriesAfterFailedUnloads(
            settingsEntries: [],
            failedEntries: [loadedEntry]
        )

        #expect(restored == [loadedEntry])
    }

    @MainActor
    @Test
    func pageInitiatedExtensionNavigationPolicyDistinguishesContextEntryAndExit() throws {
        let extensionURL = try #require(URL(string: "webkit-extension://cmux-test/options.html"))
        let normalURL = try #require(URL(string: "https://example.com/"))
        let unknownExtensionURL = try #require(URL(string: "webkit-extension://other-extension/options.html"))
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-extension-test.txt")
        let host = BrowserWebExtensionNavigationPolicyTestHost(extensionHost: extensionURL.host)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: extensionURL,
            renderInitialNavigation: false,
            browserWebExtensionHost: host
        )
        defer { panel.close() }

        #expect(!panel.shouldBlockPageInitiatedWebExtensionNavigation(to: extensionURL))
        #expect(panel.shouldBlockPageInitiatedWebExtensionNavigation(to: unknownExtensionURL))
        #expect(panel.shouldBlockPageInitiatedWebExtensionNavigation(to: fileURL))
        #expect(!panel.shouldRoutePageInitiatedWebExtensionNavigationInCurrentTab(to: extensionURL))
        #expect(panel.shouldRoutePageInitiatedWebExtensionNavigationInCurrentTab(to: normalURL))
        #expect(!panel.shouldRoutePageInitiatedWebExtensionNavigationInCurrentTab(to: fileURL))
    }

    @MainActor
    @Test
    func extensionExitPreservesNilTargetNewTabIntent() {
        let delegate = BrowserNavigationDelegate()

        #expect(!delegate.shouldRouteWebExtensionNavigationAsCurrentTab(
            targetFrameIsMainFrame: nil,
            shouldOpenInNewTab: false,
            navigationType: .linkActivated
        ))
        #expect(!delegate.shouldRouteWebExtensionNavigationAsCurrentTab(
            targetFrameIsMainFrame: nil,
            shouldOpenInNewTab: false,
            navigationType: .other
        ))
        #expect(delegate.shouldRouteWebExtensionNavigationAsCurrentTab(
            targetFrameIsMainFrame: true,
            shouldOpenInNewTab: false,
            navigationType: .linkActivated
        ))
    }

    @Test
    @available(macOS 15.4, *)
    func permissionStateStorePersistsEntryStatesIndependently() throws {
        let suiteName = "cmux-web-extension-permissions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserWebExtensionPermissionStateStore(defaults: defaults)
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let firstState = BrowserWebExtensionPermissionState(
            grantedPermissions: ["tabs": expiration],
            deniedPermissions: ["cookies": expiration],
            grantedPermissionMatchPatterns: ["https://example.com/*": expiration],
            deniedPermissionMatchPatterns: ["https://denied.example/*": expiration],
            hasRequestedOptionalAccessToAllHosts: true,
            hasAccessToPrivateData: false
        )
        let secondState = BrowserWebExtensionPermissionState(
            grantedPermissions: ["storage": expiration],
            deniedPermissions: [:],
            grantedPermissionMatchPatterns: [:],
            deniedPermissionMatchPatterns: [:],
            hasRequestedOptionalAccessToAllHosts: false,
            hasAccessToPrivateData: true
        )

        store.save(firstState, for: "com.example.first", standardizedPath: "/Extensions/First")
        store.save(secondState, for: "com.example.second", standardizedPath: "/Extensions/Second")

        #expect(store.state(for: "com.example.first", standardizedPath: "/Extensions/First") == firstState)
        #expect(store.state(for: "com.example.second", standardizedPath: "/Extensions/Second") == secondState)
        #expect(store.state(for: "missing", standardizedPath: "/Extensions/Missing") == nil)
    }

    @Test
    @available(macOS 15.4, *)
    func permissionStateDoesNotCrossResourceIdentities() throws {
        let suiteName = "cmux-web-extension-permission-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserWebExtensionPermissionStateStore(defaults: defaults)
        let state = BrowserWebExtensionPermissionState(
            grantedPermissions: ["tabs": Date(timeIntervalSince1970: 1_800_000_000)],
            deniedPermissions: [:],
            grantedPermissionMatchPatterns: [:],
            deniedPermissionMatchPatterns: [:],
            hasRequestedOptionalAccessToAllHosts: false,
            hasAccessToPrivateData: false
        )

        store.save(state, for: "com.example.extension", standardizedPath: "/Extensions/Original")

        #expect(store.state(for: "com.example.extension", standardizedPath: "/Extensions/Original") == state)
        #expect(store.state(for: "com.example.extension", standardizedPath: "/Extensions/Replacement") == nil)
    }

    @Test
    @available(macOS 15.4, *)
    func permissionStateStoreRemovesOnlyTargetEntry() throws {
        let suiteName = "cmux-web-extension-permission-removal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserWebExtensionPermissionStateStore(defaults: defaults)
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let firstState = BrowserWebExtensionPermissionState(
            grantedPermissions: ["tabs": expiration],
            deniedPermissions: [:],
            grantedPermissionMatchPatterns: [:],
            deniedPermissionMatchPatterns: [:],
            hasRequestedOptionalAccessToAllHosts: false,
            hasAccessToPrivateData: false
        )
        let secondState = BrowserWebExtensionPermissionState(
            grantedPermissions: ["storage": expiration],
            deniedPermissions: [:],
            grantedPermissionMatchPatterns: [:],
            deniedPermissionMatchPatterns: [:],
            hasRequestedOptionalAccessToAllHosts: false,
            hasAccessToPrivateData: false
        )

        store.save(firstState, for: "com.example.first", standardizedPath: "/Extensions/First")
        store.save(secondState, for: "com.example.second", standardizedPath: "/Extensions/Second")
        store.removeState(for: "com.example.first", standardizedPath: "/Extensions/First")

        #expect(store.state(for: "com.example.first", standardizedPath: "/Extensions/First") == nil)
        #expect(store.state(for: "com.example.second", standardizedPath: "/Extensions/Second") == secondState)
    }

    @Test
    func pluginkitParserHandlesVerboseSpaceSeparatedOutput() {
        let output = """
        +    com.bitwarden.desktop.safari(2026.7.0)  01234567-89AB-CDEF-0123-456789ABCDEF  2026-07-09 03:21:09 +0000  /Applications/Bitwarden.app/Contents/PlugIns/safari.appex
        -    com.example.disabled(1.2.3)\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\t2026-07-09 03:22:09 +0000\t/Applications/Example App.app/Contents/PlugIns/Example Extension.appex
        """

        let candidates = BrowserWebExtensionDiscoveryService.parse(pluginkitOutput: output)

        #expect(candidates.map(\.id) == [
            "com.bitwarden.desktop.safari",
            "com.example.disabled",
        ])
        #expect(candidates.first?.version == "2026.7.0")
        #expect(candidates.first?.path == "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex")
        #expect(candidates.last?.version == "1.2.3")
        #expect(candidates.last?.path == "/Applications/Example App.app/Contents/PlugIns/Example Extension.appex")
    }

    @Test
    func pluginkitQueriesOnlyTheElectedExtensionVersion() {
        #expect(BrowserWebExtensionDiscoveryService.pluginkitArguments == [
            "-m",
            "-p",
            "com.apple.Safari.web-extension",
            "-v",
        ])
    }
}

@MainActor
private final class BrowserWebExtensionNavigationPolicyTestHost: BrowserWebExtensionHosting {
    private let extensionHost: String?
    private let contextToken = NSObject()
    private let configuration = WKWebViewConfiguration()

    init(extensionHost: String?) {
        self.extensionHost = extensionHost
    }

    func attach(to configuration: WKWebViewConfiguration) {}

    func webViewConfiguration(forNavigatingTo url: URL) -> BrowserWebExtensionNavigationConfiguration? {
        guard url.scheme?.lowercased() == "webkit-extension",
              url.host == extensionHost else { return nil }
        return BrowserWebExtensionNavigationConfiguration(
            contextIdentifier: ObjectIdentifier(contextToken),
            webViewConfiguration: configuration
        )
    }

    func register(panel: BrowserPanel) {}

    func unregister(panelID: UUID) {}

    func noteActivated(panelID: UUID) {}

    func noteTabMetadataChanged(panelID: UUID) {}

    func performCommand(for event: NSEvent) -> Bool { false }
}
