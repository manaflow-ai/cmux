//! Part of `Hub`; see `hub/mod.rs`. A read of an image file that finished without returning the
//! image gets it here, read from the session's machine (Leo: "this preview is not correct").
//!
//! Codex's `view_image` (app-server item `imageView`) reaches the client as a `read` call titled
//! "View <file>" that names the file in its `locations` and completes with no content: the model
//! saw the image, the client got only the path. The pane then asks its own Mac for that path, and
//! for a chat on another machine the file is not there, so the row showed the bare path and no
//! image. Claude Code's Read of a PNG returns its image (`claude_stdio/result_images.rs`) and is
//! drawn; this gives every harness's image read the same row.
//!
//! The daemon runs where the agent does, so it reads the file the call named and adds it to the
//! completion as an ACP image block, the shape a Claude Read's image has. The update is logged like
//! every other, so a chat reopened later, or watched from another machine, still draws it. Only a
//! completed `read` call whose content holds no image, naming one location whose bytes are a PNG,
//! JPEG, GIF or WebP no larger than [`MAX_READ_IMAGE_BYTES`], gets one. Anything else (a text file,
//! a file that is gone, one too large, a record that already carries the image) is left as it
//! came, and the pane falls back to the path as before.

use base64::Engine;
use serde_json::{Value, json};
use std::io::Read;

use crate::path_canon::canonical_path;

/// The most bytes of one image file a read gets: its base64 (4/3 of it) stays within the 8 MiB a
/// Claude tool result's images keep (`claude_stdio::result_images::MAX_RESULT_IMAGE_BYTES`), the
/// most the client draws for one image.
pub(super) const MAX_READ_IMAGE_BYTES: u64 = 6 << 20;

/// Adds the image a completed `read` call named to its content, as above. `cwd` is the session's
/// folder, for a relative location.
pub(super) fn add_read_image(kind: &str, msg: &mut Value, cwd: &std::path::Path) {
    // Not a `.replay`: a resumed chat's replayed history is not drawn (`paging.rs`), and reading
    // each of its files again would log every image once more per resume.
    if kind != "tool_call_update" {
        return;
    }
    let Some(update) = msg.pointer_mut("/params/update").filter(|u| u.is_object()) else {
        return;
    };
    if update.get("kind").and_then(Value::as_str) != Some("read")
        || update.get("status").and_then(Value::as_str) != Some("completed")
    {
        return;
    }
    let content = update.get("content");
    if content.and_then(Value::as_array).is_some_and(|blocks| {
        blocks.iter().any(|block| block.pointer("/content/type") == Some(&json!("image")))
    }) {
        return;
    }
    if content.is_some_and(|content| !content.is_null() && !content.is_array()) {
        return;
    }
    // One file: a read naming several is not a view of one image.
    let Some([location]) = update.get("locations").and_then(Value::as_array).map(Vec::as_slice)
    else {
        return;
    };
    // From the path the agent named, never a `canonicalPath` its own `_meta` may carry.
    let path =
        location.get("path").and_then(Value::as_str).and_then(|p| canonical_path(p, Some(cwd)));
    let Some((mime, bytes)) = path.as_deref().and_then(image_file) else {
        return;
    };
    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
    let image =
        json!({"type": "content", "content": {"type": "image", "mimeType": mime, "data": data}});
    match update.get_mut("content").and_then(Value::as_array_mut) {
        Some(blocks) => blocks.push(image),
        None => {
            if let Some(fields) = update.as_object_mut() {
                fields.insert("content".into(), json!([image]));
            }
        }
    }
}

/// The file at `path` and its image type, when it is a regular file of at most
/// [`MAX_READ_IMAGE_BYTES`] whose first bytes are a PNG's, JPEG's, GIF's or WebP's. Only its
/// first bytes are read unless they are an image's, so a read of a source file costs one small
/// read. A FIFO or device is never opened for reading in a way that waits (`O_NONBLOCK`), and is
/// refused by its type.
fn image_file(path: &str) -> Option<(&'static str, Vec<u8>)> {
    if !std::fs::metadata(path).ok()?.is_file() {
        return None;
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let mut file = options.open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > MAX_READ_IMAGE_BYTES {
        return None;
    }
    // Its first 12 bytes (fewer for a smaller file), then the rest only for an image's.
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    (&mut file).take(12).read_to_end(&mut bytes).ok()?;
    let mime = image_mime(&bytes)?;
    // A file that grew since its size was read is cut off one byte past the limit, and refused.
    file.take(MAX_READ_IMAGE_BYTES + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > MAX_READ_IMAGE_BYTES {
        return None;
    }
    Some((mime, bytes))
}

/// The image type `bytes` start with, by their signature, never by the file's name.
fn image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP".as_slice()) {
        Some("image/webp")
    } else {
        None
    }
}

#[cfg(test)]
#[path = "tool_read_images_tests.rs"]
mod tests;
