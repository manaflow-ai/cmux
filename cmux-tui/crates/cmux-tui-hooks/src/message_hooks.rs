//! Hook commands for the events whose output the helper writes: the ones
//! that hand an agent its pending messages (`cmux agent message`), and
//! claude's `SessionStart`, which carries cmux's startup line (how the
//! session compacts). Every other event keeps the journal-only shape.

use serde_json::{Map, Value, json};

use super::{COMMAND_MARKER, HOOK_MODE_ARG, shell_quote, sync_barrier_event};

/// What a launch's own message hooks name it with: the wrapper's process id
/// (`CMUX_TUI_CLAUDE_PID`), written into each command (issue 36496).
pub const LAUNCH_ENV: &str = "CMUX_TUI_HOOK_LAUNCH";

/// The events after which an idle Claude waits for its messages: a start
/// and every end of a turn (`StopFailure` ends one on an API error).
const CLAUDE_WAKE_EVENTS: &[&str] = &["SessionStart", "Stop", "StopFailure"];

/// Claude Code does not enforce a background hook's timeout; this bounds the
/// wait hook anyway if a later version does. The helper ends itself sooner.
const CLAUDE_WAKE_TIMEOUT_SECONDS: u64 = 86_400;

/// The prompt hook that hands queued messages over; it never waits.
const CLAUDE_DRAIN_TIMEOUT_SECONDS: u64 = 10;

/// Adds the hooks that hand agent messages to the Claude one wrapper launch
/// starts (issue 36496) to that launch's `--settings` hooks. Every command
/// names `launch` (the wrapper's process id, which it exports as
/// `CMUX_TUI_CLAUDE_PID`) as a literal, so only Claude processes that run
/// this launch's settings carry it: the Claude the wrapper execs, or the one
/// a launcher it execs starts with the same arguments, whether the launcher
/// execs it or not. A Claude started inside it (a tool call, a second
/// install, a nested wrapper, which injects nothing) inherits
/// `CMUX_TUI_CLAUDE_PID` but runs other settings, so its hooks name no
/// launch and take nothing. The settings carry no process inspection.
///
/// - `SessionStart`, `Stop`, `StopFailure`: a background `asyncRewake` wait
///   (`cmux-tui-hook claude inbox-wait`) that exits 2 with the messages on
///   stderr, which Claude Code shows the model as a system reminder, waking
///   an idle session. `async` keeps a Claude Code without `asyncRewake` from
///   waiting on it.
/// - `UserPromptSubmit`: `inbox-drain`, which hands queued messages over as
///   the submitted prompt's context. The shared prompt hook (byte-identical
///   to the installed one, so Claude Code runs it once) names no launch and
///   takes nothing under the wrapper.
///
/// `quoted_binary` is the cmux-tui binary for hosts without the helper.
pub fn add_claude_launch_hooks(
    hooks: &mut Map<String, Value>,
    launch: u32,
    quoted_binary: Option<&str>,
) -> anyhow::Result<()> {
    let helper = |mode: &str, missing: &str| match quoted_binary {
        Some(binary) => format!("{LAUNCH_ENV}={launch} {binary} {HOOK_MODE_ARG} claude {mode}"),
        None => format!(
            "h=${{CMUX_TUI_HOOK:-${{TMUX:+${{XDG_DATA_HOME:-$HOME/.local/share}}/cmux-tui/bin/cmux-tui-hook}}}};{LAUNCH_ENV}={launch} \"${{h:-{missing}}}\" claude {mode}"
        ),
    };
    let wake = json!({
        "type": "command",
        "command": format!("{};#{COMMAND_MARKER}", helper("inbox-wait", ":")),
        "timeout": CLAUDE_WAKE_TIMEOUT_SECONDS,
        "async": true,
        "asyncRewake": true,
    });
    let drain = json!({
        "type": "command",
        "command": format!("{} 2>/dev/null||echo {{}};#{COMMAND_MARKER}", helper("inbox-drain", "false")),
        "timeout": CLAUDE_DRAIN_TIMEOUT_SECONDS,
    });
    let groups = CLAUDE_WAKE_EVENTS
        .iter()
        .map(|event| (*event, wake.clone()))
        .chain([("UserPromptSubmit", drain)]);
    for (event, hook) in groups {
        let entries = hooks.entry(event).or_insert_with(|| json!([]));
        let entries = entries
            .as_array_mut()
            .ok_or_else(|| anyhow::anyhow!("hook event {event:?} must be an array"))?;
        entries.push(json!({"hooks": [hook]}));
    }
    Ok(())
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
