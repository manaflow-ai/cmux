//! Segments: docs packed into blocks of about `block_bytes` of text, and a
//! trigram -> block posting list per trigram.
//!
//! The newest segment is live: it takes appends and holds its text, docs and
//! postings (a hash map) in memory. A full live segment is sealed into one
//! immutable byte image (layout below). A sealed segment keeps only its
//! block table and trigram key table in memory; text, doc records and
//! posting lists are read on demand (`pread`) from its file, so resident
//! memory stays a small fraction of the text (the page cache holds what
//! queries touch). Without an index directory (tests) the image stays in
//! memory.
//!
//! Image layout, little endian: magic, header (text, doc, block, key and
//! posting-data sizes, u64 each), text, doc records (41 bytes), block
//! records (14 bytes), keys, counts, offsets (u32 each), posting data.

use std::collections::HashMap;
use std::fs::File;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;

use crate::trigram;

/// No value, for the optional `u32` and `i64` doc fields.
pub(crate) const NONE_U32: u32 = u32::MAX;
pub(crate) const NONE_I64: i64 = i64::MIN;

const MAGIC: &[u8; 8] = b"CMXSEG02";
const HEADER_BYTES: u64 = 8 + 5 * 8;
const DOC_RECORD: usize = 41;
const BLOCK_RECORD: usize = 14;

/// One doc's metadata. Strings are interned in the engine.
#[derive(Clone, Copy, Debug)]
pub(crate) struct DocMeta {
    pub kind: u8,
    pub source: u32,
    pub target: u32,
    pub title: u32,
    pub key: u32,
    pub position: i64,
    pub at_ms: i64,
    /// Offset of the text in the segment's text.
    pub start: u32,
    pub len: u32,
}

/// One block: docs `first_doc..end_doc`, a bit per kind they hold, and where
/// its text starts (it ends where the next block's starts).
#[derive(Clone, Copy, Debug)]
pub(crate) struct BlockMeta {
    pub first_doc: u32,
    pub end_doc: u32,
    pub kinds: u16,
    pub text_start: u32,
}

/// Where a sealed image lives.
pub(crate) enum Store {
    Memory(Vec<u8>),
    File { file: File, path: PathBuf },
}

impl Store {
    fn read(&self, offset: u64, len: usize, out: &mut Vec<u8>) -> io::Result<()> {
        out.clear();
        match self {
            Self::Memory(bytes) => {
                let start = usize::try_from(offset).map_err(invalid)?;
                let slice = start
                    .checked_add(len)
                    .and_then(|end| bytes.get(start..end))
                    .ok_or_else(|| invalid("segment read is out of range"))?;
                out.extend_from_slice(slice);
                Ok(())
            }
            Self::File { file, .. } => {
                out.resize(len, 0);
                read_exact_at(file, out, offset)
            }
        }
    }

    fn len(&self) -> u64 {
        match self {
            Self::Memory(bytes) => bytes.len() as u64,
            Self::File { file, .. } => file.metadata().map_or(0, |meta| meta.len()),
        }
    }
}

#[cfg(unix)]
fn read_exact_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<()> {
    use std::os::unix::fs::FileExt;
    file.read_exact_at(buf, offset)
}

