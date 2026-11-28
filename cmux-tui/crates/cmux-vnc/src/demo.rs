//! The loopback demo server's RFB rules (Packages/Shared/CmuxVNC's
//! CmuxVNCDemoServer): the server side of the handshake, the client messages
//! it reads, when an update goes out and the bytes of its rectangles. Pure:
//! Swift keeps the socket, the drawn scene, the damage list and the zlib
//! stream (one per connection, so it cannot round-trip as JSON), and asks
//! `vnc_demo_*` for the rest.

use serde::{Deserialize, Serialize};

use crate::auth::des;
use crate::pixel::PixelFormat;

/// The RFB encodings the demo speaks.
pub const ENCODING_RAW: i32 = 0;
pub const ENCODING_ZRLE: i32 = 16;
pub const ENCODING_CURSOR: i32 = -239;

/// Where a connection is in the handshake.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    #[default]
    Version,
    Security,
    Auth,
    ClientInit,
    Normal,
}

/// One viewer's protocol state, kept by the Swift caller between calls.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Connection {
    pub phase: Phase,
    /// The VNC authentication challenge sent (16 bytes), while in `Auth`.
    pub challenge: Vec<u8>,
    /// The encodings the viewer's last SetEncodings named.
    pub encodings: Vec<i32>,
    /// A FramebufferUpdateRequest is outstanding.
    pub requested: bool,
    pub cursor_sent: bool,
    pub buttons: u8,
    pub shift: bool,
}

/// What the server shows: the desktop's size, name and password.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub width: u16,
    pub height: u16,
    #[serde(default)]
    pub name: String,
    /// None: no authentication.
    #[serde(default)]
    pub password: Option<String>,
}

/// A client message the scene acts on.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    #[serde(rename_all = "camelCase")]
    Key { keysym: u32, down: bool, shift: bool },
    #[serde(rename_all = "camelCase")]
    Pointer { x: u16, y: u16, left_down: bool },
    /// A non-incremental request: the whole screen is damaged.
    FullUpdate,
}

/// What one batch of client bytes did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Step {
    /// How many input bytes were read; the rest waits for more.
    pub consumed: usize,
    /// Bytes to send, in order.
    pub reply: Vec<u8>,
    pub events: Vec<Event>,
    /// An update request arrived: see whether one can go ([`flush`]).
    pub flush: bool,
    /// Send [`failure`] of this and close.
    pub failure: Option<String>,
}

fn u16_at(bytes: &[u8], offset: usize) -> u16 {
    u16::from_be_bytes([bytes[offset], bytes[offset + 1]])
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]])
}

/// The server's pixel format: 32-bit little-endian BGRX, as the scene draws.
pub fn pixel_format() -> PixelFormat {
    PixelFormat {
        bits_per_pixel: 32,
        depth: 24,
        big_endian: false,
        true_color: true,
        red_max: 255,
        green_max: 255,
        blue_max: 255,
        red_shift: 16,
        green_shift: 8,
        blue_shift: 0,
    }
}

