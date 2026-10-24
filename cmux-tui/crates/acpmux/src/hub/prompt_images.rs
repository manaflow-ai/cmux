//! Images sent with a prompt (Leo, 2026-10-13: a sent prompt's images vanished). Each image's
//! bytes are kept once, named by their SHA-256, under `<ACPMUX_HOME>/attachments`, and the
//! prompt's `user_message` names them (`images: [{id, mimeType, name}]`), so a chat shows its
//! images after it is sent, after a restart, and in a fork (which copies the log).
//! A queued prompt's `queued` and `queue_updated` records name its images the same way, so its
//! row shows them before it runs. `_acpmux/attachment` reads one back for a session whose log
//! names it.

use super::{EventFilter, Hub, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::PathBuf;

fn dir() -> PathBuf {
    crate::config::home().join("attachments")
}

/// The records that name a prompt's images.
const NAMING_KINDS: [&str; 3] = ["user_message", "queued", "queue_updated"];

/// The type a kept file's bytes are, from their magic number: PNG, JPEG, GIF, WebP, BMP, TIFF,
/// HEIC/HEIF, AVIF and PDF. `None` for anything else (an SVG is text: its record names it).
fn sniffed_type(bytes: &[u8]) -> Option<&'static str> {
    let at = |offset: usize, magic: &[u8]| bytes.get(offset..offset + magic.len()) == Some(magic);
    if at(0, b"\x89PNG\r\n\x1a\n") {
        return Some("image/png");
    }
    if at(0, b"\xff\xd8\xff") {
        return Some("image/jpeg");
    }
    if at(0, b"GIF87a") || at(0, b"GIF89a") {
        return Some("image/gif");
    }
    if at(0, b"RIFF") && at(8, b"WEBP") {
        return Some("image/webp");
    }
    if at(0, b"BM") && bytes.len() >= 14 {
        return Some("image/bmp");
    }
    if at(0, b"II*\0") || at(0, b"MM\0*") {
        return Some("image/tiff");
    }
    if at(0, b"%PDF-") {
        return Some("application/pdf");
    }
    if at(4, b"ftyp") {
        return iso_media_type(bytes);
    }
    None
}

/// An ISO base media file's image type from its whole `ftyp` box: its major brand and every
/// compatible brand inside the box (as libavif's read.c reads it), so an AVIF whose major brand
/// is `mif1` is AVIF. `None` for a box cut short, one whose brands are not whole, or one that
/// names no HEIF brand.
fn iso_media_type(bytes: &[u8]) -> Option<&'static str> {
    let u32_at = |at: usize| {
        bytes.get(at..at + 4).and_then(|b| <[u8; 4]>::try_from(b).ok()).map(u32::from_be_bytes)
    };
    let (header, size) = match u32_at(0)? {
        // A 64-bit size follows the type.
        1 => {
            let large = bytes
                .get(8..16)
                .and_then(|b| <[u8; 8]>::try_from(b).ok())
                .map(u64::from_be_bytes)?;
            (16, usize::try_from(large).ok()?)
        }
        // The box runs to the end of the file.
        0 => (8, bytes.len()),
        size => (8, size as usize),
    };
    // The major brand and minor version, then whole compatible brands, all inside the file.
    if size < header + 8 || size > bytes.len() || (size - header - 8) % 4 != 0 {
        return None;
    }
    let brands: Vec<&[u8]> = std::iter::once(&bytes[header..header + 4])
        .chain(bytes[header + 8..size].chunks_exact(4))
        .collect();
    let has =
        |names: &[&[u8; 4]]| brands.iter().any(|brand| names.iter().any(|name| *brand == *name));
    if has(&[b"avif", b"avis"]) {
        Some("image/avif")
    } else if has(&[b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx"]) {
        Some("image/heic")
    } else if has(&[b"mif1", b"msf1", b"heif"]) {
        Some("image/heif")
    } else {
        None
    }
}

