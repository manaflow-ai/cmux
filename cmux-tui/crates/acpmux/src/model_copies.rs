//! Model-sized copies of large images (`docs/prompt-uploads.md` section 6). There is no size cap
//! on a file sent with a prompt (Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES
//! OF ANY TYPE"), so an image past what the model takes inline reaches the agent as a
//! `resource_link` to its path (`prompt_uploads.rs`). The agent can open it, but the model never
//! sees it. When the prompt is written to the agent, each such PNG also gets a copy sized for the
//! harness ([`limits`]): scaled so its long edge fits, as an inline image next to the link to the
//! original, while the prompt has inline room.
//!
//! - The copy is made only for the agent's `session/prompt`. The transcript and the queue keep the
//!   prompt as sent, with no base64 in the log.
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
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};

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
            let budget = limits.max_bytes.min(left / 4 * 3);
            // No room for even a small copy: the rest keep only their links.
            if budget < 64 << 10 {
                return None;
            }
            let (bytes, w, h) = copy_of(&path, limits.max_edge, budget)?;
            let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
            left = left.saturating_sub(data.len() + 512);
            Some((path, data, w, h))
        });
        out.push(block);
        let Some((path, data, w, h)) = copy else { continue };
        out.push(json!({"type": "image", "mimeType": "image/png", "data": data}));
        out.push(json!({"type": "text", "text": format!(
            "(The image above is {} scaled to {w}x{h} for you; the original is at that path.)",
            path.display()
        )}));
    }
    out
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
    for _ in 0..4 {
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
        // An image already within the edge is not scaled again: it will not get smaller.
        if w.max(h) < edge {
            return None;
        }
        edge = edge * 3 / 4;
    }
    None
}

/// Writes `bytes` to `path` whole or not at all (a temporary name, then a rename). A copy that
/// cannot be saved is made again next time.
fn save(path: &Path, bytes: &[u8]) {
    let tmp = path.with_extension(format!("tmp-{}", uuid::Uuid::now_v7()));
    let wrote = std::fs::File::create(&tmp).and_then(|mut f| f.write_all(bytes));
    if wrote.is_err() || std::fs::rename(&tmp, path).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// A PNG's width and height from its header.
fn png_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let reader = png::Decoder::new(std::io::Cursor::new(bytes)).read_info().ok()?;
    Some((reader.info().width, reader.info().height))
}

/// The PNG read from `input` scaled down (never up) so its long edge is at most `max_edge`, by
/// area averaging, a row at a time, encoded as an 8-bit PNG (RGB, or RGBA when it has alpha).
/// None for a PNG that is not valid or is interlaced (its rows come in passes).
pub fn downscale(input: impl std::io::Read, max_edge: u32) -> Option<(Vec<u8>, u32, u32)> {
    let mut decoder = png::Decoder::new(input);
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    // Only one row is held; the default 64 MiB limit is for the whole frame.
    decoder.set_limits(png::Limits { bytes: 256 << 20 });
    let mut reader = decoder.read_info().ok()?;
    let (w, h) = (reader.info().width, reader.info().height);
    if reader.info().interlaced || w == 0 || h == 0 {
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
    let scale = (f64::from(max_edge) / f64::from(w.max(h))).min(1.0);
    let out_w = ((f64::from(w) * scale).round() as u32).max(1);
    let out_h = ((f64::from(h) * scale).round() as u32).max(1);
    let out_channels = if alpha { 4 } else { 3 };
    // The sums of one output row's pixels, RGBA, and how many input pixels each took.
    let mut sums = vec![[0u64; 4]; out_w as usize];
    let mut counts = vec![0u64; out_w as usize];
    let mut pixels = Vec::with_capacity((out_w * out_h * out_channels) as usize);
    let mut row_of = |sums: &mut [[u64; 4]], counts: &mut [u64]| {
        for (sum, count) in sums.iter_mut().zip(counts.iter_mut()) {
            let n = (*count).max(1);
            pixels.extend(sum[..out_channels as usize].iter().map(|v| (v / n) as u8));
            *sum = [0; 4];
            *count = 0;
        }
    };
    let mut target = 0u32;
    for y in 0..h {
        let row = reader.next_row().ok()??;
        let ty = (u64::from(y) * u64::from(out_h) / u64::from(h)) as u32;
        if ty != target {
            row_of(&mut sums, &mut counts);
            target = ty;
        }
        for (x, px) in row.data().chunks_exact(channels).enumerate().take(w as usize) {
            let tx = (x as u64 * u64::from(out_w) / u64::from(w)) as usize;
            let rgba = match px {
                [g] => [*g, *g, *g, 255],
                [g, a] => [*g, *g, *g, *a],
                [r, g, b] => [*r, *g, *b, 255],
                [r, g, b, a] => [*r, *g, *b, *a],
                _ => return None,
            };
            for (s, v) in sums[tx].iter_mut().zip(rgba) {
                *s += u64::from(v);
            }
            counts[tx] += 1;
        }
    }
    row_of(&mut sums, &mut counts);
    let mut bytes = Vec::new();
    let mut encoder = png::Encoder::new(&mut bytes, out_w, out_h);
    encoder.set_color(if alpha { png::ColorType::Rgba } else { png::ColorType::Rgb });
    encoder.set_depth(png::BitDepth::Eight);
    encoder.write_header().ok()?.write_image_data(&pixels).ok()?;
    Some((bytes, out_w, out_h))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `w`x`h` RGB PNG: left half red, right half blue.
    fn halves(w: u32, h: u32) -> Vec<u8> {
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

    fn pixels(png_bytes: &[u8]) -> (u32, u32, Vec<u8>) {
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

    #[test]
    fn a_png_within_the_edge_is_never_scaled_up() {
        let (_, w, h) = downscale(std::io::Cursor::new(halves(640, 480)), 1568).unwrap();
        assert_eq!((w, h), (640, 480));
        assert!(downscale(std::io::Cursor::new(b"not a png".to_vec()), 1568).is_none());
    }
}
