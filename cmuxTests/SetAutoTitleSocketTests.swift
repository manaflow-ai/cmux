import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Socket-level behavior tests for `workspace.set_auto_title`: the v2 method
/// auto-naming engines use to apply AI-generated titles with `.auto`
/// provenance. Serialized because the suite goes through the shared
/// `TerminalController` and toggles the opt-in setting in `UserDefaults`.
@MainActor
@Suite(.serialized) struct SetAutoTitleSocketTests {

    private func decodeResponse(_ response: String) throws -> [String: Any] {
        let data = try #require(response.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = ["id": method, "method": method, "params": params]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        return try decodeResponse(TerminalController.shared.handleSocketLine(requestLine))
    }

    /// Runs `body` with the auto-naming setting forced to `enabled`, restoring
    /// the user's previous value afterwards.
    private func withAutoNamingSetting<T>(_ enabled: Bool, _ body: () throws -> T) rethrows -> T {
        let key = AutomationCatalogSection().workspaceAutoNaming.userDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        return try body()
    }

    /// Runs `body` with the auto-naming agent override set to `slug`, restoring
    /// the user's previous value afterwards.
    private func withAutoNamingAgentSetting<T>(_ slug: String, _ body: () throws -> T) rethrows -> T {
        let key = AutomationCatalogSection().autoNamingAgent.userDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(slug, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        return try body()
    }

    private func withManager<T>(_ body: (TabManager, Workspace) throws -> T) throws -> T {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(nil) }
        return try body(manager, workspace)
    }

