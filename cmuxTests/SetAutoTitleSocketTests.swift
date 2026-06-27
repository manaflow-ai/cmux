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

    /// Runs `body` with the auto-naming language override set to `slug`,
    /// restoring the user's previous value afterwards.
    private func withAutoNamingLanguageSetting<T>(_ slug: String, _ body: () throws -> T) rethrows -> T {
        let key = AutomationCatalogSection().autoNamingLanguage.userDefaultsKey
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

    @Test func probeReportsResolvedAutoNamingLanguage() throws {
        try withAutoNamingSetting(true) {
            try withAutoNamingLanguageSetting("ja") {
                let envelope = try call(method: "workspace.set_auto_title", params: ["probe": true])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["auto_naming_language_name"] as? String == "Japanese")
                #expect(result["auto_naming_language_tag"] as? String == "ja")
            }
            try withAutoNamingLanguageSetting("en") {
                let envelope = try call(method: "workspace.set_auto_title", params: ["probe": true])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["auto_naming_language_name"] as? String == "English")
                #expect(result["auto_naming_language_tag"] as? String == "en")
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

    @Test func successfulNoOpClearsRecordedFailureWithoutApplyingTitle() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                AutoNamingStatusStore.record(rawCategory: "failed", agent: "codex", at: 1)
                #expect(AutoNamingStatusStore.current() != nil)
                let originalTitle = workspace.title
                let originalSource = workspace.effectiveCustomTitleSource
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "success": true
                ])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["confirmed"] as? Bool == true)
                #expect(result["status_cleared"] as? Bool == true)
                #expect(result["workspace_applied"] == nil)
                #expect(workspace.title == originalTitle)
                #expect(workspace.effectiveCustomTitleSource == originalSource)
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
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
                _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
                let params: [String: Any] = [
                    "probe": true,
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelId.uuidString,
                    "panel_only_if_multiple": true
                ]
                var envelope = try call(method: "workspace.set_auto_title", params: params)
                var result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_user_owned"] as? Bool == false)
                #expect(result["auto_naming_panel_writable"] as? Bool == true)

                workspace.setCustomTitle("My Project")
                envelope = try call(method: "workspace.set_auto_title", params: params)
                result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_user_owned"] as? Bool == true)
                #expect(result["auto_naming_panel_writable"] as? Bool == true)
            }
        }
    }

    @Test func probeReportsCurrentAutoTitleOnlyForAutoOwnedWorkspace() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                workspace.setCustomTitle("Fix auth bug", source: .auto)
                var envelope = try call(method: "workspace.set_auto_title", params: [
                    "probe": true,
                    "workspace_id": workspace.id.uuidString
                ])
                var result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_user_owned"] as? Bool == false)
                #expect(result["auto_naming_current_title"] as? String == "Fix auth bug")

                workspace.setCustomTitle("My Project")
                envelope = try call(method: "workspace.set_auto_title", params: [
                    "probe": true,
                    "workspace_id": workspace.id.uuidString
                ])
                result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_user_owned"] as? Bool == true)
                #expect(result["auto_naming_current_title"] is NSNull)
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

    @Test func repeatedWorkspaceTitleStillAppliesPanelTitleAfterSplit() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
                _ = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "title": "Fix auth bug"
                ])

                _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelId.uuidString,
                    "panel_only_if_multiple": true,
                    "title": "Fix auth bug"
                ])
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_applied"] as? Bool == true)
                #expect(result["panel_applied"] as? Bool == true)
                #expect(workspace.panelCustomTitles[panelId] == "Fix auth bug")
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

    @Test func mockedAutoNamingPipelineUsesProbeLanguageAndApplySocket() throws {
        try withAutoNamingSetting(true) {
            try withAutoNamingLanguageSetting("ja") {
                try withManager { _, workspace in
                    let probeEnvelope = try call(method: "workspace.set_auto_title", params: [
                        "probe": true,
                        "workspace_id": workspace.id.uuidString
                    ])
                    let probe = try #require(probeEnvelope["result"] as? [String: Any])
                    let language = AutoNamingPromptLanguage(
                        name: try #require(probe["auto_naming_language_name"] as? String),
                        tag: try #require(probe["auto_naming_language_tag"] as? String)
                    )
                    let engine = AutoNamingEngine()
                    let lines = [
                        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ログインの不具合を直して"}]}}"#,
                        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"認証フローを確認します。"}]}}"#,
                    ]
                    let extraction = engine.extractCodexRollout(fromRolloutLines: lines)
                    let context = try #require(engine.buildContext(from: extraction.messages))
                    let prompt = engine.buildPrompt(currentTitle: nil, context: context, language: language)
                    #expect(prompt.contains("Write the title in Japanese (ja) only."))

                    let sanitized = try #require({
                        if case .title(let title) = engine.sanitizeResponseOutcome("ログイン修正", currentTitle: nil) {
                            return title
                        }
                        return nil
                    }())
                    let applyEnvelope = try call(method: "workspace.set_auto_title", params: [
                        "workspace_id": workspace.id.uuidString,
                        "title": sanitized
                    ])
                    let result = try #require(applyEnvelope["result"] as? [String: Any])
                    #expect(result["workspace_applied"] as? Bool == true)
                    #expect(workspace.title == "ログイン修正")
                    #expect(workspace.effectiveCustomTitleSource == .auto)

                    workspace.setCustomTitle("My Project")
                    let rejectedEnvelope = try call(method: "workspace.set_auto_title", params: [
                        "workspace_id": workspace.id.uuidString,
                        "title": "別名"
                    ])
                    let rejected = try #require(rejectedEnvelope["result"] as? [String: Any])
                    #expect(rejected["workspace_applied"] as? Bool == false)
                    #expect(workspace.title == "My Project")
                    #expect(workspace.effectiveCustomTitleSource == .user)
                }
            }
        }
    }

    @Test func userWorkspaceTitleStillAllowsPanelApplyWithDistinguishableResult() throws {
        try withAutoNamingSetting(true) {
            try withManager { _, workspace in
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let panelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
                _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
                AutoNamingStatusStore.record(rawCategory: "failed", agent: "codex", at: 1)
                workspace.setCustomTitle("My Project")
                let envelope = try call(method: "workspace.set_auto_title", params: [
                    "workspace_id": workspace.id.uuidString,
                    "panel_id": panelId.uuidString,
                    "title": "Fix auth bug"
                ])
                #expect(envelope["ok"] as? Bool == true)
                let result = try #require(envelope["result"] as? [String: Any])
                #expect(result["workspace_applied"] as? Bool == false)
                #expect(result["panel_applied"] as? Bool == true)
                #expect(workspace.title == "My Project")
                #expect(workspace.panelCustomTitles[panelId] == "Fix auth bug")
                #expect(AutoNamingStatusStore.current() == nil)
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
