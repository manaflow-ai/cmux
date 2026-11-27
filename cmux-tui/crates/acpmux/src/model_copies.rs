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
//! JPEG and WebP copies come in a follow-up that adds their decoders.

use crate::hub::file_uploads;
use base64::Engine;
use serde_json::{Value, json};
use std::io::BufReader;
use std::path::{Path, PathBuf};

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
    let mut out = Vec::with_capacity(blocks.len());
    for block in blocks {
        let copy = upload_png(session, &block).and_then(|path| {
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

/// The path of the PNG `block` links to, when it is a finished upload of chat `session` that
/// `prompt_uploads::resolve` put as a link (not inline).
fn upload_png(session: &str, block: &Value) -> Option<PathBuf> {
    if block.get("type").and_then(Value::as_str) != Some("resource_link")
        || block.get("mimeType").and_then(Value::as_str) != Some("image/png")
    {
        return None;
    }
    let path = PathBuf::from(block.pointer("/_meta/acpmux/uploadPath")?.as_str()?);
    let chat = file_uploads::session_dir(session)?;
    // `<uploads>/<chat>/<upload id>/<name>`, and nothing else.
    let ok = file_uploads::is_upload(&path)
        && path.parent().and_then(Path::parent) == Some(chat.as_path());
    ok.then_some(path)
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
                let file = file_uploads::open_finished(path).ok()?;
                let made = downscale(BufReader::new(file), edge)?;
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
    let pixels = scaler.finish();
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
#[path = "model_copies_tests.rs"]
mod tests;
