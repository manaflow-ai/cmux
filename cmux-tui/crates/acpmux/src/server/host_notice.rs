//! `_acpmux/host_notice {text}`: one muted line in every live chat on this
//! daemon, from outside any chat (`acpmux machine notice --text`). cmux Cloud's
//! server adds one after it resizes the machine ("Machine grew to 4 vCPU /
//! 8 GiB (it ran out of memory)"). Each live (not closed) session's journal gets
//! a mux `host_notice` record `{text, source: "cloud"}`, a transcript kind
//! (`hub/paging.rs`) a chat client draws as a notice row. Part of the request
//! handler (`requests.rs`).
//!
//! Never from a Web client, or a peer forwarding for one: only this machine
//! (its socket, its app, the provider exec that runs the CLI) adds lines.

use super::Conn;
use crate::hub::{Control, Hub};
use crate::rpc::RpcError;
use crate::store::SessionStatus;
use serde_json::{Value, json};
use std::sync::Arc;

/// The method name.
pub(super) const METHOD: &str = "_acpmux/host_notice";
/// The record kind.
pub const KIND: &str = "host_notice";
/// The longest line, in characters.
pub const MAX_CHARS: usize = 300;

/// The line a notice carries: trimmed, one line, at most [`MAX_CHARS`].
pub fn line(text: &str) -> Result<String, RpcError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(RpcError::invalid_params("text is empty"));
    }
    if text.contains(['\n', '\r']) {
        return Err(RpcError::invalid_params("text is one line"));
    }
    if text.chars().count() > MAX_CHARS {
        return Err(RpcError::invalid_params(format!("text is at most {MAX_CHARS} characters")));
    }
    Ok(text.to_owned())
}

/// Appends the notice to every live session here; returns how many got it.
pub fn append_all(hub: &Hub, text: &str) -> usize {
    let live: Vec<_> =
        hub.sessions().into_iter().filter(|s| s.meta().status != SessionStatus::Closed).collect();
    for s in &live {
        hub.append(s, "mux", KIND, json!({"text": text, "source": "cloud"}));
    }
    live.len()
}

pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if super::remote_guard::control_of(conn.origin, conn.auth, params) == Control::Web {
        return Err(RpcError::new(-32000, "a host notice is added only from this machine"));
    }
    let Some(text) = params.get("text").and_then(Value::as_str) else {
        return Err(RpcError::invalid_params("text must be a string"));
    };
    let text = line(text)?;
    let (hub, t) = (hub.clone(), text.clone());
    let appended = tokio::task::spawn_blocking(move || append_all(&hub, &t))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    Ok(json!({"appended": appended}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_notice_is_one_bounded_line() {
        assert_eq!(
            line("  Machine grew to 4 vCPU / 8 GiB ").unwrap(),
            "Machine grew to 4 vCPU / 8 GiB"
        );
        assert!(line("").is_err());
        assert!(line("a\nb").is_err());
        assert!(line(&"x".repeat(MAX_CHARS)).is_ok());
        assert!(line(&"x".repeat(MAX_CHARS + 1)).is_err());
    }
}
