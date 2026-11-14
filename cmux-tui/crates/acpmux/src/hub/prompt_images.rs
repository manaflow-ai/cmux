//! Images sent with a prompt (Leo, 2026-10-13: a sent prompt's images vanished). Each image's
//! bytes are kept once, named by their SHA-256, under `<ACPMUX_HOME>/attachments`, and the
//! prompt's `user_message` names them (`images: [{id, mimeType, name}]`), so a chat shows its
//! images after it is sent, after a restart, and in a fork (which copies the log).
//! A queued prompt's `queued` and `queue_updated` records name its images the same way, so its
//! row shows them before it runs. `_acpmux/attachment` reads one back for a session whose log
//! names it.

use super::{EventFilter, Hub, Session};
use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

const MAX_DISPLAY_NAME: usize = 256;
const MAX_DISPLAY_MIME: usize = 128;
const MAX_DISPLAY_RANGE: u64 = 4 * 1024 * 1024;
const MAX_SOURCE_NAME: usize = 64;

fn dir() -> PathBuf {
    crate::config::home().join("attachments")
}

/// The records that name a prompt's images.
const NAMING_KINDS: [&str; 3] = ["user_message", "queued", "queue_updated"];

/// The type a kept file's bytes are, from their magic number: PNG, JPEG, GIF, WebP, BMP, TIFF,
/// HEIC/HEIF, AVIF and PDF. `None` for anything else (an SVG is text: its record names it).
pub(crate) fn sniffed_type(bytes: &[u8]) -> Option<&'static str> {
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
    let (major, compatible) = (bytes.get(header..header + 4)?, bytes.get(header + 8..size)?);
    let brands: Vec<&[u8]> = std::iter::once(major).chain(compatible.chunks_exact(4)).collect();
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

/// The bytes of each image block among `blocks`, by the id a record names it by (`decode`).
pub(crate) fn image_bytes(blocks: &[Value]) -> Vec<(String, Vec<u8>)> {
    blocks
        .iter()
        .filter_map(decode)
        .filter_map(|(bytes, named)| Some((named.get("id")?.as_str()?.to_owned(), bytes)))
        .collect()
}

/// Where image `id`'s bytes are kept on this machine; None for an id `decode` never makes.
pub(crate) fn image_path(id: &str) -> Option<PathBuf> {
    valid_id(id).then(|| dir().join(id))
}

/// The ids of the images a record's `msg` names (`images: [{id, ..}]`).
pub(crate) fn named_ids(msg: &Value) -> impl Iterator<Item = &str> {
    let images = msg.get("images").and_then(Value::as_array).into_iter().flatten();
    images.filter_map(|named| named.get("id").and_then(Value::as_str))
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
        named.set("name", json!(name));
    }
    Some((bytes, named))
}

/// The app an attachment came from, as the app said it in the prompt's display metadata (an
/// `inlineParts` entry's `source`, AttachmentSource.swift): `{name, bundleId?, site?}`, each field
/// checked the way the app makes it, so the record never keeps anything else under that name.
/// `None` for one that is not one. It rides the request's `_meta`, never a block's: a block's own
/// `_meta` never reaches the harness. Leo, 2026-10-29: "Also, I guess it's, like, you know, be
/// interesting to add, like, attributions for screenshots and attachments and whatnot, right?"
pub(crate) fn checked_source(raw: &Value) -> Option<Value> {
    let raw = raw.as_object()?;
    let name = raw.get("name")?.as_str()?.trim();
    if name.is_empty() || name.chars().count() > MAX_SOURCE_NAME {
        return None;
    }
    let mut source = json!({"name": name});
    if let Some(value) = raw.get("bundleId") {
        let id = value.as_str()?;
        let allowed = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_');
        if id.is_empty()
            || id.len() > 255
            || id.starts_with('.')
            || !id.contains('.')
            || !id.chars().all(allowed)
        {
            return None;
        }
        source.set("bundleId", json!(id));
    }
    if let Some(value) = raw.get("site") {
        let site = value.as_str()?;
        let allowed =
            |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '-');
        if site.is_empty() || site.len() > 253 || !site.chars().all(allowed) {
            return None;
        }
        source.set("site", json!(site));
    }
    Some(source)
}

