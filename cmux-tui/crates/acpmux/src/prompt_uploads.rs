//! A prompt's files by reference: a block may name a finished upload of its own chat
//! (`_acpmux/file_put_begin`/`_chunk`/`_finish`, `hub/file_uploads.rs`) instead of carrying the
//! bytes, and the daemon that runs the chat puts the bytes in before anything else reads the
//! prompt.
//!
//! claude-sr2, 2026-10-26: Leo's message with 8 screenshots (about 6.6 MB) failed with "Not
//! sent: no answer from acpmux", and so did its Retry; "fix it so 20 screenshots send in seconds:
//! attachments go as blobs or files referenced from the prompt, not inlined base64 in one frame".
//! The app's page host drops a call over 4 MiB unanswered (`ChromiumPageHostBridge`), and every
//! acpmux hop takes one message of at most `rpc::MAX_MESSAGE_BYTES` (15 MiB), so screenshots
//! inline in one `session/prompt` cannot pass. Uploaded in chunks of at most
//! `file_uploads::CHUNK_BYTES` first, they go in a prompt of a few hundred bytes.
//!
//! The reference is `_meta.acpmux.upload {uploadId, fileName}` on an `image` block (the bytes
//! must be an image: they become its `data`, and its `mimeType` is the type the bytes are) or a
//! `resource` block (they become its `resource.blob`). The resolved block is what an inline sender
//! would have sent, so every later step (an attachment's copy and note, `attach.rs`; the
//! transcript's images, `prompt_images.rs`; the queue, the ledger, the agent) is unchanged. Only a
//! file of the chat's own uploads folder is read, never through a symlink. A remote web client
//! uploads nothing here (`filePut.remote`), so it references nothing either.
//!
//! A chat on a peer: the prompt is forwarded as it is, and the peer that owns the chat resolves
//! it, from the uploads its own `file_put_*` requests made (`peer_forward.rs` forwards those). A
//! peer that does not list [`FEATURE`] is refused before anything is sent.

use crate::rpc::RpcError;
use base64::Engine;
use serde_json::{Value, json};
use std::io::Read;

/// The `initialize` feature of a daemon that resolves upload references in a prompt.
pub const FEATURE: &str = "promptUploads";
/// The most references one prompt holds (20 screenshots and room).
pub const MAX_FILES: usize = 32;
/// The largest file one reference reads.
pub const MAX_FILE_BYTES: usize = 8 << 20;
/// The most one prompt's references read together: as base64, with the text, under the agent
/// host's 64 MiB frame (`agent_host::MAX_FRAME`).
pub const MAX_TOTAL_BYTES: usize = 32 << 20;

fn upload_of(block: &Value) -> Option<&Value> {
    block.pointer("/_meta/acpmux/upload").filter(|u| !u.is_null())
}

/// Whether any of `blocks` names an upload.
pub fn any(blocks: &[Value]) -> bool {
    blocks.iter().any(|b| upload_of(b).is_some())
}

fn refused(reason: &str, message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({
        "reason": reason,
        "maxFiles": MAX_FILES,
        "maxFileBytes": MAX_FILE_BYTES,
        "maxTotalBytes": MAX_TOTAL_BYTES,
    }))
}

