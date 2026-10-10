//! Hook commands for the events that hand an agent its pending messages
//! (`cmux agent message`) and the journal-only shape every other event keeps.

use super::{COMMAND_MARKER, shell_quote};

/// Events whose hook output carries the agent's pending messages
/// (`cmux agent message`): the helper prints the provider's JSON itself, so
/// the command echoes `{}` only when the helper is missing or fails, and
/// Claude runs the hook synchronously to read that output.
pub(super) fn delivers_messages(provider: &str, event: &str) -> bool {
    matches!(
        (provider, event),
        ("claude", "UserPromptSubmit") | ("codex", "UserPromptSubmit") | ("codex", "Stop")
    )
}

/// The installed hook command. It runs `$CMUX_TUI_HOOK`, which every cmux-tui
/// terminal exports. An agent inside tmux may have been started by a tmux
/// server that never ran in a cmux-tui terminal, so without that variable a
/// tmux pane falls back to the installed helper, which routes the event to the
/// cmux-tui terminal attached to the pane's tmux session. Anywhere else the
/// command stays a process-free no-op.
pub(super) fn hook_command(provider: &str, event: &str) -> String {
    if delivers_messages(provider, event) {
        return format!(
            "h=${{CMUX_TUI_HOOK:-${{TMUX:+${{XDG_DATA_HOME:-$HOME/.local/share}}/cmux-tui/bin/cmux-tui-hook}}}};\"${{h:-false}}\" {} {} 2>/dev/null||echo {{}};#{COMMAND_MARKER}",
            shell_quote(provider),
            shell_quote(event),
        );
    }
    journal_hook_command(provider, event)
}

/// The command shape that only reports to the journal, still installed for
/// every event that delivers no messages.
pub(super) fn journal_hook_command(provider: &str, event: &str) -> String {
    format!(
        "h=${{CMUX_TUI_HOOK:-${{TMUX:+${{XDG_DATA_HOME:-$HOME/.local/share}}/cmux-tui/bin/cmux-tui-hook}}}};\"${{h:-:}}\" {} {} 2>/dev/null||:;echo {{}};#{COMMAND_MARKER}",
        shell_quote(provider),
        shell_quote(event),
    )
}
