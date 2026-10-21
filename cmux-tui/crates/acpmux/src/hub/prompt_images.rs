//! Images sent with a prompt (Leo, 2026-10-13: a sent prompt's images vanished). Each image's
//! bytes are kept once, named by their SHA-256, under `<ACPMUX_HOME>/attachments`, and the
//! prompt's `user_message` names them (`images: [{id, mimeType, name}]`), so a chat shows its
//! images after it is sent, after a restart, and in a fork (which copies the log).
//! `_acpmux/attachment` reads one back for a session whose log names it.
//!
//! A client may also send an image or a PDF ahead of its prompt (`_acpmux/attachment_put`), kept
//! the same way, and name it in the prompt's block (`uri: "acpmux-attachment:<id>"`, no `data`), so
//! no prompt frame carries the bytes: six Retina screenshots in one prompt passed the WebSocket
//! frame limit and reset the chat's connection (2026-10-20). The prompt gets the bytes back here
//! before anything else reads it.

use super::{EventFilter, Hub, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::path::PathBuf;

fn dir() -> PathBuf {
    crate::config::home().join("attachments")
}

/// How a prompt block names an attachment `_acpmux/attachment_put` kept.
pub const ATTACHMENT_URI: &str = "acpmux-attachment:";
/// The most bytes one put attachment has (the pane's PDF bound is 20 MiB).
const MAX_PUT_BYTES: usize = 24 << 20;
/// What a client may put: the images and the PDF a prompt carries.
const PUT_TYPES: &[&str] =
    &["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf"];

/// Where the marks of the attachments `session` put live, one empty file per id: only that
/// session's prompts may name them. None for a session id that is not a plain name.
fn put_marks(session: &str) -> Option<PathBuf> {
    let plain = !session.is_empty()
        && session.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    plain.then(|| dir().join("put").join(session))
}

/// Keeps `bytes` once under their SHA-256 and returns it.
fn store(bytes: &[u8]) -> std::io::Result<String> {
    use sha2::Digest;
    let id: String = sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect();
    let path = dir().join(&id);
    if !path.is_file() {
        std::fs::create_dir_all(dir())?;
        // Written aside and renamed, so a reader never sees half an image.
        let partial = dir().join(format!("{id}.{}.partial", uuid::Uuid::now_v7()));
        std::fs::write(&partial, bytes)?;
        std::fs::rename(&partial, &path)?;
    }
    Ok(id)
}

/// A kept image's name: 64 lowercase hex digits, never a path.
fn valid_id(id: &str) -> bool {
    id.len() == 64 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Keeps the bytes of each `image` block in `blocks` and returns what `user_message` records of
/// them. An image that cannot be read or kept is left out: the prompt still goes.
fn keep(blocks: &[Value]) -> Vec<Value> {
    use base64::Engine;
    blocks
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("image"))
        .filter_map(|block| {
            let data = block.get("data").and_then(Value::as_str)?;
            let bytes = base64::engine::general_purpose::STANDARD.decode(data).ok()?;
            let id = match store(&bytes) {
                Ok(id) => id,
                Err(e) => {
                    tracing::warn!("cannot keep a prompt image: {e}");
                    return None;
                }
            };
            let mime = block.get("mimeType").and_then(Value::as_str).unwrap_or("image/png");
            let mut kept = json!({"id": id, "mimeType": mime});
            if let Some(name) = block.get("name").and_then(Value::as_str) {
                kept["name"] = json!(name);
            }
            Some(kept)
        })
        .collect()
}

/// Gives each block of `blocks` that names an attachment `session` put
/// (`uri: "acpmux-attachment:<id>"`) its bytes back as `data`. An id the session did not put, or
/// whose bytes are gone, refuses the prompt: the agent never gets a prompt without its image.
pub fn expand_put_attachments(session: &str, blocks: &mut [Value]) -> Result<(), RpcError> {
    use base64::Engine;
    for block in blocks.iter_mut() {
        let Some(id) = block
            .get("uri")
            .and_then(Value::as_str)
            .and_then(|uri| uri.strip_prefix(ATTACHMENT_URI))
            .map(str::to_owned)
        else {
            continue;
        };
        let missing = || {
            RpcError::invalid_params(format!(
                "attachment {id} is not kept for this chat; attach it again"
            ))
            .with_data(json!({"reason": "attachment.missing"}))
        };
        if !valid_id(&id) || !put_marks(session).is_some_and(|marks| marks.join(&id).is_file()) {
            return Err(missing());
        }
        let bytes = std::fs::read(dir().join(&id)).map_err(|_| missing())?;
        let Some(fields) = block.as_object_mut() else { continue };
        fields.remove("uri");
        fields.insert(
            "data".into(),
            Value::String(base64::engine::general_purpose::STANDARD.encode(bytes)),
        );
    }
    Ok(())
}

impl Hub {
    /// `_acpmux/attachment_put {sessionId, mimeType, data}`: keeps an image or a PDF (`data`,
    /// base64) for session `session`'s next prompts, which name it by the returned `{id}`.
    pub fn put_attachment(&self, session: &str, params: &Value) -> Result<Value, RpcError> {
        use base64::Engine;
        let mime = params.get("mimeType").and_then(Value::as_str).unwrap_or_default();
        if !PUT_TYPES.contains(&mime) {
            return Err(RpcError::invalid_params(format!(
                "an attachment is an image or a PDF, not {mime:?}"
            )));
        }
        let data = params
            .get("data")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("data (base64) is required"))?;
        if data.len() / 4 * 3 > MAX_PUT_BYTES {
            return Err(RpcError::invalid_params(format!(
                "an attachment is at most {} MiB",
                MAX_PUT_BYTES >> 20
            ))
            .with_data(json!({"reason": "attachment.tooLarge"})));
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|e| RpcError::invalid_params(format!("data is not base64: {e}")))?;
        let marks = put_marks(session).ok_or_else(|| RpcError::invalid_params("no such chat"))?;
        let id = store(&bytes).map_err(|e| RpcError::internal(format!("cannot keep it: {e}")))?;
        std::fs::create_dir_all(&marks)
            .and_then(|()| std::fs::write(marks.join(&id), b""))
            .map_err(|e| RpcError::internal(format!("cannot keep it: {e}")))?;
        Ok(json!({"id": id}))
    }

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
