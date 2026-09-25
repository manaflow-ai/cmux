import Foundation
import Testing
import CmuxCore
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
        var createdProfileIDs: [UUID] = []
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            for profileID in createdProfileIDs {
                _ = store.deleteProfile(id: profileID)
            }
            store.noteUsed(previousLastUsedProfileID)
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled, defaults: defaults)
        }

        let suffix = UUID().uuidString
        let target = try #require(store.createProfile(named: "Issue 2720 Target \(suffix)"))
        createdProfileIDs.append(target.id)
        let fallback = try #require(store.createProfile(named: "Issue 2720 Fallback \(suffix)"))
        createdProfileIDs.append(fallback.id)
        let ambiguousName = "Issue 2720 Shared \(suffix)"
        let ambiguousFirst = try #require(store.createProfile(named: ambiguousName))
        createdProfileIDs.append(ambiguousFirst.id)
        let ambiguousSecond = try #require(store.createProfile(named: ambiguousName.lowercased()))
        createdProfileIDs.append(ambiguousSecond.id)

        BrowserAvailabilitySettings.setDisabled(false, defaults: defaults)
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

        BrowserAvailabilitySettings.setDisabled(true, defaults: defaults)
        let disabledOpenResponse = try call(
            method: "browser.open_split",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "profile": unknownSelector,
            ]
        )
        let disabledOpenError = try errorPayload(disabledOpenResponse)
        #expect(disabledOpenError["code"] as? String == "invalid_params")
        #expect((disabledOpenError["message"] as? String)?.contains(unknownSelector) == true)

        let disabledPaneResponse = try call(
            method: "pane.create",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "direction": "right",
                "type": "browser",
                "profile": unknownSelector,
            ]
        )
        let disabledPaneError = try errorPayload(disabledPaneResponse)
        #expect(disabledPaneError["code"] as? String == "invalid_params")
        #expect((disabledPaneError["message"] as? String)?.contains(unknownSelector) == true)

        let disabledSelectedOpenResponse = try call(
            method: "browser.open_split",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "profile": target.id.uuidString,
            ]
        )
        let disabledSelectedOpenError = try errorPayload(disabledSelectedOpenResponse)
        #expect(disabledSelectedOpenError["code"] as? String == "invalid_params")
        #expect((disabledSelectedOpenError["message"] as? String)?.contains("disabled") == true)

        let disabledSelectedPaneResponse = try call(
            method: "pane.create",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "direction": "right",
                "type": "browser",
                "profile": target.id.uuidString,
            ]
        )
        let disabledSelectedPaneError = try errorPayload(disabledSelectedPaneResponse)
        #expect(disabledSelectedPaneError["code"] as? String == "invalid_params")
        #expect((disabledSelectedPaneError["message"] as? String)?.contains("disabled") == true)
        BrowserAvailabilitySettings.setDisabled(false, defaults: defaults)

        let malformedOpenResponse = try call(
            method: "browser.open_split",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "profile": "   ",
            ]
        )
        let malformedOpenError = try errorPayload(malformedOpenResponse)
        #expect(malformedOpenError["code"] as? String == "invalid_params")
        #expect((malformedOpenError["message"] as? String)?.contains("non-empty") == true)
        #expect(
            (malformedOpenError["data"] as? [String: Any])?["profile_parameter"] as? String
                == "profile"
        )

        let malformedPaneResponse = try call(
            method: "pane.create",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "direction": "right",
                "type": "browser",
                "profile_name": 123,
            ]
        )
        let malformedPaneError = try errorPayload(malformedPaneResponse)
        #expect(malformedPaneError["code"] as? String == "invalid_params")
        #expect((malformedPaneError["message"] as? String)?.contains("non-empty") == true)

        let multipleOpenResponse = try call(
            method: "browser.open_split",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "profile": target.displayName,
                "profile_id": fallback.id.uuidString,
            ]
        )
        let multipleOpenError = try errorPayload(multipleOpenResponse)
        #expect(multipleOpenError["code"] as? String == "invalid_params")
        #expect((multipleOpenError["message"] as? String)?.contains("only one") == true)

        let multiplePaneResponse = try call(
            method: "pane.create",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "direction": "right",
                "type": "browser",
                "profile": target.displayName,
                "profile_name": fallback.displayName,
            ]
        )
        let multiplePaneError = try errorPayload(multiplePaneResponse)
        #expect(multiplePaneError["code"] as? String == "invalid_params")
        #expect((multiplePaneError["message"] as? String)?.contains("only one") == true)

        let terminalProfileResponse = try call(
            method: "pane.create",
            params: [
                "workspace_id": fallbackWorkspace.id.uuidString,
                "surface_id": fallbackSourceID.uuidString,
                "direction": "right",
                "type": "terminal",
                "profile": target.displayName,
            ]
        )
        let terminalProfileError = try errorPayload(terminalProfileResponse)
        #expect(terminalProfileError["code"] as? String == "invalid_params")
        #expect((terminalProfileError["message"] as? String)?.contains("browser pane") == true)

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

    @Test func explicitProfilesAreRejectedForRemoteWorkspaceCreation() throws {
        let defaults = UserDefaults.standard
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled(defaults: defaults)
        let manager = TabManager()
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            manager.tabs.forEach { $0.teardownAllPanels() }
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled, defaults: defaults)
        }

        BrowserAvailabilitySettings.setDisabled(false, defaults: defaults)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "example.com",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil
            ),
            autoConnect: false
        )
        let sourceID = try #require(workspace.focusedPanelId)
        let profileID = BrowserProfileStore.shared.builtInDefaultProfileID.uuidString
        TerminalController.shared.setActiveTabManager(manager)

        for method in ["browser.open_split", "pane.create"] {
            var params: [String: Any] = [
                "workspace_id": workspace.id.uuidString,
                "surface_id": sourceID.uuidString,
                "profile": profileID,
                "focus": false,
            ]
            if method == "pane.create" {
                params["direction"] = "right"
                params["type"] = "browser"
            }

            let error = try errorPayload(try call(method: method, params: params))
            #expect(error["code"] as? String == "invalid_params")
            #expect((error["message"] as? String)?.contains("remote workspace") == true)
        }
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
