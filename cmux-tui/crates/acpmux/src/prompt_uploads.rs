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
//! every file's path while the message has room. Only a file of the chat's own uploads folder is
//! read, never through a symlink or another hard link (`file_uploads::open_finished`), and only
//! an inline image is read whole. A prompt that waits is refused at its turn if a file it links
//! to was swept meanwhile. A remote web client uploads nothing here
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

/// The upload a block names: its `_meta.acpmux.upload`, or (refused as invalid by [`resolve`])
/// null for a link whose `uri` is [`URI_SCHEME`] with no such field, so it never reaches an agent
/// or an older peer unresolved.
fn upload_of(block: &Value) -> Option<&Value> {
    static NONE: Value = Value::Null;
    let named = block.pointer("/_meta/acpmux/upload").filter(|u| !u.is_null());
    let by_uri =
        block.get("uri").and_then(Value::as_str).is_some_and(|u| u.starts_with(URI_SCHEME));
    named.or(by_uri.then_some(&NONE))
}

/// The folders of the uploads `blocks` name as the prompt's own: `_meta.acpmux.upload.owned` is
/// the owner token `file_put_begin` with `forPrompt` gave its sender (`attach::blocks_for`), and
/// it matches. Deleted when the prompt is refused (`attach::Saved`), so none is left behind; a
/// reference to anyone else's upload names none. Each token is read off the runtime.
pub async fn owned(session: &str, blocks: &[Value]) -> Vec<std::path::PathBuf> {
    let refs = owned_refs(blocks);
    if refs.is_empty() {
        return Vec::new();
    }
    let session = session.to_owned();
    tokio::task::spawn_blocking(move || {
        refs.iter()
            .filter_map(|(id, token)| crate::hub::file_uploads::owned_dir(&session, id, token))
            .collect()
    })
    .await
    .unwrap_or_default()
}

/// Each `(uploadId, owner token)` `blocks` name ([`owned`]).
pub fn owned_refs(blocks: &[Value]) -> Vec<(String, String)> {
    let refs = blocks.iter().filter_map(upload_of).filter_map(|u| {
        let token = u.get("owned").and_then(Value::as_str)?;
        Some((u.get("uploadId").and_then(Value::as_str)?.to_owned(), token.to_owned()))
    });
    refs.collect()
}

/// The id, in its one spelling, of every upload `blocks` name, owned or not, by reference or by
/// a link resolved from one (`uploadPath`, `<uploads>/<chat>/<id>/<name>`). Any chat's: the set
/// is what a caller keeps, so a larger one deletes less. A path is split on `/` and `\` alike: a
/// peer's may be a Windows path.
pub fn upload_ids(blocks: &[Value]) -> std::collections::HashSet<String> {
    let named = blocks.iter().filter_map(upload_of).filter_map(|u| u.get("uploadId")?.as_str());
    let linked = blocks.iter().filter_map(|b| {
        let path = b.pointer("/_meta/acpmux/uploadPath")?.as_str()?;
        path.rsplit(['/', '\\']).nth(1)
    });
    let ids = named.chain(linked).filter_map(|id| uuid::Uuid::try_parse(id).ok());
    ids.map(|id| id.to_string()).collect()
}

/// Whether `block` names an upload (`send_message` sends files that go by reference so).
pub fn names_upload(block: &Value) -> bool {
    upload_of(block).is_some()
}

/// Whether any of `blocks` names an upload, or carries a link this daemon resolved from one.
pub fn any(blocks: &[Value]) -> bool {
    blocks.iter().any(|b| upload_of(b).is_some()) || links_upload(blocks)
}

