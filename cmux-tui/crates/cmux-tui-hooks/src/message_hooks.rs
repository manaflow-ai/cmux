//! Hook commands for the events whose output the helper writes: the ones
//! that hand an agent its pending messages (`cmux agent message`), and
//! claude's `SessionStart`, which carries cmux's startup line (how the
//! session compacts). Every other event keeps the journal-only shape.

use serde_json::{Map, Value, json};

use super::{COMMAND_MARKER, HOOK_MODE_ARG, shell_quote, sync_barrier_event};

/// The events after which an idle Claude waits for its messages: a start
/// and every end of a turn (`StopFailure` ends one on an API error).
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) const CLAUDE_WAKE_EVENTS: &[&str] = &["SessionStart", "Stop", "StopFailure"];

/// Claude Code does not enforce a background hook's timeout; this bounds the
/// wait hook anyway if a later version does. The helper ends itself sooner.
#[cfg_attr(not(unix), allow(dead_code))]
const CLAUDE_WAKE_TIMEOUT_SECONDS: u64 = 86_400;

/// Adds Claude's idle wake to a wrapped session's hooks (issue 36496): after
/// each event in [`CLAUDE_WAKE_EVENTS`] a background `asyncRewake` hook waits
/// in the daemon for this terminal's messages and exits 2 with them on
/// stderr, which Claude Code shows the model as a system reminder, waking an
/// idle session. `async` keeps a Claude Code without `asyncRewake` from
/// waiting on it. Only the wrapper's `--settings` carry it, never an
/// installed settings file: the helper checks that it runs under the
/// wrapper's Claude (`CMUX_TUI_CLAUDE_PID`), which only the wrapper sets.
/// `quoted_binary` is the cmux-tui binary for hosts without the helper.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn with_claude_wake(
    mut root: Map<String, Value>,
    quoted_binary: Option<&str>,
) -> anyhow::Result<Map<String, Value>> {
    let hooks = root
        .get_mut("hooks")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow::anyhow!("hooks missing"))?;
    let command = match quoted_binary {
        Some(binary) => format!("{binary} {HOOK_MODE_ARG} claude inbox-wait;#{COMMAND_MARKER}"),
        None => format!(
            "h=${{CMUX_TUI_HOOK:-${{TMUX:+${{XDG_DATA_HOME:-$HOME/.local/share}}/cmux-tui/bin/cmux-tui-hook}}}};\"${{h:-:}}\" claude inbox-wait;#{COMMAND_MARKER}"
        ),
    };
    for event in CLAUDE_WAKE_EVENTS {
        let groups = hooks.entry(*event).or_insert_with(|| json!([]));
        let groups = groups
            .as_array_mut()
            .ok_or_else(|| anyhow::anyhow!("hook event {event:?} must be an array"))?;
        groups.push(json!({"hooks": [{
            "type": "command",
            "command": command,
            "timeout": CLAUDE_WAKE_TIMEOUT_SECONDS,
            "async": true,
            "asyncRewake": true,
        }]}));
    }
    Ok(root)
}

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

/// The installed hook command. It runs `$CMUX_TUI_HOOK`, which every cmux-tui
/// terminal exports. An agent inside tmux may have been started by a tmux
/// server that never ran in a cmux-tui terminal, so without that variable a
/// tmux pane falls back to the installed helper, which routes the event to the
/// cmux-tui terminal attached to the pane's tmux session. Anywhere else the
/// command stays a process-free no-op.
pub(super) fn hook_command(provider: &str, event: &str) -> String {
    if matches!(provider, "claude" | "codex") && sync_barrier_event(event) {
        return format!(
            "h=${{CMUX_TUI_HOOK:-${{TMUX:+${{XDG_DATA_HOME:-$HOME/.local/share}}/cmux-tui/bin/cmux-tui-hook}}}};if [ -n \"$h\" ];then \"$h\" {} {}||exit 2;else echo {{}};fi;#{COMMAND_MARKER}",
            shell_quote(provider),
            shell_quote(event),
        );
    }
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
