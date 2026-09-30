import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd+V sends Ctrl+V to Claude Code or Codex only when the setting is on, the
/// agent is live in the pane and owns the terminal's foreground, the clipboard
/// holds only an image, and the pane is local. Every other combination keeps
/// the temp-path paste.
@Suite("Agent image paste routing")
struct TerminalAgentImagePasteRoutingTests {
    private static let screenshotTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
    private static let liveClaude = "agentPIDKey:claude_code"
    private static let liveCodex = "agentPIDKey:codex.019a2b3c-session"

    private func decision(
        isEnabled: Bool = true,
        agentContext: String = liveClaude,
        types: [NSPasteboard.PasteboardType] = screenshotTypes,
        agentOwnsForeground: Bool = true,
        target: TerminalImageTransferTarget = .local
    ) -> Bool {
        TerminalAgentImagePasteRouting.shouldSendAgentPasteKey(
            isEnabled: isEnabled,
            agentContext: { agentContext },
            pasteboardTypes: { types },
            agentOwnsForeground: { agentOwnsForeground },
            resolveTarget: { target }
        )
    }

    @Test func sendsCtrlVForAScreenshotIntoALiveClaudeCodeOrCodex() {
        #expect(decision(agentContext: Self.liveClaude))
        #expect(decision(agentContext: Self.liveCodex))
        #expect(decision(agentContext: "initialCommand:zsh\n\(Self.liveCodex)"))
        #expect(TerminalAgentImagePasteRouting.agentPasteKeyName == "ctrl+v")
    }

    @Test func settingOffKeepsTheTempPathPaste() {
        #expect(!decision(isEnabled: false))
    }

    @Test func settingOffNeverReadsTheAgentPasteboardOrTarget() {
        var evaluated: [String] = []
        let result = TerminalAgentImagePasteRouting.shouldSendAgentPasteKey(
            isEnabled: false,
            agentContext: { evaluated.append("agent"); return Self.liveClaude },
            pasteboardTypes: { evaluated.append("pasteboard"); return Self.screenshotTypes },
            agentOwnsForeground: { evaluated.append("foreground"); return true },
            resolveTarget: { evaluated.append("target"); return .local }
        )
        #expect(!result)
        #expect(evaluated.isEmpty)
    }

    @Test func otherAgentsAndExitedOrRestoredAgentsKeepTheTempPathPaste() {
        #expect(!decision(agentContext: ""))
        #expect(!decision(agentContext: "agentPIDKey:opencode"))
        #expect(!decision(agentContext: "agentPIDKey:pi"))
        // A launch command or restored snapshot alone doesn't prove the agent
        // is still running; Ctrl+V into the shell afterwards would drop the image.
        #expect(!decision(agentContext: "initialCommand:claude"))
        #expect(!decision(agentContext: "restoredAgent:codex"))
    }

    @Test func remoteAndCloudPanesKeepTheUploadPath() {
        #expect(!decision(target: .remote(.workspaceRemote)))
        #expect(!decision(target: .cloud))
    }

