//! Compressed WebSocket frames for large messages (Leo, 2026-10-31: "why are we not following
//! protocol/transport best practices with compression/better formats"). A peer's session list
//! is JSON text that compresses about 6x at zlib's fastest level (443 real rows, 1.2 MB, went
//! to 0.2 MB), and it used to cross the link whole.
//!
//! tungstenite 0.29 has no permessage-deflate, so acpmux negotiates its own, per connection:
//! a client that reads them lists [`ZLIB`] in `initialize` `_meta.acpmux.compression`, and
//! from then on the server sends each message of [`MIN_BYTES`] or more as one Binary frame
//! holding the zlib stream of its JSON text; smaller ones stay Text. The initialize reply
//! says `_meta.acpmux.compression: "zlib"` when it does. A client that never asks (every
//! build before this one) gets Text as before, and a server that never heard of the field
//! ignores it, so mixed builds keep working.
//!
//! Only the server compresses. Client-to-server Binary frames are upload data
//! (`server/upload_frames.rs`), and what a client sends in bulk (prompt images) is compressed
//! already. The per-message limit, `rpc::MAX_MESSAGE_BYTES`, still bounds the JSON text, so
//! an older reader of the same text never sees more than before.

use flate2::Compression;
use flate2::read::ZlibDecoder;
use flate2::write::ZlibEncoder;
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};

/// The one codec: zlib (RFC 1950, deflate with a checksum), in every acpmux build through
/// `flate2`'s pure-Rust backend.
pub const ZLIB: &str = "zlib";

/// Messages shorter than this stay Text: compressing them saves little and costs a copy.
pub const MIN_BYTES: usize = 16 << 10;

/// Past this, the writer compresses on a blocking thread (31 MiB takes tens of milliseconds).
const BLOCKING_BYTES: usize = 1 << 20;

/// The `initialize` `_meta.acpmux.compression` a client sends to get compressed frames.
pub fn offer() -> Value {
    json!([ZLIB])
}

/// Whether `initialize` params ask for zlib frames.
pub fn offered(params: Option<&Value>) -> bool {
    params
        .and_then(|p| p.pointer("/_meta/acpmux/compression"))
        .and_then(Value::as_array)
        .is_some_and(|codecs| codecs.iter().any(|c| c.as_str() == Some(ZLIB)))
}

/// One WebSocket connection's choice: off until its client asks in `initialize`. Only a
/// transport whose writer compresses ([`Wire::frame`]) has one.
#[derive(Debug, Default)]
pub struct Wire {
    on: AtomicBool,
}

impl Wire {
    pub fn enable(&self) {
        self.on.store(true, Ordering::SeqCst);
    }

    pub fn enabled(&self) -> bool {
        self.on.load(Ordering::SeqCst)
    }

    /// The frame for one outgoing JSON-RPC line: Binary zlib when this connection asked and
    /// the line is [`MIN_BYTES`] or more, else Text. None when the runtime shuts down
    /// before a large one is compressed: the connection is ending.
    pub async fn frame(&self, line: String) -> Option<tokio_tungstenite::tungstenite::Message> {
        use tokio_tungstenite::tungstenite::Message as Frame;
        let text = match line.strip_suffix('\n') {
            Some(text) => text.to_owned(),
            None => line,
        };
        if !self.enabled() || text.len() < MIN_BYTES {
            return Some(Frame::Text(text.into()));
        }
        if text.len() < BLOCKING_BYTES {
            return Some(Frame::Binary(deflate(text.as_bytes()).into()));
        }
        let bytes = tokio::task::spawn_blocking(move || deflate(text.as_bytes())).await.ok()?;
        Some(Frame::Binary(bytes.into()))
    }
}

/// `text` as one zlib stream, at the fastest level: on a session list it gives most of the
/// ratio of the default level at about twice the speed.
pub fn deflate(text: &[u8]) -> Vec<u8> {
    let mut encoder = ZlibEncoder::new(Vec::with_capacity(text.len() / 4), Compression::new(1));
    // Writing to a Vec cannot fail.
    let _ = encoder.write_all(text);
    encoder.finish().unwrap_or_default()
}

/// The JSON text of a zlib frame, refused past `limit` bytes inflated (a frame of a few MB
/// must not inflate to gigabytes) or when it is not zlib holding UTF-8.
pub fn inflate(bytes: &[u8], limit: usize) -> Result<String, String> {
    let mut text = Vec::new();
    let read = ZlibDecoder::new(bytes)
        .take(u64::try_from(limit).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_end(&mut text);
    if let Err(e) = read {
        return Err(format!("a compressed frame did not inflate: {e}"));
    }
    if text.len() > limit {
        return Err(format!("a compressed frame inflates past {limit} bytes"));
    }
    String::from_utf8(text).map_err(|_| "a compressed frame is not UTF-8 text".to_owned())
}

#[cfg(test)]
#[path = "frame_compress_tests.rs"]
mod tests;
