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

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use serde_json::Value;

    use super::*;
    use crate::agent_hook_install::tests::context;
    use crate::agent_hook_install::{
        Action, Plan, atomic_write, codex_event_state_label, codex_hook_timeout,
        codex_owned_trust_hashes, codex_trust_hash, run_with_context,
    };

    #[cfg(unix)]
    #[test]
    fn message_hooks_print_the_helper_output_and_fall_back_to_an_empty_object() {
        use std::process::Command;

        let root = tempfile::tempdir().unwrap();
        let helper = root.path().join("helper");
        let command = hook_command("codex", "Stop");
        assert!(command.contains("||echo {}"), "{command}");
        let run = |hook: Option<&Path>| {
            let mut shell = Command::new("/bin/sh");
            shell.args(["-c", &command]).env_remove("TMUX");
            match hook {
                Some(hook) => shell.env("CMUX_TUI_HOOK", hook),
                None => shell.env_remove("CMUX_TUI_HOOK"),
            };
            let output = shell.output().unwrap();
            assert!(output.status.success());
            String::from_utf8(output.stdout).unwrap()
        };
        // No helper: an empty object, without starting a process.
        assert_eq!(run(None), "{}\n");
        // The helper's own object is the whole output.
        atomic_write(&helper, b"#!/bin/sh\necho '{\"decision\":\"block\"}'\n", Some(0o755))
            .unwrap();
        assert_eq!(run(Some(&helper)), "{\"decision\":\"block\"}\n");
        // A failing helper prints nothing, and the command adds the object.
        atomic_write(&helper, b"#!/bin/sh\nexit 1\n", Some(0o755)).unwrap();
        assert_eq!(run(Some(&helper)), "{}\n");
    }

    #[test]
    fn only_the_message_events_change_shape_and_claude_runs_them_synchronously() {
        for (provider, event) in
            [("claude", "UserPromptSubmit"), ("codex", "UserPromptSubmit"), ("codex", "Stop")]
        {
            assert_ne!(hook_command(provider, event), journal_hook_command(provider, event));
        }
        for (provider, event) in [("claude", "Stop"), ("codex", "PreToolUse"), ("gemini", "Stop")] {
            assert_eq!(hook_command(provider, event), journal_hook_command(provider, event));
        }
        let root = tempfile::tempdir().unwrap();
        let context = context(root.path());
        let install = Plan { action: Action::Install, providers: vec!["claude".into()] };
        assert!(!run_with_context(&install, &context).failed);
        let settings: Value =
            serde_json::from_slice(&fs::read(context.home.join(".claude/settings.json")).unwrap())
                .unwrap();
        let prompt = &settings["hooks"]["UserPromptSubmit"][0]["hooks"][0];
        assert_eq!(prompt.get("async"), None, "{prompt}");
        assert_eq!(settings["hooks"]["Stop"][0]["hooks"][0]["async"], true);
    }

    #[test]
    fn codex_trust_covers_the_journal_only_shape_of_message_events() {
        // An install from before agent messages has the journal-only command
        // for UserPromptSubmit and Stop; an upgrade must recognize its trust
        // entries as cmux-owned and replace them.
        let owned = codex_owned_trust_hashes().unwrap();
        for event in ["UserPromptSubmit", "Stop"] {
            let label = codex_event_state_label(event).unwrap();
            let hash = codex_trust_hash(
                label,
                &journal_hook_command("codex", event),
                codex_hook_timeout(event),
            );
            assert!(owned.contains(&hash), "{event}");
        }
    }
}
