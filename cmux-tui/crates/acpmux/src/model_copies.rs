//! Model-sized copies of large images (`docs/prompt-uploads.md` section 6). There is no size cap
//! on a file sent with a prompt (Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES
//! OF ANY TYPE"), so an image past what the model takes inline reaches the agent as a
//! `resource_link` to its path (`prompt_uploads.rs`). The agent can open it, but the model never
//! sees it. When the prompt is written to the agent, each such PNG also gets a copy sized for the
//! harness ([`limits`]): scaled so its long edge fits, as an inline image next to the link to the
//! original, while the prompt has inline room.
//!
//! - The copy is made only for the agent's `session/prompt`. The transcript and the queue keep the
//!   prompt as sent, and the record of what was written to the agent leaves the copy out
//!   ([`scrub_logged`]), so no copy's base64 reaches the log.
//! - A copy is made only while the turn is the machine's own: the prompt is written without one
//!   when a remote device took the turn, or a Stop came, while it was made (`hub/turns.rs`).
//! - A copy is saved next to its upload (`.model-<edge>.png`, a name no upload file can have) and
//!   goes with it when the upload is swept or cancelled. A retry or a restore reuses it.
//! - The PNG is read a row at a time and scaled by area averaging, so the original is never held
//!   in memory whatever its size.
//! - Only a finished upload of the prompt's own chat is read (`file_uploads::open_finished`).
//! - An image that cannot be copied (another type, a bad or interlaced PNG, no room) keeps only its
//!   link, as before. That is never a refusal.
//!
//!
//! An image sent inline (the composer's pasted or dropped picture, at its full size: Leo,
//! "What every coder should know about gamma"; claude-sr2-coord, 2026-11-17: "Composer image fit:
//! do it in Rust, not JS") is fitted the same way ([`fit_inline`]): a PNG or JPEG past the
//! model's edge or bytes is replaced in place by its copy scaled in linear light. That reads no
//! file, so it is done for every turn, a remote device's too. A link to an upload of the chat
//! written as a `file://` URI (the composer's link to a picture's original) gets a copy as a
//! resolved upload link does, unless the image block right before it is that picture already.
//!
//! WebP copies, and copies of JPEG uploads (whose EXIF orientation the copy must apply), come in
//! a follow-up.

use crate::hub::file_uploads;
use base64::Engine;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::io::BufReader;
use std::path::{Path, PathBuf};

/// The `initialize` feature of a daemon that fits a prompt's inline images to the model
/// ([`fit_inline`]) and cleans their metadata (`image_privacy.rs`): a client sends a pasted PNG or
/// JPEG as its own file only to one that lists it, and scales it itself for any other
/// (webviews `composer/imageWork.ts`). This daemon fits a prompt for a peer that does not list
/// it before forwarding it there (`server/peer_forward.rs`).
pub const FEATURE: &str = "fitsImages";

/// The `tEXt` chunk every copy carries (keyword, NUL, text), by which [`scrub_logged`] knows
/// its base64 in any shape a harness's line puts it.
const MARK: &[u8] = b"acpmux\0model-copy";

/// What a copy's base64 is replaced with in the log.
const OMITTED: &str = "(acpmux model-sized copy, not logged)";

/// The most pixels a copy is made from (about 1.5 s of decoding): a PNG past it, which no screen
/// makes, keeps only its link, so its decode never holds the prompt back. The file itself still
/// goes whatever its size.
const MAX_SOURCE_PIXELS: u64 = 100_000_000;

/// What a harness's model takes as one inline image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// The longest edge, in pixels, the model reads at full detail.
    pub max_edge: u32,
    /// The most decoded bytes of one image (`prompt_uploads::INLINE_IMAGE_BYTES`).
    pub max_bytes: usize,
}

/// The table, by harness family:
/// - `claude`: 1568 px, the long edge past which Anthropic's API scales an image down, and at most
///   5 MiB of base64 an image.
/// - `codex`: 2048 px, the square OpenAI fits a high-detail image in.
/// - Any other family: Claude's numbers, the strictest of the two.
pub fn limits(family: Option<&str>) -> Limits {
    let max_bytes = crate::prompt_uploads::INLINE_IMAGE_BYTES;
    match family {
        Some("codex") => Limits { max_edge: 2048, max_bytes },
        _ => Limits { max_edge: 1568, max_bytes },
    }
}

/// `blocks` (a prompt as it is written to session `session`'s agent of `family`) with a
/// model-sized copy after each large PNG link to one of the chat's uploads (module docs).
/// Never fails. A block that gets no copy stays as it was.
pub async fn add(session: &str, family: Option<&str>, blocks: &[Value]) -> Vec<Value> {
    if !blocks.iter().any(|b| upload_png(session, b).is_some()) {
        return blocks.to_vec();
    }
    let (session, limits, owned) = (session.to_owned(), limits(family), blocks.to_vec());
    let fallback = owned.clone();
    tokio::task::spawn_blocking(move || add_blocking(&session, limits, owned))
        .await
        .unwrap_or(fallback)
}