/// For the daemon that runs session `session`: puts the bytes of each upload `blocks` name in
/// its block (module docs). `web`: a remote web client's prompt, which is refused. Blocking: run
/// it off the runtime.
pub fn resolve(session: &str, web: bool, blocks: &mut [Value]) -> Result<(), RpcError> {
    let count = blocks.iter().filter(|b| upload_of(b).is_some()).count();
    if count == 0 {
        return Ok(());
    }
    if web {
        let message = "a remote web connection cannot send uploaded files".to_owned();
        return Err(refused("upload.remote", message));
    }
    if count > MAX_FILES {
        let message = format!("{count} uploaded files: a message takes at most {MAX_FILES}");
        return Err(refused("upload.tooMany", message));
    }
    let mut total = 0usize;
    for block in blocks.iter_mut() {
        let Some(upload) = upload_of(block) else { continue };
        let (id, name) = (upload.get("uploadId"), upload.get("fileName"));
        let (Some(id), Some(name)) = (id.and_then(Value::as_str), name.and_then(Value::as_str))
        else {
            let message = "an upload reference names its uploadId and fileName".to_owned();
            return Err(refused("upload.invalid", message));
        };
        let bytes = read(session, id, name, MAX_TOTAL_BYTES - total)?;
        total += bytes.len();
        let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
        let sniffed = crate::hub::prompt_images::sniffed_type(&bytes);
        match block.get("type").and_then(Value::as_str) {
            Some("image") => {
                let Some(mime) = sniffed.filter(|t| t.starts_with("image/")) else {
                    let message = format!("the upload {name} is not an image");
                    return Err(refused("upload.notImage", message));
                };
                block["data"] = json!(data);
                block["mimeType"] = json!(mime);
            }
            Some("resource") if block.get("resource").is_some_and(Value::is_object) => {
                block["resource"]["blob"] = json!(data);
                if let Some(mime) = sniffed {
                    block["resource"]["mimeType"] = json!(mime);
                }
            }
            _ => {
                let message = "an upload reference is an image block or a resource".to_owned();
                return Err(refused("upload.invalid", message));
            }
        }
        if let Some(meta) = block.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
            meta.remove("upload");
        }
    }
    Ok(())
}

/// [`resolve`] off the runtime, for a prompt that reaches a turn without passing `session/prompt`
/// (`turns.rs`: a queued prompt restored from the log, a held agent message released): no block
/// goes to an agent without its bytes. Immediate when no block names an upload.
pub async fn resolve_off_runtime(
    session: &str,
    web: bool,
    blocks: &mut Vec<Value>,
) -> Result<(), RpcError> {
    if !any(blocks) {
        return Ok(());
    }
    let (id, mut owned) = (session.to_owned(), std::mem::take(blocks));
    let read = tokio::task::spawn_blocking(move || (resolve(&id, web, &mut owned), owned));
    let (result, back) = read.await.map_err(|e| RpcError::internal(e.to_string()))?;
    *blocks = back;
    result
}

/// The bytes of session `session`'s finished upload `id` named `name`, at most `left` of them
/// (and [`MAX_FILE_BYTES`]).
fn read(session: &str, id: &str, name: &str, left: usize) -> Result<Vec<u8>, RpcError> {
    let missing = || refused("upload.missing", format!("no finished upload {name} in this chat"));
    let path = crate::hub::file_uploads::finished_path(session, id, name).ok_or_else(missing)?;
    let file = crate::config::private_state_file(&path).map_err(|_| missing())?;
    let cap = MAX_FILE_BYTES.min(left);
    let mut bytes = Vec::new();
    file.take(cap as u64 + 1).read_to_end(&mut bytes).map_err(|_| missing())?;
    if bytes.len() > cap {
        let message = if cap < MAX_FILE_BYTES {
            format!("the uploads are over {} MiB together", MAX_TOTAL_BYTES >> 20)
        } else {
            format!("{name} is over {} MiB", MAX_FILE_BYTES >> 20)
        };
        return Err(refused("upload.tooLarge", message));
    }
    Ok(bytes)
}

/// The refusal for a peer on a build that would send the agent a block without its bytes.
pub fn peer_unsupported(peer: &crate::peer::Peer) -> RpcError {
    let build = peer.remote_build().unwrap_or_else(|| "unknown".into());
    let message = format!(
        "peer {} runs acpmux build {build}, which does not read uploaded files in a message; run \
         `acpmux host update {}`",
        peer.name, peer.name
    );
    refused("upload.unsupported", message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_remote_web_prompt_is_refused_before_any_file_is_read() {
        let mut blocks = vec![json!({"type": "image", "_meta": {"acpmux": {"upload": {
            "uploadId": "01a17a00-0000-7000-8000-000000000000", "fileName": "a.png"}}}})];
        let refused = resolve("s", true, &mut blocks).unwrap_err();
        assert_eq!(refused.data.unwrap()["reason"], "upload.remote");
        assert!(resolve("s", true, &mut [json!({"type": "text", "text": "x"})]).is_ok());
    }
}
