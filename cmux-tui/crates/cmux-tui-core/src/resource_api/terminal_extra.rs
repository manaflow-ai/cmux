//! The `extra` fields of a public terminal value (`public_terminal_snapshot`):
//! live progress, program status, shell activity and the agent start mark.

use serde_json::{Map, Value, json};

/// The `extra` fields of a terminal shown by `surface` (none without one);
/// `running` is false once the terminal exited, which drops the live fields.
pub(super) fn extra(surface: Option<&crate::Surface>, running: bool) -> Map<String, Value> {
    let mut extra = Map::new();
    if let Some(progress) = surface.and_then(crate::Surface::terminal_progress) {
        extra.insert("progress".into(), progress.to_json());
    }
    if let Some(status) = surface.and_then(|surface| surface.terminal_program_status(running)) {
        extra.insert("program_status".into(), status);
    }
    // `terminal-activity-v1`: a shell command runs (OSC 133 C..D), quiet
    // `running` or interactive `in_use`; the older `busy` names a `running`
    // one only. An exited terminal publishes none.
    if running
        && let Some((state, since)) = surface.and_then(crate::Surface::terminal_command_activity)
    {
        extra.insert("activity".into(), crate::terminal_activity::activity_json(state, since));
        if state == crate::terminal_activity::CommandActivity::Running {
            extra.insert("busy".into(), crate::terminal_activity::busy_json(since));
        }
    }
    if running && let Some(since) = surface.and_then(crate::Surface::terminal_prompt_since) {
        extra.insert("prompt".into(), crate::terminal_activity::prompt_json(since));
    }
    // `terminal-exit-status-v1`: the last command the shell finished (OSC
    // 133 D), with its exit code when the shell sent one. Absent without
    // shell integration, so a missing field never reads as success.
    if running && let Some(last) = surface.and_then(crate::Surface::terminal_last_command) {
        extra.insert("last_command".into(), crate::terminal_activity::last_command_json(last));
    }
    if running && let Some(at) = surface.and_then(crate::Surface::terminal_last_output) {
        extra.insert("last_output".into(), crate::terminal_activity::last_output_json(at));
    }
    if running && let Some(at) = surface.and_then(crate::Surface::terminal_last_input) {
        extra.insert("last_input".into(), crate::terminal_activity::last_input_json(at));
    }
    // `agent_start`: the stored spawn argv is the `cmux agent start` launch
    // (agent_start_launch.rs); the CLI evens only such panes. No OS read.
    if surface
        .and_then(crate::Surface::spawn_argv)
        .is_some_and(|argv| crate::agent_start_launch::is_agent_start_argv(&argv))
    {
        extra.insert("agent_start".into(), json!(true));
    }
    extra
}
