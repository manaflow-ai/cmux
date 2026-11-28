//! Images sent with a prompt (Leo, 2026-10-13: a sent prompt's images vanished). Each image's
//! bytes are kept once, named by their SHA-256, under `<ACPMUX_HOME>/attachments`, and the
//! prompt's `user_message` names them (`images: [{id, mimeType, name}]`), so a chat shows its
//! images after it is sent, after a restart, and in a fork (which copies the log).
//! `_acpmux/attachment` reads one back for a session whose log names it.

use super::{EventFilter, Hub, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::path::PathBuf;

fn dir() -> PathBuf {
    crate::config::home().join("attachments")
}

/// A kept image's name: 64 lowercase hex digits, never a path.
fn valid_id(id: &str) -> bool {
    id.len() == 64 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Keeps the bytes of each `image` block in `blocks` and returns what `user_message` records of
/// them. An image that cannot be read or kept is left out: the prompt still goes.
fn keep(blocks: &[Value]) -> Vec<Value> {
    use base64::Engine;
    use sha2::Digest;
    blocks
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("image"))
        .filter_map(|block| {
            let data = block.get("data").and_then(Value::as_str)?;
            let bytes = base64::engine::general_purpose::STANDARD.decode(data).ok()?;
            let id: String =
                sha2::Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
            let path = dir().join(&id);
            if !path.is_file() {
                let written = std::fs::create_dir_all(dir()).and_then(|()| {
                    // Written aside and renamed, so a reader never sees half an image.
                    let partial = dir().join(format!("{id}.{}.partial", uuid::Uuid::now_v7()));
                    std::fs::write(&partial, &bytes)?;
                    std::fs::rename(&partial, &path)
                });
                if let Err(e) = written {
                    tracing::warn!("cannot keep a prompt image: {e}");
                    return None;
                }
            }
            let mime = block.get("mimeType").and_then(Value::as_str).unwrap_or("image/png");
            let mut kept = json!({"id": id, "mimeType": mime});
            if let Some(name) = block.get("name").and_then(Value::as_str) {
                kept["name"] = json!(name);
            }
            Some(kept)
        })
        .collect()
}

impl Hub {
    /// Records prompt `msg` as the session's `user_message`, naming the images of its `blocks`.
    pub(super) fn append_prompt(&self, session: &Session, mut msg: Value, blocks: &[Value]) {
        let images = keep(blocks);
        if !images.is_empty() {
            msg["images"] = Value::Array(images);
        }
        self.append(session, "mux", "user_message", msg);
    }

    /// `_acpmux/attachment`: the image `id` one of session `session`'s prompts sent, as
    /// `{mimeType, data}` (base64). Only an image the session's own log names is read.
    pub fn prompt_image(&self, session: &str, id: &str) -> Result<Value, RpcError> {
        let missing = || RpcError::not_found(format!("no image {id} in this chat"));
        if !valid_id(id) {
            return Err(missing());
        }
        let filter = EventFilter::parse(Some(&json!(["user_message"])))?;
        let page = self
            .events_page(session, 0, None, usize::MAX, None, false, &filter)
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let named = page
            .events
            .iter()
            .filter_map(|event| event.msg.get("images").and_then(Value::as_array))
            .flatten()
            .find(|image| image.get("id").and_then(Value::as_str) == Some(id))
            .cloned()
            .ok_or_else(missing)?;
        let bytes = std::fs::read(dir().join(id)).map_err(|_| missing())?;
        use base64::Engine;
        Ok(json!({
            "mimeType": named.get("mimeType").cloned().unwrap_or_else(|| json!("image/png")),
            "data": base64::engine::general_purpose::STANDARD.encode(bytes),
        }))
    }
}
