import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserProfileSocketTests {
    @Test func browserCreationCommandsHonorExplicitProfilesAndRejectInvalidSelectors() throws {
        let defaults = UserDefaults.standard
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled(defaults: defaults)
        let store = BrowserProfileStore.shared
        let previousLastUsedProfileID = store.effectiveLastUsedProfileID
        let suffix = UUID().uuidString
        let target = try #require(store.createProfile(named: "Issue 2720 Target \(suffix)"))
        let fallback = try #require(store.createProfile(named: "Issue 2720 Fallback \(suffix)"))
        let ambiguousName = "Issue 2720 Shared \(suffix)"
        let ambiguousFirst = try #require(store.createProfile(named: ambiguousName))
        let ambiguousSecond = try #require(store.createProfile(named: ambiguousName.lowercased()))
        let createdProfileIDs = [target.id, fallback.id, ambiguousFirst.id, ambiguousSecond.id]

        BrowserAvailabilitySettings.setDisabled(false, defaults: defaults)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            for profileID in createdProfileIDs {
                _ = store.deleteProfile(id: profileID)
            }
            store.noteUsed(previousLastUsedProfileID)
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled, defaults: defaults)
        }

        store.noteUsed(fallback.id)
        let openManager = TabManager()
        defer { openManager.tabs.forEach { $0.teardownAllPanels() } }
        let openWorkspace = try #require(openManager.selectedWorkspace)
        let openSourceID = try #require(openWorkspace.focusedPanelId)
        TerminalController.shared.setActiveTabManager(openManager)

        let openResponse = try call(
            method: "browser.open_split",
            params: [
                "workspace_id": openWorkspace.id.uuidString,
                "surface_id": openSourceID.uuidString,
                "url": "about:blank",
                "profile": target.displayName.lowercased(),
                "focus": false,
            ]
        )
        let openResult = try successfulResult(openResponse)
        let openedSurfaceID = try #require(
            (openResult["surface_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let openedPanel = try #require(openWorkspace.panels[openedSurfaceID] as? BrowserPanel)
        #expect(openedPanel.profileID == target.id)

        store.noteUsed(fallback.id)
        let paneManager = TabManager()
        defer { paneManager.tabs.forEach { $0.teardownAllPanels() } }
        let paneWorkspace = try #require(paneManager.selectedWorkspace)
        let paneSourceID = try #require(paneWorkspace.focusedPanelId)
        TerminalController.shared.setActiveTabManager(paneManager)

        let paneResponse = try call(
            method: "pane.create",
            params: [
                "workspace_id": paneWorkspace.id.uuidString,
                "surface_id": paneSourceID.uuidString,
                "direction": "right",
                "type": "browser",
                "url": "about:blank",
                "profile": target.id.uuidString,
                "focus": false,
            ]
        )
        let paneResult = try successfulResult(paneResponse)
        let paneSurfaceID = try #require(
            (paneResult["surface_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let panePanel = try #require(paneWorkspace.panels[paneSurfaceID] as? BrowserPanel)
        #expect(panePanel.profileID == target.id)

        store.noteUsed(fallback.id)
        let fallbackManager = TabManager()
        defer { fallbackManager.tabs.forEach { $0.teardownAllPanels() } }
        let fallbackWorkspace = try #require(fallbackManager.selectedWorkspace)
        let fallbackSourceID = try #require(fallbackWorkspace.focusedPanelId)
        TerminalController.shared.setActiveTabManager(fallbackManager)

        let fallbackResponse = try call(
            method: "browser.open_split",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "url": "about:blank",
                "focus": false,
            ]
        )
        let fallbackResult = try successfulResult(fallbackResponse)
        let fallbackSurfaceID = try #require(
            (fallbackResult["surface_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let fallbackPanel = try #require(fallbackWorkspace.panels[fallbackSurfaceID] as? BrowserPanel)
        #expect(fallbackPanel.profileID == fallback.id)

        let unknownSelector = "Issue 2720 Missing \(suffix)"
        let unknownResponse = try call(
            method: "browser.open_split",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "profile": unknownSelector,
            ]
        )
        let unknownError = try errorPayload(unknownResponse)
        #expect(unknownError["code"] as? String == "invalid_params")
        #expect((unknownError["message"] as? String)?.contains(unknownSelector) == true)
        #expect((unknownError["data"] as? [String: Any])?["profile"] as? String == unknownSelector)

        let ambiguousResponse = try call(
            method: "pane.create",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "direction": "right",
                "type": "browser",
                "profile": ambiguousName.uppercased(),
            ]
        )
        let ambiguousError = try errorPayload(ambiguousResponse)
        let ambiguousMessage = try #require(ambiguousError["message"] as? String)
        let ambiguousCandidates = try #require(
            (ambiguousError["data"] as? [String: Any])?["candidates"] as? [[String: Any]]
        )
        #expect(ambiguousError["code"] as? String == "invalid_params")
        #expect(ambiguousMessage.contains(ambiguousFirst.id.uuidString))
        #expect(ambiguousMessage.contains(ambiguousSecond.id.uuidString))
        #expect(Set(ambiguousCandidates.compactMap { $0["id"] as? String }) == [
            ambiguousFirst.id.uuidString,
            ambiguousSecond.id.uuidString,
        ])
    }

    private func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let response = TerminalController.shared.handleSocketLine(line)
        return try #require(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
    }

    private func successfulResult(_ response: [String: Any]) throws -> [String: Any] {
        #expect(response["ok"] as? Bool == true)
        return try #require(response["result"] as? [String: Any])
    }

    private func errorPayload(_ response: [String: Any]) throws -> [String: Any] {
        #expect(response["ok"] as? Bool == false)
        return try #require(response["error"] as? [String: Any])
    }
}
