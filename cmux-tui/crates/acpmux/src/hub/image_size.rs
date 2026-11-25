//! A prompt image's pixel size, kept with its record so every view reserves the image's own box
//! before its bytes arrive (Leo, 2026-11-14: "picture dimensions were forgotten then reloaded. this
//! is another cause of layout shift"). A record named its images by `{id, mimeType, name}` only, so
//! the chat drew a square slot while it read each image back, then grew or shrank the bubble to the
//! image's real shape: on every history load, scroll-back, restart and remote view.
//!
//! - [`pixel_size`] reads the size from the image's header (PNG, GIF, WebP, JPEG with its EXIF
//!   orientation, BMP), with no decoding: `prompt_images::decode` records it as `width` and
//!   `height` beside the id, so every new record carries it.
//! - [`fill_record_sizes`] gives a record written before that (no `width`/`height`) its kept
//!   image's size as the record is sent (`server::pending::event_value`), read from the kept file's
//!   header once per image and cached: an id names its bytes, so its size never changes.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Read;
use std::sync::{LazyLock, Mutex};

/// The pixel size an image's header declares, as a browser draws it (a JPEG whose EXIF orientation
/// turns it a quarter has its width and height swapped). `None` for a type it does not read or a
/// header cut short.
pub(crate) fn pixel_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let size = |w: u32, h: u32| (w > 0 && h > 0).then_some((w, h));
    let u16be =
        |at: usize| Some(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?) as u32);
    let u16le =
        |at: usize| Some(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?) as u32);
    let u32be = |at: usize| Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?));
    let u24le = |at: usize| {
        let &[b0, b1, b2] = bytes.get(at..at + 3)? else { return None };
        Some(u32::from(b0) | (u32::from(b1) << 8) | (u32::from(b2) << 16))
    };
    let at = |offset: usize, magic: &[u8]| bytes.get(offset..offset + magic.len()) == Some(magic);
    // PNG (and APNG): the IHDR chunk's width and height.
    if at(0, b"\x89PNG\r\n\x1a\n") && at(12, b"IHDR") {
        return size(u32be(16)?, u32be(20)?);
    }
    // GIF: the logical screen size.
    if at(0, b"GIF87a") || at(0, b"GIF89a") {
        return size(u16le(6)?, u16le(8)?);
    }
    // WebP: lossy (VP8), lossless (VP8L) or extended (VP8X).
    if at(0, b"RIFF") && at(8, b"WEBP") {
        if at(12, b"VP8 ") {
            return size(u16le(26)? & 0x3fff, u16le(28)? & 0x3fff);
        }
        if at(12, b"VP8L") {
            let bits = u32::from_le_bytes(bytes.get(21..25)?.try_into().ok()?);
            return size((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
        }
        if at(12, b"VP8X") {
            return size(u24le(24)? + 1, u24le(27)? + 1);
        }
        return None;
    }
    // BMP: a BITMAPINFOHEADER's signed width and height (a negative height is top-down).
    if at(0, b"BM") {
        let w = i32::from_le_bytes(bytes.get(18..22)?.try_into().ok()?);
        let h = i32::from_le_bytes(bytes.get(22..26)?.try_into().ok()?);
        return size(w.unsigned_abs(), h.unsigned_abs());
    }
    // JPEG: the first start-of-frame segment, past any EXIF (read for its orientation).
    if at(0, b"\xff\xd8") {
        let mut rotated = false;
        let mut i = 2;
        while i + 9 < bytes.len() {
            let &[0xff, marker] = bytes.get(i..i + 2)? else { return None };
            if marker == 0xff {
                i += 1;
                continue;
            }
            let length = u16be(i + 2)? as usize;
            if marker == 0xe1 {
                rotated |= exif_rotates(bytes, i + 4, (i + 2 + length).min(bytes.len()));
            }
            // SOF0-SOF15, but not DHT (C4), JPG (C8) or DAC (CC).
            if (0xc0..=0xcf).contains(&marker) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
                let (h, w) = (u16be(i + 5)?, u16be(i + 7)?);
                return if rotated { size(h, w) } else { size(w, h) };
            }
            i += 2 + length;
        }
    }
    None
}

/// Whether an APP1 segment's EXIF orientation turns the image a quarter (5-8), which the browser
/// applies, so it draws with its width and height swapped.
fn exif_rotates(b: &[u8], start: usize, end: usize) -> bool {
    if b.get(start..start + 4) != Some(b"Exif") {
        return false;
    }
    let tiff = start + 6;
    let little = b.get(tiff) == Some(&0x49);
    let u16_at = |at: usize| -> Option<u16> {
        let v: [u8; 2] = b.get(at..at + 2)?.try_into().ok()?;
        Some(if little { u16::from_le_bytes(v) } else { u16::from_be_bytes(v) })
    };
    let u32_at = |at: usize| -> Option<u32> {
        let v: [u8; 4] = b.get(at..at + 4)?.try_into().ok()?;
        Some(if little { u32::from_le_bytes(v) } else { u32::from_be_bytes(v) })
    };
    let Some(ifd) = u32_at(tiff + 4).map(|o| tiff + o as usize) else { return false };
    let Some(count) = u16_at(ifd).filter(|_| ifd + 2 <= end) else { return false };
    for index in 0..usize::from(count) {
        let entry = ifd + 2 + index * 12;
        if entry + 12 > end {
            return false;
        }
        if u16_at(entry) == Some(0x0112) {
            return u16_at(entry + 8).is_some_and(|o| o >= 5);
        }
    }
    false
}

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
