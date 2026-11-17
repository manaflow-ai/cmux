//! A picture sent with a prompt loses what it says about the person before acpmux keeps it or
//! sends it on: a JPEG's EXIF (GPS, camera, time), XMP, IPTC and comments, and the pictures a
//! phone appends after it (MPF); a PNG's text chunks (`tEXt`, `zTXt`, `iTXt`), `tIME` and EXIF
//! (`eXIf`). Only what draws the picture stays: its pixels, colour (ICC profile, `gAMA`, `cHRM`,
//! `sRGB`) and its orientation, kept as a minimal EXIF of that one tag, so it still shows upright.
//!
//! The composer sends a PNG or JPEG as the person's own file, with no canvas re-encode in the
//! page (Leo, "What every coder should know about gamma"; claude-sr2-coord, 2026-11-17: "Strip
//! metadata (EXIF/GPS, PNG text chunks) and apply EXIF orientation in Rust, in acpmux, before
//! anything is stored or sent to the model"). [`sanitize_prompt`] runs on each `session/prompt`,
//! queued send and waiting prompt's edit as the daemon takes it (`server/requests.rs`), before the
//! outbox keeps it, a peer gets it or the chat's log names its images (`hub/prompt_images.rs`); an
//! upload put inline for the model (`prompt_uploads::resolve`) is cleaned the same way. Lossless:
//! no pixel is decoded here. The model's copy applies the orientation (`model_copies.rs`).
//!
//! It fails closed (#45031 review F1, F2, F7): a file is read the way a decoder reads it (fill and
//! stray bytes between a JPEG's segments, segments between a progressive JPEG's scans, a PNG that
//! ends without IEND after its pixels), and a PNG or JPEG it still cannot read is refused with a
//! message the composer shows. Its original bytes never go on.

use crate::rpc::RpcError;
use base64::Engine as _;
use serde_json::{Value, json};

/// EXIF orientation tag (TIFF 0x0112): 1 is upright, 2..=8 the flips and turns.
const ORIENTATION_TAG: u16 = 0x0112;

const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

/// Why a prompt's picture is refused: it never goes on with its metadata, nor at a size the model
/// refuses (#45031 review F1, F4, F7).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// A PNG or JPEG whose structure this cannot read (cut short, or a chunk or segment that is
    /// not what a decoder reads), so its metadata cannot be found and taken out.
    Unreadable,
    /// Past the bytes the model takes, and one the daemon cannot scale
    /// (`model_copies::daemon_fits`): an arithmetic-coded or 12-bit JPEG, or over 100 MP.
    TooLarge,
    /// The cleaning itself failed (its task panicked).
    Failed,
}

impl Refusal {
    /// The error the prompt is refused with; the composer shows its message.
    pub fn error(self, name: Option<&str>) -> RpcError {
        let what = name.map_or_else(|| "A picture".to_owned(), |n| format!("The picture {n}"));
        let (message, reason) = match self {
            Self::Unreadable => (
                format!(
                    "{what} could not be read to remove its location and camera data, so it was not sent. Save it again as a PNG or JPEG and attach that."
                ),
                "image.unreadable",
            ),
            Self::TooLarge => (
                format!(
                    "{what} is too large for the model and cannot be scaled down here (over 100 megapixels, or a JPEG coding acpmux does not decode). Scale it down, or attach it as a file."
                ),
                "image.tooLarge",
            ),
            Self::Failed => (
                format!(
                    "{what} could not be cleaned of its location and camera data, so the message was not sent. Try again."
                ),
                "image.cleanFailed",
            ),
        };
        RpcError::invalid_params(message).with_data(json!({"reason": reason}))
    }
}

/// `bytes` without the person's metadata (module docs): `Ok(None)` when there is nothing to drop
/// or they are not a PNG or JPEG (kept as they are), and [`Refusal::Unreadable`] for a PNG or
/// JPEG whose structure this cannot read. Never the original bytes of one it could not read.
pub fn sanitize(bytes: &[u8]) -> Result<Option<Vec<u8>>, Refusal> {
    if bytes.starts_with(PNG_SIGNATURE) {
        return png(bytes);
    }
    if bytes.starts_with(&[0xff, 0xd8]) {
        return jpeg(bytes);
    }
    Ok(None)
}