fn refused(reason: &str, message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

/// For the daemon that runs session `session`: puts in place of each block that names an upload
/// the inline image or the link to its file, and adds the note of their paths (module docs).
/// `web`: a remote web client's prompt, which is refused. Blocking: run it off the runtime.
pub fn resolve(session: &str, web: bool, blocks: &mut Vec<Value>) -> Result<(), RpcError> {
    // Web control never sends uploads, nor a link this daemon resolved (`uploadPath`): a queue
    // edit from a remote web client keeps a person's resolved blocks, and must not hand their
    // files to a turn it controls.
    if web && any(blocks) {
        let message = "a remote web connection cannot send uploaded files".to_owned();
        return Err(refused("upload.remote", message));
    }
    // Resolved already (a prompt that waited): nothing to read again.
    if !blocks.iter().any(|b| upload_of(b).is_some()) {
        return Ok(());
    }
    // What the prompt's other blocks take of one message, and room for the envelope and links.
    let others: usize =
        blocks.iter().filter(|b| upload_of(b).is_none()).map(|b| b.to_string().len()).sum();
    let room = crate::rpc::MAX_MESSAGE_BYTES.saturating_sub(others + (1 << 20));
    // Counted as base64, what the message carries.
    let mut inline_left = (INLINE_PROMPT_BYTES.div_ceil(3) * 4).min(room);
    let mut listed = Vec::new();
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
        // Not there is `upload.missing`; any other failure says what it was.
        let unreadable = |e: std::io::Error| match e.kind() {
            std::io::ErrorKind::NotFound => missing(),
            _ => refused("upload.unreadable", format!("cannot read upload {name}: {e}")),
        };
        let mut file = {
            // Marked used and opened as one step against the sweep (`file_uploads::IN_USE`).
            let _held = crate::hub::file_uploads::IN_USE.lock().unwrap_or_else(|e| e.into_inner());
            let file = crate::hub::file_uploads::open_finished(&path).map_err(unreadable)?;
            crate::hub::file_uploads::touch(&path).map_err(|e| not_marked(name, &e))?;
            file
        };
        let len = file.metadata().map_err(unreadable)?.len();
        let mut head = Vec::with_capacity(64);
        (&mut file).take(64).read_to_end(&mut head).map_err(unreadable)?;
        let sniffed = crate::hub::prompt_images::sniffed_type(&head);
        let mime = sniffed.unwrap_or("application/octet-stream");
        let image = sniffed.filter(|t| t.starts_with("image/"));
        let inline = image.is_some()
            && usize::try_from(len)
                .is_ok_and(|n| n <= INLINE_IMAGE_BYTES && n.div_ceil(3) * 4 <= inline_left);
        *block = if inline {
            let mut bytes = head;
            file.read_to_end(&mut bytes).map_err(unreadable)?;
            let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
            inline_left = inline_left.saturating_sub(data.len());
            json!({"type": "image", "mimeType": mime, "name": name, "data": data})
        } else {
            // Its path, so a turn that starts later finds out if the file is gone (`still_there`).
            json!({"type": "resource_link", "uri": file_uri(&path), "name": name,
                   "mimeType": mime, "size": len,
                   "_meta": {"acpmux": {"uploadPath": path.to_string_lossy()}}})
        };
        let shown = if inline || image.is_none() { "" } else { ", not shown inline: open it" };
        listed.push(format!("- {} ({mime}, {}{shown})", path.display(), size_text(len)));
    }
    // The note lists the files while the message has room; every link names its file anyway.
    let used: usize = blocks.iter().map(|b| b.to_string().len()).sum();
    let mut note_room = crate::rpc::MAX_MESSAGE_BYTES.saturating_sub(used + (64 << 10));
    let total = listed.len();
    let shown: Vec<String> = listed
        .into_iter()
        .take_while(|line| {
            let fits = line.len() < note_room;
            note_room = note_room.saturating_sub(line.len() + 1);
            fits
        })
        .collect();
    let more = match total - shown.len() {
        0 => String::new(),
        n => format!("\n- and {n} more, each a resource_link in this message"),
    };
    blocks.push(json!({
        "type": "text",
        "text": format!(
            "<cmux-attachments-context>\nThe files sent with this message, saved on this machine:\n{}{more}\n</cmux-attachments-context>",
            shown.join("\n")
        ),
        "_meta": {"acpmux": {"context": true}},
    }));
    if blocks.iter().map(|b| b.to_string().len()).sum::<usize>() > crate::rpc::MAX_MESSAGE_BYTES {
        let message = format!(
            "{total} files do not fit one message's links ({} MiB): send them in more than one",
            crate::rpc::MAX_MESSAGE_BYTES >> 20
        );
        return Err(refused("upload.tooMany", message));
    }
    Ok(())
}

