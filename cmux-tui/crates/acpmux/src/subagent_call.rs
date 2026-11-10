//! Which Claude Code subagent made a tool call, by the call's tool use id (W5-M follow-up,
//! 2026-11-08).
//!
//! A subagent that reaches acpmux through MCP tools (`mcp__acpmux__send`, cmux's
//! `acpmux_bg_start`, a `cmux_exec` script) makes no Bash call, so the Bash hook's mark
//! (`ACPMUX_CALLER_SUBAGENT`) never names it, and its MCP server runs with its lead's caller
//! token. Claude Code names each tool call by one id in two places: the hook's input
//! (`tool_use_id`, with the subagent's `agent_id`) and the MCP request
//! (`_meta["claudecode/toolUseId"]`, which cmux's MCP server passes on to the server behind
//! it). So acpmux's PreToolUse hook records the subagent of the call here (`bg_hook.rs`), and
//! acpmux's MCP server reads it for the call it runs (`acpmux_mcp.rs`). The call's PostToolUse
//! (or PostToolUseFailure) hook removes it, a `SubagentStop` all of that subagent's, and a
//! closed session's folder goes with it.
//!
//! `<home>/run/subagent-calls/<session>/<tool use id>.json`: `{id, type}`, folders 0700, files
//! 0600, written whole under another name first ([`crate::subagent_notice::leave`]).

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The folder below the daemon's `run` folder.
const DIR: &str = "subagent-calls";
/// The `_meta` key Claude Code names an MCP tool call's tool use id by.
pub const TOOL_USE_ID_META: &str = "claudecode/toolUseId";

/// `session`'s folder.
fn session_dir(home: &Path, session: &str) -> PathBuf {
    home.join("run").join(DIR).join(crate::subagent_notice::safe_name(session))
}

/// The record of tool call `tool_use_id`; none for an id that is no plain file name.
fn call_path(home: &Path, session: &str, tool_use_id: &str) -> Option<PathBuf> {
    crate::subagent_notice::name_word(tool_use_id)
        .then(|| session_dir(home, session).join(format!("{tool_use_id}.json")))
}

/// Records that subagent `agent` (Claude Code's `agent_id`), of type `kind`, makes tool call
/// `tool_use_id` in `session`.
pub fn record(
    home: &Path,
    session: &str,
    tool_use_id: &str,
    agent: &str,
    kind: &str,
) -> std::io::Result<()> {
    let word = crate::cli::sender::subagent_word;
    if !word(agent) || !word(kind) || call_path(home, session, tool_use_id).is_none() {
        return Err(std::io::Error::other("a subagent's call is named by plain words"));
    }
    let sub = json!({"id": agent, "type": kind});
    crate::subagent_notice::leave(&session_dir(home, session), tool_use_id, &sub).map(|_| ())
}

/// The subagent (`{id, type}`) that makes tool call `tool_use_id` in `session`, while it runs.
pub fn of(home: &Path, session: &str, tool_use_id: &str) -> Option<Value> {
    let text = std::fs::read(call_path(home, session, tool_use_id)?).ok()?;
    let sub: Value = serde_json::from_slice(&text).ok()?;
    let word = |key: &str| {
        sub.get(key).and_then(Value::as_str).filter(|w| crate::cli::sender::subagent_word(w))
    };
    let (id, kind) = (word("id")?, word("type")?);
    Some(json!({"id": id, "type": kind}))
}

/// The subagent that makes the MCP `tools/call` `params` in `session`, by its
/// `_meta["claudecode/toolUseId"]`.
pub fn of_call(home: &Path, session: &str, params: &Value) -> Option<Value> {
    let id = params.get("_meta")?.get(TOOL_USE_ID_META)?.as_str()?;
    of(home, session, id)
}

/// Tool call `tool_use_id` ended: it names nobody any more.
pub fn end(home: &Path, session: &str, tool_use_id: &str) {
    if let Some(path) = call_path(home, session, tool_use_id) {
        let _ = std::fs::remove_file(path);
    }
}

/// Subagent `agent` stopped: none of its calls runs any more.
pub fn end_agent(home: &Path, session: &str, agent: &str) {
    let Ok(entries) = std::fs::read_dir(session_dir(home, session)) else { return };
    for path in entries.filter_map(Result::ok).map(|e| e.path()) {
        let theirs = std::fs::read(&path)
            .ok()
            .and_then(|text| serde_json::from_slice::<Value>(&text).ok())
            .is_some_and(|sub| sub.get("id").and_then(Value::as_str) == Some(agent));
        if theirs {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Removes `session`'s records: it closed.
pub fn forget(home: &Path, session: &str) {
    let _ = std::fs::remove_dir_all(session_dir(home, session));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_call_names_its_subagent_until_it_ends() {
        let home = std::env::temp_dir().join(format!("subagent-call-{}", uuid::Uuid::now_v7()));
        let sub = json!({"id": "a0a68e7af3df5967e", "type": "general-purpose"});
        record(&home, "s/1", "toolu_01a", "a0a68e7af3df5967e", "general-purpose").unwrap();
        record(&home, "s/1", "toolu_01b", "a0a68e7af3df5967e", "general-purpose").unwrap();
        record(&home, "s/1", "toolu_01c", "b1", "Explore").unwrap();
        assert!(record(&home, "s/1", "..", "a0", "general-purpose").is_err(), "no path");
        assert!(record(&home, "s/1", "toolu_01d", "a/0", "general-purpose").is_err(), "no path");
        let params = json!({"name": "send", "_meta": {TOOL_USE_ID_META: "toolu_01a"}});
        assert_eq!(of_call(&home, "s/1", &params), Some(sub.clone()));
        assert_eq!(of_call(&home, "s/1", &json!({"name": "send"})), None);
        assert_eq!(of(&home, "s/2", "toolu_01a"), None, "another session's call");
        end(&home, "s/1", "toolu_01a");
        assert_eq!(of(&home, "s/1", "toolu_01a"), None);
        assert_eq!(of(&home, "s/1", "toolu_01b"), Some(sub));
        end_agent(&home, "s/1", "a0a68e7af3df5967e");
        assert_eq!(of(&home, "s/1", "toolu_01b"), None);
        assert_eq!(of(&home, "s/1", "toolu_01c"), Some(json!({"id": "b1", "type": "Explore"})));
        forget(&home, "s/1");
        assert_eq!(of(&home, "s/1", "toolu_01c"), None);
        let _ = std::fs::remove_dir_all(&home);
    }
}
