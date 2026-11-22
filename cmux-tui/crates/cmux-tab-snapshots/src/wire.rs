//! The `tabs` service frames. Every message is one frame: a 1-byte kind, then
//! the body. Control bodies are JSON (camelCase); a blob body is binary:
//! 32 raw hash bytes, 1 mime id byte, then the blob bytes.
//!
//! On a link channel, which delivers bytes in chunks, each frame travels
//! behind its length ([`crate::stream`]).

use crate::hash::{BlobHash, Mime};
use crate::row::{Row, RowPatch};
use serde::{Deserialize, Serialize};
use std::fmt;

/// Frame kind bytes. Phone to Mac are 0x0_, Mac to phone are 0x1_.
pub mod kind {
    pub const VIEWPORT: u8 = 0x01;
    pub const WANT: u8 = 0x02;
    pub const HAVE: u8 = 0x03;
    pub const RESUME: u8 = 0x04;
    pub const MANIFEST: u8 = 0x11;
    pub const DELTA: u8 = 0x12;
    pub const BLOB: u8 = 0x13;
}

/// The phone's card geometry, so the Mac can size thumbnails for it.
#[derive(Clone, Debug, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Viewport {
    pub card_pixel_width: u32,
    pub card_aspect: f64,
    pub display_scale: f64,
    pub screen_pixel_w: u32,
    pub screen_pixel_h: u32,
}

/// The phone's last applied manifest rev and the producer epoch it came
/// from, sent on reconnect. An empty `epoch` means the phone holds none; the
/// Mac answers that with a manifest.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Resume {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub epoch: String,
    pub rev: u64,
}

/// Every row, in tab order, at `rev`. `epoch` names the producer run that
/// handed out `rev`: revs from different epochs are unrelated.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Manifest {
    pub epoch: String,
    pub rev: u64,
    pub rows: Vec<Row>,
}

/// What changed from `baseRev` to `rev` within one `epoch`. A new tab is
/// appended to the end. `order`, present only when the tab order changed,
/// is the full order after the delta; the receiver applies it after
/// `changed` and `removed`. A tab it does not list keeps its relative
/// order after the listed ones.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Delta {
    pub epoch: String,
    pub rev: u64,
    pub base_rev: u64,
    pub changed: Vec<RowPatch>,
    pub removed: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<Vec<String>>,
}

/// One blob. The decoder does not check the hash; the receiver does.
#[derive(Clone, PartialEq, Eq)]
pub struct BlobFrame {
    pub hash: BlobHash,
    pub mime: Mime,
    pub bytes: Vec<u8>,
}

impl fmt::Debug for BlobFrame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BlobFrame")
            .field("hash", &self.hash)
            .field("mime", &self.mime)
            .field("len", &self.bytes.len())
            .finish()
    }
}

/// One `tabs` frame.
#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    /// Phone to Mac.
    Viewport(Viewport),
    /// Phone to Mac: hashes in the phone's priority order, sent ahead of
    /// anything pushed. Replaces the last `want`. Each named hash is sent,
    /// even one the Mac sent before.
    Want(Vec<BlobHash>),
    /// Phone to Mac: hashes the phone already holds, sent once on link-up.
    Have(Vec<BlobHash>),
    /// Phone to Mac: sent first on reconnect.
    Resume(Resume),
    /// Mac to phone.
    Manifest(Manifest),
    /// Mac to phone.
    Delta(Delta),
    /// Mac to phone.
    Blob(BlobFrame),
}

/// Why a frame did not decode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WireError {
    /// A zero-length frame.
    Empty,
    /// A kind byte this build does not know.
    UnknownKind(u8),
    /// A JSON body that does not parse as its kind.
    Json { kind: u8, message: String },
    /// A blob body shorter than its 33-byte header.
    ShortBlob { len: usize },
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => f.write_str("empty tabs frame"),
            Self::UnknownKind(kind) => write!(f, "unknown tabs frame kind 0x{kind:02x}"),
            Self::Json { kind, message } => write!(f, "tabs frame 0x{kind:02x}: {message}"),
            Self::ShortBlob { len } => write!(f, "blob frame body of {len} bytes, header is 33"),
        }
    }
}

impl std::error::Error for WireError {}

/// Bytes in a blob frame before the blob: kind, hash, mime id.
pub const BLOB_HEADER_LEN: usize = 1 + 32 + 1;

fn json_frame<T: Serialize>(kind: u8, value: &T) -> Vec<u8> {
    let mut out = vec![kind];
    // These types hold only strings, numbers and lists, which always
    // serialize. A failure would leave a bare kind byte, which the peer
    // reports as a JSON error rather than misreading.
    if serde_json::to_writer(&mut out, value).is_err() {
        out.truncate(1);
    }
    out
}

fn json_body<'a, T: Deserialize<'a>>(kind: u8, body: &'a [u8]) -> Result<T, WireError> {
    serde_json::from_slice(body).map_err(|err| WireError::Json { kind, message: err.to_string() })
}

impl Message {
    /// The frame's kind byte.
    pub fn kind(&self) -> u8 {
        match self {
            Self::Viewport(_) => kind::VIEWPORT,
            Self::Want(_) => kind::WANT,
            Self::Have(_) => kind::HAVE,
            Self::Resume(_) => kind::RESUME,
            Self::Manifest(_) => kind::MANIFEST,
            Self::Delta(_) => kind::DELTA,
            Self::Blob(_) => kind::BLOB,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let kind = self.kind();
        match self {
            Self::Viewport(v) => json_frame(kind, v),
            Self::Want(hashes) | Self::Have(hashes) => json_frame(kind, hashes),
            Self::Resume(r) => json_frame(kind, r),
            Self::Manifest(m) => json_frame(kind, m),
            Self::Delta(d) => json_frame(kind, d),
            Self::Blob(blob) => encode_blob(blob.hash, blob.mime, &blob.bytes),
        }
    }

    pub fn decode(frame: &[u8]) -> Result<Self, WireError> {
        let Some((&kind, body)) = frame.split_first() else {
            return Err(WireError::Empty);
        };
        Ok(match kind {
            kind::VIEWPORT => Self::Viewport(json_body(kind, body)?),
            kind::WANT => Self::Want(json_body(kind, body)?),
            kind::HAVE => Self::Have(json_body(kind, body)?),
            kind::RESUME => Self::Resume(json_body(kind, body)?),
            kind::MANIFEST => Self::Manifest(json_body(kind, body)?),
            kind::DELTA => Self::Delta(json_body(kind, body)?),
            kind::BLOB => Self::Blob(decode_blob(body)?),
            other => return Err(WireError::UnknownKind(other)),
        })
    }
}

/// Encodes a blob frame without first copying the bytes into a [`BlobFrame`].
pub fn encode_blob(hash: BlobHash, mime: Mime, bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(BLOB_HEADER_LEN + bytes.len());
    out.push(kind::BLOB);
    out.extend_from_slice(&hash.0);
    out.push(mime.id());
    out.extend_from_slice(bytes);
    out
}

fn decode_blob(body: &[u8]) -> Result<BlobFrame, WireError> {
    let short = || WireError::ShortBlob { len: body.len() };
    let (hash, rest) = body.split_first_chunk::<32>().ok_or_else(short)?;
    let (&mime, bytes) = rest.split_first().ok_or_else(short)?;
    Ok(BlobFrame { hash: BlobHash(*hash), mime: Mime::from_id(mime), bytes: bytes.to_vec() })
}

#[cfg(test)]
#[path = "wire_tests.rs"]
mod tests;
