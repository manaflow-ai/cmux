//! zstd dictionaries trained per content kind. Small files (most of a source
//! tree) compress poorly alone because each starts with an empty window; a
//! dictionary trained on a sample of their kind gives them a shared start.
//!
//! The sender trains on the folder's own files, sends the dictionary once
//! (it counts against bytes on the wire), then uses it for small chunks.

use std::collections::{BTreeMap, HashMap};
use std::io;
use std::sync::Mutex;

use crate::classify::Kind;
use crate::frame::Dicts;

#[derive(Default)]
pub struct Trained {
    by_id: BTreeMap<u32, Vec<u8>>,
    by_kind: BTreeMap<Kind, u32>,
    /// Prepared dictionaries, made on first use: digesting a 64 KiB dictionary costs more than
    /// compressing a small chunk with it, so doing it per chunk made dictionaries look slow.
    compressors: Mutex<HashMap<(u32, i32), zstd::bulk::Compressor<'static>>>,
    decompressors: Mutex<HashMap<u32, zstd::bulk::Decompressor<'static>>>,
}

impl Dicts for Trained {
    fn get(&self, id: u32) -> Option<&[u8]> {
        self.by_id.get(&id).map(Vec::as_slice)
    }

    fn compress(&self, id: u32, level: i32, raw: &[u8]) -> Option<Vec<u8>> {
        let mut cache = self.compressors.lock().unwrap_or_else(|e| e.into_inner());
        let c = match cache.entry((id, level)) {
            std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
            std::collections::hash_map::Entry::Vacant(e) => {
                e.insert(zstd::bulk::Compressor::with_dictionary(level, self.get(id)?).ok()?)
            }
        };
        c.compress(raw).ok()
    }

    fn decompress(&self, id: u32, payload: &[u8], raw_len: usize) -> io::Result<Vec<u8>> {
        let mut cache = self.decompressors.lock().unwrap_or_else(|e| e.into_inner());
        let d = match cache.entry(id) {
            std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
            std::collections::hash_map::Entry::Vacant(e) => {
                let dict = self.get(id).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "unknown dictionary")
                })?;
                e.insert(zstd::bulk::Decompressor::with_dictionary(dict)?)
            }
        };
        d.decompress(payload, raw_len)
    }
}

impl Trained {
    /// Trains one dictionary per kind from `samples` (kind, bytes), when a kind has enough of them.
    /// Kinds with under 32 samples or 64 KiB of sample bytes get none.
    pub fn train<'a>(samples: impl Iterator<Item = (Kind, &'a [u8])>, dict_bytes: usize) -> Self {
        let mut grouped: BTreeMap<Kind, Vec<&[u8]>> = BTreeMap::new();
        for (kind, bytes) in samples {
            if matches!(kind, Kind::Compressed) || bytes.is_empty() {
                continue;
            }
            let group = grouped.entry(kind).or_default();
            if group.len() < 4000 {
                group.push(bytes.get(..bytes.len().min(16 * 1024)).unwrap_or_default());
            }
        }
        let mut out = Self::default();
        for (kind, group) in grouped {
            let total: usize = group.iter().map(|s| s.len()).sum();
            if group.len() < 32 || total < 64 * 1024 {
                continue;
            }
            if let Ok(dict) = zstd::dict::from_samples(&group, dict_bytes.min(total / 4)) {
                let id = out.by_id.len() as u32 + 1;
                out.by_id.insert(id, dict);
                out.by_kind.insert(kind, id);
            }
        }
        out
    }

    pub fn for_kind(&self, kind: Kind) -> Option<u32> {
        self.by_kind.get(&kind).copied()
    }

    /// Bytes the dictionaries cost to send.
    pub fn wire_bytes(&self) -> u64 {
        self.by_id.values().map(|d| d.len() as u64 + 8).sum()
    }
}
