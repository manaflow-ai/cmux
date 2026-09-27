import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd+V sends Ctrl+V to Claude Code or Codex only when the setting is on, the
/// agent is live in the pane, the clipboard holds only an image, and the pane
/// is local. Every other combination keeps the temp-path paste.
@Suite("Agent image paste routing")
struct TerminalAgentImagePasteRoutingTests {
    private static let screenshotTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
    private static let liveClaude = "agentPIDKey:claude_code"
    private static let liveCodex = "agentPIDKey:codex.019a2b3c-session"

    private func decision(
        isEnabled: Bool = true,
        agentContext: String = liveClaude,
        types: [NSPasteboard.PasteboardType] = screenshotTypes,
        target: TerminalImageTransferTarget = .local
    ) -> Bool {
        TerminalAgentImagePasteRouting.shouldSendAgentPasteKey(
            isEnabled: isEnabled,
            agentContext: { agentContext },
            pasteboardTypes: { types },
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
}