    @Test func probeReportsSummarizerAgentOverride() throws {
        try withAutoNamingSetting(true) {
            // "auto" override → no summarizer_agent (null).
            try withAutoNamingAgentSetting("auto") {
                let envelope = try call(method: "workspace.set_auto_title", params: ["probe": true])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["summarizer_agent"] is NSNull)
            }
            // A specific override → carried on the probe response.
            try withAutoNamingAgentSetting("codex") {
                let envelope = try call(method: "workspace.set_auto_title", params: ["probe": true])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["summarizer_agent"] as? String == "codex")
            }
        }
    }

    @Test func failureReportRecordsStatusWithoutApplyingTitle() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                AutoNamingStatusStore.clear()
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "failure": "failed",
                    "agent": "codex",
                    "workspace_id": workspace.id.uuidString
                ])
                #expect(envelope["ok"] as? Bool == true)
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["recorded"] as? Bool == true)
                // No title path ran.
                #expect(result["workspace_applied"] == nil)
                #expect(workspace.effectiveCustomTitleSource != .auto)
                let status = AutoNamingStatusStore.current()
                #expect(status?.category == .failed)
                #expect(status?.agent == "codex")
                AutoNamingStatusStore.clear()
            }
        }
    }

    @Test func successfulApplyClearsRecordedFailure() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                AutoNamingStatusStore.record(rawCategory: "failed", agent: "codex", at: 1)
                #expect(AutoNamingStatusStore.current() != nil)
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "title": "Fix auth bug"
                ])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_applied"] as? Bool == true)
                #expect(AutoNamingStatusStore.current() == nil)
                AutoNamingStatusStore.clear()
            }
        }
    }

    @Test func notInstalledSurvivesAReportAfterSuccessfulApply() throws {
        // Regression: a missing-override pass applies a fallback title (which
        // clears stale status) and THEN reports not_installed. The order must
        // leave the Settings note visible rather than wiping it.
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                AutoNamingStatusStore.clear()
                _ = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "title": "Fix auth bug"
                ])
                #expect(AutoNamingStatusStore.current() == nil) // apply cleared
                _ = try call(method: "workspace.set_auto_title", params: [
                    "failure": "not_installed",
                    "agent": "codex",
                    "workspace_id": workspace.id.uuidString
                ])
                let status = AutoNamingStatusStore.current()
                #expect(status?.category == .notInstalled)
                #expect(status?.agent == "codex")
                AutoNamingStatusStore.clear()
            }
        }
    }

    @Test func probeReportsLiveSettingState() throws {
        try withAutoNamingSetting(true) {
            let envelope = try call(method: "workspace.set_auto_title", params: ["probe": true])
            #expect(envelope["ok"] as? Bool == true)
            let result = try #require(envelope["result"] as? [String: Any])
            #expect(result["enabled"] as? Bool == true)
        }
        try withAutoNamingSetting(false) {
            let envelope = try call(method: "workspace.set_auto_title", params: ["probe": true])
            #expect(envelope["ok"] as? Bool == true)
            let result = try #require(envelope["result"] as? [String: Any])
            #expect(result["enabled"] as? Bool == false)
        }
    }

    @Test func probeWithWorkspaceIdReportsUserOwnership() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                var envelope = try call(method: "workspace.set_auto_title", params: [
                    "probe": true,
                    "workspace_id": workspace.id.uuidString
                ])
                var result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_user_owned"] as? Bool == false)

                workspace.setCustomTitle("My Project")
                envelope = try call(method: "workspace.set_auto_title", params: [
                    "probe": true,
                    "workspace_id": workspace.id.uuidString
                ])
                result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_user_owned"] as? Bool == true)
            }
        }
    }

    @Test func panelOnlyIfMultipleSuppressesSinglePanelWorkspace() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

                // One panel: the tab write is suppressed, the workspace still names.
                guard workspace.panels.count == 1 else { return }
                var envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelId.uuidString,
                    "panel_only_if_multiple": true,
                    "title": "Fix auth bug"
                ])
                var result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_applied"] as? Bool == true)
                #expect(result["panel_applied"] is NSNull || result["panel_applied"] == nil)
                #expect(workspace.panelCustomTitles[panelId] == nil)

                // Two panels: the tab write fires.
                _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
                envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelId.uuidString,
                    "panel_only_if_multiple": true,
                    "title": "Debug login flow"
                ])
                result = try #require(envelope["result"] as? [String: Any])
                #expect(result["panel_applied"] as? Bool == true)
                #expect(workspace.panelCustomTitles[panelId] == "Debug login flow")
            }
        }
    }

    @Test func appliesAutoTitleToUntitledWorkspace() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "title": "Fix auth bug"
                ])
                #expect(envelope["ok"] as? Bool == true)
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_applied"] as? Bool == true)
                #expect(workspace.title == "Fix auth bug")
                #expect(workspace.effectiveCustomTitleSource == .auto)
            }
        }
    }

    @Test func rejectedOverUserTitleWithDistinguishableResult() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                workspace.setCustomTitle("My Project")
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "title": "Fix auth bug"
                ])
                #expect(envelope["ok"] as? Bool == true)
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_applied"] as? Bool == false)
                #expect(workspace.title == "My Project")
            }
        }
    }

    @Test func rejectedWhenSettingDisabled() throws {
        try withAutoNamingSetting(false) {
            try withManager { _, workspace in
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "title": "Fix auth bug"
                ])
                #expect(envelope["ok"] as? Bool == false)
                let error = try #require(envelope["error"] as? [String: Any])
                #expect(error["code"] as? String == "disabled")
                #expect(workspace.title != "Fix auth bug")
            }
        }
    }

    @Test func panelIdTargetsTabTitleAndWorkspaceOnlyLeavesTabsAlone() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

                // Workspace-only call: tabs untouched.
                _ = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "title": "Fix auth bug"
                ])
                #expect(workspace.panelCustomTitles[panelId] == nil)

                // Panel-targeted call names the tab with auto provenance.
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelId.uuidString,
                    "title": "Debug login flow"
                ])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["panel_applied"] as? Bool == true)
                #expect(workspace.panelCustomTitles[panelId] == "Debug login flow")
                #expect(workspace.panelCustomTitleSources[panelId] == .auto)
            }
        }
    }

    // MARK: - surface.sync_codex_native_title (cmux #11144)
    //
    // Mirrors an OSC terminal-title update, but sourced from Codex's own
    // native thread title instead of a terminal escape sequence, so it writes
    // through `Workspace.updatePanelTitle` (the same raw tier OSC already
    // uses) rather than the `.auto` custom-title tier `workspace.set_auto_title`
    // writes to. Unlike that method, it is NOT gated by the opt-in Workspace
    // Auto-Naming setting — matching Claude's unconditional OSC-driven tab
    // title updates. The title itself is resolved by the caller (the detached
    // `cmux hooks codex sync-native-title` process, via `CodexNativeTitleStore`
    // in the CMUXAgentLaunch package) before this call, so these tests exercise
    // the handler with a plain `title` param — the reader itself is covered by
    // `CodexNativeTitleStoreTests` in that package.

    @Test func syncCodexNativeTitleAppliesRawPanelTitleWhenNoCustomTitleExists() throws {
        try withManager { _, workspace in
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

            let envelope = try call(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString,
                "panel_id": panelId.uuidString,
                "title": "測試 cmux 與 codex Tab 同步"
            ])
            let result = try #require(envelope["result"] as? [String: Any])
            #expect(result["applied"] as? Bool == true)
            #expect(workspace.panelTitles[panelId] == "測試 cmux 與 codex Tab 同步")
            // The raw tier, not the custom-title tier: no auto/user provenance recorded.
            #expect(workspace.panelCustomTitles[panelId] == nil)
        }
    }

    @Test func syncCodexNativeTitleNeverOverridesAUserRenamedTab() throws {
        try withManager { _, workspace in
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
            _ = workspace.setPanelCustomTitle(panelId: panelId, title: "my renamed tab", source: .user)

            let envelope = try call(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString,
                "panel_id": panelId.uuidString,
                "title": "some fresh Codex title"
            ])
            #expect(envelope["ok"] as? Bool == true)
            #expect(workspace.panelCustomTitles[panelId] == "my renamed tab")
            #expect(workspace.panelCustomTitleSources[panelId] == .user)
        }
    }

    @Test func syncCodexNativeTitleNeverOverridesAnAutoNamedTab() throws {
        try withManager { _, workspace in
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
            _ = workspace.setPanelCustomTitle(panelId: panelId, title: "auto-named tab", source: .auto)

            let envelope = try call(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString,
                "panel_id": panelId.uuidString,
                "title": "some fresh Codex title"
            ])
            #expect(envelope["ok"] as? Bool == true)
            #expect(workspace.panelCustomTitles[panelId] == "auto-named tab")
        }
    }

    @Test func syncCodexNativeTitleIgnoresWorkspaceAutoNamingSetting() throws {
        // Priority: independent of the opt-in Workspace Auto-Naming feature —
        // must apply identically whether that setting is on or off.
        try withAutoNamingSetting(false) {
            try withManager { _, workspace in
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

                let envelope = try call(method: "surface.sync_codex_native_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelId.uuidString,
                    "title": "applies even with auto-naming off"
                ])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["applied"] as? Bool == true)
                #expect(workspace.panelTitles[panelId] == "applies even with auto-naming off")
            }
        }
    }

    @Test func syncCodexNativeTitleMalformedParamsProduceCleanErrors() throws {
        try withManager { _, workspace in
            let pane = try #require(workspace.bonsplitController.allPaneIds.first)
            let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

            // Missing title.
            var envelope = try call(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString,
                "panel_id": panelId.uuidString
            ])
            #expect(envelope["ok"] as? Bool == false)
            var error = try #require(envelope["error"] as? [String: Any])
            #expect(error["code"] as? String == "invalid_params")

            // Missing workspace id.
            envelope = try call(method: "surface.sync_codex_native_title", params: [
                "panel_id": panelId.uuidString,
                "title": "Fix auth bug"
            ])
            #expect(envelope["ok"] as? Bool == false)
            error = try #require(envelope["error"] as? [String: Any])
            #expect(error["code"] as? String == "invalid_params")

            // Missing panel id.
            envelope = try call(method: "surface.sync_codex_native_title", params: [
                "workspace_id": workspace.id.uuidString,
                "title": "Fix auth bug"
            ])
            #expect(envelope["ok"] as? Bool == false)
            error = try #require(envelope["error"] as? [String: Any])
            #expect(error["code"] as? String == "invalid_params")

            // Unknown workspace.
            envelope = try call(method: "surface.sync_codex_native_title", params: [
                "workspace_id": UUID().uuidString,
                "panel_id": panelId.uuidString,
                "title": "Fix auth bug"
            ])
            #expect(envelope["ok"] as? Bool == false)
            error = try #require(envelope["error"] as? [String: Any])
            #expect(error["code"] as? String == "not_found")
        }
    }

    @Test func malformedParamsProduceCleanErrors() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                // Missing title.
                var envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString
                ])
                #expect(envelope["ok"] as? Bool == false)
                var error = try #require(envelope["error"] as? [String: Any])
                #expect(error["code"] as? String == "invalid_params")

                // Missing workspace id.
                envelope = try call(method: "workspace.set_auto_title", params: [
                    "title": "Fix auth bug"
                ])
                #expect(envelope["ok"] as? Bool == false)
                error = try #require(envelope["error"] as? [String: Any])
                #expect(error["code"] as? String == "invalid_params")

                // Unknown workspace.
                envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": UUID().uuidString,
                    "title": "Fix auth bug"
                ])
                #expect(envelope["ok"] as? Bool == false)
                error = try #require(envelope["error"] as? [String: Any])
                #expect(error["code"] as? String == "not_found")
            }
        }
    }
}