/// `blocks` with each inline PNG or JPEG image past what the model of `family` takes (its long
/// edge or its bytes, [`limits`]) replaced by its copy scaled in linear light, as a PNG, in the
/// same place (module docs). Reads no file. Never fails: an image that cannot be decoded stays as
/// it was.
pub async fn fit_inline(family: Option<&str>, blocks: &[Value]) -> Vec<Value> {
    let limits = limits(family);
    if !blocks.iter().any(|b| inline_image(b).is_some()) {
        return blocks.to_vec();
    }
    let (owned, fallback) = (blocks.to_vec(), blocks.to_vec());
    tokio::task::spawn_blocking(move || fit_inline_blocking(limits, owned))
        .await
        .unwrap_or(fallback)
}

/// [`fit_inline`], blocking.
pub fn fit_inline_blocking(limits: Limits, mut blocks: Vec<Value>) -> Vec<Value> {
    for block in &mut blocks {
        let Some(data) = inline_image(block) else { continue };
        let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else { continue };
        let Some((copy, _, _)) = fitted(&bytes, limits) else { continue };
        let data = base64::engine::general_purpose::STANDARD.encode(&copy);
        block.set_path(&["data"], json!(data));
        block.set_path(&["mimeType"], json!("image/png"));
    }
    blocks
}

/// The base64 of `block` when it is an inline image.
fn inline_image(block: &Value) -> Option<&str> {
    if block.get("type").and_then(Value::as_str) != Some("image") {
        return None;
    }
    block.get("data").and_then(Value::as_str).filter(|d| !d.is_empty())
}

/// The copy of PNG or JPEG `bytes` that fits `limits` (an encoded PNG and its size, upright as its
/// EXIF orientation says), or None when it already fits and is upright (or is not one of those,
/// or cannot be decoded). A turned picture is always copied: a model may not read the tag.
pub fn fitted(bytes: &[u8], limits: Limits) -> Option<(Vec<u8>, u32, u32)> {
    let jpeg = match crate::hub::prompt_images::sniffed_type(bytes)? {
        "image/png" => false,
        "image/jpeg" => true,
        _ => return None,
    };
    let (w, h) = if jpeg { jpeg_size(bytes)? } else { png_size(bytes)? };
    let turn = crate::image_privacy::orientation(bytes);
    if w.max(h) <= limits.max_edge && bytes.len() <= limits.max_bytes && turn == 1 {
        return None;
    }
    let mut edge = limits.max_edge;
    // A copy past `max_bytes` is made again, smaller, a few times.
    for _ in 0..6 {
        let made = if jpeg {
            downscale_jpeg(bytes, edge)?
        } else {
            downscale_oriented(std::io::Cursor::new(bytes), edge, turn)?
        };
        if made.0.len() <= limits.max_bytes {
            return Some(made);
        }
        edge = edge.min(made.1.max(made.2)) * 3 / 4;
    }
    None
}

/// [`add`], blocking.
fn add_blocking(session: &str, limits: Limits, blocks: Vec<Value>) -> Vec<Value> {
    // As `prompt_uploads::resolve` counts it: base64 images within the inline room, and the whole
    // prompt within one message.
    let size: usize = blocks.iter().map(|b| b.to_string().len()).sum();
    let room = crate::rpc::MAX_MESSAGE_BYTES.saturating_sub(size + (1 << 20));
    let inline: usize = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("image"))
        .filter_map(|b| b.get("data").and_then(Value::as_str))
        .map(str::len)
        .sum();
    let prompt_room = crate::prompt_uploads::INLINE_PROMPT_BYTES.div_ceil(3) * 4;
    let mut left = prompt_room.saturating_sub(inline).min(room);
    let mut out: Vec<Value> = Vec::with_capacity(blocks.len());
    for block in blocks {
        // The composer's link to the original of the picture it sent just before: the model has
        // that picture already.
        let after_image = out.last().is_some_and(|b| inline_image(b).is_some());
        let copy = upload_png(session, &block).filter(|_| !after_image).and_then(|path| {
            // The note and the image block's own JSON are counted below, as written.
            let budget = limits.max_bytes.min(left.saturating_sub(4 << 10) / 4 * 3);
            // No room for even a small copy: the rest keep only their links.
            if budget < 64 << 10 {
                return None;
            }
            let (bytes, w, h) = copy_of(&path, limits.max_edge, budget)?;
            let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
            let image = json!({"type": "image", "mimeType": "image/png", "data": data});
            let note = json!({"type": "text", "text": format!(
                "(The image above is {} scaled to {w}x{h} for you; the original is at that path.)",
                path.display()
            )});
            // Each block as it is serialized in the prompt, with its comma.
            let added = image.to_string().len() + note.to_string().len() + 2;
            left = left.checked_sub(added)?;
            Some([image, note])
        });
        out.push(block);
        out.extend(copy.into_iter().flatten());
    }
    out
}

/// `record` (what acpmux wrote to an agent, before it is logged) with the base64 of every
/// model-sized copy in it, in the ACP prompt or a harness's own line, replaced by a note.
pub fn scrub_logged(record: &mut Value) {
    match record {
        Value::String(s) if is_copy(s) => *s = OMITTED.to_owned(),
        Value::Array(items) => items.iter_mut().for_each(scrub_logged),
        Value::Object(map) => map.values_mut().for_each(scrub_logged),
        _ => {}
    }
}

