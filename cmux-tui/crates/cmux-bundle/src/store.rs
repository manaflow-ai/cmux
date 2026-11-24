//! Where sealed chunks live. A store holds only ciphertext, keyed by chunk id; it never needs the pair's
//! key, so the same trait backs a phone's cache, a Mac's disk and a client for the relay's chunk cache.

use crate::{ChunkId, Result, hex};
use std::collections::HashMap;
use std::path::PathBuf;

/// A store of sealed chunks.
pub trait Store {
    /// Whether the store holds `id`.
    fn has(&self, id: &ChunkId) -> bool;
    /// The sealed chunk filed under `id`, if any.
    fn get(&self, id: &ChunkId) -> Result<Option<Vec<u8>>>;
    /// Files `sealed` under `id` (a second put of the same id may be skipped).
    fn put(&mut self, id: &ChunkId, sealed: &[u8]) -> Result<()>;
}

/// Sealed chunks in memory.
#[derive(Debug, Default, Clone)]
pub struct MemStore {
    chunks: HashMap<ChunkId, Vec<u8>>,
}

impl MemStore {
    /// How many chunks it holds.
    pub fn len(&self) -> usize {
        self.chunks.len()
    }

    /// Whether it holds none.
    pub fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    /// Sealed bytes it holds in total.
    pub fn bytes(&self) -> usize {
        self.chunks.values().map(Vec::len).sum()
    }
}

impl Store for MemStore {
    fn has(&self, id: &ChunkId) -> bool {
        self.chunks.contains_key(id)
    }

    fn get(&self, id: &ChunkId) -> Result<Option<Vec<u8>>> {
        Ok(self.chunks.get(id).cloned())
    }

    fn put(&mut self, id: &ChunkId, sealed: &[u8]) -> Result<()> {
        self.chunks.entry(*id).or_insert_with(|| sealed.to_vec());
        Ok(())
    }
}

/// Sealed chunks as files: `<root>/<first two hex digits>/<64 hex digits>`, written beside their name
/// and renamed into place, never changed after.
#[derive(Debug, Clone)]
pub struct DirStore {
    root: PathBuf,
}

impl DirStore {
    /// A store under `root` (made on the first put).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    fn path(&self, id: &ChunkId) -> PathBuf {
        let name = hex(id);
        self.root.join(name.get(..2).unwrap_or("00")).join(name)
    }
}

impl Store for DirStore {
    fn has(&self, id: &ChunkId) -> bool {
        self.path(id).is_file()
    }

    fn get(&self, id: &ChunkId) -> Result<Option<Vec<u8>>> {
        match std::fs::read(self.path(id)) {
            Ok(b) => Ok(Some(b)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    fn put(&mut self, id: &ChunkId, sealed: &[u8]) -> Result<()> {
        let path = self.path(id);
        if path.is_file() {
            return Ok(());
        }
        let dir = path.parent().unwrap_or(&self.root);
        std::fs::create_dir_all(dir)?;
        let tmp = dir.join(format!(".{}.{}", hex(id), std::process::id()));
        std::fs::write(&tmp, sealed)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dir_store_round_trips() {
        let dir = std::env::temp_dir().join(format!("cmux-bundle-store-{}", std::process::id()));
        let mut s = DirStore::new(&dir);
        let id = [0xab; 32];
        assert!(!s.has(&id));
        assert_eq!(s.get(&id).unwrap(), None);
        s.put(&id, b"sealed").unwrap();
        s.put(&id, b"ignored").unwrap();
        assert_eq!(s.get(&id).unwrap().as_deref(), Some(&b"sealed"[..]));
        std::fs::remove_dir_all(&dir).ok();
    }
}