/// A kept image's name: 64 lowercase hex digits, never a path.
fn valid_id(id: &str) -> bool {
    id.len() == 64 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// An `image` block's bytes, and what a record names it by (`{id, mimeType, name?}`, the id
/// the SHA-256 of the bytes). `None` for any other block, or image data that is not base64.
fn decode(block: &Value) -> Option<(Vec<u8>, Value)> {
    use base64::Engine;
    use sha2::Digest;
    if block.get("type").and_then(Value::as_str) != Some("image") {
        return None;
    }
    let data = block.get("data").and_then(Value::as_str)?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(data).ok()?;
    let id: String = sha2::Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
    let mime = block.get("mimeType").and_then(Value::as_str).unwrap_or("image/png");
    let mut named = json!({"id": id, "mimeType": mime});
    if let Some(name) = block.get("name").and_then(Value::as_str) {
        named["name"] = json!(name);
    }
    Some((bytes, named))
}

/// The id an `image` block's bytes are kept under; `None` for any other block.
pub(super) fn id_of(block: &Value) -> Option<String> {
    decode(block).and_then(|(_, named)| named["id"].as_str().map(str::to_owned))
}

/// What `keep` would record of `blocks`' images, without keeping them (a queued prompt's row,
/// `views.rs`).
pub(super) fn named(blocks: &[Value]) -> Vec<Value> {
    blocks.iter().filter_map(decode).map(|(_, named)| named).collect()
}

/// Keeps the bytes of each `image` block in `blocks` and returns what `user_message` (and a
/// queued prompt's `queued` and `queue_updated`) records of them. An image that cannot be read
/// or kept is left out: the prompt still goes.
pub(super) fn keep(blocks: &[Value]) -> Vec<Value> {
    blocks
        .iter()
        .filter_map(decode)
        .filter_map(|(bytes, named)| {
            let id = named["id"].as_str()?;
            let path = dir().join(id);
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
            Some(named)
        })
        .collect()
}

/// The prompt's ACP blocks in their original order, with attachment bytes replaced by durable
/// metadata. The web transcript uses this field to interleave text and attachments after a reload;
/// `images` is the result of `keep`, so an image is included only when its bytes have a durable id.
/// No block's base64 payload is copied into the event log.
pub(super) fn inline_parts(blocks: &[Value], images: &[Value]) -> Vec<Value> {
    let kept_images: HashSet<&str> =
        images.iter().filter_map(|image| image.get("id").and_then(Value::as_str)).collect();
    blocks
        .iter()
        .filter_map(|block| {
            let kind = block.get("type").and_then(Value::as_str)?;
            match kind {
                "text" if !crate::prompt_context::is_context(block) => {
                    let text = block.get("text").and_then(Value::as_str)?;
                    let mut part = json!({"kind": "text", "text": text});
                    if block.pointer("/_meta/cmux/pasted").and_then(Value::as_bool) == Some(true) {
                        part["pasted"] = Value::Bool(true);
                    }
                    Some(part)
                }
                "image" => {
                    let (_, named) = decode(block)?;
                    let id = named.get("id").and_then(Value::as_str)?;
                    kept_images.contains(id).then(|| {
                        let mut part = named;
                        part["kind"] = Value::String("image".into());
                        part
                    })
                }
                "document" | "audio" => {
                    let fallback = if kind == "document" { "document" } else { "audio" };
                    let name = block.get("name").and_then(Value::as_str).unwrap_or(fallback);
                    let mut part = json!({"kind": kind, "name": name});
                    if let Some(mime_type) = block.get("mimeType").and_then(Value::as_str) {
                        part["mimeType"] = Value::String(mime_type.into());
                    }
                    if let Some(size) = block_size(block) {
                        part["size"] = json!(size);
                    }
                    if let Some(page_count) = block.get("pageCount").and_then(Value::as_u64) {
                        part["pageCount"] = json!(page_count);
                    }
                    Some(part)
                }
                "resource_link" => {
                    let uri = block.get("uri").and_then(Value::as_str)?;
                    let name = block.get("name").and_then(Value::as_str).unwrap_or(uri);
                    let mut part = json!({"kind": "file", "name": name, "uri": uri});
                    if let Some(mime_type) = block.get("mimeType").and_then(Value::as_str) {
                        part["mimeType"] = Value::String(mime_type.into());
                    }
                    Some(part)
                }
                _ => None,
            }
        })
        .collect()
}

/// The decoded byte count of a document/audio block, without retaining its payload in the event.
fn block_size(block: &Value) -> Option<u64> {
    use base64::Engine;
    let data = block.get("data").and_then(Value::as_str)?;
    u64::try_from(base64::engine::general_purpose::STANDARD.decode(data).ok()?.len()).ok()
}

impl Hub {
    /// Records prompt `msg` as the session's `user_message`, naming the images of its `blocks`,
    /// preserving their ordered content metadata, and recording pasted text ranges (`session.rs`,
    /// `mark_pasted`).
    pub(super) fn append_prompt(&self, session: &Session, mut msg: Value, blocks: &[Value]) {
        let images = keep(blocks);
        if !images.is_empty() {
            msg["images"] = Value::Array(images);
        }
        let ordered =
            inline_parts(blocks, msg.get("images").and_then(Value::as_array).unwrap_or(&[]));
        if !ordered.is_empty() {
            msg["inlineParts"] = Value::Array(ordered);
        }
        super::session::mark_pasted(&mut msg, blocks);
        self.append(session, "mux", "user_message", msg);
    }

    /// `_acpmux/attachment`: the image `id` one of session `session`'s prompts sent or queued
    /// (so a queued prompt's row shows it before it runs), as `{mimeType, data}` (base64). Only
    /// an image the session's own log names is read.
    ///
    /// The log is read newest first, only the records that can name an image are parsed, and the
    /// read stops at the first that names it; an image never kept is refused without reading the
    /// log. Reading every record from the first took 16.7 s for one image of a 701 MB chat, and
    /// the bubble showed an empty box meanwhile (Leo, 2026-10-21).
    ///
    /// Its `mimeType` is the type its bytes are (`sniffed_type`), so it does not depend on which
    /// record the read finds: one id is one set of bytes, though two prompts may have labelled
    /// them differently. Only bytes of no known type take the newest record's label.
    pub fn prompt_image(&self, session: &str, id: &str) -> Result<Value, RpcError> {
        let missing = || RpcError::not_found(format!("no image {id} in this chat"));
        let path = dir().join(id);
        if !valid_id(id) || !path.is_file() {
            return Err(missing());
        }
        let filter = EventFilter::parse(Some(&json!(NAMING_KINDS)))?;
        let skip = |dir: &[u8], kind: &[u8]| filter.surely_skips(dir, kind);
        let mut named = None;
        self.store
            .scan_back(session, 0, u64::MAX, &skip, &mut |rec| {
                if !filter.matches(&rec) {
                    return true;
                }
                named = rec
                    .msg
                    .get("images")
                    .and_then(Value::as_array)
                    .and_then(|images| {
                        images
                            .iter()
                            .find(|image| image.get("id").and_then(Value::as_str) == Some(id))
                    })
                    .cloned();
                named.is_none()
            })
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let named = named.ok_or_else(missing)?;
        let bytes = std::fs::read(path).map_err(|_| missing())?;
        use base64::Engine;
        let mime = sniffed_type(&bytes)
            .map(|known| json!(known))
            .or_else(|| named.get("mimeType").cloned())
            .unwrap_or_else(|| json!("image/png"));
        Ok(json!({
            "mimeType": mime,
            "data": base64::engine::general_purpose::STANDARD.encode(bytes),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::{decode, inline_parts, sniffed_type};
    use serde_json::json;

    #[test]
    fn a_kept_files_type_comes_from_its_magic_number() {
        let png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";
        assert_eq!(sniffed_type(png), Some("image/png"));
        assert_eq!(sniffed_type(b"\xff\xd8\xff\xe0\0\x10JFIF"), Some("image/jpeg"));
        assert_eq!(sniffed_type(b"GIF89a\x01\0\x01\0"), Some("image/gif"));
        assert_eq!(sniffed_type(b"GIF87a\x01\0\x01\0"), Some("image/gif"));
        assert_eq!(sniffed_type(b"RIFF\x24\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniffed_type(b"BM\x36\0\0\0\0\0\0\0\x36\0\0\0"), Some("image/bmp"));
        assert_eq!(sniffed_type(b"II*\0\x08\0\0\0"), Some("image/tiff"));
        assert_eq!(sniffed_type(b"MM\0*\0\0\0\x08"), Some("image/tiff"));
        assert_eq!(sniffed_type(&ftyp(b"heic", &[b"mif1", b"heic"])), Some("image/heic"));
        assert_eq!(sniffed_type(&ftyp(b"mif1", &[b"mif1", b"miaf"])), Some("image/heif"));
        assert_eq!(sniffed_type(&ftyp(b"avif", &[b"avif", b"mif1", b"miaf"])), Some("image/avif"));
        assert_eq!(sniffed_type(b"%PDF-1.7\n"), Some("application/pdf"));
        // Text, a short or truncated header, another ISO brand, or nothing: no type.
        assert_eq!(sniffed_type(b"<svg xmlns='http://www.w3.org/2000/svg'/>"), None);
        assert_eq!(sniffed_type(b"\x89PNG"), None);
        assert_eq!(sniffed_type(b"BM"), None);
        assert_eq!(sniffed_type(&ftyp(b"isom", &[b"isom", b"mp41"])), None);
        assert_eq!(sniffed_type(b"\0\0\0\x18ftyp"), None);
        assert_eq!(sniffed_type(b""), None);
    }

    /// An ISO-BMFF `ftyp` box with `major` and `compatible` brands, its size its own length,
    /// followed by the start of the next box (as a file's `meta` follows its `ftyp`).
    fn ftyp(major: &[u8; 4], compatible: &[&[u8; 4]]) -> Vec<u8> {
        let size = 16 + 4 * compatible.len() as u32;
        let mut out = size.to_be_bytes().to_vec();
        out.extend_from_slice(b"ftyp");
        out.extend_from_slice(major);
        out.extend_from_slice(&0u32.to_be_bytes());
        for brand in compatible {
            out.extend_from_slice(*brand);
        }
        out.extend_from_slice(b"\0\0\0\x08meta");
        out
    }

    /// An HEIF file's type is its whole `ftyp` box (major and compatible brands, as libavif's
    /// read.c reads it), never its major brand alone; a box cut short names no type.
    #[test]
    fn an_iso_media_files_type_comes_from_its_whole_ftyp_box() {
        // AVIF named only among the compatible brands, behind an HEIF major brand.
        assert_eq!(sniffed_type(&ftyp(b"mif1", &[b"mif1", b"avif", b"miaf"])), Some("image/avif"));
        assert_eq!(sniffed_type(&ftyp(b"msf1", &[b"msf1", b"avis"])), Some("image/avif"));
        // HEIC the same way.
        assert_eq!(sniffed_type(&ftyp(b"mif1", &[b"mif1", b"heic"])), Some("image/heic"));
        // A brand past the end of the box is the next box's, not this one's.
        let mut outside = ftyp(b"mif1", &[b"mif1"]);
        outside.truncate(20);
        outside.extend_from_slice(b"avif");
        assert_eq!(sniffed_type(&outside), Some("image/heif"));
        // Cut short: 12 bytes of an AVIF header, a box longer than the file, a box shorter than
        // its header, and compatible brands that are not whole.
        assert_eq!(sniffed_type(b"\0\0\0\x18ftypavif"), None);
        let whole = ftyp(b"avif", &[b"avif", b"mif1"]);
        assert_eq!(sniffed_type(&whole[..20]), None);
        assert_eq!(sniffed_type(b"\0\0\0\x08ftypavif\0\0\0\0"), None);
        assert_eq!(sniffed_type(b"\0\0\0\x12ftypavif\0\0\0\0av"), None);
        // A box that runs to the end of the file (size 0), and one with a 64-bit size.
        assert_eq!(sniffed_type(b"\0\0\0\0ftypmif1\0\0\0\0mif1avif"), Some("image/avif"));
        let mut large = 1u32.to_be_bytes().to_vec();
        large.extend_from_slice(b"ftyp");
        large.extend_from_slice(&28u64.to_be_bytes());
        large.extend_from_slice(b"mif1\0\0\0\0heic");
        assert_eq!(sniffed_type(&large), Some("image/heic"));
        // A 64-bit size cut off, one below its own header and brands, and one past any file.
        assert_eq!(sniffed_type(&large[..12]), None);
        let mut small = large.clone();
        small[8..16].copy_from_slice(&20u64.to_be_bytes());
        assert_eq!(sniffed_type(&small), None);
        let mut huge = large.clone();
        huge[8..16].copy_from_slice(&u64::MAX.to_be_bytes());
        assert_eq!(sniffed_type(&huge), None);
    }

    #[test]
    fn inline_parts_keep_acp_order_without_attachment_bytes() {
        let image = json!({
            "type": "image",
            "mimeType": "image/png",
            "name": "one.png",
            "data": "AQID"
        });
        let kept = vec![decode(&image).unwrap().1];
        let blocks = vec![
            json!({"type": "text", "text": "before", "_meta": {"cmux": {"pasted": true}}}),
            image,
            json!({"type": "text", "text": "after"}),
            json!({"type": "document", "mimeType": "application/pdf", "name": "brief.pdf", "data": "JVBERi0="}),
            json!({"type": "resource_link", "uri": "attachment://notes.txt", "name": "notes.txt"}),
        ];

        let parts = inline_parts(&blocks, &kept);
        assert_eq!(
            parts.iter().map(|part| part["kind"].as_str().unwrap()).collect::<Vec<_>>(),
            ["text", "image", "text", "document", "file"]
        );
        assert_eq!(parts[0]["pasted"], true);
        assert_eq!(parts[1]["id"], kept[0]["id"]);
        assert_eq!(parts[3]["size"], 5);
        assert!(parts.iter().all(|part| part.get("data").is_none()));
    }
}
