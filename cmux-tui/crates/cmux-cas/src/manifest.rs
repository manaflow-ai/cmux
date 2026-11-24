//! An artifact's root manifest: its files, each as the ids of its chunks.
//!
//! ```json
//! {"schema": "cmux.cas.v1", "kind": "web-bundle", "ids": "blake3",
//!  "entries": [{"path": "index.html", "mode": 420, "size": 70000,
//!               "chunks": [["<64 hex>", 65536], ["<64 hex>", 4464]]}],
//!  "size": 70000, "total_blake3": "<64 hex>"}
//! ```
//!
//! The manifest's id, its root, is `BLAKE3(manifest bytes)`; a signed [`crate::Pointer`] names
//! it. `total_blake3` is the id, in the manifest's scheme, of every entry's bytes back to back,
//! which [`Manifest::assemble`] checks so the rebuilt artifact is bit-exact. Fields a reader
//! does not know are ignored, so a later schema can add some (the techniques page's `patches`)
//! without breaking a version 1 reader.

use crate::Result;
use crate::cdc::{Chunker, Params};
use crate::id::{Id, IdScheme, hex, unhex};
use crate::store::ChunkStore;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// The schema this build writes and reads.
pub const SCHEMA: &str = "cmux.cas.v1";

/// One file of an artifact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// Its path in the artifact.
    pub path: String,
    /// Its Unix mode bits.
    pub mode: u32,
    /// Its size.
    pub size: u64,
    /// Its chunks, in order: each id (hex) and length.
    pub chunks: Vec<(String, u64)>,
}

/// An artifact's root manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    /// [`SCHEMA`].
    pub schema: String,
    /// What the artifact is (`app-archive`, `web-bundle`, `cloud-binary`, ...).
    pub kind: String,
    /// The id scheme: `blake3` or `blake3-keyed` ([`IdScheme::name`]).
    pub ids: String,
    /// Its files, in order.
    pub entries: Vec<Entry>,
    /// Every entry's size together.
    pub size: u64,
    /// The id of every entry's bytes back to back (hex).
    pub total_blake3: String,
}

impl Manifest {
    /// Chunks `files` (path, mode, bytes) into `store` under `scheme` and returns their manifest.
    /// Each file is chunked on its own, so no chunk spans two files.
    pub fn build(
        kind: &str,
        scheme: &IdScheme,
        files: &[(&str, u32, &[u8])],
        params: Params,
        store: &dyn ChunkStore,
    ) -> Result<Self> {
        let mut entries = Vec::with_capacity(files.len());
        let mut total = hasher(scheme);
        let mut size = 0;
        for &(path, mode, bytes) in files {
            let mut chunks = Vec::new();
            for chunk in Chunker::new(bytes, params) {
                chunks.push((hex(&store.put(scheme, chunk)?), chunk.len() as u64));
            }
            total.update(bytes);
            size += bytes.len() as u64;
            entries.push(Entry { path: path.to_owned(), mode, size: bytes.len() as u64, chunks });
        }
        Ok(Self {
            schema: SCHEMA.to_owned(),
            kind: kind.to_owned(),
            ids: scheme.name().to_owned(),
            entries,
            size,
            total_blake3: hex(total.finalize().as_bytes()),
        })
    }

    /// The manifest's bytes, as its root id names them.
    pub fn to_json(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }

