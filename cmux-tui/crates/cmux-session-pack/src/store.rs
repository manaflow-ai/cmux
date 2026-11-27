//! The chunk store: `<root>/chunks/<aa>/<id>` and `<root>/sessions/<name>.json`.
//!
//! A chunk file is `[codec][kind][length before compression, u32 LE]` and then the bytes, zstd
//! (codec 1) or as they are (codec 0, when zstd gained nothing: a PNG). Its id is
//! BLAKE3(kind, bytes before compression). A chunk is written beside its name and renamed into
//! place, and never changed after.

use crate::Result;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// A chunk's id.
pub type Id = [u8; 32];

/// An events chunk.
pub const KIND_EVENTS: u8 = b'E';
/// A blobs chunk.
pub const KIND_BLOBS: u8 = b'B';
/// A blob table chunk.
pub const KIND_TABLE: u8 = b'T';

const CODEC_RAW: u8 = 0;
const CODEC_ZSTD: u8 = 1;
const HEADER: usize = 6;
/// zstd's window is 8 MiB at level 19; a chunk larger than that (one huge line) gets a window
/// that covers it, up to the 128 MiB every decoder accepts.
const WINDOW_DEFAULT: usize = 8 << 20;

/// An id as 64 hex digits.
pub fn hex(id: &Id) -> String {
    let mut s = String::with_capacity(64);
    for b in id {
        // A digit under 16 always has a char.
        s.extend(char::from_digit(u32::from(b >> 4), 16));
        s.extend(char::from_digit(u32::from(b & 15), 16));
    }
    s
}

/// The id 64 hex digits name.
pub fn unhex(s: &str) -> Result<Id> {
    let b = s.as_bytes();
    if b.len() != 64 {
        return Err(format!("chunk id {s:?} is not 64 hex digits").into());
    }
    let mut id = [0u8; 32];
    for (slot, [hi, lo]) in id.iter_mut().zip(b.as_chunks::<2>().0) {
        let digit = |c: u8| match c {
            b'0'..=b'9' => Ok(c - b'0'),
            b'a'..=b'f' => Ok(c - b'a' + 10),
            _ => Err(format!("chunk id {s:?} is not 64 hex digits")),
        };
        *slot = digit(*hi)? << 4 | digit(*lo)?;
    }
    Ok(id)
}

/// The id of a chunk of `kind` holding `payload`.
pub fn chunk_id(kind: u8, payload: &[u8]) -> Id {
    let mut h = blake3::Hasher::new();
    h.update(&[kind]);
    h.update(payload);
    *h.finalize().as_bytes()
}

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

/// How the error for a chunk the store lacks starts; the chunk's id follows it.
pub const MISSING: &str = "this store lacks chunk ";

/// A store's folder.
#[derive(Debug, Clone)]
pub struct Store {
    root: PathBuf,
}

impl Store {
    /// The store in `root` (made by the first write).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// The store's folder.
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn chunk_path(&self, id: &Id) -> PathBuf {
        let h = hex(id);
        let dir: String = h.chars().take(2).collect();
        self.root.join("chunks").join(dir).join(h)
    }

    /// Where `name`'s manifest is.
    pub fn manifest_path(&self, name: &str) -> PathBuf {
        self.root.join("sessions").join(format!("{name}.json"))
    }

    /// Whether the store holds chunk `id`.
    pub fn has(&self, id: &Id) -> bool {
        self.chunk_path(id).is_file()
    }

    /// The size of chunk `id`'s file.
    pub fn stored_len(&self, id: &Id) -> Result<u64> {
        let path = self.chunk_path(id);
        Ok(fs::metadata(&path).map_err(|e| format!("{}: {e}", path.display()))?.len())
    }

    /// Chunk `id`'s file, as it is on disk.
    pub fn stored(&self, id: &Id) -> Result<Vec<u8>> {
        let path = self.chunk_path(id);
        fs::read(&path).map_err(|e| match e.kind() {
            // A store that began from a session's tail lacks older chunks until it asks for them.
            std::io::ErrorKind::NotFound => format!("{MISSING}{}", hex(id)).into(),
            _ => format!("{}: {e}", path.display()).into(),
        })
    }

    /// Chunk `id`'s bytes before compression.
    pub fn get(&self, id: &Id) -> Result<Vec<u8>> {
        Ok(decode_chunk(&self.stored(id)?).map_err(|e| format!("chunk {}: {e}", hex(id)))?.1)
    }

    /// Writes a chunk file under `id` unless it is there. The caller made `file` from the bytes
    /// `id` names ([`encode_chunk`]) or checked it against them ([`decode_chunk`]).
    pub fn put_stored(&self, id: &Id, file: &[u8]) -> Result<()> {
        let path = self.chunk_path(id);
        if path.is_file() {
            return Ok(());
        }
        write_atomic(&path, file)
    }

    /// Every chunk id in the store.
    pub fn ids(&self) -> Result<Vec<Id>> {
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

/// Writes `bytes` beside `path` and renames the file into place, so a reader sees the old file or
/// the whole new one.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or("a path with no folder")?;
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let name = path.file_name().and_then(|n| n.to_str()).ok_or("a path with no name")?;
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let mut f = fs::File::create(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
    f.write_all(bytes)?;
    f.sync_data()?;
    drop(f);
    fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(())
}