/// Whether `s` is the base64 of a copy: a PNG whose first chunk after its header is [`MARK`].
fn is_copy(s: &str) -> bool {
    // The signature, IHDR (25 bytes) and the mark's chunk head, in whole base64 quanta.
    const HEAD: usize = (8 + 25 + 8 + MARK.len()).div_ceil(3) * 4;
    if s.len() < HEAD || !s.starts_with("iVBORw0KGgo") {
        return false;
    }
    let Ok(head) = base64::engine::general_purpose::STANDARD
        .decode(s.as_bytes().get(..HEAD).unwrap_or_default())
    else {
        return false;
    };
    head.get(33 + 4..33 + 8) == Some(b"tEXt") && head.get(41..41 + MARK.len()) == Some(MARK)
}

/// The path of the PNG or JPEG `block` links to, when it is a finished upload of chat `session`
/// that `prompt_uploads::resolve` put as a link (not inline), or a link the composer wrote itself
/// (`file://` and the upload's path, no type); either by the file's first bytes.
fn upload_png(session: &str, block: &Value) -> Option<PathBuf> {
    if block.get("type").and_then(Value::as_str) != Some("resource_link") {
        return None;
    }
    let mime = block.get("mimeType").and_then(Value::as_str);
    let copied = |m: &str| m == "image/png" || m == "image/jpeg";
    let resolved = block.pointer("/_meta/acpmux/uploadPath").and_then(Value::as_str);
    let path = match resolved {
        Some(path) if mime.is_some_and(copied) => PathBuf::from(path),
        Some(_) => return None,
        None if mime.is_none_or(copied) => {
            file_uri_path(block.get("uri").and_then(Value::as_str)?)?
        }
        None => return None,
    };
    let chat = file_uploads::session_dir(session)?;
    // `<uploads>/<chat>/<upload id>/<name>`, and nothing else.
    let ok = file_uploads::is_upload(&path)
        && path.parent().and_then(Path::parent) == Some(chat.as_path());
    if !ok {
        return None;
    }
    // What the file is by its first bytes, whatever the link says.
    let mut head = [0u8; 8];
    let mut file = file_uploads::open_finished(&path).ok()?;
    std::io::Read::read_exact(&mut file, &mut head).ok()?;
    crate::hub::prompt_images::sniffed_type(&head).is_some_and(copied).then_some(path)
}

/// How much of an upload is read for its EXIF orientation: a PNG's `eXIf` comes before its
/// pixels, a JPEG's APP1 within its first segments.
const ORIENTATION_HEAD: u64 = 1 << 20;

/// The path of a `file://` URI whose segments are percent-encoded (the composer's
/// `attachments.ts` `fileUri`). None for any other URI, or one that does not decode to UTF-8.
fn file_uri_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    if !rest.starts_with('/') {
        return None;
    }
    let raw = rest.as_bytes();
    let mut out = Vec::with_capacity(raw.len());
    let mut at = 0;
    while at < raw.len() {
        if raw[at] == b'%' {
            let hex = std::str::from_utf8(raw.get(at + 1..at + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            at += 3;
        } else {
            out.push(raw[at]);
            at += 1;
        }
    }
    Some(PathBuf::from(String::from_utf8(out).ok()?))
}

/// The copy of the PNG at `path` scaled to fit `max_edge` and `max_bytes` (an encoded PNG and its
/// size), from its saved copy if there is one. None when it cannot be made within them. Blocking.
fn copy_of(path: &Path, max_edge: u32, max_bytes: usize) -> Option<(Vec<u8>, u32, u32)> {
    let dir = path.parent()?;
    let mut edge = max_edge;
    // A copy past `max_bytes` is made again, smaller, a few times.
    for _ in 0..6 {
        let saved = dir.join(format!(".model-{edge}.png"));
        let made = match std::fs::read(&saved) {
            Ok(bytes) => png_size(&bytes).map(|(w, h)| (bytes, w, h)),
            Err(_) => {
                use std::io::Read as _;
                let mut head = Vec::new();
                let mut file = file_uploads::open_finished(path).ok()?;
                (&mut file).take(ORIENTATION_HEAD).read_to_end(&mut head).ok()?;
                let made = if crate::hub::prompt_images::sniffed_type(&head) == Some("image/jpeg") {
                    // A JPEG decodes whole (`downscale_jpeg`), within `MAX_SOURCE_PIXELS`.
                    file.read_to_end(&mut head).ok()?;
                    downscale_jpeg(&head, edge)?
                } else {
                    let turn = crate::image_privacy::orientation(&head);
                    let file = file_uploads::open_finished(path).ok()?;
                    downscale_oriented(BufReader::new(file), edge, turn)?
                };
                save(&saved, &made.0);
                Some(made)
            }
        };
        let (bytes, w, h) = made?;
        if bytes.len() <= max_bytes {
            return Some((bytes, w, h));
        }
        // Past the bytes (a noisy image, or one already within the edge): smaller again.
        edge = edge.min(w.max(h)) * 3 / 4;
    }
    None
}

/// Writes `bytes` to `path` whole or not at all ([`crate::config::write_atomic_unsynced`]: a
/// temporary name, owner-only, then a rename, and the copies of a writer stopped before its rename
/// removed). A copy that cannot be saved is made again next time. Under the held home it goes
/// through that folder (`home_fs`): a home replaced after the check never gets the copy (#41372
/// review F5).
fn save(path: &Path, bytes: &[u8]) {
    let _ = crate::config::write_atomic_unsynced(path, bytes);
}

/// A PNG's width and height from its header.
fn png_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let reader = png::Decoder::new(std::io::Cursor::new(bytes)).read_info().ok()?;
    Some((reader.info().width, reader.info().height))
}