#[cfg(windows)]
fn read_exact_at(file: &File, mut buf: &mut [u8], mut offset: u64) -> io::Result<()> {
    use std::os::windows::fs::FileExt;
    while !buf.is_empty() {
        let read = file.seek_read(buf, offset)?;
        if read == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        buf = &mut buf[read..];
        offset += read as u64;
    }
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn read_exact_at(_file: &File, _buf: &mut [u8], _offset: u64) -> io::Result<()> {
    Err(io::ErrorKind::Unsupported.into())
}

pub(crate) fn invalid(error: impl ToString) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

/// The live segment.
pub(crate) struct Live {
    pub id: u64,
    text: Vec<u8>,
    docs: Vec<DocMeta>,
    blocks: Vec<BlockMeta>,
    postings: HashMap<u32, Vec<u32>>,
    deleted: Vec<u64>,
}

/// A sealed segment: tables in memory, the rest in its image.
pub(crate) struct Sealed {
    pub id: u64,
    pub store: Store,
    text_len: u64,
    doc_count: u32,
    docs_at: u64,
    data_at: u64,
    blocks: Vec<BlockMeta>,
    keys: Vec<u32>,
    counts: Vec<u32>,
    offsets: Vec<u32>,
    pub deleted: Vec<u64>,
}

pub(crate) enum Segment {
    /// Takes appends. Only the engine holds its `Arc` (so `Arc::get_mut`
    /// always succeeds) until it is frozen.
    Live(Arc<Live>),
    /// Full and being sealed off the engine's lock: read-only, shared with a
    /// `SealJob`, its own deleted bits (a keyed replace can hit it).
    Frozen(Arc<Live>, Vec<u64>),
    Sealed(Sealed),
}

/// Scratch the live segment reuses across appends: a bit per trigram seen
/// in the open block, and the trigrams to clear when it closes.
pub(crate) struct LiveScratch {
    seen: Vec<u64>,
    touched: Vec<u32>,
    folded: Vec<u8>,
}

impl LiveScratch {
    pub fn new() -> Self {
        Self { seen: vec![0; (1 << 24) / 64], touched: Vec::new(), folded: Vec::new() }
    }

    pub fn resident_bytes(&self) -> usize {
        self.seen.capacity() * 8 + self.touched.capacity() * 4 + self.folded.capacity()
    }

    fn clear(&mut self) {
        for key in self.touched.drain(..) {
            self.seen[(key >> 6) as usize] &= !(1u64 << (key & 63));
        }
    }
}

/// A block read for verification: its docs and its text.
#[derive(Default)]
pub(crate) struct BlockData {
    pub docs: Vec<DocMeta>,
    pub text: Vec<u8>,
    /// Segment text offset of `text[0]`.
    pub base: u32,
    raw: Vec<u8>,
}

impl BlockData {
    pub fn doc_text(&self, doc: &DocMeta) -> &str {
        let start = doc.start.saturating_sub(self.base) as usize;
        let bytes = self.text.get(start..start + doc.len as usize).unwrap_or_default();
        // Docs are appended from `&str`, so each range is whole UTF-8.
        std::str::from_utf8(bytes).unwrap_or_default()
    }
}

impl Live {
    pub fn new(id: u64) -> Self {
        Self {
            id,
            text: Vec::new(),
            docs: Vec::new(),
            blocks: Vec::new(),
            postings: HashMap::new(),
            deleted: Vec::new(),
        }
    }

    /// Appends `text` as a doc with `meta` (its `start` and `len` are set
    /// here), indexes its trigrams, and returns the doc's index.
    pub fn append(
        &mut self,
        mut meta: DocMeta,
        text: &str,
        block_bytes: usize,
        scratch: &mut LiveScratch,
    ) -> u32 {
        let open_new = match self.blocks.last() {
            None => true,
            Some(block) => self.text.len() - block.text_start as usize >= block_bytes,
        };
        if open_new {
            scratch.clear();
            self.blocks.push(BlockMeta {
                first_doc: self.docs.len() as u32,
                end_doc: self.docs.len() as u32,
                kinds: 0,
                text_start: self.text.len() as u32,
            });
        }
        let block_id = (self.blocks.len() - 1) as u32;
        meta.start = self.text.len() as u32;
        meta.len = text.len() as u32;
        self.text.extend_from_slice(text.as_bytes());
        let doc = self.docs.len() as u32;
        let block = &mut self.blocks[block_id as usize];
        block.end_doc = doc + 1;
        block.kinds |= 1 << meta.kind;
        self.docs.push(meta);
        if self.deleted.len() * 64 <= doc as usize {
            self.deleted.push(0);
        }
        crate::fold::fold_into(text, &mut scratch.folded);
        for window in scratch.folded.windows(3) {
            let key = trigram::key(window[0], window[1], window[2]);
            let word = &mut scratch.seen[(key >> 6) as usize];
            let bit = 1u64 << (key & 63);
            if *word & bit == 0 {
                *word |= bit;
                scratch.touched.push(key);
                self.postings.entry(key).or_default().push(block_id);
            }
        }
        doc
    }

    /// The sealed image of this segment.
    pub fn encode(&self) -> Vec<u8> {
        let mut entries: Vec<(&u32, &Vec<u32>)> = self.postings.iter().collect();
        entries.sort_unstable_by_key(|(key, _)| **key);
        let mut data = Vec::new();
        let mut keys = Vec::with_capacity(entries.len());
        let mut counts = Vec::with_capacity(entries.len());
        let mut offsets = Vec::with_capacity(entries.len() + 1);
        for (key, ids) in entries {
            keys.push(*key);
            counts.push(ids.len() as u32);
            offsets.push(data.len() as u32);
            trigram::encode(ids, &mut data);
        }
        offsets.push(data.len() as u32);
        let mut out = Vec::with_capacity(
            HEADER_BYTES as usize
                + self.text.len()
                + self.docs.len() * DOC_RECORD
                + self.blocks.len() * BLOCK_RECORD
                + keys.len() * 12
                + data.len()
                + 4,
        );
        out.extend_from_slice(MAGIC);
        for size in [self.text.len(), self.docs.len(), self.blocks.len(), keys.len(), data.len()] {
            out.extend_from_slice(&(size as u64).to_le_bytes());
        }
        out.extend_from_slice(&self.text);
        for doc in &self.docs {
            out.push(doc.kind);
            for value in [doc.source, doc.target, doc.title, doc.key, doc.start, doc.len] {
                out.extend_from_slice(&value.to_le_bytes());
            }
            out.extend_from_slice(&doc.position.to_le_bytes());
            out.extend_from_slice(&doc.at_ms.to_le_bytes());
        }
        for block in &self.blocks {
            for value in [block.first_doc, block.end_doc, block.text_start] {
                out.extend_from_slice(&value.to_le_bytes());
            }
            out.extend_from_slice(&block.kinds.to_le_bytes());
        }
        for list in [&keys, &counts, &offsets] {
            for value in list.iter() {
                out.extend_from_slice(&value.to_le_bytes());
            }
        }
        out.extend_from_slice(&data);
        out
    }

    pub fn deleted(&self) -> &[u64] {
        &self.deleted
    }

    pub fn text_len(&self) -> usize {
        self.text.len()
    }

    pub fn doc_count(&self) -> usize {
        self.docs.len()
    }
}

impl Sealed {
    /// Opens an image, reading its tables into memory.
    pub fn open(id: u64, store: Store, deleted: Vec<u64>) -> io::Result<Self> {
        let mut header = Vec::new();
        store.read(0, HEADER_BYTES as usize, &mut header)?;
        if header.get(..8) != Some(&MAGIC[..]) {
            return Err(invalid("not a cmux search segment"));
        }
        let size = |index: usize| {
            let mut bytes = [0u8; 8];
            bytes.copy_from_slice(&header[8 + index * 8..16 + index * 8]);
            u64::from_le_bytes(bytes)
        };
        let (text_len, doc_count, block_count, key_count, data_len) =
            (size(0), size(1), size(2), size(3), size(4));
        let docs_at = HEADER_BYTES.checked_add(text_len);
        let blocks_at =
            docs_at.and_then(|at| at.checked_add(doc_count.checked_mul(DOC_RECORD as u64)?));
        let keys_at =
            blocks_at.and_then(|at| at.checked_add(block_count.checked_mul(BLOCK_RECORD as u64)?));
        let data_at =
            keys_at.and_then(|at| at.checked_add(key_count.checked_mul(12)?.checked_add(4)?));
        let (Some(docs_at), Some(blocks_at), Some(data_at)) = (docs_at, blocks_at, data_at) else {
            return Err(invalid("segment sizes overflow"));
        };
        if data_at.checked_add(data_len) != Some(store.len())
            || doc_count > u64::from(u32::MAX)
            || text_len > u64::from(u32::MAX)
        {
            return Err(invalid("segment sizes do not match its length"));
        }
        let mut tables = Vec::new();
        store.read(blocks_at, (data_at - blocks_at) as usize, &mut tables)?;
        let u32_at = |at: usize| {
            let mut bytes = [0u8; 4];
            bytes.copy_from_slice(&tables[at..at + 4]);
            u32::from_le_bytes(bytes)
        };
        let mut blocks = Vec::with_capacity(block_count as usize);
        for index in 0..block_count as usize {
            let at = index * BLOCK_RECORD;
            let block = BlockMeta {
                first_doc: u32_at(at),
                end_doc: u32_at(at + 4),
                text_start: u32_at(at + 8),
                kinds: u16::from_le_bytes([tables[at + 12], tables[at + 13]]),
            };
            if block.first_doc > block.end_doc
                || u64::from(block.end_doc) > doc_count
                || u64::from(block.text_start) > text_len
            {
                return Err(invalid("segment block is out of range"));
            }
            blocks.push(block);
        }
        let list = |start: usize, count: usize| -> Vec<u32> {
            (0..count).map(|index| u32_at(start + index * 4)).collect()
        };
        let keys_start = block_count as usize * BLOCK_RECORD;
        let key_count = key_count as usize;
        let keys = list(keys_start, key_count);
        let counts = list(keys_start + key_count * 4, key_count);
        let offsets = list(keys_start + key_count * 8, key_count + 1);
        if offsets.windows(2).any(|pair| pair[0] > pair[1])
            || offsets.last().is_some_and(|&last| u64::from(last) > data_len)
        {
            return Err(invalid("segment postings are out of range"));
        }
        Ok(Self {
            id,
            store,
            text_len,
            doc_count: doc_count as u32,
            docs_at,
            data_at,
            blocks,
            keys,
            counts,
            offsets,
            deleted,
        })
    }
}

impl Segment {
    pub fn id(&self) -> u64 {
        match self {
            Self::Live(live) | Self::Frozen(live, _) => live.id,
            Self::Sealed(sealed) => sealed.id,
        }
    }

    pub fn doc_count(&self) -> usize {
        match self {
            Self::Live(live) | Self::Frozen(live, _) => live.docs.len(),
            Self::Sealed(sealed) => sealed.doc_count as usize,
        }
    }

    pub fn blocks(&self) -> &[BlockMeta] {
        match self {
            Self::Live(live) | Self::Frozen(live, _) => &live.blocks,
            Self::Sealed(sealed) => &sealed.blocks,
        }
    }

    pub fn text_len(&self) -> usize {
        match self {
            Self::Live(live) | Self::Frozen(live, _) => live.text.len(),
            Self::Sealed(sealed) => sealed.text_len as usize,
        }
    }

    /// Postings, doc and block tables, wherever they live (not the text).
    pub fn index_bytes(&self) -> usize {
        match self {
            Self::Live(live) | Self::Frozen(live, _) => {
                live.docs.len() * DOC_RECORD
                    + live.blocks.len() * BLOCK_RECORD
                    + live.postings.values().map(|ids| ids.len() * 2).sum::<usize>()
                    + live.postings.len() * 12
            }
            Self::Sealed(sealed) => {
                sealed.store.len().saturating_sub(HEADER_BYTES + sealed.text_len) as usize
            }
        }
    }

    /// Bytes this segment holds in process memory (the page cache aside).
    pub fn resident_bytes(&self) -> usize {
        match self {
            Self::Live(live) | Self::Frozen(live, _) => {
                live.text.capacity()
                    + live.docs.capacity() * size_of::<DocMeta>()
                    + live.blocks.capacity() * size_of::<BlockMeta>()
                    + live.deleted.capacity() * 8
                    + live.postings.values().map(|ids| ids.capacity() * 4 + 32).sum::<usize>()
                    + live.postings.capacity() * 8
            }
            Self::Sealed(sealed) => {
                let tables = sealed.blocks.capacity() * size_of::<BlockMeta>()
                    + (sealed.keys.capacity()
                        + sealed.counts.capacity()
                        + sealed.offsets.capacity())
                        * 4
                    + sealed.deleted.capacity() * 8;
                tables
                    + match &sealed.store {
                        Store::Memory(bytes) => bytes.capacity(),
                        Store::File { .. } => 0,
                    }
            }
        }
    }

    pub fn deleted_bits(&self) -> &[u64] {
        match self {
            Self::Live(live) => &live.deleted,
            Self::Frozen(_, deleted) => deleted,
            Self::Sealed(sealed) => &sealed.deleted,
        }
    }

    pub fn is_deleted(&self, doc: u32) -> bool {
        self.deleted_bits()
            .get((doc >> 6) as usize)
            .is_some_and(|word| word & (1 << (doc & 63)) != 0)
    }

    pub fn delete(&mut self, doc: u32) {
        let bits = match self {
            Self::Live(live) => match Arc::get_mut(live) {
                Some(live) => &mut live.deleted,
                None => return,
            },
            Self::Frozen(_, deleted) => deleted,
            Self::Sealed(sealed) => &mut sealed.deleted,
        };
        let index = (doc >> 6) as usize;
        if bits.len() <= index {
            bits.resize(index + 1, 0);
        }
        bits[index] |= 1 << (doc & 63);
    }

    /// Reads block `block_id`'s docs and text into `out`.
    pub fn load_block(&self, block_id: u32, out: &mut BlockData) -> io::Result<()> {
        let blocks = self.blocks();
        let block = *blocks.get(block_id as usize).ok_or_else(|| invalid("no such block"))?;
        let end = blocks
            .get(block_id as usize + 1)
            .map_or(self.text_len() as u32, |next| next.text_start);
        out.base = block.text_start;
        out.docs.clear();
        out.text.clear();
        match self {
            Self::Live(live) | Self::Frozen(live, _) => {
                let docs = live.docs.get(block.first_doc as usize..block.end_doc as usize);
                let text = live.text.get(block.text_start as usize..end as usize);
                let (Some(docs), Some(text)) = (docs, text) else {
                    return Err(invalid("live block is out of range"));
                };
                out.docs.extend_from_slice(docs);
                out.text.extend_from_slice(text);
            }
            Self::Sealed(sealed) => {
                let count = (block.end_doc - block.first_doc) as usize;
                sealed.store.read(
                    sealed.docs_at + u64::from(block.first_doc) * DOC_RECORD as u64,
                    count * DOC_RECORD,
                    &mut out.raw,
                )?;
                for record in out.raw.chunks_exact(DOC_RECORD) {
                    out.docs.push(decode_doc(record));
                }
                if out.docs.iter().any(|doc| {
                    doc.start < block.text_start
                        || u64::from(doc.start) + u64::from(doc.len) > u64::from(end)
                }) {
                    return Err(invalid("segment doc is out of its block"));
                }
                sealed.store.read(
                    HEADER_BYTES + u64::from(block.text_start),
                    end.saturating_sub(block.text_start) as usize,
                    &mut out.text,
                )?;
            }
        }
        Ok(())
    }

    /// The blocks that may hold every trigram of `keys`, ascending; `None`
    /// when `keys` is empty (every block may).
    pub fn candidates(&self, keys: &[u32], buffer: &mut Vec<u32>) -> io::Result<Option<Vec<u32>>> {
        if keys.is_empty() {
            return Ok(None);
        }
        match self {
            Self::Live(live) | Self::Frozen(live, _) => {
                let mut lists: Vec<&Vec<u32>> = Vec::with_capacity(keys.len());
                for key in keys {
                    match live.postings.get(key) {
                        Some(list) => lists.push(list),
                        None => return Ok(Some(Vec::new())),
                    }
                }
                lists.sort_unstable_by_key(|list| list.len());
                let mut result = lists[0].clone();
                for list in &lists[1..] {
                    if result.is_empty() {
                        break;
                    }
                    trigram::intersect(&mut result, list);
                }
                Ok(Some(result))
            }
            Self::Sealed(sealed) => {
                let mut found: Vec<(u32, usize)> = Vec::with_capacity(keys.len());
                for key in keys {
                    match sealed.keys.binary_search(key) {
                        Ok(index) => found.push((sealed.counts[index], index)),
                        Err(_) => return Ok(Some(Vec::new())),
                    }
                }
                found.sort_unstable();
                let mut raw = Vec::new();
                let mut read = |index: usize, out: &mut Vec<u32>| -> io::Result<()> {
                    let start = sealed.offsets[index];
                    let end = sealed.offsets[index + 1];
                    sealed.store.read(
                        sealed.data_at + u64::from(start),
                        end.saturating_sub(start) as usize,
                        &mut raw,
                    )?;
                    trigram::decode(&raw, sealed.counts[index] as usize, out);
                    Ok(())
                };
                let mut result = Vec::new();
                read(found[0].1, &mut result)?;
                for &(_, index) in &found[1..] {
                    if result.is_empty() {
                        break;
                    }
                    read(index, buffer)?;
                    trigram::intersect(&mut result, buffer);
                }
                Ok(Some(result))
            }
        }
    }
}

fn decode_doc(record: &[u8]) -> DocMeta {
    let u32_at = |at: usize| {
        let mut bytes = [0u8; 4];
        bytes.copy_from_slice(&record[at..at + 4]);
        u32::from_le_bytes(bytes)
    };
    let i64_at = |at: usize| {
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&record[at..at + 8]);
        i64::from_le_bytes(bytes)
    };
    DocMeta {
        kind: record[0],
        source: u32_at(1),
        target: u32_at(5),
        title: u32_at(9),
        key: u32_at(13),
        start: u32_at(17),
        len: u32_at(21),
        position: i64_at(25),
        at_ms: i64_at(33),
    }
}