    @Test func clipboardsWithTextURLsOrFilesKeepTheRegularPaste() {
        let nonImageTypes: [NSPasteboard.PasteboardType] = [
            .string,
            NSPasteboard.PasteboardType(rawValue: "public.utf8-plain-text"),
            .html,
            .rtf,
            .rtfd,
            .URL,
            .fileURL,
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"),
            NSPasteboard.PasteboardType(rawValue: "com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSStringPboardType"),
        ]
        for extra in nonImageTypes {
            #expect(
                !TerminalAgentImagePasteRouting.clipboardHoldsOnlyImageData(Self.screenshotTypes + [extra]),
                "image plus \(extra.rawValue) must keep the regular paste"
            )
            #expect(!decision(types: Self.screenshotTypes + [extra]))
        }
    }

    @Test func clipboardImageDetectionNeedsAnImageType() {
        #expect(TerminalAgentImagePasteRouting.clipboardHoldsOnlyImageData([.tiff]))
        #expect(TerminalAgentImagePasteRouting.clipboardHoldsOnlyImageData([.png]))
        #expect(TerminalAgentImagePasteRouting.clipboardHoldsOnlyImageData([
            NSPasteboard.PasteboardType(rawValue: "public.jpeg"),
        ]))
        #expect(!TerminalAgentImagePasteRouting.clipboardHoldsOnlyImageData([]))
        #expect(!TerminalAgentImagePasteRouting.clipboardHoldsOnlyImageData([
            NSPasteboard.PasteboardType(rawValue: "com.example.private-data"),
        ]))
    }

    // MARK: - Stale and background agents

    @Test func agentOutsideTheForegroundKeepsTheTempPathPaste() {
        #expect(!decision(agentOwnsForeground: false))
    }

    @Test func foregroundCheckMatchesTheAgentsProcessGroup() {
        let agentPID: pid_t = 4_100
        // The agent leads the foreground group.
        #expect(TerminalAgentImagePasteRouting.agentOwnsForeground(
            recordedAgentPIDs: [agentPID],
            foregroundProcessGroupID: 4_100,
            processGroupID: { _ in 4_100 }
        ))
        // A wrapper leads the group the agent runs in.
        #expect(TerminalAgentImagePasteRouting.agentOwnsForeground(
            recordedAgentPIDs: [agentPID],
            foregroundProcessGroupID: 4_000,
            processGroupID: { _ in 4_000 }
        ))
        // Ctrl+Z-suspended agent: the shell's group is in the foreground.
        #expect(!TerminalAgentImagePasteRouting.agentOwnsForeground(
            recordedAgentPIDs: [agentPID],
            foregroundProcessGroupID: 3_000,
            processGroupID: { _ in 4_100 }
        ))
        // No foreground group, an exited agent (getpgid fails), or no agent PID.
        #expect(!TerminalAgentImagePasteRouting.agentOwnsForeground(
            recordedAgentPIDs: [agentPID],
            foregroundProcessGroupID: nil,
            processGroupID: { _ in 4_100 }
        ))
        #expect(!TerminalAgentImagePasteRouting.agentOwnsForeground(
            recordedAgentPIDs: [agentPID],
            foregroundProcessGroupID: 3_000,
            processGroupID: { _ in -1 }
        ))
        #expect(!TerminalAgentImagePasteRouting.agentOwnsForeground(
            recordedAgentPIDs: [],
            foregroundProcessGroupID: 3_000,
            processGroupID: { _ in 3_000 }
        ))
    }

    @Test func onlyClaudeCodeAndCodexPIDsCountForTheForegroundCheck() {
        let pids = TerminalAgentImagePasteRouting.clipboardImageAgentPIDs(
            panelAgentPIDKeys: ["claude_code", "codex.session-a", "opencode", "pi.session-b"],
            agentPIDs: ["claude_code": 10, "codex.session-a": 20, "opencode": 30, "pi.session-b": 40]
        )
        #expect(Set(pids) == [10, 20])
    }

    @Test @MainActor
    func liveForegroundAgentInAWorkspaceSendsCtrlV() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.recordAgentPID(key: "codex.current-process", pid: getpid(), panelId: panel.id, refreshPorts: false)

        #expect(workspaceDecision(workspace, panel, foregroundProcessGroupID: Int(getpgid(getpid()))))
    }

    @Test @MainActor
    func stalePIDWithoutAnExitHookKeepsTheTempPathPaste() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        // The agent was killed without a SessionEnd hook: its PID is still
        // recorded, and nothing has swept it yet.
        workspace.recordAgentPID(key: "codex.dead-session", pid: 999_999, panelId: panel.id, refreshPorts: false)
        #expect(workspace.agentPIDKeysByPanelId[panel.id]?.contains("codex.dead-session") == true)

        // Even a foreground group that matches the dead PID can't vouch for it.
        #expect(!workspaceDecision(
            workspace,
            panel,
            foregroundProcessGroupID: 999_999,
            processGroupID: { _ in 999_999 }
        ))
        #expect(workspace.agentPIDKeysByPanelId[panel.id]?.contains("codex.dead-session") != true)
    }

    @Test @MainActor
    func liveAgentOutsideTheForegroundGroupKeepsTheTempPathPaste() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.recordAgentPID(key: "codex.current-process", pid: getpid(), panelId: panel.id, refreshPorts: false)

        // Suspended with Ctrl+Z, or running in another tmux window: the agent
        // is alive, but another process group owns the terminal.
        #expect(!workspaceDecision(
            workspace,
            panel,
            foregroundProcessGroupID: Int(getpgid(getpid())) + 1
        ))
    }

    @MainActor
    private func workspaceDecision(
        _ workspace: Workspace,
        _ panel: TerminalPanel,
        foregroundProcessGroupID: Int?,
        processGroupID: (pid_t) -> pid_t = { getpgid($0) }
    ) -> Bool {
        TerminalAgentImagePasteRouting.shouldSendAgentPasteKey(
            isEnabled: true,
            workspace: workspace,
            panel: panel,
            pasteboardTypes: { Self.screenshotTypes },
            foregroundProcessGroupID: { foregroundProcessGroupID },
            processGroupID: processGroupID,
            refreshPortsAfterPrune: false,
            resolveTarget: { .local }
        )
    }
}
