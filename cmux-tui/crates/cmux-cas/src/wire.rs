//! `cas/1`'s messages and their codec, on any byte stream.
//!
//! A frame is its body's length (u32 LE) and the body:
//!
//! ```text
//! version  u16 LE   the sender's protocol version (this build: VERSION = 1)
//! kind     u8       HAVE = 1, WANT = 2, DATA = 3, NOPE = 4
//! fields   *        each: tag u8, length u32 LE, value
//! ```
//!
//! **Lockstep.** Every message says its version, and every field is tagged, so the two ends of a
//! link upgrade in either order:
//!
//! - a reader skips a field tag it does not know (a newer sender added it) and reads the rest;
//! - a reader that finds no field a newer version would add uses that field's default;
//! - a message kind a reader does not know decodes as [`Message::Unknown`], which the reader
//!   answers with `NOPE` naming that kind and its own version ([`crate::peer::respond`]); the
//!   newer sender falls back to what that version speaks;
//! - a field's meaning never changes once a version has shipped it; a new meaning is a new tag.
//!
//! Version 0 is refused. A version above [`VERSION`] is read the same way (its fields this build
//! knows mean what they meant).
//!
//! **Tags.** 1 root (32 bytes), 2 ids (n x 32 bytes), 3 priority (u8), 4 id (32 bytes),
//! 5 bytes, 6 kind (u8: the message kind a NOPE refuses), 7 reason (UTF-8).
//!
//! Later versions (RFD 0166 techniques, section 3): a bloom of ids in `HAVE`, a Bao outboard and
//! group offset in `DATA` (so a lying peer is dropped after one 16 KiB group, not one chunk), and
//! `PATCH?` as a new kind. Each is a new tag or kind, so this version keeps talking to them.

use crate::Result;
use crate::id::Id;
use std::io::{Read, Write};

/// The protocol version this build speaks.
pub const VERSION: u16 = 1;
/// The largest frame body a reader accepts: a 256 KiB chunk and its header, or 8,192 ids.
pub const MAX_BODY: usize = 1 << 20;

/// `HAVE`.
pub const KIND_HAVE: u8 = 1;
/// `WANT`.
pub const KIND_WANT: u8 = 2;
/// `DATA`.
pub const KIND_DATA: u8 = 3;
/// `NOPE`.
pub const KIND_NOPE: u8 = 4;

/// Field tags.
pub mod tag {
    /// A root manifest id.
    pub const ROOT: u8 = 1;
    /// Chunk ids, 32 bytes each.
    pub const IDS: u8 = 2;
    /// A `WANT`'s priority (0 first).
    pub const PRIORITY: u8 = 3;
    /// One chunk id.
    pub const ID: u8 = 4;
    /// A chunk's bytes.
    pub const BYTES: u8 = 5;
    /// The message kind a `NOPE` refuses.
    pub const KIND: u8 = 6;
    /// Why, for a person reading a log.
    pub const REASON: u8 = 7;
}

/// A frame as it is on the wire: version, kind and tagged fields, known or not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// The sender's protocol version.
    pub version: u16,
    /// The message kind.
    pub kind: u8,
    /// Its fields, in order.
    pub fields: Vec<(u8, Vec<u8>)>,
}

impl Frame {
    /// The first field tagged `tag`.
    pub fn field(&self, tag: u8) -> Option<&[u8]> {
        self.fields.iter().find(|(t, _)| *t == tag).map(|(_, v)| v.as_slice())
    }

    /// The frame's body (no length prefix).
    pub fn encode_body(&self) -> Result<Vec<u8>> {
        let size = self
            .fields
            .iter()
            .try_fold(3usize, |n, (_, v)| n.checked_add(5)?.checked_add(v.len()))
            .ok_or("a frame over usize")?;
        let mut out = Vec::with_capacity(size.min(MAX_BODY));
        out.extend_from_slice(&self.version.to_le_bytes());
        out.push(self.kind);
        for (tag, value) in &self.fields {
            let len = u32::try_from(value.len()).map_err(|_| "a field over 4 GiB")?;
            out.push(*tag);
            out.extend_from_slice(&len.to_le_bytes());
            out.extend_from_slice(value);
        }
        if out.len() > MAX_BODY {
            return Err(format!(
                "a frame of {} bytes is over the {MAX_BODY} a reader takes",
                out.len()
            )
            .into());
        }
        Ok(out)
    }

    /// The frame in `body`.
    pub fn decode_body(body: &[u8]) -> Result<Self> {
        let &[v0, v1, kind, ref rest @ ..] = body else {
            return Err("a frame shorter than its header".into());
        };
        let version = u16::from_le_bytes([v0, v1]);
        if version == 0 {
            return Err("a frame of version 0".into());
        }
        let mut fields = Vec::new();
        let mut rest = rest;
        while let &[tag, a, b, c, d, ref after @ ..] = rest {
            let len = u32::from_le_bytes([a, b, c, d]) as usize;
            if after.len() < len {
                return Err(
                    format!("field {tag} says {len} bytes and {} are left", after.len()).into()
                );
            }
            let (value, next) = after.split_at(len);
            fields.push((tag, value.to_vec()));
            rest = next;
        }
        if !rest.is_empty() {
            return Err("a frame ends inside a field header".into());
        }
        Ok(Self { version, kind, fields })
    }

    /// Writes the frame, length first.
    pub fn write_to(&self, out: &mut dyn Write) -> Result<()> {
        let body = self.encode_body()?;
        let len = u32::try_from(body.len()).map_err(|_| "a frame over 4 GiB")?;
        out.write_all(&len.to_le_bytes())?;
        out.write_all(&body)?;
        Ok(())
    }

