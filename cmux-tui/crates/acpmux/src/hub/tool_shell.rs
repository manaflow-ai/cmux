//! Part of `Hub`; see `hub/mod.rs`. A shell call's exit code and command
//! line in the one place every client reads them, whichever ACP agent ran it.
//!
//! Clients read a finished shell call's exit status from
//! `rawOutput.exit_code` (Codex through cmux-codex-acp puts it there) and its
//! command line from `rawInput.command`. Other ACP agents report the same
//! facts elsewhere:
//!
//! - OpenCode (`opencode acp`, v1.19.5 `acp/tool.ts` `completedToolRawOutput`)
//!   sends its shell tool's metadata as `rawOutput.metadata`, whose `exit` is
//!   the exit code (`tool/shell.ts`). A command that exits nonzero is still a
//!   `completed` call, so without its code it reads as a success.
//! - pi (`pi-acp` 0.0.34, `acp/translate/bash.ts`) draws a bash call as a
//!   terminal: no `rawInput`, the command in `title`, its output in
//!   `_meta.terminal_output.data` and its end in
//!   `_meta.terminal_exit.exit_code` (the terminal-in-a-tool-call `_meta`
//!   extension), with `_meta.terminal_info.cwd` on the call itself.
//!
//! This copies those into `rawOutput.exit_code` and, for pi's call,
//! `rawInput.command`/`cwd`, beside what the agent sent: nothing it sent is
//! changed, a call that already says either keeps its own, and nothing is
//! made up for an agent that does not report one (Gemini CLI's ACP sends no
//! input, output or exit code for its shell calls; Claude Code gives its exit
//! code only in the result's text, which clients read there).

use serde_json::{Map, Value, json};

/// Adds `rawOutput.exit_code` and pi's `rawInput` to a `tool_call` or
/// `tool_call_update` record's update when the agent reported them elsewhere.
/// Any other record, or an update that already has them, is left as it is.
pub(super) fn add_shell_fields(kind: &str, msg: &mut Value) {
    if !matches!(kind.strip_suffix(".replay").unwrap_or(kind), "tool_call" | "tool_call_update") {
        return;
    }
    let Some(update) = msg.pointer_mut("/params/update").and_then(Value::as_object_mut) else {
        return;
    };
    add_exit_code(update);
    add_terminal_input(update);
}

/// The exit code the agent reported outside `rawOutput.exit_code`: pi's
/// `_meta.terminal_exit.exit_code`, else OpenCode's `rawOutput.metadata.exit`.
fn reported_exit_code(update: &Map<String, Value>) -> Option<i64> {
    let terminal = update.get("_meta").and_then(|meta| meta.pointer("/terminal_exit/exit_code"));
    let opencode = update.get("rawOutput").and_then(|out| out.pointer("/metadata/exit"));
    terminal.and_then(Value::as_i64).or_else(|| opencode.and_then(Value::as_i64))
}

fn add_exit_code(update: &mut Map<String, Value>) {
    let raw = update.get("rawOutput");
    if raw.is_some_and(|out| out.get("exit_code").is_some() || out.get("exitCode").is_some()) {
        return;
    }
    let Some(code) = reported_exit_code(update) else { return };
    let raw = update.entry("rawOutput").or_insert(Value::Null);
    if raw.is_null() {
        *raw = json!({});
    }
    // A text or list result has nowhere to put it; such a call keeps what it sent.
    if let Some(raw) = raw.as_object_mut() {
        raw.insert("exit_code".into(), json!(code));
    }
}

/// pi's bash call (`_meta.terminal_info`) names its command only in its
/// title: that title becomes `rawInput.command`, with the terminal's cwd. A
/// title that is only the tool's name (pi's when the arguments had not come
/// yet) names no command.
fn add_terminal_input(update: &mut Map<String, Value>) {
    if update.get("rawInput").is_some_and(|input| !input.is_null()) {
        return;
    }
    let Some(info) = update.get("_meta").and_then(|meta| meta.get("terminal_info")) else {
        return;
    };
    let cwd = info.get("cwd").and_then(Value::as_str).map(str::to_owned);
    let title = update.get("title").and_then(Value::as_str).map(str::trim).unwrap_or("");
    if title.is_empty() || title.eq_ignore_ascii_case("bash") {
        return;
    }
    let mut input = Map::new();
    input.insert("command".into(), json!(title));
    if let Some(cwd) = cwd {
        input.insert("cwd".into(), json!(cwd));
    }
    update.insert("rawInput".into(), Value::Object(input));
}

#[cfg(test)]
mod tests;
