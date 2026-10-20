import CnxModel
import Foundation

/// The one question a tab close can ask, as the cmux-next Mac app asks it
/// (`CmuxNextApp/Handlers/TabCloseGuard.swift`, #17501): only while a closing
/// terminal is doing work. A working agent in it (or one waiting on an answer)
/// is that agent's question ("Codex is still working."); else a foreground
/// program other than the login shell, which the Mac reports through
/// `process-info` (`foreground_executable`), asks "Still running: sleep.".
/// Idle shells, ended shells, browser tabs and agent chats close at once.
/// The title is never read: a Codex named by its thread, `sleep` or `yes`
/// under zsh's title all asked nothing before (round 11 N2/A1), and since a
/// phone close ends the terminal (`close-terminal`) that stopped them.
public struct TabCloseGuard: Sendable {
    public init() {}

    public struct Prompt: Equatable, Sendable {
        public var title: String
        public var message: String
    }

    /// The terminals whose foreground program the Mac is asked for: live
    /// terminal tabs with no working agent (an agent's tab is its own question).
    public func terminalsToAsk(_ tabs: [WorkspaceTab]) -> [WorkspaceTab] {
        tabs.filter { $0.kind == .terminal && !$0.hasEndedShell && workingAgent($0) == nil }
    }

    /// The display name of an agent working (or waiting on a permission or a
    /// question) in `tab`'s terminal, else nil. An unnamed agent reads "The agent".
    public func workingAgent(_ tab: WorkspaceTab) -> String? {
        guard tab.kind == .terminal, !tab.hasEndedShell else { return nil }
        let working = tab.agentStatus == .working || (tab.agentStatus == .waiting && tab.waitingFor != nil)
        guard working else { return nil }
        guard let harness = tab.harness, !harness.isEmpty else { return "The agent" }
        return tab.agentName
    }

    /// The question for closing `tabs` (one tab or a group), given the
    /// programs the Mac reported for `terminalsToAsk(tabs)`; nil closes at once.
    public func prompt(closing tabs: [WorkspaceTab], programs: [String]) -> Prompt? {
        let title = tabs.count == 1 ? "Close \u{201C}\(tabs[0].title)\u{201D}?" : "Close \(tabs.count) tabs?"
        if let agent = tabs.lazy.compactMap(workingAgent).first {
            return Prompt(title: title, message: "\(agent) is still working.")
        }
        let unique = Set(programs.filter { !$0.isEmpty }).sorted()
        guard !unique.isEmpty else { return nil }
        return Prompt(title: title, message: "Still running: \(unique.joined(separator: ", ")).")
    }

    /// `process-info`'s foreground program when it is not the terminal's own
    /// shell, else nil.
    public static func runningProgram(foregroundExecutable: String?, command: String?) -> String? {
        TerminalProcessInfo(command: command, foregroundExecutable: foregroundExecutable).runningProgram
    }
}
