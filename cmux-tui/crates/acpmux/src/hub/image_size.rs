//! A prompt image's pixel size, kept with its record so every view reserves the image's own box
//! before its bytes arrive (Leo, 2026-11-14: "picture dimensions were forgotten then reloaded. this
//! is another cause of layout shift"). A record named its images by `{id, mimeType, name}` only, so
//! the chat drew a square slot while it read each image back, then grew or shrank the bubble to the
//! image's real shape: on every history load, scroll-back, restart and remote view.
//!
//! - `prompt_images::decode` records a new image's size (`acpmux_book::image_dims`, read from
//!   its header: PNG, GIF, WebP, JPEG with its EXIF orientation, BMP) as `width` and `height`
//!   beside the id, so every new record carries it.
//! - [`fill_record_sizes`] gives a record written before that (no `width`/`height`) its kept
//!   image's size as the record is sent (`server::pending::event_value`), read from the kept file's
//!   header once per image and cached: an id names its bytes, so its size never changes.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Read;
use std::sync::{LazyLock, Mutex};

/// The pixel size an image's header declares, as a browser draws it: the reader the hub's new
/// records and the book share (`acpmux_book::image_dims`).
pub(crate) use acpmux_book::image_dims::image_dims as pixel_size;

/// Kept images' sizes by id (`None`: a kept file whose header names no size). An id is the
/// SHA-256 of the image's bytes, so an entry is never stale; a size is a few bytes.
static KEPT_SIZES: LazyLock<Mutex<HashMap<String, Option<(u32, u32)>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
const MAX_KEPT_SIZES: usize = 1 << 16;
/// What a header read takes first; a JPEG whose frame header sits past a large EXIF block (an
/// embedded thumbnail) is read further, up to `MAX_HEADER`.
const FIRST_READ: u64 = 64 << 10;
const MAX_HEADER: u64 = 4 << 20;

/// The size of the kept image `id` (`prompt_images::image_path`), read from its header once.
pub(crate) fn kept_size(id: &str) -> Option<(u32, u32)> {
    if let Some(known) = KEPT_SIZES.lock().unwrap_or_else(|e| e.into_inner()).get(id) {
        return *known;
    }
    // An image this machine does not keep yet (a peer's chat, one a restore writes back later) is
    // not remembered as sizeless: it is read again once it is kept.
    let mut file = std::fs::File::open(super::prompt_images::image_path(id)?).ok()?;
    let mut head = Vec::with_capacity(FIRST_READ as usize);
    (&mut file).take(FIRST_READ).read_to_end(&mut head).ok()?;
    let size = pixel_size(&head).or_else(|| {
        if !head.starts_with(b"\xff\xd8") || (head.len() as u64) < FIRST_READ {
            return None;
        }
        file.take(MAX_HEADER - FIRST_READ).read_to_end(&mut head).ok()?;
        pixel_size(&head)
    });
    let mut sizes = KEPT_SIZES.lock().unwrap_or_else(|e| e.into_inner());
    if sizes.len() >= MAX_KEPT_SIZES {
        sizes.clear();
    }
    sizes.insert(id.to_owned(), size);
    size
}

/// Gives each image a prompt record names (`images`, and `inlineParts`' image parts) its kept
/// image's `width` and `height` when the record has none: a record written before images carried
/// their size draws at its final shape too, after a restart or an update included.
pub(crate) fn fill_record_sizes(kind: &str, msg: &mut Value) {
    if !super::prompt_images::NAMING_KINDS.contains(&kind) {
        return;
    }
    let sized = |image: &Value| image.get("width").is_some() && image.get("height").is_some();
    let missing = |list: Option<&Value>, image_only: bool| {
        list.and_then(Value::as_array).is_some_and(|items| {
            items.iter().any(|item| {
                (!image_only || item.get("kind").and_then(Value::as_str) == Some("image"))
                    && item.get("id").is_some()
                    && !sized(item)
            })
        })
    };
    // The common record (no images, or every image sized) is never copied or touched.
    if !missing(msg.get("images"), false) && !missing(msg.get("inlineParts"), true) {
        return;
    }
    for (field, image_only) in [("images", false), ("inlineParts", true)] {
        let Some(items) = msg.get_mut(field).and_then(Value::as_array_mut) else { continue };
        for item in items {
            if image_only && item.get("kind").and_then(Value::as_str) != Some("image") {
                continue;
            }
            if sized(item) {
                continue;
            }
            let Some((w, h)) = item.get("id").and_then(Value::as_str).and_then(kept_size) else {
                continue;
            };
            item.set("width", json!(w));
            item.set("height", json!(h));
        }
    }
}

#[cfg(test)]
#[path = "image_size_tests.rs"]
mod tests;
