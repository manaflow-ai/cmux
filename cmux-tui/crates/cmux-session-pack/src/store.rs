//! The chunk store: `<root>/chunks/<aa>/<id>` and `<root>/sessions/<name>.json`.
//!
//! A chunk file is `[codec][kind][length before compression, u32 LE]` and then the bytes, zstd
//! (codec 1) or as they are (codec 0, when zstd gained nothing: a PNG). Its id is
//! BLAKE3(kind, bytes before compression). A chunk is written beside its name and renamed into
//! place, and never changed after.

use crate::Result;
use std::fs;
use std::io::{Read as _, Write as _};
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
/// The largest uncompressed chunk this crate will encode or decode.
///
/// This is also the upper bound passed to zstd when a received chunk declares its
/// expanded size.  Bundle and peer readers apply a corresponding bound to the
/// stored representation before allocating it.
pub(crate) const MAX_CHUNK_BYTES: usize = 256 << 20;
pub(crate) const MAX_STORED_CHUNK_BYTES: usize = MAX_CHUNK_BYTES + HEADER;
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
    if payload.len() > MAX_CHUNK_BYTES {
        return Err(format!(
            "a chunk of {} bytes is over the {} byte chunk limit",
            payload.len(),
            MAX_CHUNK_BYTES
        )
        .into());
    }
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
    if file.len() > MAX_STORED_CHUNK_BYTES {
        return Err(format!(
            "a chunk file of {} bytes is over the {} byte chunk limit",
            file.len(),
            MAX_STORED_CHUNK_BYTES
        )
        .into());
    }
    let len = u32::from_le_bytes([a, b, c, d]) as usize;
    if len > MAX_CHUNK_BYTES {
        return Err(format!(
            "a chunk expands to {len} bytes, over the {} byte chunk limit",
            MAX_CHUNK_BYTES
        )
        .into());
    }
    let payload = match codec {
        CODEC_RAW => {
            if body.len() != len {
                return Err(format!("a raw chunk says {len} bytes and holds {}", body.len()).into());
            }
            body.to_vec()
        }
        CODEC_ZSTD => {
            let mut d = zstd::stream::read::Decoder::new(body)?;
            d.window_log_max(27)?;
            let mut payload = Vec::with_capacity(len.min(64 << 10));
            (&mut d).take(len as u64).read_to_end(&mut payload)?;
            if payload.len() != len || d.read(&mut [0u8; 1])? != 0 {
                return Err(
                    format!("a zstd chunk does not expand to its declared {len} bytes").into()
                );
            }
            payload
        }
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
        let path = self.chunk_path(id);
        if fs::read(&path).is_ok_and(|local| local == file) {
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
    let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
    tmp.write_all(bytes)?;
    tmp.as_file().sync_data()?;
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{CODEC_RAW, CODEC_ZSTD, KIND_EVENTS, decode_chunk, encode_chunk};

    #[test]
    fn rejects_expanded_lengths_before_allocating() {
        for codec in [CODEC_RAW, CODEC_ZSTD] {
            let mut file = vec![codec, KIND_EVENTS];
            file.extend_from_slice(&u32::MAX.to_le_bytes());
            let err = decode_chunk(&file).unwrap_err().to_string();
            assert!(err.contains("chunk limit"), "{err}");
        }
    }

    #[test]
    fn rejects_raw_body_length_before_copying() {
        let mut file = vec![CODEC_RAW, KIND_EVENTS];
        file.extend_from_slice(&4u32.to_le_bytes());
        file.extend_from_slice(b"too short");
        let err = decode_chunk(&file).unwrap_err().to_string();
        assert!(err.contains("raw chunk"), "{err}");
    }

    #[test]
    fn compressed_chunks_reject_mutated_lengths_and_truncated_frames() {
        let payload = vec![b'x'; 100_000];
        let valid = encode_chunk(KIND_EVENTS, &payload, 3).unwrap();
        assert_eq!(valid[0], CODEC_ZSTD);
        assert_eq!(decode_chunk(&valid).unwrap().1, payload);
        for len in [0u32, 1, 99_999, 100_001, 128 << 20, 256 << 20, u32::MAX] {
            let mut bad = valid.clone();
            bad[2..6].copy_from_slice(&len.to_le_bytes());
            assert!(decode_chunk(&bad).is_err(), "declared length {len}");
        }
        for end in 0..valid.len() {
            assert!(decode_chunk(&valid[..end]).is_err(), "cut {end}");
        }
    }

    #[test]
    fn compressed_chunks_reject_a_window_above_128_mib() {
        // A zstd frame without a content size, window descriptor 0x90 = 256 MiB,
        // followed by an empty final raw block. The decoded payload is empty.
        let mut file = vec![CODEC_ZSTD, KIND_EVENTS, 0, 0, 0, 0];
        file.extend_from_slice(&[0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x90, 1, 0, 0]);
        assert!(decode_chunk(&file).is_err());
    }
}