/// The id an `image` block's bytes are kept under; `None` for any other block.
pub(super) fn id_of(block: &Value) -> Option<String> {
    decode(block).and_then(|(_, named)| named["id"].as_str().map(str::to_owned))
}

/// What `keep_sourced` would record of `blocks`' images, without keeping them (a queued
/// prompt's row, `views.rs`), each with its own block's source from the prompt's display metadata
/// (`name_image_sources`): a queued prompt's listed images keep their sources.
pub(super) fn named_sourced(blocks: &[Value], display_parts: Option<&Value>) -> Vec<Value> {
    let mut named: Vec<(usize, Value)> = blocks
        .iter()
        .enumerate()
        .filter_map(|(index, block)| decode(block).map(|(_, named)| (index, named)))
        .collect();
    name_image_sources(&mut named, blocks, display_parts);
    named.into_iter().map(|(_, named)| named).collect()
}

/// Keeps the bytes of each `image` block in `blocks` and returns what `user_message` (and a
/// queued prompt's `queued` and `queue_updated`) records of them, each with its source from the
/// prompt's display metadata (`name_image_sources`), so Edit message and a reload keep it. An image
/// that cannot be read or kept is left out: the prompt still goes.
pub(super) fn keep_sourced(blocks: &[Value], display_parts: Option<&Value>) -> Vec<Value> {
    let mut kept = keep_indexed(blocks);
    name_image_sources(&mut kept, blocks, display_parts);
    kept.into_iter().map(|(_, image)| image).collect()
}

/// The kept image records, each with its block's index in `blocks`.
fn keep_indexed(blocks: &[Value]) -> Vec<(usize, Value)> {
    blocks
        .iter()
        .enumerate()
        .filter_map(|(index, block)| decode(block).map(|decoded| (index, decoded)))
        .filter_map(|(index, (bytes, named))| {
            let id = named["id"].as_str()?;
            let path = dir().join(id);
            if !path.is_file() {
                let written = crate::config::refuse_lost_home(&path)
                    .map_err(std::io::Error::other)
                    // Through the folder this daemon holds (`home_fs`): a home replaced after
                    // the check never gets the image.
                    .and_then(|()| crate::home_fs::create_dir_all(dir(), 0o777))
                    .and_then(|()| {
                        // Written aside and renamed, so a reader never sees half an image.
                        let partial = dir().join(format!("{id}.{}.partial", uuid::Uuid::now_v7()));
                        let written = write_owner_only(&partial, &bytes)
                            .and_then(|()| crate::home_fs::rename(&partial, &path));
                        if written.is_err() {
                            let _ = crate::home_fs::remove_file(&partial);
                        }
                        written
                    });
                if let Err(e) = written {
                    tracing::warn!("cannot keep a prompt image: {e}");
                    return None;
                }
            }
            Some((index, named))
        })
        .collect()
}

/// Sets a prompt record's `inlineParts` to `parts`, unless they say nothing its `text` does not:
/// none, or one plain text part (no paste, file or display fields) whose text is the record's
/// `text`. Every reader falls back to `text` without them, as for a record from before
/// `inlineParts` (`retry_turn.rs` `prompt_blocks`, `fork_before.rs`, the web and iOS
/// transcripts), and that one part was the prompt's whole text a second time in the record, in
/// the journal and in the log's kind index (cmuxterm-hq#9263).
pub(super) fn set_inline_parts(msg: &mut Value, parts: Vec<Value>) {
    let only_text = match parts.as_slice() {
        [] => true,
        [part] => {
            part.as_object().is_some_and(|fields| {
                fields.len() == 2 && fields.get("kind").and_then(Value::as_str) == Some("text")
            }) && part.get("text").and_then(Value::as_str).is_some()
                && part.get("text") == msg.get("text")
        }
        _ => false,
    };
    if !only_text {
        msg.set("inlineParts", Value::Array(parts));
    }
}