    /// The manifest in `bytes`, when its schema is one this build reads.
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let m: Self = serde_json::from_slice(bytes)?;
        if m.schema != SCHEMA {
            return Err(format!("manifest schema {:?} is not {SCHEMA:?}", m.schema).into());
        }
        Ok(m)
    }

    /// The manifest in `bytes`, only when they hash to `root` (the id a signed pointer named).
    pub fn open(bytes: &[u8], root: &Id) -> Result<Self> {
        if root_of(bytes) != *root {
            return Err(format!("the manifest does not hash to root {}", hex(root)).into());
        }
        Self::parse(bytes)
    }

    /// The manifest's root id.
    pub fn root(&self) -> Result<Id> {
        Ok(root_of(&self.to_json()?))
    }

    /// Every chunk id it names, each once, in order of first use.
    pub fn chunk_ids(&self) -> Result<Vec<Id>> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for entry in &self.entries {
            for (id, _) in &entry.chunks {
                let id = unhex(id)?;
                if seen.insert(id) {
                    out.push(id);
                }
            }
        }
        Ok(out)
    }

    /// Entry `index`'s bytes from `store`, each chunk's length checked.
    pub fn read_entry(&self, store: &dyn ChunkStore, index: usize) -> Result<Vec<u8>> {
        let entry = self.entries.get(index).ok_or("no such entry")?;
        let mut out = Vec::with_capacity(usize::try_from(entry.size).unwrap_or(0));
        for (id, len) in &entry.chunks {
            let bytes = store.get(&unhex(id)?)?;
            if bytes.len() as u64 != *len {
                return Err(format!("chunk {id} is {} bytes, not {len}", bytes.len()).into());
            }
            out.extend_from_slice(&bytes);
        }
        if out.len() as u64 != entry.size {
            return Err(format!("{} is {} bytes, not {}", entry.path, out.len(), entry.size).into());
        }
        Ok(out)
    }

    /// Every entry's bytes back to back, checked against `total_blake3` under `scheme`: the
    /// artifact, bit-exact.
    pub fn assemble(&self, store: &dyn ChunkStore, scheme: &IdScheme) -> Result<Vec<u8>> {
        if self.ids != scheme.name() {
            return Err(
                format!("the manifest's ids are {}, not {}", self.ids, scheme.name()).into()
            );
        }
        let mut out = Vec::with_capacity(usize::try_from(self.size).unwrap_or(0));
        for index in 0..self.entries.len() {
            out.extend_from_slice(&self.read_entry(store, index)?);
        }
        if hex(&scheme.id(&out)) != self.total_blake3 {
            return Err("the assembled artifact does not hash to the manifest's total".into());
        }
        Ok(out)
    }
}

/// The root id of manifest bytes: `BLAKE3(bytes)`.
pub fn root_of(bytes: &[u8]) -> Id {
    *blake3::hash(bytes).as_bytes()
}

fn hasher(scheme: &IdScheme) -> blake3::Hasher {
    match scheme {
        IdScheme::Public => blake3::Hasher::new(),
        IdScheme::Keyed(key) => blake3::Hasher::new_keyed(key),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cdc::tests::noise;
    use crate::store::MemStore;

    #[test]
    fn build_assemble_round_trips_and_forces_file_boundaries() {
        let store = MemStore::new();
        let a = noise(10, 300_000);
        let b = noise(11, 5);
        let c = noise(12, 70_000);
        let files: [(&str, u32, &[u8]); 3] = [("a", 0o755, &a), ("b", 0o644, &b), ("c", 0o644, &c)];
        let m = Manifest::build("test", &IdScheme::Public, &files, Params::CAS_V1, &store).unwrap();
        assert_eq!(m.size, 370_005);
        // Each file starts a chunk: the 5-byte file is a chunk of its own.
        assert_eq!(m.entries[1].chunks.len(), 1);
        assert_eq!(m.entries[1].chunks[0].1, 5);
        assert_eq!(m.read_entry(&store, 2).unwrap(), c);
        assert_eq!(m.assemble(&store, &IdScheme::Public).unwrap(), [a, b, c].concat());
        // Round trip through bytes and its root.
        let bytes = m.to_json().unwrap();
        assert_eq!(Manifest::open(&bytes, &m.root().unwrap()).unwrap(), m);
        assert!(Manifest::open(&bytes, &[0; 32]).is_err());
        // A later schema's extra field is ignored.
        let mut v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        v["patches"] = serde_json::json!([]);
        assert_eq!(Manifest::parse(&serde_json::to_vec(&v).unwrap()).unwrap(), m);
        // Assembling under another scheme is refused.
        assert!(m.assemble(&store, &IdScheme::Keyed([3; 32])).is_err());
    }
}
