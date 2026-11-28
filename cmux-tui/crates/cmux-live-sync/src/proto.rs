//! The wire between leader (the Mac) and follower (the VM): frames on one duplex byte stream,
//! each a 4-byte big-endian header length, the header as JSON, a 4-byte body length and the body
//! (file bytes, concatenated in the order the header lists them). Any stream carries it: the
//! machine link's `sync.live` dial, a socketpair in tests, a child's stdio.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

use crate::replica::{Hash, Outcome};

pub const PROTOCOL: u32 = 1;
/// Largest header or body one frame may carry; a round splits its writes to stay under it.
pub const MAX_FRAME: usize = 64 * 1024 * 1024;
/// Body bytes per apply frame before a round starts the next one.
pub const BATCH_BYTES: usize = 16 * 1024 * 1024;

/// One file's bytes in a body: where they sit is the running sum of `len`s before it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub path: String,
    /// The path's state; `None` when it is absent (then `len` is 0).
    pub hash: Option<Hash>,
    pub len: u64,
}

/// One change the leader asks the follower to make.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WireOp {
    /// Put the bytes (the next `len` of the body) at `path` if it holds `expect`.
    Write { path: String, expect: Option<Hash>, hash: Hash, len: u64 },
    /// Remove `path` if it holds `expect`.
    Delete { path: String, expect: Hash },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Msg {
    /// First frame each way. The follower sends the synced revision it holds a copy of.
    Hello {
        protocol: u32,
        synced: Option<String>,
    },
    /// The follower's state for some paths (`full`: every path it has; the rest are absent).
    State {
        full: bool,
        entries: Vec<(String, Option<Hash>)>,
        alerts: Vec<String>,
    },
    /// The leader wants these paths' bytes as they are now.
    Fetch {
        id: u64,
        paths: Vec<String>,
    },
    /// The answer to a fetch: an item per path, bytes in the body.
    Blobs {
        id: u64,
        items: Vec<Item>,
    },
    /// Changes for the follower, bytes in the body.
    Apply {
        id: u64,
        ops: Vec<WireOp>,
    },
    /// One outcome per op, in order.
    Applied {
        id: u64,
        outcomes: Vec<Outcome>,
    },
    /// The new synced revision: its id and the paths that moved (`None`: removed). The follower
    /// keeps a copy so a leader that lost its store starts from it, not from empty.
    Synced {
        id: String,
        changes: Vec<(String, Option<Hash>)>,
    },
    /// The whole synced tree (the follower's copy, sent once after Hello when the leader has none).
    SyncedTree {
        id: String,
        tree: Vec<(String, Hash)>,
    },
    Ping,
    Pong,
}

pub fn write_frame(w: &mut impl Write, msg: &Msg, body: &[u8]) -> io::Result<()> {
    let header = serde_json::to_vec(msg).map_err(io::Error::other)?;
    if header.len() > MAX_FRAME || body.len() > MAX_FRAME {
        return Err(io::Error::other("frame too large"));
    }
    let mut out = Vec::with_capacity(8 + header.len() + body.len());
    out.extend_from_slice(&u32::try_from(header.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(&header);
    out.extend_from_slice(&u32::try_from(body.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(body);
    w.write_all(&out)?;
    w.flush()
}

pub fn read_frame(r: &mut impl Read) -> io::Result<(Msg, Vec<u8>)> {
    let header = read_part(r)?;
    let msg: Msg = serde_json::from_slice(&header).map_err(io::Error::other)?;
    let body = read_part(r)?;
    Ok((msg, body))
}

fn read_part(r: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::other("frame too large"));
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    Ok(buf)
}

/// Splits a body by its items' lengths.
pub fn split_body(
    body: &[u8],
    lens: impl IntoIterator<Item = u64>,
) -> io::Result<Vec<&[u8]>> {
    let mut at = 0usize;
    let mut out = vec![];
    for len in lens {
        let len = usize::try_from(len).map_err(io::Error::other)?;
        let part =
            body.get(at..at + len).ok_or_else(|| io::Error::other("body shorter than items"))?;
        out.push(part);
        at += len;
    }
    Ok(out)
}
