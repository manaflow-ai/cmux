//! A segment: docs packed into blocks of about `block_bytes` of text, and a
//! trigram -> block posting list per trigram. The newest segment is live
//! (takes appends, postings in a hash map); older ones are sealed
//! (postings as sorted keys and delta + varint lists).

use std::collections::HashMap;

use crate::trigram;

/// No value, for the optional `u32` and `i64` doc fields.
pub(crate) const NONE_U32: u32 = u32::MAX;
pub(crate) const NONE_I64: i64 = i64::MIN;

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
    pub start: u32,
    pub len: u32,
}

/// One block: docs `first_doc..end_doc`, and a bit per kind they hold.
#[derive(Clone, Copy, Debug)]
pub(crate) struct BlockMeta {
    pub first_doc: u32,
    pub end_doc: u32,
    pub kinds: u16,
    pub text_start: u32,
}

pub(crate) enum Postings {
    Live(HashMap<u32, Vec<u32>>),
    Sealed { keys: Vec<u32>, counts: Vec<u32>, offsets: Vec<u32>, data: Vec<u8> },
}

pub(crate) struct Segment {
    pub text: Vec<u8>,
    pub docs: Vec<DocMeta>,
    pub blocks: Vec<BlockMeta>,
    pub postings: Postings,
    /// A bit per doc: replaced (keyed upsert) or removed.
    pub deleted: Vec<u64>,
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

    fn clear(&mut self) {
        for key in self.touched.drain(..) {
            self.seen[(key >> 6) as usize] &= !(1u64 << (key & 63));
        }
    }
}

impl Segment {
    pub fn new_live() -> Self {
        Self {
            text: Vec::new(),
            docs: Vec::new(),
            blocks: Vec::new(),
            postings: Postings::Live(HashMap::new()),
            deleted: Vec::new(),
        }
    }

    pub fn is_sealed(&self) -> bool {
        matches!(self.postings, Postings::Sealed { .. })
    }

    /// Appends `text` as a doc with `meta` (its `start` and `len` are set
    /// here) and indexes its trigrams. Returns the doc's index; `None` for a
    /// sealed segment, which takes no appends.
    pub fn append(
        &mut self,
        mut meta: DocMeta,
        text: &str,
        block_bytes: usize,
        scratch: &mut LiveScratch,
    ) -> Option<u32> {
        let Postings::Live(postings) = &mut self.postings else { return None };
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
        let folded = &scratch.folded;
        for window in folded.windows(3) {
            let key = trigram::key(window[0], window[1], window[2]);
            let word = &mut scratch.seen[(key >> 6) as usize];
            let bit = 1u64 << (key & 63);
            if *word & bit == 0 {
                *word |= bit;
                scratch.touched.push(key);
                postings.entry(key).or_default().push(block_id);
            }
        }
        Some(doc)
    }

    /// Text bytes held.
    pub fn text_len(&self) -> usize {
        self.text.len()
    }

    /// Turns the live postings into the sealed form.
    pub fn seal(&mut self, scratch: &mut LiveScratch) {
        scratch.clear();
        let Postings::Live(live) = &mut self.postings else { return };
        let mut entries: Vec<(u32, Vec<u32>)> = std::mem::take(live).into_iter().collect();
        entries.sort_unstable_by_key(|(key, _)| *key);
        let mut keys = Vec::with_capacity(entries.len());
        let mut counts = Vec::with_capacity(entries.len());
        let mut offsets = Vec::with_capacity(entries.len() + 1);
        let mut data = Vec::new();
        for (key, ids) in entries {
            keys.push(key);
            counts.push(ids.len() as u32);
            offsets.push(data.len() as u32);
            trigram::encode(&ids, &mut data);
        }
        offsets.push(data.len() as u32);
        self.postings = Postings::Sealed { keys, counts, offsets, data };
        self.text.shrink_to_fit();
        self.docs.shrink_to_fit();
        self.blocks.shrink_to_fit();
    }

    /// Bytes the postings and doc and block tables take (not the text).
    pub fn index_bytes(&self) -> usize {
        let tables = self.docs.len() * size_of::<DocMeta>()
            + self.blocks.len() * size_of::<BlockMeta>()
            + self.deleted.len() * 8;
        tables
            + match &self.postings {
                Postings::Live(map) => map.values().map(|ids| ids.len() * 4 + 16).sum::<usize>(),
                Postings::Sealed { keys, counts, offsets, data } => {
                    (keys.len() + counts.len() + offsets.len()) * 4 + data.len()
                }
            }
    }

    pub fn is_deleted(&self, doc: u32) -> bool {
        self.deleted.get((doc >> 6) as usize).is_some_and(|word| word & (1 << (doc & 63)) != 0)
    }

    pub fn delete(&mut self, doc: u32) {
        if let Some(word) = self.deleted.get_mut((doc >> 6) as usize) {
            *word |= 1 << (doc & 63);
        }
    }

    pub fn doc_text(&self, doc: &DocMeta) -> &str {
        let bytes = &self.text[doc.start as usize..(doc.start + doc.len) as usize];
        // Docs are appended from `&str`, so each range is whole UTF-8.
        std::str::from_utf8(bytes).unwrap_or_default()
    }

    /// The blocks that may hold every trigram of `keys`, ascending; `None`
    /// when `keys` is empty (every block may).
    pub fn candidates(&self, keys: &[u32], buffer: &mut Vec<u32>) -> Option<Vec<u32>> {
        if keys.is_empty() {
            return None;
        }
        match &self.postings {
            Postings::Live(map) => {
                let mut lists: Vec<&Vec<u32>> = Vec::with_capacity(keys.len());
                for key in keys {
                    match map.get(key) {
                        Some(list) => lists.push(list),
                        None => return Some(Vec::new()),
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
                Some(result)
            }
            Postings::Sealed { keys: table, counts, offsets, data } => {
                let mut found: Vec<(u32, usize)> = Vec::with_capacity(keys.len());
                for key in keys {
                    match table.binary_search(key) {
                        Ok(index) => found.push((counts[index], index)),
                        Err(_) => return Some(Vec::new()),
                    }
                }
                found.sort_unstable();
                let list = |index: usize, out: &mut Vec<u32>| {
                    let range = offsets[index] as usize..offsets[index + 1] as usize;
                    trigram::decode(&data[range], counts[index] as usize, out);
                };
                let mut result = Vec::new();
                list(found[0].1, &mut result);
                for &(_, index) in &found[1..] {
                    if result.is_empty() {
                        break;
                    }
                    list(index, buffer);
                    trigram::intersect(&mut result, buffer);
                }
                Some(result)
            }
        }
    }
}
