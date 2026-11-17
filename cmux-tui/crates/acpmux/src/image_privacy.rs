//! A picture sent with a prompt loses what it says about the person before acpmux keeps it or
//! sends it on: a JPEG's EXIF (GPS, camera, time), XMP, IPTC and comments, and the pictures a
//! phone appends after it (MPF); a PNG's text chunks (`tEXt`, `zTXt`, `iTXt`), `tIME` and EXIF
//! (`eXIf`). Only what draws the picture stays: its pixels, colour (ICC profile, `gAMA`, `cHRM`,
//! `sRGB`) and its orientation, kept as a minimal EXIF of that one tag, so it still shows upright.
//!
//! The composer sends a PNG or JPEG as the person's own file, with no canvas re-encode in the
//! page (Leo, "What every coder should know about gamma"; claude-sr2-coord, 2026-11-17: "Strip
//! metadata (EXIF/GPS, PNG text chunks) and apply EXIF orientation in Rust, in acpmux, before
//! anything is stored or sent to the model"). [`sanitize_prompt`] runs on each `session/prompt`
//! and queued send as the daemon takes it (`server/requests.rs`), before the outbox keeps it, a
//! peer gets it or the chat's log names its images (`hub/prompt_images.rs`); an upload put inline
//! for the model (`prompt_uploads::resolve`) is cleaned the same way. Lossless: no pixel is
//! decoded here. The model's copy applies the orientation (`model_copies.rs`).

use base64::Engine as _;
use serde_json::Value;

/// EXIF orientation tag (TIFF 0x0112): 1 is upright, 2..=8 the flips and turns.
const ORIENTATION_TAG: u16 = 0x0112;

/// `bytes` without the person's metadata (module docs), or None when they are not a PNG or JPEG
/// this reads (the caller keeps them as they were) or have nothing to drop.
pub fn sanitize(bytes: &[u8]) -> Option<Vec<u8>> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return png(bytes);
    }
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        return jpeg(bytes);
    }
    None
}

/// The EXIF orientation of a PNG or JPEG (1 when it has none, or one out of range).
pub fn orientation(bytes: &[u8]) -> u16 {
    let exif = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        png_exif(bytes)
    } else if bytes.starts_with(&[0xff, 0xd8]) {
        jpeg_segments(bytes).and_then(|(segments, _)| {
            segments.into_iter().find_map(|(marker, body, _)| {
                (marker == 0xe1).then_some(body).and_then(|b| b.strip_prefix(b"Exif\0\0"))
            })
        })
    } else {
        None
    };
    exif.and_then(tiff_orientation).filter(|o| (1..=8).contains(o)).unwrap_or(1)
}

/// Each inline image block of a prompt's `blocks` (a `session/prompt`'s `prompt`, or a queued
/// send's `request.prompt`) with its PNG or JPEG cleaned (module docs). Blocking.
pub fn sanitize_blocks(blocks: &mut [Value]) {
    for block in blocks {
        if block.get("type").and_then(Value::as_str) != Some("image") {
            continue;
        }
        let Some(data) = block.get("data").and_then(Value::as_str) else { continue };
        let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else { continue };
        if let Some(clean) = sanitize(&bytes) {
            block["data"] = Value::String(base64::engine::general_purpose::STANDARD.encode(clean));
        }
    }
}

/// [`sanitize_blocks`] on the prompt of `params` (method `m`), off the runtime when it has
/// images. Never fails: an image it cannot read stays as it was.
pub async fn sanitize_prompt(m: &str, params: &mut Value) {
    let pointer = match m {
        crate::rpc::method::SESSION_PROMPT => "/prompt",
        crate::rpc::method::MUX_SEND_QUEUE => "/request/prompt",
        _ => return,
    };
    let Some(blocks) = params.pointer_mut(pointer).and_then(Value::as_array_mut) else { return };
    if !blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("image")) {
        return;
    }
    let mut owned = std::mem::take(blocks);
    owned = tokio::task::spawn_blocking(move || {
        sanitize_blocks(&mut owned);
        owned
    })
    .await
    .unwrap_or_default();
    if let Some(blocks) = params.pointer_mut(pointer).and_then(Value::as_array_mut) {
        *blocks = owned;
    }
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
            return bytes.get(at + 8..at + 8 + len);
        }
        at = at.checked_add(12)?.checked_add(len)?;
    }
    None
}

/// A PNG's chunks: (type, data, whole chunk with its length and CRC). None when it is cut short.
fn png_chunks(bytes: &[u8]) -> Option<Vec<([u8; 4], &[u8], &[u8])>> {
    let mut at = 8;
    let mut chunks = Vec::new();
    while at + 12 <= bytes.len() {
        let len = u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?) as usize;
        let end = at.checked_add(12)?.checked_add(len)?;
        let kind: [u8; 4] = bytes.get(at + 4..at + 8)?.try_into().ok()?;
        let whole = bytes.get(at..end)?;
        chunks.push((kind, whole.get(8..8 + len)?, whole));
        at = end;
        if &kind == b"IEND" {
            return Some(chunks);
        }
    }
    None
}

