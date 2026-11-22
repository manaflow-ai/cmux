//! Kitty graphics protocol output: the picture is an RGB image sent in
//! band, zlib-compressed and base64 in 4096-byte chunks, placed without
//! moving the cursor. Two image ids alternate so the new frame is placed
//! before the old one is deleted: no blank frame between them.

use std::io::Write;

use base64::Engine;
use flate2::Compression;
use flate2::write::ZlibEncoder;

/// The two image ids the viewer alternates between (arbitrary, high enough
/// not to collide with ids a shell program in the same terminal picks).
pub(super) const IMAGE_IDS: [u32; 2] = [0x5643_0001, 0x5643_0002];

/// Base64 bytes per chunk, the Kitty protocol maximum.
const CHUNK_BASE64_BYTES: usize = 4096;

/// Writes one frame: moves to the anchor cell, transmits and places image
/// `id` with pixel offsets `x_off`/`y_off`, then deletes `previous`.
#[allow(clippy::too_many_arguments)]
pub(super) fn frame(
    out: &mut impl Write,
    rgb: &[u8],
    width: u32,
    height: u32,
    col: u16,
    row: u16,
    x_off: u32,
    y_off: u32,
    id: u32,
    previous: Option<u32>,
) -> std::io::Result<()> {
    let mut encoder = ZlibEncoder::new(Vec::with_capacity(rgb.len() / 4), Compression::fast());
    encoder.write_all(rgb)?;
    let compressed = encoder.finish()?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(compressed);
    write!(out, "\x1b[{};{}H", row + 1, col + 1)?;
    let chunks: Vec<&[u8]> = encoded.as_bytes().chunks(CHUNK_BASE64_BYTES).collect();
    let last = chunks.len().saturating_sub(1);
    for (index, chunk) in chunks.iter().enumerate() {
        let more = u8::from(index != last);
        if index == 0 {
            write!(
                out,
                "\x1b_Ga=T,f=24,o=z,s={width},v={height},i={id},p=1,X={x_off},Y={y_off},C=1,q=2,m={more};"
            )?;
        } else {
            write!(out, "\x1b_Gm={more};")?;
        }
        out.write_all(chunk)?;
        out.write_all(b"\x1b\\")?;
    }
    if let Some(previous) = previous {
        delete(out, previous)?;
    }
    out.flush()
}

/// Deletes image `id` and its placements, freeing its data.
pub(super) fn delete(out: &mut impl Write, id: u32) -> std::io::Result<()> {
    write!(out, "\x1b_Ga=d,d=I,i={id},q=2\x1b\\")
}
