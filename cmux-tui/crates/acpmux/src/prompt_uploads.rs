//! A prompt's files by reference: a block may name a finished upload of its own chat
//! (`_acpmux/file_put_begin`/`_chunk`/`_finish`, `hub/file_uploads.rs`) instead of carrying the
//! bytes, and the daemon that runs the chat puts what the agent gets in its place before anything
//! else reads the prompt.
//!
//! claude-sr2, 2026-10-26: Leo's message with 8 screenshots (about 6.6 MB) failed with "Not
//! sent: no answer from acpmux", and so did its Retry; "fix it so 20 screenshots send in seconds:
//! attachments go as blobs or files referenced from the prompt, not inlined base64 in one frame".
//! The app's page host drops a call over 4 MiB unanswered (`ChromiumPageHostBridge`), and every
//! acpmux hop takes one message of at most `rpc::MAX_MESSAGE_BYTES` (15 MiB), so screenshots
//! inline in one `session/prompt` cannot pass. Uploaded first, in chunks, they go in a prompt of a
//! few hundred bytes.
//!
//! The reference is `_meta.acpmux.upload {uploadId, fileName}` on an `image` block, or on a
//! `resource_link` whose `uri` is `acpmux-upload:<uploadId>` (valid ACP before it is resolved). There is no size or count cap (Leo, 2026-10-26: "I ALREADY
//! SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE"): a file of any type and size stays where
//! it was uploaded, and the agent gets its path. An image goes inline as well, so the model sees
//! it, while it fits the model's input ([`INLINE_IMAGE_BYTES`]) and the prompt's inline room
//! ([`INLINE_PROMPT_BYTES`], so the prompt stays one message on every hop); any other file, and an
//! image past those, goes as a `resource_link` to its path, never as base64. A context note lists
//! every file's path. Only a file of the chat's own uploads folder is read, never through a
//! symlink, and only an inline image is read whole. A remote web client uploads nothing here
//! (`filePut.remote`), so it references nothing either.
//!
//! A chat on a peer: the prompt is forwarded as it is, and the peer that owns the chat resolves
//! it, from the uploads its own `file_put_*` requests made (`peer_forward.rs` forwards those). A
//! peer that does not list [`FEATURE`] is refused before anything is sent.

use crate::rpc::RpcError;
use base64::Engine;
use serde_json::{Value, json};
use std::io::Read;
use std::path::Path;

/// The `initialize` feature of a daemon that resolves upload references in a prompt.
pub const FEATURE: &str = "promptUploads";
/// The `uri` of a `resource_link` that names an upload: `acpmux-upload:<uploadId>`.
pub const URI_SCHEME: &str = "acpmux-upload:";
/// The largest image put inline for the model: Claude's API refuses an image whose base64 is
/// over 5 MiB, which this is the decoded size of. A larger one goes by its path.
pub const INLINE_IMAGE_BYTES: usize = (5 << 20) / 4 * 3;
/// The most image bytes one prompt carries inline: as base64, with its text, one JSON-RPC
/// message on every hop (`rpc::MAX_MESSAGE_BYTES`, 15 MiB). The images past it go by path.
pub const INLINE_PROMPT_BYTES: usize = 10 << 20;

fn upload_of(block: &Value) -> Option<&Value> {
    block.pointer("/_meta/acpmux/upload").filter(|u| !u.is_null())
}

/// Whether any of `blocks` names an upload.
pub fn any(blocks: &[Value]) -> bool {
    blocks.iter().any(|b| upload_of(b).is_some())
}

fn refused(reason: &str, message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

/// For the daemon that runs session `session`: puts in place of each block that names an upload
/// the inline image or the link to its file, and adds the note of their paths (module docs).
/// `web`: a remote web client's prompt, which is refused. Blocking: run it off the runtime.
pub fn resolve(session: &str, web: bool, blocks: &mut Vec<Value>) -> Result<(), RpcError> {
    if !any(blocks) {
        return Ok(());
    }
    if web {
        let message = "a remote web connection cannot send uploaded files".to_owned();
        return Err(refused("upload.remote", message));
    }
    let (mut inline_left, mut listed) = (INLINE_PROMPT_BYTES, Vec::new());
    for block in blocks.iter_mut() {
        let Some(upload) = upload_of(block) else { continue };
        let (id, name) = (upload.get("uploadId"), upload.get("fileName"));
        let (Some(id), Some(name)) = (id.and_then(Value::as_str), name.and_then(Value::as_str))
        else {
            let message = "an upload reference names its uploadId and fileName".to_owned();
            return Err(refused("upload.invalid", message));
        };
        // An `image`, or a `resource_link` whose `uri` is [`URI_SCHEME`] and the same upload id, so
        // the block is valid ACP before it is resolved (`docs/prompt-uploads.md` section 5).
        let uri = block.get("uri").and_then(Value::as_str);
        let valid = match block.get("type").and_then(Value::as_str) {
            Some("image") => uri.is_none(),
            Some("resource_link") => uri.and_then(|u| u.strip_prefix(URI_SCHEME)) == Some(id),
            _ => false,
        };
        if !valid {
            let message = format!(
                "an upload reference is an image block, or a resource_link with uri \
                 {URI_SCHEME}{id}"
            );
            return Err(refused("upload.invalid", message));
        }
        let missing =
            || refused("upload.missing", format!("no finished upload {name} in this chat"));
        let path =
            crate::hub::file_uploads::finished_path(session, id, name).ok_or_else(missing)?;
        let mut file = crate::config::private_state_file(&path).map_err(|_| missing())?;
        let len = file.metadata().map_err(|_| missing())?.len();
        let mut head = Vec::with_capacity(64);
        (&mut file).take(64).read_to_end(&mut head).map_err(|_| missing())?;
        let sniffed = crate::hub::prompt_images::sniffed_type(&head);
        let mime = sniffed.unwrap_or("application/octet-stream");
        let image = sniffed.filter(|t| t.starts_with("image/"));
        let inline = image.is_some()
            && usize::try_from(len).is_ok_and(|n| n <= INLINE_IMAGE_BYTES && n <= inline_left);
        *block = if inline {
            let mut bytes = head;
            file.read_to_end(&mut bytes).map_err(|_| missing())?;
            inline_left -= bytes.len();
            let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
            json!({"type": "image", "mimeType": mime, "name": name, "data": data})
        } else {
            json!({"type": "resource_link", "uri": file_uri(&path), "name": name,
                   "mimeType": mime, "size": len})
        };
        let shown = if inline || image.is_none() { "" } else { ", not shown inline: open it" };
        listed.push(format!("- {} ({mime}, {}{shown})", path.display(), size_text(len)));
    }
    blocks.push(json!({
        "type": "text",
        "text": format!(
            "<cmux-attachments-context>\nThe files sent with this message, saved on this machine:\n{}\n</cmux-attachments-context>",
            listed.join("\n")
        ),
        "_meta": {"acpmux": {"context": true}},
    }));
    Ok(())
}

fn size_text(bytes: u64) -> String {
    format!("{:.1} MiB", bytes as f64 / f64::from(1 << 20))
}

/// A `file://` URI for an uploaded file, percent-encoded.
fn file_uri(path: &Path) -> String {
    reqwest::Url::from_file_path(path)
        .map(String::from)
        .unwrap_or_else(|()| format!("file://{}", path.display()))
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
        assert!(resolve("s", true, &mut vec![json!({"type": "text", "text": "x"})]).is_ok());
    }
}
