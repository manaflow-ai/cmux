//! Hook commands for the events whose output the helper writes: the ones
//! that hand an agent its pending messages (`cmux agent message`), and
//! claude's `SessionStart`, which carries cmux's startup line (how the
//! session compacts). Every other event keeps the journal-only shape.

use super::{COMMAND_MARKER, shell_quote, sync_barrier_event};

/// Events whose hook output carries the agent's pending messages
/// (`cmux agent message`): the helper prints the provider's JSON itself, so
/// the command echoes `{}` only when the helper is missing or fails, and
/// Claude runs the hook synchronously to read that output.
pub(super) fn delivers_messages(provider: &str, event: &str) -> bool {
    matches!(
        (provider, event),
        ("claude", "UserPromptSubmit")
            | ("claude", "SessionStart")
            | ("codex", "UserPromptSubmit")
            | ("codex", "Stop")
    )
}

/// The helper an installed command falls back to without `CMUX_TUI_HOOK`:
/// the installed one inside tmux, nothing elsewhere.
const INSTALLED_FALLBACK: &str =
    "${TMUX:+${XDG_DATA_HOME:-$HOME/.local/share}/cmux-tui/bin/cmux-tui-hook}";

/// The installed hook command. It runs `$CMUX_TUI_HOOK`, which every cmux-tui
/// terminal exports. An agent inside tmux may have been started by a tmux
/// server that never ran in a cmux-tui terminal, so without that variable a
/// tmux pane falls back to the installed helper, which routes the event to the
/// cmux-tui terminal attached to the pane's tmux session. Anywhere else the
/// command stays a process-free no-op.
pub(super) fn hook_command(provider: &str, event: &str) -> String {
    hook_command_with(provider, event, "", INSTALLED_FALLBACK)
}

/// The command shapes of [`hook_command`], run after `prefix` (shell words
/// ending in `;`) and falling back to `fallback` (a shell word expanded in an
/// assignment) when `CMUX_TUI_HOOK` is unset or empty.
pub(super) fn hook_command_with(
    provider: &str,
    event: &str,
    prefix: &str,
    fallback: &str,
) -> String {
    let provider_word = shell_quote(provider);
    let event_word = shell_quote(event);
    if matches!(provider, "claude" | "codex") && sync_barrier_event(event) {
        return format!(
            "{prefix}h=${{CMUX_TUI_HOOK:-{fallback}}};if [ -n \"$h\" ];then \"$h\" {provider_word} {event_word}||exit 2;else echo {{}};fi;#{COMMAND_MARKER}",
        );
    }
    if delivers_messages(provider, event) {
        return format!(
            "{prefix}h=${{CMUX_TUI_HOOK:-{fallback}}};\"${{h:-false}}\" {provider_word} {event_word} 2>/dev/null||echo {{}};#{COMMAND_MARKER}",
        );
    }
    format!(
        "{prefix}h=${{CMUX_TUI_HOOK:-{fallback}}};\"${{h:-:}}\" {provider_word} {event_word} 2>/dev/null||:;echo {{}};#{COMMAND_MARKER}",
    )
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
