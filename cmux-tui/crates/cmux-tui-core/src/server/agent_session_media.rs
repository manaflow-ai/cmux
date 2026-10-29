//! `agent-session-media`: one image of the attached chat, read through its host acpmux (moved
//! out of agent_session_attach.rs, behavior unchanged).
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
