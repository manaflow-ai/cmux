//! The chunk store: `<root>/chunks/<aa>/<id>` and `<root>/sessions/<name>.json`.
//!
//! A chunk file is `[codec][kind][length before compression, u32 LE]` and then the bytes, zstd
//! (codec 1) or as they are (codec 0, when zstd gained nothing: a PNG). Its id is
//! BLAKE3(kind, bytes before compression). A chunk is written beside its name and renamed into
//! place, and never changed after. The chunk file, the layout and the atomic write are
//! `cmux-cas`'s ([`cmux_cas::DiskStore`]); a session pack adds its manifests and the kind byte
//! in its ids.

use crate::Result;
use cmux_cas::ChunkStore as _;
use std::fs;
use std::path::{Path, PathBuf};

pub use cmux_cas::store::MISSING;
pub use cmux_cas::{decode_chunk, encode_chunk, hex, unhex, write_atomic};

/// A chunk's id.
pub type Id = [u8; 32];

/// An events chunk.
pub const KIND_EVENTS: u8 = b'E';
/// A blobs chunk.
pub const KIND_BLOBS: u8 = b'B';
/// A blob table chunk.
pub const KIND_TABLE: u8 = b'T';

/// The id of a chunk of `kind` holding `payload`.
pub fn chunk_id(kind: u8, payload: &[u8]) -> Id {
    let mut h = blake3::Hasher::new();
    h.update(&[kind]);
    h.update(payload);
    *h.finalize().as_bytes()
}

/// A store's folder.
#[derive(Debug, Clone)]
pub struct Store {
    chunks: cmux_cas::DiskStore,
}

impl Store {
    /// The store in `root` (made by the first write).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { chunks: cmux_cas::DiskStore::new(root) }
    }

    /// The store's folder.
    pub fn root(&self) -> &Path {
        self.chunks.root()
    }

    fn chunk_path(&self, id: &Id) -> PathBuf {
        self.chunks.chunk_path(id)
    }

    /// Where `name`'s manifest is.
    pub fn manifest_path(&self, name: &str) -> PathBuf {
        self.root().join("sessions").join(format!("{name}.json"))
    }

    /// Whether the store holds chunk `id`.
    pub fn has(&self, id: &Id) -> bool {
        self.chunks.has(id)
    }

    /// The size of chunk `id`'s file.
    pub fn stored_len(&self, id: &Id) -> Result<u64> {
        self.chunks.stored_len(id)
    }

    /// Chunk `id`'s file, as it is on disk.
    pub fn stored(&self, id: &Id) -> Result<Vec<u8>> {
        // A store that began from a session's tail lacks older chunks until it asks for them
        // (the error starts with [`MISSING`]).
        self.chunks.stored(id)
    }

    /// Chunk `id`'s bytes before compression.
    pub fn get(&self, id: &Id) -> Result<Vec<u8>> {
        Ok(decode_chunk(&self.stored(id)?).map_err(|e| format!("chunk {}: {e}", hex(id)))?.1)
    }

    /// Writes a chunk file under `id` unless it is there. The caller made `file` from the bytes
    /// `id` names ([`encode_chunk`]) or checked it against them ([`decode_chunk`]).
    pub fn put_stored(&self, id: &Id, file: &[u8]) -> Result<()> {
        self.chunks.put_stored(id, file)
    }

    /// Whether the local file decodes to the requested content id. A torn or damaged
    /// file can be requested again when resuming a transfer.
    pub fn verified(&self, id: &Id) -> Result<bool> {
        let file = match fs::read(self.chunk_path(id)) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(e) => return Err(e.into()),
        };
        Ok(decode_chunk(&file).is_ok_and(|(kind, bytes)| chunk_id(kind, &bytes) == *id))
    }

    /// Accepts a received file only under its content id. Replace any damaged local copy.
    pub fn receive(&self, id: &Id, file: &[u8]) -> Result<()> {
        let (kind, bytes) = decode_chunk(file)?;
        if chunk_id(kind, &bytes) != *id {
            return Err(format!("chunk {} does not hash to its id", hex(id)).into());
        }
        self.chunks.replace_stored(id, file)
    }

    /// Every chunk id in the store.
    pub fn ids(&self) -> Result<Vec<Id>> {
        self.chunks.ids()
    }
}
