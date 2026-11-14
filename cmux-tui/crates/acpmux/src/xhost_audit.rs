//! The cross-host send audit log: one JSON line per message that crosses machines, on the
//! machine that sent it and on the one that took it, in `cross-host-audit.jsonl` under the
//! acpmux home (owner-only). A line names who sent what to whom and how it went (a peer link
//! or the send relay), never the text: `{"at", "dir": "sent"|"received", "via", "to", "from",
//! "host", "bytes", ...}`.
//!
//! - Sent: a send handed to the send relay (`cli/send_relay.rs`, the CLI and the MCP `send`
//!   tool), and a message this daemon forwarded to a peer's session (`server/peer_forward.rs`).
//! - Received: a message a peer daemon forwarded here, or one whose sender names another
//!   machine (`HOST/NAME`, such as a broker's relay of a lane VM's message), when it arrives and
//!   its checks pass, not when its turn ends (`server/requests.rs`); one this daemon then
//!   refuses is a `refused` line with the error's code.
//!
//! Writing it never fails a send: an error is said on stderr once and the message goes on.

use serde_json::{Value, json};
use std::io::Write;
use std::path::PathBuf;

/// The log's file name under the acpmux home.
pub const FILE: &str = "cross-host-audit.jsonl";

/// Where the log is: `ACPMUX_HOME` (or the default home)'s [`FILE`].
pub fn path() -> PathBuf {
    crate::config::home().join(FILE)
}

/// Append one line: `fields` (an object) with `at` (ms since the epoch), `dir` and this
/// machine's name as `host`.
pub fn record(dir: &str, mut fields: Value) {
    if let Some(object) = fields.as_object_mut() {
        object.insert("at".into(), json!(crate::store::now_ms()));
        object.insert("dir".into(), json!(dir));
        object.entry("host").or_insert_with(|| json!(crate::pairing::machine_name()));
    }
    if let Err(e) = append(&fields) {
        static SAID: std::sync::Once = std::sync::Once::new();
        SAID.call_once(|| {
            eprintln!("acpmux: cannot write the cross-host audit log {}: {e}", path().display())
        });
    }
}

/// Appended through the home's owner-only state-file open (`config::private_state_append`):
/// never through a link, refused when another user owns it or may write it, and narrowed to
/// the owner when an older file is wider.
fn append(line: &Value) -> anyhow::Result<()> {
    append_to(&path(), line)
}

fn append_to(path: &std::path::Path, line: &Value) -> anyhow::Result<()> {
    if let Some(dir) = path.parent() {
        crate::config::private_state_dir(dir)?;
    }
    let mut file = crate::config::private_state_append(path)?;
    let mut text = line.to_string();
    text.push('\n');
    file.write_all(text.as_bytes())?;
    Ok(())
}

/// The machine a sender name `HOST/NAME` names, when it is another machine than this one:
/// such a message crossed machines even when it reached this daemon over its own socket (a
/// broker on this host relaying a lane VM's message).
pub fn other_machine(from: &str) -> Option<&str> {
    let (host, rest) = from.split_once('/')?;
    let own = crate::pairing::machine_name();
    (!host.is_empty() && !rest.is_empty() && host != "local" && !host.eq_ignore_ascii_case(&own))
        .then_some(host)
}

/// What a prompt's params (`session/prompt`, or `_acpmux/send_queue`'s `request`) carry for
/// the log: its session key, sender (`fromAgent`), prompt id and text size.
pub fn prompt_fields(params: &Value) -> Value {
    let request = params.get("request").unwrap_or(params);
    let mux = request.pointer("/_meta/acpmux");
    let bytes: usize = request
        .get("prompt")
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks.iter().filter_map(|b| b.get("text").and_then(Value::as_str)).map(str::len).sum()
        })
        .unwrap_or(0);
    json!({
        "to": request.get("sessionId").cloned().unwrap_or(Value::Null),
        "from": mux.and_then(|m| m.get("fromAgent")).cloned().unwrap_or(Value::Null),
        "promptId": mux.and_then(|m| m.get("promptId")).cloned().unwrap_or(Value::Null),
        "bytes": bytes,
    })
}

/// The lines of this home's log, oldest first (tests and `acpmux` diagnostics).
pub fn read() -> Vec<Value> {
    std::fs::read_to_string(path())
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

#[cfg(test)]
mod tests;