/// Writes a new file only its owner reads (0600 on Unix).
fn write_owner_only(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut file =
        crate::home_fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// The prompt's ACP blocks in their original order, with attachment bytes replaced by durable
/// metadata. The web transcript uses this field to interleave text and attachments after a reload.
/// Every image gets its content id here even when `keep_sourced` could not write its bytes: this
/// preserves identity across a later image in the same prompt, while the separate `images` field
/// remains the authoritative list of ids that `_acpmux/attachment` can actually read. No block's
/// base64 payload is copied into the event log.
pub(super) fn inline_parts(
    blocks: &[Value],
    images: &[Value],
    display_parts: Option<&Value>,
) -> Vec<Value> {
    let kept_images: HashSet<&str> =
        images.iter().filter_map(|image| image.get("id").and_then(Value::as_str)).collect();
    let display = validated_display_parts(display_parts, blocks);
    let companion_images: HashSet<u64> = display
        .values()
        .filter_map(|part| part.get("companionOf").and_then(Value::as_u64))
        .collect();
    blocks
        .iter()
        .enumerate()
        .filter_map(|(block_index, block)| {
            let kind = block.get("type").and_then(Value::as_str)?;
            let display_part = display.get(&block_index);
            match kind {
                "text" if !crate::prompt_context::is_context(block) => {
                    let text = block.get("text").and_then(Value::as_str)?;
                    if let Some(display_part) = display_part
                        && matches!(
                            display_part.get("kind").and_then(Value::as_str),
                            Some("file" | "pasted")
                        )
                    {
                        let mut part = display_part.clone();
                        part.set("text", Value::String(text.to_owned()));
                        if part.get("kind").and_then(Value::as_str) == Some("pasted")
                            && part.get("name").is_none()
                        {
                            part.set("name", Value::String("Pasted text".into()));
                        }
                        return Some(part);
                    }
                    let mut part = json!({"kind": "text", "text": text});
                    if block.pointer("/_meta/cmux/pasted").and_then(Value::as_bool) == Some(true) {
                        part.set("pasted", Value::Bool(true));
                    }
                    Some(part)
                }
                "image" => {
                    let (_, named) = decode(block)?;
                    let id = named.get("id").and_then(Value::as_str)?;
                    let persisted = kept_images.contains(id);
                    let mut part = named;
                    part.set("kind", Value::String("image".into()));
                    if companion_images.contains(&(block_index as u64)) {
                        part.set("blockIndex", json!(block_index));
                    }
                    if !persisted {
                        part.set("persisted", Value::Bool(false));
                    }
                    if let Some(display_part) = display_part {
                        copy_display_fields(&mut part, display_part);
                    }
                    Some(part)
                }
                "document" | "audio" => {
                    let fallback = if kind == "document" { "document" } else { "audio" };
                    let name = block.get("name").and_then(Value::as_str).unwrap_or(fallback);
                    let mut part = json!({"kind": kind, "name": name});
                    if let Some(mime_type) = block.get("mimeType").and_then(Value::as_str) {
                        part.set("mimeType", Value::String(mime_type.into()));
                    }
                    if let Some(size) = block_size(block) {
                        part.set("size", json!(size));
                    }
                    if let Some(page_count) = block.get("pageCount").and_then(Value::as_u64) {
                        part.set("pageCount", json!(page_count));
                    }
                    if let Some(display_part) = display_part {
                        copy_display_fields(&mut part, display_part);
                    }
                    Some(part)
                }
                "resource_link" => {
                    let uri = block.get("uri").and_then(Value::as_str)?;
                    if uri.is_empty() {
                        return None;
                    }
                    let name = block.get("name").and_then(Value::as_str).unwrap_or(uri);
                    let mut part = json!({"kind": "file", "name": name, "uri": uri});
                    if let Some(mime_type) = block.get("mimeType").and_then(Value::as_str) {
                        part.set("mimeType", Value::String(mime_type.into()));
                    }
                    if let Some(display_part) = display_part {
                        copy_display_fields(&mut part, display_part);
                    }
                    Some(part)
                }
                _ => None,
            }
        })
        .collect()
}

/// Validates the app's display-only prompt metadata. It never accepts bytes, paths, ids or text;
/// those come from the already-validated ACP blocks and the daemon's own attachment hashes.
pub(crate) fn validated_display_parts(
    raw: Option<&Value>,
    blocks: &[Value],
) -> HashMap<usize, Value> {
    let Some(Value::Array(parts)) = raw else { return HashMap::new() };
    let mut validated = HashMap::with_capacity(parts.len().min(blocks.len()));
    for part in parts {
        let Some(object) = part.as_object() else { continue };
        let Some(kind) = object.get("kind").and_then(Value::as_str) else { continue };
        if !matches!(kind, "text" | "image" | "file" | "document" | "audio" | "pasted") {
            continue;
        }
        let Some(block_index) = object
            .get("blockIndex")
            .and_then(Value::as_u64)
            .and_then(|index| usize::try_from(index).ok())
        else {
            continue;
        };
        if validated.contains_key(&block_index) {
            continue;
        }
        let Some(block) = blocks.get(block_index) else { continue };
        let Some(block_type) = block.get("type").and_then(Value::as_str) else { continue };
        let kind_matches = match kind {
            "text" | "pasted" => block_type == "text",
            "file" => matches!(block_type, "text" | "resource_link"),
            "image" => block_type == "image",
            "document" => block_type == "document",
            "audio" => block_type == "audio",
            _ => false,
        };
        if !kind_matches {
            continue;
        }
        if kind == "file"
            && block_type == "resource_link"
            && !matches!(block.get("uri").and_then(Value::as_str), Some(uri) if !uri.is_empty())
        {
            continue;
        }
        let mut out =
            serde_json::Map::from_iter([(String::from("kind"), Value::String(kind.into()))]);
        if let Some(raw) = object.get("companionOf") {
            let Some(index) = raw.as_u64().and_then(|n| usize::try_from(n).ok()) else { continue };
            if kind != "file"
                || block_type != "resource_link"
                || index.checked_add(1) != Some(block_index)
                || !blocks.get(index).is_some_and(|target| {
                    target.get("type").and_then(Value::as_str) == Some("image")
                        && decode(target).is_some()
                })
            {
                continue;
            }
            out.insert("companionOf".into(), json!(index));
        }
        if let Some(name) = object.get("name").and_then(Value::as_str) {
            if name.is_empty() || name.chars().count() > MAX_DISPLAY_NAME {
                continue;
            }
            out.insert("name".into(), Value::String(name.into()));
        } else if kind == "file" && block_type == "text" {
            // A text block has no authoritative filename. Without the app's name, fall back to
            // the plain text part rather than persisting an invalid nameless file descriptor.
            continue;
        }
        if let Some(mime) = object.get("mimeType").and_then(Value::as_str) {
            if mime.is_empty() || mime.len() > MAX_DISPLAY_MIME {
                continue;
            }
            out.insert("mimeType".into(), Value::String(mime.into()));
        }
        for key in ["size", "pageCount"] {
            if let Some(value) = object.get(key).and_then(Value::as_u64) {
                out.insert(key.into(), Value::Number(value.into()));
            }
        }
        // The app's composer put this attachment in the prompt's text: the web transcript draws
        // a prompt in its recorded order only when it was placed. Only `true` is kept; a prompt
        // without it (the old unplaced shape, or one from an older app) never gains it.
        if object.get("placed") == Some(&Value::Bool(true)) {
            out.insert("placed".into(), Value::Bool(true));
        }
        let start = object.get("start").and_then(Value::as_u64);
        let end = object.get("end").and_then(Value::as_u64);
        if start.is_some() != end.is_some()
            || start.is_some_and(|value| value > MAX_DISPLAY_RANGE)
            || end.is_some_and(|value| value > MAX_DISPLAY_RANGE)
        {
            continue;
        }
        if let (Some(start), Some(end)) = (start, end) {
            let Some(text) = block.get("text").and_then(Value::as_str) else { continue };
            let text_len = text.encode_utf16().count() as u64;
            if start > end || end > text_len {
                continue;
            }
            out.insert("start".into(), Value::Number(start.into()));
            out.insert("end".into(), Value::Number(end.into()));
        }
        if let Some(source) = object.get("source").and_then(checked_source) {
            out.insert("source".into(), source);
        }
        validated.insert(block_index, Value::Object(out));
    }
    validated
}

fn copy_display_fields(part: &mut Value, display: &Value) {
    let Some(object) = display.as_object() else { return };
    for key in
        ["name", "mimeType", "size", "pageCount", "start", "end", "companionOf", "placed", "source"]
    {
        if let Some(value) = object.get(key) {
            part[key] = value.clone();
        }
    }
}

/// The decoded byte count of a document/audio block, without retaining its payload in the event.
fn block_size(block: &Value) -> Option<u64> {
    use base64::Engine;
    let data = block.get("data").and_then(Value::as_str)?;
    u64::try_from(base64::engine::general_purpose::STANDARD.decode(data).ok()?.len()).ok()
}
/// The `image` blocks of images a record names (`keep_sourced`'s `{id, mimeType, name}`), read
/// back from where `keep_sourced` put them, so a prompt that is sent again (a restart's
/// continuation, `restart_resume.rs`) carries them. One that is gone or whose id is not one
/// `keep_sourced` makes is left out.
pub(super) fn blocks_of(images: &[Value]) -> Vec<Value> {
    use base64::Engine;
    images
        .iter()
        .filter_map(|named| {
            let id = named.get("id").and_then(Value::as_str).filter(|id| valid_id(id))?;
            let bytes = std::fs::read(dir().join(id)).ok()?;
            let mime = sniffed_type(&bytes)
                .map(str::to_owned)
                .or_else(|| named.get("mimeType").and_then(Value::as_str).map(str::to_owned))
                .unwrap_or_else(|| "image/png".to_owned());
            let mut block = json!({
                "type": "image",
                "mimeType": mime,
                "data": base64::engine::general_purpose::STANDARD.encode(bytes),
            });
            if let Some(name) = named.get("name") {
                block.set("name", name.clone());
            }
            Some(block)
        })
        .collect()
}

/// Puts each image's source from the prompt's display metadata on its record
/// (`{id, mimeType, name}`, with its block's index), so the transcript's thumbnail has it after a
/// reload. Each record takes only its own block's source: byte-identical images share an id but
/// not a source.
fn name_image_sources(
    images: &mut [(usize, Value)],
    blocks: &[Value],
    display_parts: Option<&Value>,
) {
    let display = validated_display_parts(display_parts, blocks);
    for (block_index, image) in images {
        if let Some(source) = display.get(block_index).and_then(|part| part.get("source")) {
            image.set("source", source.clone());
        }
    }
}

impl Hub {
    /// Records prompt `msg` as the session's `user_message`, naming the images of its `blocks`,
    /// preserving their ordered content metadata, and recording pasted text ranges (`session.rs`,
    /// `mark_pasted`).
    pub(super) fn append_prompt(
        &self,
        session: &Session,
        mut msg: Value,
        blocks: &[Value],
        display_parts: Option<&Value>,
    ) {
        let images = keep_sourced(blocks, display_parts);
        if !images.is_empty() {
            msg.set("images", Value::Array(images));
        }
        let ordered = inline_parts(
            blocks,
            msg.get("images").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default(),
            display_parts,
        );
        set_inline_parts(&mut msg, ordered);
        super::session::mark_pasted(&mut msg, blocks);
        // The immutable cmux snapshot is saved in metadata and can be appended again
        // by turns.rs. Only unrecorded client context prevents Retry/restart replay.
        let mut saved_context = Vec::new();
        crate::context_inventory::append_snapshot(
            session.meta().cmux_context.as_deref(),
            &mut saved_context,
        );
        if blocks
            .iter()
            .any(|block| crate::prompt_context::is_context(block) && !saved_context.contains(block))
        {
            msg.set("hiddenContext", Value::Bool(true));
        }
        // Purged once its creator is done: the log keeps no long body (`ephemeral.rs`).
        if session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner).throwaway {
            super::ephemeral::leave_out_body(&mut msg);
        }
        // A turn Claude Code started on its own and still runs: the rest is this prompt's turn.
        self.end_background_turn(session, "prompt");
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
mod tests;