/// Reads as many whole client messages from `input` as it holds. `challenge`
/// is the 16 bytes sent if the viewer picks VNC authentication.
pub fn receive(
    connection: &mut Connection,
    input: &[u8],
    config: &Config,
    challenge: [u8; 16],
) -> Step {
    let mut step = Step::default();
    loop {
        let rest = &input[step.consumed..];
        let take = |count: usize, step: &mut Step| -> Option<usize> {
            (rest.len() >= count).then(|| {
                step.consumed += count;
                count
            })
        };
        match connection.phase {
            Phase::Version => {
                if take(12, &mut step).is_none() {
                    return step;
                }
                let kind = if config.password.is_none() { 1 } else { 2 };
                step.reply.extend([1, kind]);
                connection.phase = Phase::Security;
            }
            Phase::Security => {
                if take(1, &mut step).is_none() {
                    return step;
                }
                match (rest[0], config.password.is_some()) {
                    (2, true) => {
                        connection.challenge = challenge.to_vec();
                        step.reply.extend(challenge);
                        connection.phase = Phase::Auth;
                    }
                    (1, false) => {
                        step.reply.extend([0, 0, 0, 0]);
                        connection.phase = Phase::ClientInit;
                    }
                    _ => {
                        step.failure = Some("unsupported security type".into());
                        return step;
                    }
                }
            }
            Phase::Auth => {
                if take(16, &mut step).is_none() {
                    return step;
                }
                let sent: [u8; 16] = connection.challenge.as_slice().try_into().unwrap_or([0; 16]);
                let password = config.password.as_deref().unwrap_or("");
                if rest[..16] != des::vnc_response(password.as_bytes(), sent) {
                    step.failure = Some("Authentication failed".into());
                    return step;
                }
                connection.challenge.clear();
                step.reply.extend([0, 0, 0, 0]);
                connection.phase = Phase::ClientInit;
            }
            Phase::ClientInit => {
                if take(1, &mut step).is_none() {
                    return step;
                }
                step.reply.extend(config.width.to_be_bytes());
                step.reply.extend(config.height.to_be_bytes());
                step.reply.extend(pixel_format().encode());
                step.reply.extend((config.name.len() as u32).to_be_bytes());
                step.reply.extend(config.name.as_bytes());
                connection.phase = Phase::Normal;
            }
            Phase::Normal => {
                let Some(&kind) = rest.first() else {
                    return step;
                };
                match kind {
                    // SetPixelFormat: the demo always sends its own.
                    0 => {
                        if take(20, &mut step).is_none() {
                            return step;
                        }
                    }
                    2 => {
                        if rest.len() < 4 {
                            return step;
                        }
                        let count = u16_at(rest, 2) as usize;
                        if take(4 + count * 4, &mut step).is_none() {
                            return step;
                        }
                        connection.encodings =
                            (0..count).map(|i| u32_at(rest, 4 + i * 4) as i32).collect();
                    }
                    3 => {
                        if take(10, &mut step).is_none() {
                            return step;
                        }
                        if rest[1] == 0 {
                            step.events.push(Event::FullUpdate);
                        }
                        connection.requested = true;
                        step.flush = true;
                    }
                    4 => {
                        if take(8, &mut step).is_none() {
                            return step;
                        }
                        let keysym = u32_at(rest, 4);
                        let down = rest[1] != 0;
                        if keysym == 0xFFE1 || keysym == 0xFFE2 {
                            connection.shift = down;
                        }
                        step.events.push(Event::Key { keysym, down, shift: connection.shift });
                    }
                    5 => {
                        if take(6, &mut step).is_none() {
                            return step;
                        }
                        connection.buttons = rest[1];
                        step.events.push(Event::Pointer {
                            x: u16_at(rest, 2),
                            y: u16_at(rest, 4),
                            left_down: rest[1] & 1 != 0,
                        });
                    }
                    // ClientCutText: skipped.
                    6 => {
                        if rest.len() < 8 {
                            return step;
                        }
                        if take(8 + u32_at(rest, 4) as usize, &mut step).is_none() {
                            return step;
                        }
                    }
                    other => {
                        step.failure = Some(format!("unknown message {other}"));
                        return step;
                    }
                }
            }
        }
    }
}

/// The bytes that end a connection with `reason` (a security result of 1 and
/// the reason string).
pub fn failure(reason: &str) -> Vec<u8> {
    let mut out = 1u32.to_be_bytes().to_vec();
    out.extend((reason.len() as u32).to_be_bytes());
    out.extend(reason.as_bytes());
    out
}

/// Whether an update goes now, given whether damage is pending, and whether it
/// starts with the cursor shape. None: nothing to send (or nothing asked).
pub fn flush(connection: &mut Connection, damage_pending: bool) -> Option<bool> {
    if connection.phase != Phase::Normal || !connection.requested {
        return None;
    }
    let cursor = connection.encodings.contains(&ENCODING_CURSOR) && !connection.cursor_sent;
    if !cursor && !damage_pending {
        return None;
    }
    connection.requested = false;
    connection.cursor_sent |= cursor;
    Some(cursor)
}

