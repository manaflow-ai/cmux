//! The chunk store, in memory ([`MemStore`]) or on disk ([`DiskStore`]).
//!
//! A chunk file is `[codec][kind][length before compression, u32 LE]` and then the bytes, zstd
//! (codec 1) or as they are (codec 0, when zstd gained nothing: a PNG). On disk it is at
//! `<root>/chunks/<aa>/<id>`, written beside its name and renamed into place, and never changed
//! after. This is `cmux-session-pack`'s chunk file and layout, which that crate now takes from
//! here; its ids hash the kind byte too, `cas/1` ids hash the bytes alone ([`crate::IdScheme`]).
//!
//! A store keeps a chunk only under the id its bytes hash to ([`ChunkStore::receive`]): that is
//! the whole of `cas/1`'s trust in a peer.

use crate::Result;
use crate::id::{Id, IdScheme, hex, unhex};
use std::collections::HashMap;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

/// The kind byte of a `cas/1` chunk in its file.
pub const KIND_CAS: u8 = b'C';

const CODEC_RAW: u8 = 0;
const CODEC_ZSTD: u8 = 1;
const HEADER: usize = 6;
/// zstd's window is 8 MiB at level 19; a chunk larger than that (one huge line) gets a window
/// that covers it, up to the 128 MiB every decoder accepts.
const WINDOW_DEFAULT: usize = 8 << 20;
/// The zstd level `cas/1` stores chunks at.
pub const LEVEL: i32 = 3;

/// How the error for a chunk the store lacks starts; the chunk's id follows it.
pub const MISSING: &str = "this store lacks chunk ";

/// A chunk as its file holds it: header and compressed bytes.
pub fn encode_chunk(kind: u8, payload: &[u8], level: i32) -> Result<Vec<u8>> {
    let len = u32::try_from(payload.len()).map_err(|_| {
        format!("a chunk of {} bytes is over the 4 GiB a chunk holds", payload.len())
    })?;
    let mut c = zstd::bulk::Compressor::new(level)?;
    if payload.len() > WINDOW_DEFAULT {
        let log = usize::BITS - (payload.len() - 1).leading_zeros();
        c.set_parameter(zstd::zstd_safe::CParameter::WindowLog(log.min(27)))?;
        c.set_parameter(zstd::zstd_safe::CParameter::EnableLongDistanceMatching(true))?;
    }
    let z = c.compress(payload)?;
    let (codec, body) =
        if z.len() < payload.len() { (CODEC_ZSTD, &z[..]) } else { (CODEC_RAW, payload) };
    let mut out = Vec::with_capacity(HEADER + body.len());
    out.push(codec);
    out.push(kind);
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(body);
    Ok(out)
}

/// A chunk file's kind and its bytes before compression.
pub fn decode_chunk(file: &[u8]) -> Result<(u8, Vec<u8>)> {
    let &[codec, kind, a, b, c, d, ref body @ ..] = file else {
        return Err("a chunk file is shorter than its header".into());
    };
    let len = u32::from_le_bytes([a, b, c, d]) as usize;
    let payload = match codec {
        CODEC_RAW => body.to_vec(),
        CODEC_ZSTD => zstd::bulk::Decompressor::new()?.decompress(body, len)?,
        other => {
            return Err(
                format!("a chunk file has codec {other}, which this build does not read").into()
            );
        }
    };
    if payload.len() != len {
        return Err(format!("a chunk file says {len} bytes and holds {}", payload.len()).into());
    }
    Ok((kind, payload))
}

/// Writes `bytes` beside `path` and renames the file into place, so a reader sees the old file or
/// the whole new one.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or("a path with no folder")?;
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
    tmp.write_all(bytes)?;
    tmp.as_file().sync_data()?;
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}