/// The EXIF orientation of a PNG or JPEG (1 when it has none, or one out of range). `bytes` may be
/// only the file's head.
pub fn orientation(bytes: &[u8]) -> u16 {
    let exif = if bytes.starts_with(PNG_SIGNATURE) {
        png_exif(bytes)
    } else if bytes.starts_with(&[0xff, 0xd8]) {
        jpeg_parts(bytes, true).and_then(|parts| {
            parts.into_iter().find_map(|part| match part {
                Part::Segment(0xe1, body, _) => body.strip_prefix(b"Exif\0\0"),
                _ => None,
            })
        })
    } else {
        None
    };
    exif.and_then(tiff_orientation).filter(|o| (1..=8).contains(o)).unwrap_or(1)
}

/// Each inline image block of a prompt's `blocks` (a `session/prompt`'s `prompt`, a queued send's
/// `request.prompt`, or a waiting prompt's edit) with its PNG or JPEG cleaned (module docs).
/// Refused: a PNG or JPEG it cannot read, or one past the model's bytes that the daemon cannot
/// scale (`model_copies::daemon_fits`; before #45031 the page fitted every picture). Blocking.
pub fn sanitize_blocks(blocks: &mut [Value]) -> Result<(), RpcError> {
    for block in blocks {
        if block.get("type").and_then(Value::as_str) != Some("image") {
            continue;
        }
        let Some(data) = block.get("data").and_then(Value::as_str) else { continue };
        let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else { continue };
        let name = block.get("name").and_then(Value::as_str);
        let clean = sanitize(&bytes).map_err(|r| r.error(name))?;
        let now = clean.as_deref().unwrap_or(&bytes);
        if now.len() > crate::prompt_uploads::INLINE_IMAGE_BYTES
            && !crate::model_copies::daemon_fits(now)
        {
            return Err(Refusal::TooLarge.error(name));
        }
        if let Some(clean) = clean {
            block["data"] = Value::String(base64::engine::general_purpose::STANDARD.encode(clean));
        }
    }
    Ok(())
}

/// [`sanitize_blocks`] on the prompt of `params` (method `m`), off the runtime when it has
/// images. Refused as [`sanitize_blocks`] says, and when the cleaning fails: the prompt never
/// goes on with a picture that was not cleaned, nor without the blocks it was sent with.
pub async fn sanitize_prompt(m: &str, params: &mut Value) -> Result<(), RpcError> {
    let pointer = match m {
        crate::rpc::method::SESSION_PROMPT => "/prompt",
        crate::rpc::method::MUX_SEND_QUEUE => "/request/prompt",
        // A waiting prompt's `update` that writes its blocks (`hub/queue_edit.rs`).
        crate::rpc::method::MUX_QUEUE_EDIT => "/prompt",
        _ => return Ok(()),
    };
    let Some(blocks) = params.pointer_mut(pointer).and_then(Value::as_array_mut) else {
        return Ok(());
    };
    if !blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("image")) {
        return Ok(());
    }
    *blocks = cleaned_off_runtime(blocks.clone(), sanitize_blocks).await?;
    Ok(())
}

/// `blocks` cleaned by `clean` on a blocking thread. A panic there refuses the prompt
/// ([`Refusal::Failed`]): neither the blocks as sent nor an emptied prompt go on (#45031 F7).
async fn cleaned_off_runtime(
    mut blocks: Vec<Value>,
    clean: fn(&mut [Value]) -> Result<(), RpcError>,
) -> Result<Vec<Value>, RpcError> {
    tokio::task::spawn_blocking(move || clean(&mut blocks).map(|()| blocks))
        .await
        .map_err(|_| Refusal::Failed.error(None))?
}

/// A PNG's `eXIf` data, from its chunks before its pixels (where the format puts it): `bytes`
/// may be only the file's head.
fn png_exif(bytes: &[u8]) -> Option<&[u8]> {
    let mut at = 8;
    while at + 8 <= bytes.len() {
        let len = u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?) as usize;
        let kind = bytes.get(at + 4..at + 8)?;
        if kind == b"IDAT" || kind == b"IEND" {
            return None;
        }
        if kind == b"eXIf" {
            return bytes.get(at + 8..at.checked_add(8)?.checked_add(len)?);
        }
        at = at.checked_add(12)?.checked_add(len)?;
    }
    None
}

/// One PNG chunk: its type, and the whole chunk with its length and CRC.
struct Chunk<'a> {
    kind: [u8; 4],
    whole: &'a [u8],
}

impl Chunk<'_> {
    /// Whether its CRC is that of its type and data.
    fn sound(&self) -> bool {
        let n = self.whole.len();
        let (Some(covered), Some(crc)) =
            (self.whole.get(4..n.saturating_sub(4)), self.whole.get(n.saturating_sub(4)..))
        else {
            return false;
        };
        <[u8; 4]>::try_from(crc).map(u32::from_be_bytes) == Ok(crc32fast::hash(covered))
    }
}

