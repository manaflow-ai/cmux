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
mod tests {
    use super::*;

    fn record(fields: Value) -> Value {
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": fields}})
    }

    fn shaped(kind: &str, fields: Value) -> Value {
        let mut msg = record(fields);
        add_shell_fields(kind, &mut msg);
        msg["params"]["update"].take()
    }

    #[test]
    fn opencode_shell_exit_code_moves_to_raw_output_exit_code() {
        // `opencode acp` v1.19.5: a command that exited 2 is a completed call.
        let update = shaped(
            "tool_call_update",
            json!({
                "sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed",
                "content": [{"type": "content", "content": {"type": "text", "text": "ls: x: No such file"}}],
                "rawOutput": {"output": "ls: x: No such file", "metadata": {"output": "ls: x: No such file", "exit": 2, "truncated": false}},
            }),
        );
        assert_eq!(update["rawOutput"]["exit_code"], 2, "{update}");
        assert_eq!(update["rawOutput"]["metadata"]["exit"], 2, "what OpenCode sent stays");
        assert_eq!(update["rawOutput"]["output"], "ls: x: No such file");
        assert_eq!(update["status"], "completed", "the status is the agent's");

        // A failed OpenCode call (`errorToolUpdate`) carries its metadata too.
        let failed = shaped(
            "tool_call_update",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "call_2", "status": "failed",
                   "rawOutput": {"error": "timed out", "metadata": {"exit": 143}}}),
        );
        assert_eq!(failed["rawOutput"]["exit_code"], 143);
        // A tool whose metadata names no exit (an edit) gets none.
        let edit = shaped(
            "tool_call_update",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "call_3", "status": "completed",
                   "rawOutput": {"output": "ok", "metadata": {"diff": "..."}}}),
        );
        assert!(edit["rawOutput"].get("exit_code").is_none(), "{edit}");
    }

    #[test]
    fn pi_terminal_call_gets_its_command_and_exit_code() {
        // pi-acp 0.0.34: the bash call names its command only in its title.
        let call = shaped(
            "tool_call",
            json!({
                "sessionUpdate": "tool_call", "toolCallId": "toolu_1", "title": "cargo test -p demo",
                "kind": "execute", "status": "pending", "locations": [],
                "content": [{"type": "terminal", "terminalId": "toolu_1"}],
                "_meta": {"terminal_info": {"terminal_id": "toolu_1", "cwd": "/work/demo"}},
            }),
        );
        assert_eq!(
            call["rawInput"],
            json!({"command": "cargo test -p demo", "cwd": "/work/demo"}),
            "{call}"
        );
        assert_eq!(call["title"], "cargo test -p demo");
        assert_eq!(call["_meta"]["terminal_info"]["cwd"], "/work/demo", "the agent's _meta stays");

        // Its end: the output's last part and the exit, with no rawOutput.
        let end = shaped(
            "tool_call_update",
            json!({
                "sessionUpdate": "tool_call_update", "toolCallId": "toolu_1", "status": "failed",
                "_meta": {
                    "terminal_output": {"terminal_id": "toolu_1", "data": "test result: FAILED\n"},
                    "terminal_exit": {"terminal_id": "toolu_1", "exit_code": 101, "signal": null},
                },
            }),
        );
        assert_eq!(end["rawOutput"], json!({"exit_code": 101}), "{end}");
        assert!(
            end.get("rawInput").is_none(),
            "an update without terminal_info names no input: {end}"
        );

        // A call whose arguments had not come yet is titled with the tool's name: no command.
        let early = shaped(
            "tool_call",
            json!({"sessionUpdate": "tool_call", "toolCallId": "toolu_2", "title": "bash", "kind": "execute",
                   "_meta": {"terminal_info": {"terminal_id": "toolu_2", "cwd": "/w"}}}),
        );
        assert!(early.get("rawInput").is_none(), "{early}");
    }

    #[test]
    fn a_call_that_says_its_own_keeps_it() {
        // Codex (cmux-codex-acp) already puts the exit code where clients read it.
        let codex = shaped(
            "tool_call_update",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed",
                   "rawOutput": {"exit_code": 0, "duration_ms": 12, "status": "completed", "metadata": {"exit": 9}}}),
        );
        assert_eq!(codex["rawOutput"]["exit_code"], 0);
        let camel = shaped(
            "tool_call_update",
            json!({"toolCallId": "c2", "rawOutput": {"exitCode": 3, "metadata": {"exit": 9}}}),
        );
        assert!(camel["rawOutput"].get("exit_code").is_none(), "{camel}");
        // A call with its own input keeps it.
        let input = shaped(
            "tool_call",
            json!({"toolCallId": "p1", "title": "ls", "rawInput": {"command": "ls -la"},
                   "_meta": {"terminal_info": {"cwd": "/w"}}}),
        );
        assert_eq!(input["rawInput"], json!({"command": "ls -la"}));
        // A text result has nowhere to put a code.
        let text = shaped(
            "tool_call_update",
            json!({"toolCallId": "p2", "rawOutput": "done", "_meta": {"terminal_exit": {"exit_code": 1}}}),
        );
        assert_eq!(text["rawOutput"], "done");
    }

    #[test]
    fn only_tool_call_records_change() {
        let fields = json!({"toolCallId": "x", "_meta": {"terminal_exit": {"exit_code": 1}}});
        assert_eq!(shaped("agent_message_chunk", fields.clone()), fields);
        assert_eq!(shaped("tool_call_update.replay", fields)["rawOutput"]["exit_code"], 1);
        // Claude Code's Bash call has its own input and no exit outside its text.
        let claude = json!({"sessionUpdate": "tool_call", "toolCallId": "toolu_9", "kind": "execute",
            "title": "`ls`", "rawInput": {"command": "ls", "description": "List files"},
            "_meta": {"claude": {"tool": "Bash"}}});
        assert_eq!(shaped("tool_call", claude.clone()), claude);
    }
}