/// Where chunks are kept, by id, as chunk files.
pub trait ChunkStore {
    /// Whether the store holds chunk `id`.
    fn has(&self, id: &Id) -> bool;
    /// Chunk `id`'s file, as the store holds it (compressed).
    fn stored(&self, id: &Id) -> Result<Vec<u8>>;
    /// Keeps a chunk file under `id` unless one is there. The caller made `file` from the bytes
    /// `id` names or checked it against them.
    fn put_stored(&self, id: &Id, file: &[u8]) -> Result<()>;
    /// Every chunk id in the store, sorted.
    fn ids(&self) -> Result<Vec<Id>>;

    /// Chunk `id`'s bytes before compression.
    fn get(&self, id: &Id) -> Result<Vec<u8>> {
        Ok(decode_chunk(&self.stored(id)?).map_err(|e| format!("chunk {}: {e}", hex(id)))?.1)
    }

    /// Keeps `bytes` under their id in `scheme` and returns the id.
    fn put(&self, scheme: &IdScheme, bytes: &[u8]) -> Result<Id> {
        let id = scheme.id(bytes);
        if !self.has(&id) {
            self.put_stored(&id, &encode_chunk(KIND_CAS, bytes, LEVEL)?)?;
        }
        Ok(id)
    }

    /// Accepts bytes a peer sent for `id` only when they hash to it in `scheme`; a peer that
    /// sent anything else is lying or broken and its bytes are dropped.
    fn receive(&self, scheme: &IdScheme, id: &Id, bytes: &[u8]) -> Result<()> {
        if scheme.id(bytes) != *id {
            return Err(format!("chunk {} does not hash to its id", hex(id)).into());
        }
        if !self.has(id) {
            self.put_stored(id, &encode_chunk(KIND_CAS, bytes, LEVEL)?)?;
        }
        Ok(())
    }
}

/// A store in memory: tests, and a peer's working set.
#[derive(Debug, Default)]
pub struct MemStore {
    chunks: RwLock<HashMap<Id, Vec<u8>>>,
}

impl MemStore {
    /// An empty store.
    pub fn new() -> Self {
        Self::default()
    }

    /// The total size of the chunk files held.
    pub fn stored_bytes(&self) -> u64 {
        self.chunks.read().map_or(0, |c| c.values().map(|f| f.len() as u64).sum())
    }
}

impl ChunkStore for MemStore {
    fn has(&self, id: &Id) -> bool {
        self.chunks.read().is_ok_and(|c| c.contains_key(id))
    }

    fn stored(&self, id: &Id) -> Result<Vec<u8>> {
        let chunks = self.chunks.read().map_err(|_| "the store's lock is poisoned")?;
        chunks.get(id).cloned().ok_or_else(|| format!("{MISSING}{}", hex(id)).into())
    }

    fn put_stored(&self, id: &Id, file: &[u8]) -> Result<()> {
        let mut chunks = self.chunks.write().map_err(|_| "the store's lock is poisoned")?;
        chunks.entry(*id).or_insert_with(|| file.to_vec());
        Ok(())
    }

    fn ids(&self) -> Result<Vec<Id>> {
        let chunks = self.chunks.read().map_err(|_| "the store's lock is poisoned")?;
        let mut out: Vec<Id> = chunks.keys().copied().collect();
        out.sort_unstable();
        Ok(out)
    }
}

/// A store's folder: `<root>/chunks/<aa>/<id>`.
#[derive(Debug, Clone)]
pub struct DiskStore {
    root: PathBuf,
}

impl DiskStore {
    /// The store in `root` (made by the first write).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// The store's folder.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Where chunk `id`'s file is.
    pub fn chunk_path(&self, id: &Id) -> PathBuf {
        let h = hex(id);
        let dir: String = h.chars().take(2).collect();
        self.root.join("chunks").join(dir).join(h)
    }

    /// The size of chunk `id`'s file.
    pub fn stored_len(&self, id: &Id) -> Result<u64> {
        let path = self.chunk_path(id);
        Ok(fs::metadata(&path).map_err(|e| format!("{}: {e}", path.display()))?.len())
    }