/// Whether a copy is made of a `w`x`h` image: not empty, and within [`MAX_SOURCE_PIXELS`].
fn copyable(w: u32, h: u32) -> bool {
    w > 0 && h > 0 && u64::from(w) * u64::from(h) <= MAX_SOURCE_PIXELS
}

/// The PNG read from `input` scaled down (never up) so its long edge is at most `max_edge`, by
/// area averaging in linear light, a row at a time, encoded as an 8-bit PNG (RGB, or RGBA when
/// it has alpha).
/// None for a PNG that is not valid or is interlaced (its rows come in passes).
pub fn downscale(input: impl std::io::Read, max_edge: u32) -> Option<(Vec<u8>, u32, u32)> {
    downscale_oriented(input, max_edge, 1)
}

/// [`downscale`], the copy turned upright by EXIF orientation `turn`.
fn downscale_oriented(
    input: impl std::io::Read,
    max_edge: u32,
    turn: u16,
) -> Option<(Vec<u8>, u32, u32)> {
    let mut decoder = png::Decoder::new(input);
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    // Only one row is held; the default 64 MiB limit is for the whole frame.
    decoder.set_limits(png::Limits { bytes: 256 << 20 });
    let mut reader = decoder.read_info().ok()?;
    let (w, h) = (reader.info().width, reader.info().height);
    if reader.info().interlaced || !copyable(w, h) {
        return None;
    }
    let (color, _) = reader.output_color_type();
    let (channels, alpha) = match color {
        png::ColorType::Grayscale => (1, false),
        png::ColorType::GrayscaleAlpha => (2, true),
        png::ColorType::Rgb => (3, false),
        png::ColorType::Rgba => (4, true),
        png::ColorType::Indexed => return None,
    };
    let (out_w, out_h) = cmux_image_linear::fit(w, h, max_edge);
    // Averaged in linear light (cmux_image_linear): text and thin lines keep their weight
    // instead of going darker. Colour is weighted by alpha, so a transparent pixel's colour,
    // which nobody sees, does not tint the opaque ones next to it.
    let mut scaler = cmux_image_linear::Downscaler::new(w, h, out_w, out_h, alpha);
    for _ in 0..h {
        let row = reader.next_row().ok()??;
        // `chunks_exact(channels)` gives only slices of `channels` bytes.
        scaler.push_row(row.data().chunks_exact(channels).take(w as usize).map(|px| match px {
            [g] => [*g, *g, *g, 255],
            [g, a] => [*g, *g, *g, *a],
            [r, g, b] => [*r, *g, *b, 255],
            [r, g, b, a] => [*r, *g, *b, *a],
            _ => [0; 4],
        }));
    }
    encode(scaler.finish(), out_w, out_h, alpha, turn)
}

/// A JPEG's width and height from its frame header.
fn jpeg_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut decoder = zune_jpeg::JpegDecoder::new(zune_core::bytestream::ZCursor::new(bytes));
    decoder.decode_headers().ok()?;
    let info = decoder.info()?;
    Some((u32::from(info.width), u32::from(info.height)))
}

/// The JPEG `bytes` scaled down (never up) so its long edge is at most `max_edge`, by area
/// averaging in linear light, encoded as an 8-bit RGB PNG ([`downscale`]). The frame is decoded
/// whole (zune-jpeg has no row reader): at most [`MAX_SOURCE_PIXELS`] of RGB. None for a JPEG
/// that does not decode.
pub fn downscale_jpeg(bytes: &[u8], max_edge: u32) -> Option<(Vec<u8>, u32, u32)> {
    let (w, h) = jpeg_size(bytes)?;
    if !copyable(w, h) {
        return None;
    }
    let options = zune_core::options::DecoderOptions::default()
        .jpeg_set_out_colorspace(zune_core::colorspace::ColorSpace::RGB)
        .set_max_width(1 << 16)
        .set_max_height(1 << 16);
    let mut decoder = zune_jpeg::JpegDecoder::new_with_options(
        zune_core::bytestream::ZCursor::new(bytes),
        options,
    );
    let rgb = decoder.decode().ok()?;
    let row = w as usize * 3;
    if rgb.len() < row * h as usize {
        return None;
    }
    let (out_w, out_h) = cmux_image_linear::fit(w, h, max_edge);
    let mut scaler = cmux_image_linear::Downscaler::new(w, h, out_w, out_h, false);
    for line in rgb.chunks_exact(row).take(h as usize) {
        scaler.push_row(line.chunks_exact(3).map(|p| [p[0], p[1], p[2], 255]));
    }
    encode(scaler.finish(), out_w, out_h, false, crate::image_privacy::orientation(bytes))
}