/// A PNG's chunks to its IEND, read as a decoder reads them. A file that ends, or whose next
/// chunk runs past its end, after its pixels began ends there (the decoder draws what it has):
/// what is left is dropped. None when IHDR is not first, or it is cut short before its pixels.
fn png_chunks(bytes: &[u8]) -> Option<Vec<Chunk<'_>>> {
    let mut at = 8;
    let mut chunks: Vec<Chunk<'_>> = Vec::new();
    let mut pixels = false;
    loop {
        let Some(head) = bytes.get(at..at + 8) else { return pixels.then_some(chunks) };
        let len = u32::from_be_bytes(head.get(..4)?.try_into().ok()?) as usize;
        let kind: [u8; 4] = head.get(4..)?.try_into().ok()?;
        let end = at.checked_add(12).and_then(|n| n.checked_add(len));
        let Some(whole) = end.and_then(|end| bytes.get(at..end)) else {
            // Cut short, or a length past the end: after the pixels, the picture ends there.
            return (pixels && &kind != b"IDAT").then_some(chunks);
        };
        if chunks.is_empty() && &kind != b"IHDR" {
            return None;
        }
        pixels |= &kind == b"IDAT";
        at += whole.len();
        chunks.push(Chunk { kind, whole });
        if &kind == b"IEND" {
            return Some(chunks);
        }
    }
}

/// The ancillary PNG chunks that draw the picture (colour, transparency, density, animation).
const PNG_KEEP: [&[u8; 4]; 12] = [
    b"tRNS", b"gAMA", b"cHRM", b"sRGB", b"iCCP", b"sBIT", b"pHYs", b"bKGD", b"cICP", b"acTL",
    b"fcTL", b"fdAT",
];

/// The critical chunks a decoder knows. Any other (an upper-case first letter) stops it, so a PNG
/// with one is not read here either.
const PNG_CRITICAL: [&[u8; 4]; 4] = [b"IHDR", b"PLTE", b"IDAT", b"IEND"];

fn png(bytes: &[u8]) -> Result<Option<Vec<u8>>, Refusal> {
    let chunks = png_chunks(bytes).ok_or(Refusal::Unreadable)?;
    let turn = orientation(bytes);
    let mut out = Vec::with_capacity(bytes.len());
    out.extend_from_slice(PNG_SIGNATURE);
    for chunk in &chunks {
        let kind = &chunk.kind;
        if kind[0].is_ascii_uppercase() {
            // A decoder stops at a critical chunk it does not know or whose CRC is wrong.
            if !PNG_CRITICAL.contains(&kind) || !chunk.sound() {
                return Err(Refusal::Unreadable);
            }
            out.extend_from_slice(chunk.whole);
        } else if PNG_KEEP.contains(&kind) && chunk.sound() {
            // An ancillary chunk with a wrong CRC is skipped by a decoder: dropped here too.
            out.extend_from_slice(chunk.whole);
        }
        // Right after the header, so a reader finds the orientation before the pixels.
        if kind == b"IHDR" && turn != 1 {
            push_png_chunk(&mut out, b"eXIf", &minimal_tiff(turn));
        }
    }
    if chunks.last().is_none_or(|c| &c.kind != b"IEND") {
        push_png_chunk(&mut out, b"IEND", &[]);
    }
    Ok((out != bytes).then_some(out))
}

fn push_png_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend(u32::try_from(data.len()).unwrap_or(u32::MAX).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let crc = crc32fast::hash(out.get(start..).unwrap_or_default());
    out.extend(crc.to_be_bytes());
}

/// One part of a JPEG between its SOI and its EOI.
enum Part<'a> {
    /// A marker segment: its marker, its body, and the whole segment with marker and length.
    Segment(u8, &'a [u8], &'a [u8]),
    /// A scan's entropy-coded data, its restart markers in it, as it is.
    Scan(&'a [u8]),
}

/// Where the next marker is from `at`, as a decoder finds it: the offset of its 0xFF, past the
/// fill bytes (0xFF) before it and any byte that is not a marker (libjpeg's "extraneous bytes
/// before marker"). None at the end of the data.
fn next_marker(bytes: &[u8], mut at: usize) -> Option<usize> {
    loop {
        at += bytes.get(at..)?.iter().position(|&b| b == 0xff)?;
        while bytes.get(at + 1) == Some(&0xff) {
            at += 1;
        }
        match bytes.get(at + 1)? {
            0x00 => at += 2,
            _ => return Some(at),
        }
    }
}