    /// The next frame on `input`, or `None` at a clean end of stream.
    pub fn read_from(input: &mut dyn Read) -> Result<Option<Self>> {
        let mut len = [0u8; 4];
        match input.read(&mut len[..1])? {
            0 => return Ok(None),
            _ => input.read_exact(&mut len[1..])?,
        }
        let len = u32::from_le_bytes(len) as usize;
        if len > MAX_BODY {
            return Err(
                format!("a frame of {len} bytes is over the {MAX_BODY} a reader takes").into()
            );
        }
        let mut body = vec![0u8; len];
        input.read_exact(&mut body)?;
        Self::decode_body(&body).map(Some)
    }
}

/// A `cas/1` message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    /// What the sender holds: a whole root's chunks, and or these ids.
    Have { version: u16, root: Option<Id>, ids: Vec<Id> },
    /// Chunks the sender asks for, most urgent at priority 0.
    Want { version: u16, ids: Vec<Id>, priority: u8 },
    /// One chunk's bytes.
    Data { version: u16, id: Id, bytes: Vec<u8> },
    /// The sender has none of `ids`, or does not speak message `kind`.
    Nope { version: u16, ids: Vec<Id>, kind: Option<u8>, reason: String },
    /// A message kind this build does not speak, from a newer peer: answered with `NOPE`.
    Unknown { version: u16, kind: u8 },
}

impl Message {
    /// The sender's version.
    pub fn version(&self) -> u16 {
        match self {
            Self::Have { version, .. }
            | Self::Want { version, .. }
            | Self::Data { version, .. }
            | Self::Nope { version, .. }
            | Self::Unknown { version, .. } => *version,
        }
    }

    /// The message as a frame.
    pub fn to_frame(&self) -> Frame {
        let id_list = |ids: &[Id]| ids.iter().flat_map(|id| id.0).collect::<Vec<u8>>();
        let (version, kind, fields) = match self {
            Self::Have { version, root, ids } => {
                let mut fields = Vec::new();
                if let Some(root) = root {
                    fields.push((tag::ROOT, root.0.to_vec()));
                }
                fields.push((tag::IDS, id_list(ids)));
                (*version, KIND_HAVE, fields)
            }
            Self::Want { version, ids, priority } => (
                *version,
                KIND_WANT,
                vec![(tag::IDS, id_list(ids)), (tag::PRIORITY, vec![*priority])],
            ),
            Self::Data { version, id, bytes } => {
                (*version, KIND_DATA, vec![(tag::ID, id.0.to_vec()), (tag::BYTES, bytes.clone())])
            }
            Self::Nope { version, ids, kind, reason } => {
                let mut fields = vec![(tag::IDS, id_list(ids))];
                if let Some(kind) = kind {
                    fields.push((tag::KIND, vec![*kind]));
                }
                if !reason.is_empty() {
                    fields.push((tag::REASON, reason.as_bytes().to_vec()));
                }
                (*version, KIND_NOPE, fields)
            }
            Self::Unknown { version, kind } => (*version, *kind, Vec::new()),
        };
        Frame { version, kind, fields }
    }

    /// The message in `frame`. Unknown field tags are skipped; an unknown kind is
    /// [`Message::Unknown`]; a known kind missing a field it needs is an error.
    pub fn from_frame(frame: &Frame) -> Result<Self> {
        let version = frame.version;
        Ok(match frame.kind {
            KIND_HAVE => Self::Have {
                version,
                root: frame.field(tag::ROOT).map(one_id).transpose()?,
                ids: frame.field(tag::IDS).map(ids).transpose()?.unwrap_or_default(),
            },
            KIND_WANT => Self::Want {
                version,
                ids: ids(frame.field(tag::IDS).ok_or("a WANT with no ids")?)?,
                priority: frame.field(tag::PRIORITY).and_then(|p| p.first().copied()).unwrap_or(0),
            },
            KIND_DATA => Self::Data {
                version,
                id: one_id(frame.field(tag::ID).ok_or("a DATA with no id")?)?,
                bytes: frame.field(tag::BYTES).ok_or("a DATA with no bytes")?.to_vec(),
            },
            KIND_NOPE => Self::Nope {
                version,
                ids: frame.field(tag::IDS).map(ids).transpose()?.unwrap_or_default(),
                kind: frame.field(tag::KIND).and_then(|k| k.first().copied()),
                reason: frame
                    .field(tag::REASON)
                    .map(|r| String::from_utf8_lossy(r).into_owned())
                    .unwrap_or_default(),
            },
            kind => Self::Unknown { version, kind },
        })
    }

    /// The message's frame body.
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.to_frame().encode_body()
    }

    /// The message in frame body `body`.
    pub fn decode(body: &[u8]) -> Result<Self> {
        Self::from_frame(&Frame::decode_body(body)?)
    }
}

fn one_id(bytes: &[u8]) -> Result<Id> {
    <[u8; 32]>::try_from(bytes)
        .map(Id)
        .map_err(|_| format!("an id of {} bytes, not 32", bytes.len()).into())
}

fn ids(bytes: &[u8]) -> Result<Vec<Id>> {
    let (ids, rest) = bytes.as_chunks::<32>();
    if !rest.is_empty() {
        return Err(format!("an id list of {} bytes, not a multiple of 32", bytes.len()).into());
    }
    Ok(ids.iter().copied().map(Id).collect())
}

#[cfg(test)]
#[path = "wire_tests.rs"]
mod tests;
