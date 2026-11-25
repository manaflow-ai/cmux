//! R2 pack files, the HTTPS floor: chunk files laid end to end in one object, with an index of
//! where each sits. A client with no peer reads `want` from the packs with Range GETs, adjacent
//! wants coalesced into one range while the gap between them costs less than another request.
//!
//! A pack is write-once and named by its own BLAKE3 (`packs/<id>.pack`, its index
//! `packs/<id>.idx.json`), so a CDN or a regional cache may hold it forever.

use crate::manifest::Chunk;
use crate::store::{self, Store};
use crate::{Id, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// One chunk file's place in a pack.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// The chunk.
    pub id: Id,
    /// Its chunk file's first byte in the pack.
    pub offset: u64,
    /// Its chunk file's length (compressed, with header).
    pub len: u32,
}

/// A pack's index.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Index {
    /// The pack's id (BLAKE3 of its bytes).
    pub pack: Option<Id>,
    /// Its chunks, by offset.
    pub entries: Vec<Entry>,
}

/// A pack being written.
#[derive(Default)]
pub struct Writer {
    bytes: Vec<u8>,
    entries: Vec<Entry>,
}

impl Writer {
    /// Append a chunk file (from [`store::encode`]).
    pub fn push(&mut self, id: Id, file: &[u8]) -> Result<()> {
        self.entries.push(Entry {
            id,
            offset: self.bytes.len() as u64,
            len: u32::try_from(file.len())?,
        });
        self.bytes.extend_from_slice(file);
        Ok(())
    }

    /// The pack's bytes and its index.
    pub fn finish(self) -> (Vec<u8>, Index) {
        let id = Id::of(&self.bytes);
        (self.bytes, Index { pack: Some(id), entries: self.entries })
    }
}

/// One Range GET.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Range {
    /// The pack it reads.
    pub pack: Id,
    /// First byte.
    pub start: u64,
    /// One past the last byte.
    pub end: u64,
    /// The chunk files inside it that were wanted.
    pub entries: Vec<Entry>,
}

impl Range {
    /// Bytes it moves.
    pub fn len(&self) -> u64 {
        self.end - self.start
    }

    /// Whether it moves nothing.
    pub fn is_empty(&self) -> bool {
        self.end == self.start
    }
}

/// The byte cost of one more request: a gap shorter than this is read rather than skipped.
/// About one round trip of a 50 Mbit/s link at 40 ms.
pub const GAP: u64 = 256 << 10;

/// The Range GETs that fetch `want` from `indexes`, coalescing wants closer than `gap`. A chunk
/// no index holds is returned in the second list.
pub fn ranges(indexes: &[Index], want: &[Chunk], gap: u64) -> (Vec<Range>, Vec<Id>) {
    let mut at: HashMap<Id, (Id, Entry)> = HashMap::new();
    for idx in indexes {
        let Some(pack) = idx.pack else { continue };
        for e in &idx.entries {
            at.entry(e.id).or_insert((pack, *e));
        }
    }
    let mut missing = Vec::new();
    let mut by_pack: HashMap<Id, Vec<Entry>> = HashMap::new();
    for c in want {
        match at.get(&c.id) {
            Some((pack, e)) => by_pack.entry(*pack).or_default().push(*e),
            None => missing.push(c.id),
        }
    }
    let mut out = Vec::new();
    let mut packs: Vec<_> = by_pack.into_iter().collect();
    packs.sort_by_key(|(p, _)| *p);
    for (pack, mut es) in packs {
        es.sort_by_key(|e| e.offset);
        es.dedup_by_key(|e| e.offset);
        let mut cur: Option<Range> = None;
        for e in es {
            let end = e.offset + u64::from(e.len);
            match cur.as_mut() {
                Some(r) if e.offset <= r.end + gap => {
                    r.end = r.end.max(end);
                    r.entries.push(e);
                }
                _ => {
                    out.extend(cur.take());
                    cur = Some(Range { pack, start: e.offset, end, entries: vec![e] });
                }
            }
        }
        out.extend(cur);
    }
    (out, missing)
}

/// Store the wanted chunk files a fetched range's `bytes` hold, each checked against its id.
pub fn receive(store: &Store, range: &Range, bytes: &[u8]) -> Result<()> {
    if bytes.len() as u64 != range.len() {
        return Err(format!(
            "range of pack {} came back {} bytes, not {}",
            range.pack,
            bytes.len(),
            range.len()
        )
        .into());
    }
    for e in &range.entries {
        let from = usize::try_from(e.offset - range.start)?;
        let file = &bytes[from..from + e.len as usize];
        store.receive(&e.id, file)?;
    }
    Ok(())
}

/// A pack of `chunks` read from `store`, in order.
pub fn write(store: &Store, chunks: &[Chunk]) -> Result<(Vec<u8>, Index)> {
    let mut w = Writer::default();
    for c in chunks {
        let bytes = store.get(&c.id)?;
        w.push(c.id, &store::encode(&bytes, store::LEVEL)?)?;
    }
    Ok(w.finish())
}
