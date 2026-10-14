import CnxModel
import Foundation

/// Whether closing a tab needs the person's confirmation (Codex QA F9): a
/// terminal running an agent or a known long-running program, not a shell at
/// its prompt. The Mac reports agents (Codex, Claude) by status; a program
/// otherwise names the tab through its title.
public struct TabCloseGuard: Sendable {
    /// Programs whose tab asks before closing (by the title's first word).
    static let programs: Set<String> = [
        "codex", "claude", "gemini", "aider", "vim", "nvim", "vi", "emacs", "nano", "hx", "top", "htop", "btop",
        "less", "man", "ssh", "mosh", "tmux", "screen", "python", "python3", "node", "npm", "pnpm", "bun", "cargo",
        "make", "docker", "kubectl",
    ]

    public init() {}

    /// The running program's name, or nil when the tab closes at once.
    public func runningProgram(_ tab: WorkspaceTab) -> String? {
        guard tab.kind == .terminal else { return nil }
        if tab.agentStatus != nil { return tab.agentName }
        let first = tab.title.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let name = (first as NSString).lastPathComponent.lowercased()
        return Self.programs.contains(name) ? name : nil
    }
}