/// `pixels` (RGB, or RGBA with `alpha`), turned upright by EXIF orientation `turn`, as an 8-bit
/// PNG carrying [`MARK`].
fn encode(
    pixels: Vec<u8>,
    out_w: u32,
    out_h: u32,
    alpha: bool,
    turn: u16,
) -> Option<(Vec<u8>, u32, u32)> {
    // Upright, as the EXIF orientation says the picture is seen (`image_privacy::orient`).
    let (pixels, out_w, out_h) =
        crate::image_privacy::orient(pixels, out_w, out_h, if alpha { 4 } else { 3 }, turn);
    let mut bytes = Vec::new();
    let mut encoder = png::Encoder::new(&mut bytes, out_w, out_h);
    encoder.set_color(if alpha { png::ColorType::Rgba } else { png::ColorType::Rgb });
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().ok()?;
    // Right after IHDR, so [`is_copy`] finds it at a fixed place.
    writer.write_chunk(png::chunk::tEXt, MARK).ok()?;
    writer.write_image_data(&pixels).ok()?;
    writer.finish().ok()?;
    Some((bytes, out_w, out_h))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A `w`x`h` RGB PNG: left half red, right half blue.
    pub(crate) fn halves(w: u32, h: u32) -> Vec<u8> {
        let mut data = Vec::with_capacity((w * h * 3) as usize);
        for _ in 0..h {
            for x in 0..w {
                data.extend(if x < w / 2 { [255, 0, 0] } else { [0, 0, 255] });
            }
        }
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, w, h);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        e.write_header().unwrap().write_image_data(&data).unwrap();
        out
    }

    pub(crate) fn pixels(png_bytes: &[u8]) -> (u32, u32, Vec<u8>) {
        let mut reader = png::Decoder::new(std::io::Cursor::new(png_bytes)).read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size()];
        let info = reader.next_frame(&mut buf).unwrap();
        buf.truncate(info.buffer_size());
        (info.width, info.height, buf)
    }

    #[test]
    fn each_harness_gets_its_models_edge() {
        assert_eq!(limits(Some("claude")).max_edge, 1568);
        assert_eq!(limits(Some("codex")).max_edge, 2048);
        assert_eq!(limits(Some("opencode")), limits(Some("claude")));
        assert_eq!(limits(None).max_bytes, crate::prompt_uploads::INLINE_IMAGE_BYTES);
    }

    #[test]
    fn a_large_png_is_scaled_to_the_edge_keeping_its_shape_and_colours() {
        let (bytes, w, h) = downscale(std::io::Cursor::new(halves(4000, 3000)), 1568).unwrap();
        assert_eq!((w, h), (1568, 1176));
        let (pw, ph, px) = pixels(&bytes);
        assert_eq!((pw, ph), (w, h));
        // The left edge is red and the right edge blue, as in the original.
        assert_eq!(&px[..3], &[255, 0, 0]);
        let last = px.len() - 3;
        assert_eq!(&px[last..], &[0, 0, 255]);
    }

    /// A `n`x`n` grey PNG of 1 px black and white: a checkerboard, or alternating rows.
    fn black_and_white(n: u32, checker: bool) -> Vec<u8> {
        let data: Vec<u8> = (0..n * n)
            .map(|i| {
                let (x, y) = (i % n, i / n);
                let on = if checker { (x + y) % 2 == 0 } else { y % 2 == 0 };
                if on { 255 } else { 0 }
            })
            .collect();
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, n, n);
        e.set_color(png::ColorType::Grayscale);
        e.set_depth(png::BitDepth::Eight);
        e.write_header().unwrap().write_image_data(&data).unwrap();
        out
    }

    /// Fine black and white detail (text, thin lines in a screenshot) keeps its light: half
    /// black, half white is 188, not the 127 an average of sRGB codes gives
    /// ("What every coder should know about gamma").
    #[test]
    fn a_model_copy_averages_light_not_srgb_codes() {
        for checker in [true, false] {
            for edge in [256, 128] {
                let (bytes, w, h) =
                    downscale(std::io::Cursor::new(black_and_white(512, checker)), edge).unwrap();
                assert_eq!((w, h), (edge, edge));
                let px = pixels(&bytes).2;
                let off: Vec<u8> =
                    px.iter().copied().filter(|v| !(187..=188).contains(v)).take(4).collect();
                assert!(off.is_empty(), "checker {checker} edge {edge}: {off:?}");
            }
        }
    }

    /// An `n`x`n` grey baseline JPEG of 8 px black and white squares, one per DCT block, so each
    /// block is flat and is its DC term alone (quantizer 1, the standard DC table, AC all EOB).
    /// No JPEG encoder is a dependency; this one writes only what the test needs.
    pub(crate) fn checker_jpeg(n: u32) -> Vec<u8> {
        let mut out = vec![0xff, 0xd8];
        let segment = |out: &mut Vec<u8>, marker: u8, body: &[u8]| {
            out.extend([0xff, marker]);
            out.extend(u16::try_from(body.len() + 2).unwrap().to_be_bytes());
            out.extend(body);
        };
        let mut dqt = vec![0u8];
        dqt.extend([1u8; 64]);
        segment(&mut out, 0xdb, &dqt);
        let (h, w) =
            (u16::try_from(n).unwrap().to_be_bytes(), u16::try_from(n).unwrap().to_be_bytes());
        segment(&mut out, 0xc0, &[8, h[0], h[1], w[0], w[1], 1, 1, 0x11, 0]);
        let mut dht = vec![0x00, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
        dht.extend(0..=11u8);
        segment(&mut out, 0xc4, &dht);
        segment(&mut out, 0xc4, &[0x10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00]);
        segment(&mut out, 0xda, &[1, 1, 0x00, 0, 63, 0]);
        // The standard luminance DC codes by size category: (code, length).
        const DC: [(u16, u8); 12] = [
            (0b00, 2),
            (0b010, 3),
            (0b011, 3),
            (0b100, 3),
            (0b101, 3),
            (0b110, 3),
            (0b1110, 4),
            (0b11110, 5),
            (0b111110, 6),
            (0b1111110, 7),
            (0b11111110, 8),
            (0b111111110, 9),
        ];
        let (mut acc, mut bits, mut data) = (0u32, 0u8, Vec::new());
        let mut put = |value: u32, len: u8, data: &mut Vec<u8>| {
            for i in (0..len).rev() {
                acc = (acc << 1) | ((value >> i) & 1);
                bits += 1;
                if bits == 8 {
                    data.push(acc as u8);
                    if acc as u8 == 0xff {
                        data.push(0);
                    }
                    (acc, bits) = (0, 0);
                }
            }
        };
        let mut previous = 0i32;
        for by in 0..n / 8 {
            for bx in 0..n / 8 {
                let dc = if (bx + by).is_multiple_of(2) { 8 * 127 } else { -8 * 128 };
                let diff = dc - previous;
                previous = dc;
                let size = (32 - diff.unsigned_abs().leading_zeros()) as u8;
                let (code, len) = DC[size as usize];
                put(u32::from(code), len, &mut data);
                let extra = if diff < 0 { (diff - 1) as u32 } else { diff as u32 };
                put(extra & ((1 << size) - 1), size, &mut data);
                // AC: end of block, the one code of length 1.
                put(0, 1, &mut data);
            }
        }
        put(0x7f, 7, &mut data);
        out.extend(data);
        out.extend([0xff, 0xd9]);
        out
    }

    fn inline_block(bytes: &[u8], mime: &str) -> Value {
        let data = base64::engine::general_purpose::STANDARD.encode(bytes);
        json!({"type": "image", "mimeType": mime, "data": data, "name": "Screenshot.png"})
    }

    fn block_pixels(block: &Value) -> (u32, u32, Vec<u8>) {
        let data = block["data"].as_str().unwrap();
        pixels(&base64::engine::general_purpose::STANDARD.decode(data).unwrap())
    }

    /// The composer sends a pasted picture at its full size (no canvas scaling in the page), and
    /// the daemon fits it: a 1 px black and white checkerboard twice the model's edge arrives as
    /// the 188 grey that is half its light, not the 127 an sRGB average (the page's canvas
    /// `drawImage`) gave ("What every coder should know about gamma").
    #[test]
    fn a_pasted_checkerboard_arrives_at_the_agent_as_half_its_light() {
        let limits = limits(Some("claude"));
        let text = json!({"type": "text", "text": "look"});
        let image = inline_block(&black_and_white(3136, true), "image/png");
        let out = fit_inline_blocking(limits, vec![text.clone(), image]);
        assert_eq!(out[0], text);
        assert_eq!(out[1]["mimeType"], "image/png");
        assert_eq!(out[1]["name"], "Screenshot.png");
        let (w, h, px) = block_pixels(&out[1]);
        assert_eq!((w, h), (1568, 1568));
        let off: Vec<u8> =
            px.iter().copied().filter(|v| !(187..=188).contains(v)).take(4).collect();
        assert!(off.is_empty(), "not half the light: {off:?}");
    }

    /// An image within the model's edge and bytes goes as the composer sent it, byte for byte.
    #[test]
    fn an_inline_image_that_fits_is_left_as_sent() {
        let image = inline_block(&halves(800, 600), "image/png");
        let out = fit_inline_blocking(limits(None), vec![image.clone()]);
        assert_eq!(out, vec![image]);
        // Not an image it decodes: as sent too.
        let gif = json!({"type": "image", "mimeType": "image/gif", "data": "R0lGODlhAQABAAAAACw="});
        assert_eq!(fit_inline_blocking(limits(None), vec![gif.clone()]), vec![gif]);
    }

    /// A large JPEG (a photo) is fitted too, as a PNG within the model's bytes.
    #[test]
    fn a_large_inline_jpeg_is_fitted_in_linear_light() {
        let jpeg = checker_jpeg(2048);
        // The test's own encoder decodes to exact black and white.
        let (w, h) = jpeg_size(&jpeg).unwrap();
        assert_eq!((w, h), (2048, 2048));
        let out = fit_inline_blocking(limits(None), vec![inline_block(&jpeg, "image/jpeg")]);
        assert_eq!(out[0]["mimeType"], "image/png");
        let (w, h, px) = block_pixels(&out[0]);
        assert_eq!((w, h), (1568, 1568));
        // Half black, half white: half the light, measured as light.
        let light = px.iter().map(|v| f64::from(cmux_image_linear::to_linear(*v))).sum::<f64>()
            / px.len() as f64
            / f64::from(cmux_image_linear::to_linear(255));
        assert!((0.49..=0.51).contains(&light), "light {light}");
    }

    /// The after side of webviews/bench/composer-image-fit.bench.ts: what the agent gets from the
    /// composer's full-size picture, written as PNGs (a 1 px checkerboard and
    /// docs/assets/screenshot.png), and the daemon's fit of a 5K screenshot timed.
    /// Run: `GAMMA_OUT=DIR cargo test --release -p acpmux --lib model_copies::tests::composer_fit_after -- --ignored --nocapture`.
    #[test]
    #[ignore = "writes after PNGs and timings; run by hand"]
    fn composer_fit_after() {
        let out = PathBuf::from(std::env::var("GAMMA_OUT").unwrap_or_else(|_| "gamma-out".into()));
        std::fs::create_dir_all(&out).unwrap();
        let limits = limits(Some("claude"));
        let (board, _, _) = fitted(&black_and_white(3136, true), limits).unwrap();
        let (w, h, px) = pixels(&board);
        let mean = px.iter().map(|v| f64::from(*v)).sum::<f64>() / px.len() as f64;
        println!("checkerboard 3136 -> {w}x{h}: mean {mean:.1}");
        std::fs::write(out.join("checker-after-acpmux.png"), &board).unwrap();
        let shot =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../docs/assets/screenshot.png");
        match std::fs::read(&shot).ok().and_then(|bytes| fitted(&bytes, limits)) {
            Some((bytes, w, h)) => {
                println!("screenshot -> {w}x{h}");
                std::fs::write(out.join("screenshot-after-acpmux.png"), bytes).unwrap();
            }
            None => println!("no screenshot at {}", shot.display()),
        }
        // A 5K screenshot (5120x2880) as the bench makes it: a dark gradient, noise over a band.
        let (sw, sh) = (5120u32, 2880u32);
        let mut seed = 0x9e37_79b9_u32;
        let mut rgb = Vec::with_capacity((sw * sh * 3) as usize);
        for y in 0..sh {
            for x in 0..sw {
                if (600..1500).contains(&y) {
                    seed ^= seed << 13;
                    seed ^= seed >> 17;
                    seed ^= seed << 5;
                    rgb.extend([seed as u8; 3]);
                } else {
                    let t = (x + y) as f32 / (sw + sh) as f32;
                    rgb.extend([
                        (27.0 + t * 30.0) as u8,
                        (29.0 + t * 70.0) as u8,
                        (36.0 + t * 110.0) as u8,
                    ]);
                }
            }
        }
        let mut png_bytes = Vec::new();
        let mut e = png::Encoder::new(&mut png_bytes, sw, sh);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        e.write_header().unwrap().write_image_data(&rgb).unwrap();
        let block = inline_block(&png_bytes, "image/png");
        let mut runs: Vec<f64> = (0..7)
            .map(|_| {
                let t = std::time::Instant::now();
                std::hint::black_box(fit_inline_blocking(limits, vec![block.clone()]));
                t.elapsed().as_secs_f64() * 1000.0
            })
            .collect();
        runs.sort_by(f64::total_cmp);
        let sent = fit_inline_blocking(limits, vec![block]);
        println!(
            "5K screenshot {:.2} MB PNG -> fit_inline (base64 decode, PNG decode, linear downscale, PNG encode, base64): median {:.0} ms, best {:.0} ms; agent gets {:.2} MB base64",
            png_bytes.len() as f64 / 1048576.0,
            runs[runs.len() / 2],
            runs[0],
            sent[0]["data"].as_str().unwrap().len() as f64 / 1048576.0
        );
        // What the daemon does first as it takes the prompt (`image_privacy::sanitize_prompt`):
        // the metadata out, lossless, no pixel decoded.
        let median = |mut runs: Vec<f64>| {
            runs.sort_by(f64::total_cmp);
            (runs[runs.len() / 2], runs[0])
        };
        let time = |f: &dyn Fn()| {
            median(
                (0..7)
                    .map(|_| {
                        let t = std::time::Instant::now();
                        f();
                        t.elapsed().as_secs_f64() * 1000.0
                    })
                    .collect(),
            )
        };
        let shot_block = inline_block(&png_bytes, "image/png");
        let (m, b) = time(&|| {
            let mut blocks = vec![shot_block.clone()];
            crate::image_privacy::sanitize_blocks(&mut blocks);
            std::hint::black_box(blocks);
        });
        println!(
            "5K screenshot PNG -> sanitize (base64 decode, chunks, base64): median {m:.0} ms, best {b:.0} ms"
        );
        let photo = checker_jpeg(4096);
        let photo_block = inline_block(&photo, "image/jpeg");
        let (m, b) = time(&|| {
            let mut blocks = vec![photo_block.clone()];
            crate::image_privacy::sanitize_blocks(&mut blocks);
            std::hint::black_box(blocks);
        });
        println!(
            "4096 px JPEG {:.2} MB -> sanitize: median {m:.0} ms, best {b:.0} ms",
            photo.len() as f64 / 1048576.0
        );
        let (m, b) = time(&|| {
            std::hint::black_box(fit_inline_blocking(limits, vec![photo_block.clone()]));
        });
        println!(
            "4096 px JPEG -> fit_inline (JPEG decode, linear downscale, PNG encode): median {m:.0} ms, best {b:.0} ms"
        );
    }

    #[test]
    fn a_file_uri_decodes_to_its_path() {
        assert_eq!(
            file_uri_path("file:///tmp/up%20loads/a%2Bb.png"),
            Some(PathBuf::from("/tmp/up loads/a+b.png"))
        );
        assert_eq!(file_uri_path("https://example.com/a.png"), None);
        assert_eq!(file_uri_path("file://host/a.png"), None);
        assert_eq!(file_uri_path("file:///bad%zz"), None);
    }

    #[test]
    fn a_png_too_large_to_decode_quickly_gets_no_copy() {
        assert!(copyable(8000, 8000) && copyable(10_000, 10_000));
        assert!(!copyable(20_000, 10_000) && !copyable(100_000, 100_000));
        assert!(!copyable(0, 10) && !copyable(10, 0));
    }

    /// A 2x1 PNG of `color` from `data`, with `palette` and `trns` when given.
    fn two_pixels(color: png::ColorType, data: &[u8], palette: Option<(&[u8], &[u8])>) -> Vec<u8> {
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, 2, 1);
        e.set_color(color);
        e.set_depth(png::BitDepth::Eight);
        if let Some((plte, trns)) = palette {
            e.set_palette(plte.to_vec());
            e.set_trns(trns.to_vec());
        }
        e.write_header().unwrap().write_image_data(data).unwrap();
        out
    }

    #[test]
    fn a_transparent_pixel_does_not_tint_the_opaque_one_it_is_averaged_with() {
        // Opaque red and fully transparent blue: red, half covered (not translucent purple).
        let rgba = two_pixels(png::ColorType::Rgba, &[255, 0, 0, 255, 0, 0, 255, 0], None);
        // White and transparent black, as grey with alpha.
        let grey = two_pixels(png::ColorType::GrayscaleAlpha, &[255, 255, 0, 0], None);
        // The same red and blue from a palette whose blue is transparent (tRNS).
        let plte: &[u8] = &[255, 0, 0, 0, 0, 255];
        let indexed = two_pixels(png::ColorType::Indexed, &[0, 1], Some((plte, &[255, 0])));
        for (png_bytes, want) in
            [(rgba, [255, 0, 0, 127]), (grey, [255, 255, 255, 127]), (indexed, [255, 0, 0, 127])]
        {
            let (bytes, w, h) = downscale(std::io::Cursor::new(png_bytes), 1).unwrap();
            assert_eq!((w, h), (1, 1));
            assert_eq!(pixels(&bytes).2, want);
        }
    }

    #[test]
    fn a_copys_base64_is_left_out_of_the_log_in_any_shape() {
        let (bytes, _, _) = downscale(std::io::Cursor::new(halves(4000, 3000)), 1568).unwrap();
        let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
        // Another PNG, a screenshot sent inline, is logged as it was.
        let other = base64::engine::general_purpose::STANDARD.encode(halves(64, 64));
        let mut acp = json!({"method": "session/prompt", "params": {"prompt": [
            {"type": "image", "mimeType": "image/png", "data": data},
            {"type": "image", "mimeType": "image/png", "data": other},
        ]}});
        let mut claude = json!({"type": "user", "message": {"content": [
            {"type": "image", "source": {"type": "base64", "data": data}},
        ]}});
        scrub_logged(&mut acp);
        scrub_logged(&mut claude);
        assert_eq!(acp["params"]["prompt"][0]["data"], OMITTED);
        assert_eq!(acp["params"]["prompt"][1]["data"], other);
        assert_eq!(claude["message"]["content"][0]["source"]["data"], OMITTED);
        assert!(!is_copy("iVBORw0KGgo") && !is_copy("not base64 at all, long enough to be read"));
    }

    #[test]
    fn a_png_within_the_edge_is_never_scaled_up() {
        let (_, w, h) = downscale(std::io::Cursor::new(halves(640, 480)), 1568).unwrap();
        assert_eq!((w, h), (640, 480));
        assert!(downscale(std::io::Cursor::new(b"not a png".to_vec()), 1568).is_none());
    }

    /// A model-sized copy saved beside its upload (#41372 review F5): held past its home check
    /// and the home replaced, the copy lands in the held home and the new one gets nothing.
    #[cfg(unix)]
    #[test]
    fn a_model_copy_save_held_past_its_check() {
        use crate::lost_home_race_tests::{forced, isolated, nothing};
        isolated(
            module_path!(),
            "a_model_copy_save_held_past_its_check",
            |home| {
                let dir =
                    home.join("uploads").join("chat-a").join(uuid::Uuid::now_v7().to_string());
                std::fs::create_dir_all(&dir).unwrap();
                let saved = dir.join(".model-1568.png");
                let kept = saved.strip_prefix(home).unwrap().to_string_lossy().into_owned();
                let target = saved.clone();
                forced(home, target, nothing, Some(&kept), move || save(&saved, b"png bytes"));
            },
            |_, _| {},
        );
    }
}
