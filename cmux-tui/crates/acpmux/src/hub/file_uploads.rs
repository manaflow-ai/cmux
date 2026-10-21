//! Files the person drops or pastes into a chat that the composer can't attach as a prompt block
//! (a binary, a large text file): the app sends each one (`_acpmux/file_put {sessionId,
//! fileName, data}`), and the daemon that owns the session writes it owner-only on its own machine, under
//! `<ACPMUX_HOME>/uploads/<session id>/<random>/<name>` (its own folder, so two files may share a
//! name), and answers `{path}`. The composer puts the path in the prompt and the agent opens it
//! with its own tools. A chat on an ssh peer gets the file there: the request names the session, so
//! `peer_forward.rs` takes it to the daemon that owns it, and a peer that does not advertise
//! [`FEATURE`] is refused before anything is sent.
//!
//! Each file is at most [`MAX_BYTES`]: the request crosses the peer link as one WebSocket frame,
//! and an older peer's listener reads at most tungstenite's default 16 MiB frame (a larger one
//! resets the link and every chat on it). 10 MiB is 13.4 MiB of base64, leaving room for the rest
//! of the request. Like the app's own Chat Uploads folder, nothing deletes them yet.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::path::PathBuf;

/// The `initialize` feature of a daemon that takes `_acpmux/file_put`.
pub const FEATURE: &str = "filePut";
/// The most bytes one file has (see the module doc for why).
pub const MAX_BYTES: usize = 10 << 20;

fn root() -> PathBuf {
    crate::config::home().join("uploads")
}

/// The folder of session `id`'s uploads; none for an id that is not a plain name.
fn session_dir(id: &str) -> Option<PathBuf> {
    let plain =
        !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    plain.then(|| root().join(id))
}

/// A name a folder holds as one plain file (the app's `AgentPaneUpload.isFileName`): 1 to 255
/// UTF-8 bytes, not a dot file (nor `.` or `..`), no `/` (nor `\` on Windows), and no control or
/// bidirectional formatting character.
pub fn is_file_name(name: &str) -> bool {
    if !(1..=255).contains(&name.len())
        || name.starts_with('.')
        || name.contains('/')
        || (cfg!(windows) && name.contains('\\'))
    {
        return false;
    }
    !name.chars().any(|c| {
        let v = u32::from(c);
        v < 0x20
            || v == 0x7f
            || (0x80..=0x9f).contains(&v)
            || (0x202a..=0x202e).contains(&v)
            || (0x2066..=0x2069).contains(&v)
            || v == 0x200e
            || v == 0x200f
    })
}

fn too_large() -> RpcError {
    RpcError::invalid_params(format!("a file is at most {} MiB", MAX_BYTES >> 20))
        .with_data(json!({"reason": "filePut.tooLarge", "maxBytes": MAX_BYTES}))
}

/// The request's `fileName` and `data` (base64) when they keep the contract, before anything is
/// decoded or sent on: the daemon a request reaches first checks it, so no oversize frame goes
/// over a peer link. (Not `name`: that names a session (`server::session_key`), and a forward to
/// a peer drops it.)
pub fn check(params: &Value) -> Result<(&str, &str), RpcError> {
    let name = params
        .get("fileName")
        .and_then(Value::as_str)
        .filter(|name| is_file_name(name))
        .ok_or_else(|| {
            RpcError::invalid_params("fileName must be a plain file name")
                .with_data(json!({"reason": "filePut.name"}))
        })?;
    let data = params
        .get("data")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("data (base64) is required"))?;
    if data.len() > MAX_BYTES.div_ceil(3) * 4 {
        return Err(too_large());
    }
    Ok((name, data))
}

/// `_acpmux/file_put` for one of this daemon's chats: an unknown or purged one is refused.
pub async fn handle(hub: &super::Hub, params: Value) -> Result<Value, RpcError> {
    let id = hub.resolve(crate::server::session_key(&params)?)?.id.clone();
    tokio::task::spawn_blocking(move || put(&id, &params))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
}

/// Writes the file of `params` for session `id` (this daemon's own) and answers `{path}`.
/// Blocking: run it off the runtime.
pub fn put(id: &str, params: &Value) -> Result<Value, RpcError> {
    use base64::Engine;
    let (name, data) = check(params)?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| RpcError::invalid_params(format!("data is not base64: {e}")))?;
    if bytes.len() > MAX_BYTES {
        return Err(too_large());
    }
    let dir = session_dir(id).ok_or_else(|| RpcError::invalid_params("no such chat"))?;
    let failed = |e: anyhow::Error| RpcError::internal(format!("cannot save the file: {e}"));
    crate::config::private_state_dir(&dir).map_err(failed)?;
    let path = dir.join(uuid::Uuid::now_v7().to_string()).join(name);
    crate::agent_tools::write_private(&path, &bytes).map_err(failed)?;
    Ok(json!({"path": path.to_string_lossy()}))
}

/// The refusal for a peer that does not take `_acpmux/file_put`: the app answers that the chat
/// takes no uploads.
pub fn peer_unsupported(peer: &crate::peer::Peer) -> RpcError {
    RpcError::method_not_found(&format!(
        "{} (peer {} runs acpmux build {}; run `acpmux host update {}`)",
        crate::rpc::method::MUX_FILE_PUT,
        peer.name,
        peer.remote_build().unwrap_or_else(|| "unknown".into()),
        peer.name
    ))
    .with_data(json!({"reason": "filePut.unsupported"}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_name_is_one_plain_file() {
        for good in ["state.sqlite", "a b.txt", "日本語.pdf", "x"] {
            assert!(is_file_name(good), "{good}");
        }
        let long = "a".repeat(256);
        for bad in [
            "",
            ".env",
            ".",
            "..",
            "a/b",
            "a\u{0}b",
            "a\nb",
            "a\u{7f}",
            "a\u{202e}txt",
            long.as_str(),
        ] {
            assert!(!is_file_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn the_cap_leaves_the_frame_room_on_an_old_peers_link() {
        // tungstenite's default frame limit, which an older peer's listener keeps.
        let frame = 16 << 20;
        assert!(MAX_BYTES.div_ceil(3) * 4 + 4096 < frame);
    }
}
