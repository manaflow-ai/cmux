//! `agent-session-media`: one image of the attached chat, read whole through its host acpmux,
//! or (with an `offset`) one byte range of one of its videos, so the app streams it to a player.
use super::*;

/// Reads one image from the attached chat's host acpmux. The attachment daemon keeps the path
/// scoped to the bound session; this command only relays the already checked media reader bytes.
pub(super) fn media(attachment: &Attachment, path: String) -> Result<Value, Refusal> {
    use base64::Engine;
    let image_extension = std::path::Path::new(&path)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "png" | "jpg" | "jpeg" | "gif" | "webp"
            )
        });
    if !image_extension {
        return Err(Refusal::BadRequest);
    }
    if path.is_empty() || path.len() > 4096 {
        return Err(Refusal::BadRequest);
    }
    let opened = attachment
        .link
        .call(
            "_acpmux/media_open",
            json!({"sessionId": attachment.session, "path": path}),
            CALL_TIMEOUT,
        )
        .map_err(Refusal::of)?;
    let handle = opened.get("handle").and_then(Value::as_str).ok_or(Refusal::BadRequest)?;
    let size = opened.get("size").and_then(Value::as_u64).ok_or(Refusal::BadRequest)?;
    const MAX_BYTES: u64 = 10 << 20;
    const MAX_RANGE: u64 = 6 << 20;
    if size == 0 || size > MAX_BYTES {
        return Err(Refusal::BadRequest);
    }
    let mut bytes = Vec::with_capacity(usize::try_from(size).map_err(|_| Refusal::BadRequest)?);
    let mut offset = 0u64;
    while offset < size {
        let length = (size - offset).min(MAX_RANGE);
        let range = attachment
            .link
            .call(
                "_acpmux/media_range",
                json!({"sessionId": attachment.session, "handle": handle, "offset": offset, "length": length}),
                CALL_TIMEOUT,
            )
            .map_err(Refusal::of)?;
        let actual = range.get("offset").and_then(Value::as_u64).ok_or(Refusal::BadRequest)?;
        if actual != offset {
            return Err(Refusal::BadRequest);
        }
        let encoded = range.get("data").and_then(Value::as_str).ok_or(Refusal::BadRequest)?;
        let chunk = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| Refusal::BadRequest)?;
        if chunk.is_empty() || chunk.len() as u64 > length {
            return Err(Refusal::BadRequest);
        }
        offset = offset.saturating_add(chunk.len() as u64);
        bytes.extend_from_slice(&chunk);
    }
    Ok(json!({
        "mimeType": opened.get("mimeType").cloned().unwrap_or(Value::Null),
        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
    }))
}

/// The most bytes one video range reads: acpmux's own range cap (`hub/media_read.rs`
/// `MAX_RANGE`), 8 MiB of base64 in the answer.
const MAX_VIDEO_RANGE: u64 = 6 << 20;
/// The longest open-file handle accepted back (acpmux's are short random ids).
const MAX_HANDLE: usize = 128;

/// Whether `path` names a video the media reader serves (acpmux sniffs the bytes again).
fn is_video_path(path: &str) -> bool {
    std::path::Path::new(path).extension().and_then(|extension| extension.to_str()).is_some_and(
        |extension| {
            matches!(extension.to_ascii_lowercase().as_str(), "mp4" | "mov" | "m4v" | "webm")
        },
    )
}

/// Reads one byte range of a video of the attached chat through its host acpmux, so the app
/// streams it to its player (Leo, 2026-11-04: "i can neither preview a vid in place nor have it
/// pop up anymore :("). The first range opens the file (`_acpmux/media_open`, the same reader
/// and folder checks as an image: the chat's folder, `/tmp`, its home and its uploads, no link,
/// no dot name, at most 200 MiB); its answer's `handle` reads the next range of the same open
/// file, until a range reaches the end and acpmux closes it. The session is the tab's own, and
/// acpmux refuses a handle opened for any other. Answers `{offset, size, identity, data,
/// mimeType?, handle?}`: `mimeType` on an open, `handle` while bytes are left.
pub(super) fn media_range(
    attachment: &Attachment,
    path: String,
    offset: u64,
    length: Option<u64>,
    handle: Option<String>,
) -> Result<Value, Refusal> {
    use base64::Engine;
    if path.is_empty() || path.len() > 4096 || !is_video_path(&path) {
        return Err(Refusal::BadRequest);
    }
    let length = length.unwrap_or(MAX_VIDEO_RANGE);
    if length == 0 || length > MAX_VIDEO_RANGE {
        return Err(Refusal::BadRequest);
    }
    if let Some(handle) = &handle
        && (handle.is_empty()
            || handle.len() > MAX_HANDLE
            || !handle.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
    {
        return Err(Refusal::BadRequest);
    }
    let (handle, mime) = match handle {
        Some(handle) => (handle, None),
        None => {
            let opened = attachment
                .link
                .call(
                    "_acpmux/media_open",
                    json!({"sessionId": attachment.session, "path": path}),
                    CALL_TIMEOUT,
                )
                .map_err(Refusal::of)?;
            let mime = opened.get("mimeType").and_then(Value::as_str).ok_or(Refusal::BadRequest)?;
            if !mime.starts_with("video/") {
                return Err(Refusal::BadRequest);
            }
            let handle = opened.get("handle").and_then(Value::as_str).ok_or(Refusal::BadRequest)?;
            (handle.to_owned(), Some(mime.to_owned()))
        }
    };
    let range = attachment
        .link
        .call(
            "_acpmux/media_range",
            json!({"sessionId": attachment.session, "handle": handle, "offset": offset, "length": length}),
            CALL_TIMEOUT,
        )
        .map_err(Refusal::of)?;
    if range.get("offset").and_then(Value::as_u64) != Some(offset) {
        return Err(Refusal::BadRequest);
    }
    let size = range.get("size").and_then(Value::as_u64).ok_or(Refusal::BadRequest)?;
    let identity = range.get("identity").and_then(Value::as_str).ok_or(Refusal::BadRequest)?;
    let encoded = range.get("data").and_then(Value::as_str).ok_or(Refusal::BadRequest)?;
    let read = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| Refusal::BadRequest)?
        .len() as u64;
    if read == 0 || read > length {
        return Err(Refusal::BadRequest);
    }
    let mut answer = serde_json::Map::new();
    answer.insert("offset".into(), json!(offset));
    answer.insert("size".into(), json!(size));
    answer.insert("identity".into(), json!(identity));
    answer.insert("data".into(), json!(encoded));
    if let Some(mime) = mime {
        answer.insert("mimeType".into(), json!(mime));
    }
    // acpmux closes the file once a range reaches its end: no handle is left to continue.
    if offset.saturating_add(read) < size {
        answer.insert("handle".into(), json!(handle));
    }
    Ok(Value::Object(answer))
}
