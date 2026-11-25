//! A bundle's manifest: what it is, how long, and its chunks in order.
//!
//! Wire form: `[u8 version = 1][u8 kind][u64 BE total length][u32 BE chunk count]` and then, per chunk,
//! `[32-byte id][u32 BE length]`. The bundle's root id is the pair's keyed hash of those bytes, so two
//! ends name the same bundle the same way and nobody else can.

use crate::store::Store;
use crate::{ChunkId, Error, PairKey, Result, cdc, seal};

/// The manifest's version byte.
pub const VERSION: u8 = 1;
const HEADER: usize = 1 + 1 + 8 + 4;
const ENTRY: usize = 32 + 4;
/// The most chunks one manifest lists (16 GiB at the largest chunk size).
pub const MAX_CHUNKS: usize = 1 << 16;

/// What a bundle carries. Unknown kinds decode (a newer peer's kind) and are carried as `Other`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A file or attachment.
    Attachment,
    /// A page of a session's history.
    HistoryPage,
    /// A projectionfs block run.
    ProjectionBlocks,
    /// A checkpoint (a VM resume image, a session pack).
    Checkpoint,
    /// A kind this build does not name.
    Other(u8),
}

impl Kind {
    fn byte(self) -> u8 {
        match self {
            Self::Attachment => 1,
            Self::HistoryPage => 2,
            Self::ProjectionBlocks => 3,
            Self::Checkpoint => 4,
            Self::Other(b) => b,
        }
    }

    fn from_byte(b: u8) -> Self {
        match b {
            1 => Self::Attachment,
            2 => Self::HistoryPage,
            3 => Self::ProjectionBlocks,
            4 => Self::Checkpoint,
            b => Self::Other(b),
        }
    }
}

/// One chunk of a bundle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChunkRef {
    /// The chunk's id.
    pub id: ChunkId,
    /// Its content length.
    pub len: u32,
}

/// A bundle's manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    /// What the bundle carries.
    pub kind: Kind,
    /// The bundle's length.
    pub total: u64,
    /// Its chunks in order.
    pub chunks: Vec<ChunkRef>,
}

impl Manifest {
    /// Cuts `data` into chunks, seals each one into `store` (skipping those it already holds), and returns
    /// the manifest.
    pub fn build(key: &PairKey, kind: Kind, data: &[u8], store: &mut dyn Store) -> Result<Self> {
        let mut chunks = Vec::new();
        for piece in cdc::chunks(data) {
            let id = key.chunk_id(piece);
            if !store.has(&id) {
                store.put(&id, &seal::seal_with_id(key, &id, piece))?;
            }
            chunks.push(ChunkRef { id, len: piece.len() as u32 });
        }
        if chunks.len() > MAX_CHUNKS {
            return Err(Error::Malformed("bundle too large"));
        }
        Ok(Self { kind, total: data.len() as u64, chunks })
    }

    /// The manifest's wire form.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER + ENTRY * self.chunks.len());
        out.push(VERSION);
        out.push(self.kind.byte());
        out.extend_from_slice(&self.total.to_be_bytes());
        out.extend_from_slice(&(self.chunks.len() as u32).to_be_bytes());
        for c in &self.chunks {
            out.extend_from_slice(&c.id);
            out.extend_from_slice(&c.len.to_be_bytes());
        }
        out
    }

    /// The manifest `bytes` hold; the chunk lengths must sum to the total.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let (&version, _) = bytes.split_first().ok_or(Error::Malformed("manifest"))?;
        if version != VERSION {
            return Err(Error::Version(version));
        }
        let [kind] = field::<1>(bytes, 1)?;
        let kind = Kind::from_byte(kind);
        let total = u64::from_be_bytes(field(bytes, 2)?);
        let count = u32::from_be_bytes(field(bytes, 10)?) as usize;
        if count > MAX_CHUNKS || bytes.len() != HEADER + count * ENTRY {
            return Err(Error::Malformed("manifest length"));
        }
        let mut chunks = Vec::with_capacity(count);
        let mut sum = 0u64;
        let entries = bytes.get(HEADER..).ok_or(Error::Malformed("manifest"))?;
        for entry in entries.chunks_exact(ENTRY) {
            let id: ChunkId = field(entry, 0)?;
            let len = u32::from_be_bytes(field(entry, 32)?);
            if len == 0 || len as usize > cdc::MAX {
                return Err(Error::Malformed("chunk length"));
            }
            sum += u64::from(len);
            chunks.push(ChunkRef { id, len });
        }
        if sum != total {
            return Err(Error::Malformed("manifest total"));
        }
        Ok(Self { kind, total, chunks })
    }

    /// The bundle's root id under `key`.
    pub fn root(&self, key: &PairKey) -> ChunkId {
        let mut h = key.id_hasher();
        h.update(b"manifest");
        h.update(&self.encode());
        *h.finalize().as_bytes()
    }

    /// The chunks `store` lacks, in manifest order, each once.
    pub fn lacking(&self, store: &dyn Store) -> Vec<ChunkId> {
        let mut seen = std::collections::HashSet::new();
        self.chunks
            .iter()
            .filter(|c| !store.has(&c.id) && seen.insert(c.id))
            .map(|c| c.id)
            .collect()
    }

    /// The bundle's bytes, opened from `store`; every chunk is checked against its id.
    pub fn assemble(&self, key: &PairKey, store: &dyn Store) -> Result<Vec<u8>> {
        let mut out = Vec::with_capacity(usize::try_from(self.total).unwrap_or(0));
        for c in &self.chunks {
            let sealed = store.get(&c.id)?.ok_or(Error::Missing(c.id))?;
            let content = seal::open(key, &c.id, &sealed)?;
            if content.len() != c.len as usize {
                return Err(Error::Seal);
            }
            out.extend_from_slice(&content);
        }
        Ok(out)
    }
}

/// The `N` bytes of `bytes` at `at`, or a malformed-manifest error when they run short.
fn field<const N: usize>(bytes: &[u8], at: usize) -> Result<[u8; N]> {
    bytes
        .get(at..at.saturating_add(N))
        .and_then(|s| s.try_into().ok())
        .ok_or(Error::Malformed("manifest"))
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemStore;

    #[test]
    fn round_trips_and_assembles() {
        let key = PairKey::derive(&[7; 32]);
        let data: Vec<u8> = (0..300_000u32).flat_map(|i| (i * 7919).to_le_bytes()).collect();
        let mut store = MemStore::default();
        let m = Manifest::build(&key, Kind::Attachment, &data, &mut store).unwrap();
        assert!(m.chunks.len() > 4);
        let decoded = Manifest::decode(&m.encode()).unwrap();
        assert_eq!(decoded, m);
        assert_eq!(decoded.root(&key), m.root(&key));
        assert_eq!(m.assemble(&key, &store).unwrap(), data);
        assert!(m.lacking(&store).is_empty());
        assert_eq!(m.lacking(&MemStore::default()).len(), m.chunks.len());
    }

    #[test]
    fn refuses_bad_forms() {
        assert_eq!(Manifest::decode(&[9]), Err(Error::Version(9)));
        assert!(Manifest::decode(&[1, 1]).is_err());
        let key = PairKey::derive(&[7; 32]);
        let mut store = MemStore::default();
        let m = Manifest::build(&key, Kind::HistoryPage, b"page", &mut store).unwrap();
        let mut bad = m.encode();
        bad[9] ^= 1; // total no longer matches
        assert!(Manifest::decode(&bad).is_err());
        let mut other = m.encode();
        other[1] = 200;
        assert_eq!(Manifest::decode(&other).unwrap().kind, Kind::Other(200));
    }
}