/// Whether every file a resolved prompt links to by path is still there: a prompt that waited
/// (queued, held, restored after a restart) is refused at its turn when an upload was swept
/// meanwhile, instead of handing the agent a path to nothing. Blocking.
fn still_there(blocks: &[Value]) -> Result<(), RpcError> {
    for block in blocks {
        let Some(path) = block.pointer("/_meta/acpmux/uploadPath").and_then(Value::as_str) else {
            continue;
        };
        // Only this daemon's uploads are checked (and kept from the sweep a while longer): a
        // path a client wrote there itself tells it nothing about any other file.
        let path = Path::new(path);
        if !crate::hub::file_uploads::is_upload(path) {
            continue;
        }
        let _held = crate::hub::file_uploads::IN_USE.lock().unwrap_or_else(|e| e.into_inner());
        let name = block.get("name").and_then(Value::as_str).unwrap_or("a file");
        if !std::fs::symlink_metadata(path).is_ok_and(|m| m.is_file()) {
            return Err(refused("upload.missing", format!("upload {name} was removed")));
        }
        crate::hub::file_uploads::touch(path).map_err(|e| not_marked(name, &e))?;
    }
    Ok(())
}

/// An upload whose use could not be marked (`file_uploads::touch`, a full disk): refused, since
/// the age sweep would not know the turn needs it.
fn not_marked(name: &str, e: &anyhow::Error) -> RpcError {
    refused("upload.unreadable", format!("cannot mark upload {name} in use: {e}"))
}

fn links_upload(blocks: &[Value]) -> bool {
    blocks.iter().any(|b| b.pointer("/_meta/acpmux/uploadPath").is_some())
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
/// goes to an agent without its bytes, and no link to a file swept while it waited
/// ([`still_there`]). Immediate when no block names or links an upload.
pub async fn resolve_off_runtime(
    session: &str,
    web: bool,
    blocks: &mut Vec<Value>,
) -> Result<(), RpcError> {
    if !any(blocks) {
        return Ok(());
    }
    let (id, mut owned) = (session.to_owned(), std::mem::take(blocks));
    let read = tokio::task::spawn_blocking(move || {
        let result = resolve(&id, web, &mut owned).and_then(|()| still_there(&owned));
        (result, owned)
    });
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
    fn a_resolved_link_under_web_control_is_refused() {
        // A web client's queue edit keeps a person's resolved blocks; its turn is refused.
        let mut blocks = vec![
            json!({"type": "text", "text": "edited"}),
            json!({"type": "resource_link", "uri": "file:///x/a.bin", "name": "a.bin",
                "_meta": {"acpmux": {"uploadPath": "/x/a.bin"}}}),
        ];
        let refused = resolve("s", true, &mut blocks).unwrap_err();
        assert_eq!(refused.data.unwrap()["reason"], "upload.remote");
        // The same blocks under the person's control are resolved already: nothing to read.
        assert!(resolve("s", false, &mut blocks).is_ok());
        assert_eq!(blocks.len(), 2);
    }

    #[test]
    fn a_remote_web_prompt_is_refused_before_any_file_is_read() {
        let mut blocks = vec![json!({"type": "image", "_meta": {"acpmux": {"upload": {
            "uploadId": "01a17a00-0000-7000-8000-000000000000", "fileName": "a.png"}}}})];
        let refused = resolve("s", true, &mut blocks).unwrap_err();
        assert_eq!(refused.data.unwrap()["reason"], "upload.remote");
        assert!(resolve("s", true, &mut vec![json!({"type": "text", "text": "x"})]).is_ok());
    }

    #[test]
    fn a_link_names_its_upload_on_any_platform() {
        let (id, peer) = (uuid::Uuid::now_v7(), uuid::Uuid::now_v7());
        let link = |path: String| json!({"type": "resource_link", "_meta": {"acpmux": {"uploadPath": path}}});
        let blocks = [
            link(format!("/home/me/.acpmux/uploads/chat/{id}/a.png")),
            link(format!("C:\\Users\\me\\acpmux\\uploads\\chat\\{}\\b.png", peer.simple())),
            link("a.png".to_owned()),
        ];
        assert_eq!(upload_ids(&blocks), [id.to_string(), peer.to_string()].into_iter().collect());
    }
}