/// A FramebufferUpdate's header for `count` rectangles.
pub fn update_header(count: u16) -> Vec<u8> {
    let mut out = vec![0, 0];
    out.extend(count.to_be_bytes());
    out
}

/// A rectangle's 12-byte header.
pub fn rect_header(x: u16, y: u16, width: u16, height: u16, encoding: i32) -> Vec<u8> {
    let mut out = Vec::with_capacity(12);
    for v in [x, y, width, height] {
        out.extend(v.to_be_bytes());
    }
    out.extend(encoding.to_be_bytes());
    out
}

/// Whether the viewer takes ZRLE (else raw).
pub fn uses_zrle(connection: &Connection) -> bool {
    connection.encodings.contains(&ENCODING_ZRLE)
}

/// A rectangle of `pixels` (BGRX values, `width` a row) as raw RFB pixels.
pub fn raw(pixels: &[u32]) -> Vec<u8> {
    pixels.iter().flat_map(|p| p.to_le_bytes()).collect()
}

fn cpixel(pixel: u32, out: &mut Vec<u8>) {
    out.extend(&pixel.to_le_bytes()[..3]);
}

fn tile(tile: &[u32], out: &mut Vec<u8>) {
    if tile.iter().all(|p| *p == tile[0]) {
        out.push(1);
        cpixel(tile[0], out);
        return;
    }
    let mut runs: Vec<(u32, usize)> = Vec::new();
    for &pixel in tile {
        match runs.last_mut() {
            Some((last, length)) if *last == pixel => *length += 1,
            _ => runs.push((pixel, 1)),
        }
    }
    let rle_size: usize = runs.iter().map(|(_, length)| 3 + (length - 1) / 255 + 1).sum();
    if rle_size < tile.len() * 3 {
        out.push(128);
        for (pixel, length) in runs {
            cpixel(pixel, out);
            let mut remaining = length - 1;
            while remaining >= 255 {
                out.push(255);
                remaining -= 255;
            }
            out.push(remaining as u8);
        }
        return;
    }
    out.push(0);
    for &pixel in tile {
        cpixel(pixel, out);
    }
}

/// A `width`×`height` rectangle of `pixels` (BGRX values, row after row) as
/// ZRLE tiles before compression: solid tiles, plain RLE when it is smaller,
/// raw otherwise (three of the client's tile decoders).
pub fn zrle_tiles(pixels: &[u32], width: usize, height: usize) -> Vec<u8> {
    let mut out = Vec::new();
    let mut scratch = Vec::with_capacity(64 * 64);
    for tile_y in (0..height).step_by(64) {
        let h = 64.min(height - tile_y);
        for tile_x in (0..width).step_by(64) {
            let w = 64.min(width - tile_x);
            scratch.clear();
            for row in tile_y..tile_y + h {
                scratch.extend_from_slice(&pixels[row * width + tile_x..row * width + tile_x + w]);
            }
            tile(&scratch, &mut out);
        }
    }
    out
}

/// A small arrow cursor as a Cursor pseudo-encoding rectangle.
pub fn cursor_rectangle() -> Vec<u8> {
    const W: usize = 12;
    const H: usize = 18;
    let mut colours = Vec::with_capacity(W * H * 4);
    let mut mask = Vec::new();
    for row in 0..H {
        let mut mask_row = vec![0u8; W.div_ceil(8)];
        for col in 0..W {
            let inside = col <= row && row < H - 4 || (row >= H - 4 && (3..=6).contains(&col));
            let edge = col == 0 || col == row || row == H - 5 && col > 6;
            let colour = if inside && !edge { 255 } else { 0 };
            colours.extend([colour, colour, colour, 0]);
            if inside || edge {
                mask_row[col / 8] |= 0x80 >> (col % 8);
            }
        }
        mask.extend(mask_row);
    }
    let mut out = rect_header(0, 0, W as u16, H as u16, ENCODING_CURSOR);
    out.extend(colours);
    out.extend(mask);
    out
}

#[cfg(test)]
#[path = "demo_tests.rs"]
mod tests;