/// Where a scan's entropy-coded data from `at` ends: the 0xFF of the first marker that is not a
/// restart marker. In the data a 0xFF is followed by 0x00 (a stuffed byte), a restart marker or
/// another 0xFF (fill). The end of the data when there is none.
fn scan_end(bytes: &[u8], mut at: usize) -> usize {
    while let Some(found) = bytes.get(at..).and_then(|rest| rest.iter().position(|&b| b == 0xff)) {
        let mut next = at + found + 1;
        while bytes.get(next) == Some(&0xff) {
            next += 1;
        }
        match bytes.get(next) {
            None => break,
            Some(0x00 | 0xd0..=0xd7) => at = next + 1,
            Some(_) => return next - 1,
        }
    }
    bytes.len()
}

/// A JPEG's parts after its SOI, read as a decoder reads them: every marker segment (before,
/// between and after its scans: a progressive JPEG's tables and any APPn or COM there) and each
/// scan's data, to its EOI. Bytes between segments that are not a marker are skipped, as a decoder
/// skips them. `head`: only to the first scan's header, for its orientation and frame.
///
/// When the data ends before its EOI, or a segment runs past its end, the parts read so far, as
/// a decoder draws what it has; but None when that is before any scan (unless `head`). None for a
/// second SOI or a segment length under 2.
fn jpeg_parts(bytes: &[u8], head: bool) -> Option<Vec<Part<'_>>> {
    if !bytes.starts_with(&[0xff, 0xd8]) {
        return None;
    }
    let mut at = 2;
    let mut parts = Vec::new();
    let mut scanned = false;
    loop {
        let cut = |parts| (head || scanned).then_some(parts);
        let Some(marker_at) = next_marker(bytes, at) else { return cut(parts) };
        let Some(&marker) = bytes.get(marker_at + 1) else { return cut(parts) };
        match marker {
            0xd9 => return Some(parts),
            // No length: a restart marker out of a scan, or TEM, which a decoder skips.
            0x01 | 0xd0..=0xd7 => {
                at = marker_at + 2;
                continue;
            }
            0xd8 => return None,
            _ => {}
        }
        let Some(&[hi, lo]) = bytes.get(marker_at + 2..marker_at + 4) else { return cut(parts) };
        let len = usize::from(u16::from_be_bytes([hi, lo]));
        if len < 2 {
            return None;
        }
        let Some(whole) = bytes.get(marker_at..marker_at + 2 + len) else { return cut(parts) };
        parts.push(Part::Segment(marker, whole.get(4..)?, whole));
        at = marker_at + 2 + len;
        if marker == 0xda {
            if head {
                return Some(parts);
            }
            let end = scan_end(bytes, at);
            parts.push(Part::Scan(bytes.get(at..end)?));
            scanned = true;
            at = end;
        }
    }
}

/// A JPEG's frame header (read from its head): `(SOF marker, sample precision, width, height)`.
pub(crate) fn jpeg_frame(bytes: &[u8]) -> Option<(u8, u8, u32, u32)> {
    jpeg_parts(bytes, true)?.into_iter().find_map(|part| match part {
        Part::Segment(
            marker @ (0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf),
            body,
            _,
        ) => {
            let [p, h0, h1, w0, w1, ..] = *body else { return None };
            let (w, h) = (u16::from_be_bytes([w0, w1]), u16::from_be_bytes([h0, h1]));
            Some((marker, p, u32::from(w), u32::from(h)))
        }
        _ => None,
    })
}