/// The ancillary PNG chunks that draw the picture (colour, transparency, density, animation).
const PNG_KEEP: [&[u8; 4]; 12] = [
    b"tRNS", b"gAMA", b"cHRM", b"sRGB", b"iCCP", b"sBIT", b"pHYs", b"bKGD", b"cICP", b"acTL",
    b"fcTL", b"fdAT",
];

fn png(bytes: &[u8]) -> Option<Vec<u8>> {
    let chunks = png_chunks(bytes)?;
    let turn = orientation(bytes);
    let mut out = Vec::with_capacity(bytes.len());
    out.extend_from_slice(bytes.get(..8)?);
    let mut dropped = false;
    for (kind, _, whole) in &chunks {
        // Critical chunks (an upper-case first letter) draw it; so do the ancillary ones listed.
        let keep = kind[0].is_ascii_uppercase() || PNG_KEEP.contains(&kind);
        if keep {
            out.extend_from_slice(whole);
        } else {
            dropped = true;
        }
        // Right after the header, so a reader finds the orientation before the pixels.
        if kind == b"IHDR" && turn != 1 {
            let exif = minimal_tiff(turn);
            out.extend((exif.len() as u32).to_be_bytes());
            let start = out.len();
            out.extend_from_slice(b"eXIf");
            out.extend_from_slice(&exif);
            let crc = crc32(out.get(start..).unwrap_or_default());
            out.extend(crc.to_be_bytes());
        }
    }
    (dropped || bytes.len() != out.len()).then_some(out)
}

/// A JPEG's segments before its scan: (marker, body, whole segment), and the offset of its
/// start-of-scan marker. None when it is cut short.
fn jpeg_segments(bytes: &[u8]) -> Option<(Vec<(u8, &[u8], &[u8])>, usize)> {
    let mut at = 2;
    let mut segments = Vec::new();
    loop {
        // Fill bytes before a marker.
        while bytes.get(at) == Some(&0xff) && bytes.get(at + 1) == Some(&0xff) {
            at += 1;
        }
        if bytes.get(at) != Some(&0xff) {
            return None;
        }
        let marker = *bytes.get(at + 1)?;
        if marker == 0xda {
            return Some((segments, at));
        }
        let len = usize::from(u16::from_be_bytes([*bytes.get(at + 2)?, *bytes.get(at + 3)?]));
        if len < 2 {
            return None;
        }
        let whole = bytes.get(at..at + 2 + len)?;
        segments.push((marker, whole.get(4..)?, whole));
        at += 2 + len;
    }
}

fn jpeg(bytes: &[u8]) -> Option<Vec<u8>> {
    let (segments, scan) = jpeg_segments(bytes)?;
    let turn = orientation(bytes);
    let mut out = Vec::with_capacity(bytes.len());
    out.extend_from_slice(&[0xff, 0xd8]);
    let mut placed = turn == 1;
    for (marker, body, whole) in &segments {
        let keep = match marker {
            // JFIF, and an ICC profile or Adobe's colour transform: they draw the picture.
            0xe0 => true,
            0xe2 => body.starts_with(b"ICC_PROFILE\0"),
            0xee => body.starts_with(b"Adobe"),
            // Any other APPn (EXIF, XMP, MPF, IPTC, maker data) and comments go.
            0xe1 | 0xe3..=0xed | 0xef | 0xfe => false,
            // Tables, frame headers, restart intervals.
            _ => true,
        };
        if !keep {
            continue;
        }
        // The orientation goes after JFIF (which must come first) and before anything else.
        if !placed && *marker != 0xe0 {
            push_exif(&mut out, turn);
            placed = true;
        }
        out.extend_from_slice(whole);
    }
    if !placed {
        push_exif(&mut out, turn);
    }
    // The scan up to its end-of-image marker; what a phone appends after it (MPF pictures,
    // each with its own EXIF) goes. In the scan a 0xFF byte is followed by 0x00 or a restart
    // marker, so the first FF D9 is the end of the image.
    let rest = bytes.get(scan..)?;
    let end = rest.windows(2).position(|w| w == [0xff, 0xd9]).map_or(rest.len(), |p| p + 2);
    out.extend_from_slice(rest.get(..end)?);
    Some(out)
}

fn push_exif(out: &mut Vec<u8>, turn: u16) {
    let mut body = b"Exif\0\0".to_vec();
    body.extend(minimal_tiff(turn));
    out.extend_from_slice(&[0xff, 0xe1]);
    out.extend(u16::try_from(body.len() + 2).unwrap_or(u16::MAX).to_be_bytes());
    out.extend(body);
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

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
        }
    }
    !crc
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