    /// Writes `file` under `id`, replacing what is there (a torn or damaged copy).
    pub fn replace_stored(&self, id: &Id, file: &[u8]) -> Result<()> {
        let path = self.chunk_path(id);
        if fs::read(&path).is_ok_and(|local| local == file) {
            return Ok(());
        }
        write_atomic(&path, file)
    }
}

impl ChunkStore for DiskStore {
    fn has(&self, id: &Id) -> bool {
        self.chunk_path(id).is_file()
    }

    fn stored(&self, id: &Id) -> Result<Vec<u8>> {
        let path = self.chunk_path(id);
        fs::read(&path).map_err(|e| match e.kind() {
            // A store that began from part of an artifact lacks the rest until it asks for it.
            std::io::ErrorKind::NotFound => format!("{MISSING}{}", hex(id)).into(),
            _ => format!("{}: {e}", path.display()).into(),
        })
    }

    fn put_stored(&self, id: &Id, file: &[u8]) -> Result<()> {
        let path = self.chunk_path(id);
        if path.is_file() {
            return Ok(());
        }
        write_atomic(&path, file)
    }

    fn ids(&self) -> Result<Vec<Id>> {
        let mut out = Vec::new();
        let Ok(dirs) = fs::read_dir(self.root.join("chunks")) else { return Ok(out) };
        for dir in dirs {
            for f in fs::read_dir(dir?.path())? {
                if let Some(id) = f?.file_name().to_str().and_then(|n| unhex(n).ok()) {
                    out.push(id);
                }
            }
        }
        out.sort_unstable();
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exercise(store: &dyn ChunkStore) {
        let scheme = IdScheme::Public;
        let text = b"hello hello hello hello hello hello hello hello".repeat(100);
        let id = store.put(&scheme, &text).unwrap();
        assert!(store.has(&id));
        assert_eq!(store.get(&id).unwrap(), text);
        // Compressible bytes are kept compressed.
        assert!(store.stored(&id).unwrap().len() < text.len());
        // Bytes that do not hash to the id are refused and nothing is kept.
        let other = scheme.id(b"other");
        assert!(store.receive(&scheme, &other, b"not other").is_err());
        assert!(!store.has(&other));
        store.receive(&scheme, &other, b"other").unwrap();
        assert_eq!(store.get(&other).unwrap(), b"other");
        let mut want = vec![id, other];
        want.sort_unstable();
        assert_eq!(store.ids().unwrap(), want);
        let missing = scheme.id(b"missing");
        assert!(store.get(&missing).unwrap_err().to_string().starts_with(MISSING));
    }

    #[test]
    fn mem_store_keeps_verified_chunks() {
        exercise(&MemStore::new());
    }

    #[test]
    fn disk_store_keeps_verified_chunks() {
        let dir = tempfile::tempdir().unwrap();
        let store = DiskStore::new(dir.path());
        exercise(&store);
        let id = IdScheme::Public.id(b"other");
        assert!(store.chunk_path(&id).starts_with(dir.path().join("chunks")));
        // A second store on the same folder sees the same chunks.
        assert_eq!(DiskStore::new(dir.path()).get(&id).unwrap(), b"other");
    }

    #[test]
    fn chunk_file_round_trips_raw_and_zstd() {
        let random: Vec<u8> =
            (0..4096u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
        for payload in [&b""[..], b"x", &[7u8; 10_000], &random] {
            let file = encode_chunk(KIND_CAS, payload, LEVEL).unwrap();
            assert_eq!(decode_chunk(&file).unwrap(), (KIND_CAS, payload.to_vec()));
        }
        assert!(decode_chunk(&[9, KIND_CAS, 0, 0, 0, 0]).is_err());
        assert!(decode_chunk(&[0, KIND_CAS]).is_err());
    }
}