fn jpeg(bytes: &[u8]) -> Result<Option<Vec<u8>>, Refusal> {
    let parts = jpeg_parts(bytes, false).ok_or(Refusal::Unreadable)?;
    let turn = orientation(bytes);
    let mut out = Vec::with_capacity(bytes.len());
    out.extend_from_slice(&[0xff, 0xd8]);
    let mut placed = turn == 1;
    for part in &parts {
        let (marker, body, whole) = match part {
            Part::Scan(data) => {
                out.extend_from_slice(data);
                continue;
            }
            Part::Segment(marker, body, whole) => (*marker, *body, *whole),
        };
        let keep = match marker {
            // JFIF (without its thumbnail, below), and an ICC profile or Adobe's colour
            // transform: they draw the picture.
            0xe0 => body.starts_with(b"JFIF\0"),
            0xe2 => body.starts_with(b"ICC_PROFILE\0"),
            0xee => body.starts_with(b"Adobe"),
            // Any other APPn (EXIF, XMP, MPF, IPTC, maker data, a JFXX thumbnail) and comments
            // go, wherever they are: before the frame or between a progressive JPEG's scans.
            0xe1..=0xef | 0xfe => false,
            // Tables, frame and scan headers, restart intervals.
            _ => true,
        };
        if !keep {
            continue;
        }
        // The orientation goes after JFIF (which must come first) and before anything else.
        if !placed && marker != 0xe0 {
            push_exif(&mut out, turn);
            placed = true;
        }
        if marker == 0xe0 {
            // JFIF's version, units and density, with no thumbnail (0 x 0).
            let mut jfif = body.get(..12).unwrap_or(body).to_vec();
            jfif.resize(14, 0);
            push_segment(&mut out, 0xe0, &jfif);
        } else {
            out.extend_from_slice(whole);
        }
    }
    if !placed {
        push_exif(&mut out, turn);
    }
    // What a phone appends after the EOI (MPF pictures, each with its own EXIF) goes.
    out.extend_from_slice(&[0xff, 0xd9]);
    Ok((out != bytes).then_some(out))
}

fn push_segment(out: &mut Vec<u8>, marker: u8, body: &[u8]) {
    out.extend_from_slice(&[0xff, marker]);
    out.extend(u16::try_from(body.len() + 2).unwrap_or(u16::MAX).to_be_bytes());
    out.extend_from_slice(body);
}

fn push_exif(out: &mut Vec<u8>, turn: u16) {
    let mut body = b"Exif\0\0".to_vec();
    body.extend(minimal_tiff(turn));
    push_segment(out, 0xe1, &body);
}

/// A little-endian TIFF of one IFD with only the orientation tag.
fn minimal_tiff(turn: u16) -> Vec<u8> {
    let mut t = b"II*\0".to_vec();
    t.extend(8u32.to_le_bytes());
    t.extend(1u16.to_le_bytes());
    t.extend(ORIENTATION_TAG.to_le_bytes());
    t.extend(3u16.to_le_bytes()); // SHORT
    t.extend(1u32.to_le_bytes());
    t.extend(u32::from(turn).to_le_bytes());
    t.extend(0u32.to_le_bytes());
    t
}

/// The orientation tag of a TIFF (EXIF) block's first IFD.
fn tiff_orientation(tiff: &[u8]) -> Option<u16> {
    let le = match tiff.get(..4)? {
        b"II*\0" => true,
        b"MM\0*" => false,
        _ => return None,
    };
    let u16_at = |at: usize| {
        let b: [u8; 2] = tiff.get(at..at + 2)?.try_into().ok()?;
        Some(if le { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) })
    };
    let u32_at = |at: usize| {
        let b: [u8; 4] = tiff.get(at..at + 4)?.try_into().ok()?;
        Some(if le { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) })
    };
    let ifd = u32_at(4)? as usize;
    let count = usize::from(u16_at(ifd)?);
    (0..count).find_map(|i| {
        let entry = ifd + 2 + i * 12;
        (u16_at(entry)? == ORIENTATION_TAG).then(|| u16_at(entry + 8)).flatten()
    })
}

/// `pixels` (`channels` per pixel, `w`x`h`) drawn as EXIF `turn` says the picture is seen:
/// the pixels and their new width and height.
pub fn orient(pixels: Vec<u8>, w: u32, h: u32, channels: usize, turn: u16) -> (Vec<u8>, u32, u32) {
    if !(2..=8).contains(&turn) {
        return (pixels, w, h);
    }
    let (w, h) = (w as usize, h as usize);
    let swap = turn >= 5;
    let (ow, oh) = if swap { (h, w) } else { (w, h) };
    let mut out = vec![0u8; pixels.len()];
    for y in 0..h {
        for x in 0..w {
            // Where source (x, y) lands, per the EXIF definitions.
            let (dx, dy) = match turn {
                2 => (w - 1 - x, y),
                3 => (w - 1 - x, h - 1 - y),
                4 => (x, h - 1 - y),
                5 => (y, x),
                6 => (h - 1 - y, x),
                7 => (h - 1 - y, w - 1 - x),
                _ => (y, w - 1 - x),
            };
            let from = (y * w + x) * channels;
            let to = (dy * ow + dx) * channels;
            if let (Some(dst), Some(src)) =
                (out.get_mut(to..to + channels), pixels.get(from..from + channels))
            {
                dst.copy_from_slice(src);
            }
        }
    }
    (out, ow as u32, oh as u32)
}

#[cfg(test)]
#[path = "image_privacy_tests.rs"]
mod tests;
