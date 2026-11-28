//! The local chunk store: `<root>/<aa>/<id>`, each file `[codec][len u32 LE]` and the bytes,
//! zstd (codec 1) or as they are (codec 0, when zstd gained nothing). Written beside its name
//! and renamed into place, never changed after; read back only after its id checks.

use crate::{Id, Result};
use std::io::Write as _;
use std::path::{Path, PathBuf};

const CODEC_RAW: u8 = 0;
const CODEC_ZSTD: u8 = 1;
const HEADER: usize = 5;
/// The zstd level chunks are written at: 19 is what `cmux-session-pack` ships at; the
/// producer pays once, every client reads it.
pub const LEVEL: i32 = 19;

/// A chunk file of `bytes`: the smaller of zstd and the bytes as they are.
pub fn encode(bytes: &[u8], level: i32) -> Result<Vec<u8>> {
    let z = zstd::bulk::compress(bytes, level)?;
    let (codec, body) =
        if z.len() < bytes.len() { (CODEC_ZSTD, z.as_slice()) } else { (CODEC_RAW, bytes) };
    let mut out = Vec::with_capacity(HEADER + body.len());
    out.push(codec);
    out.extend_from_slice(&u32::try_from(bytes.len())?.to_le_bytes());
    out.extend_from_slice(body);
    Ok(out)
}

/// The bytes a chunk file holds, refused unless they are `id`.
pub fn decode(file: &[u8], id: &Id) -> Result<Vec<u8>> {
    let [codec, a, b, c, d, body @ ..] = file else {
        return Err(format!("chunk {id} is cut short").into());
    };
    let len = u32::from_le_bytes([*a, *b, *c, *d]) as usize;
    if len > crate::cdc::MAX {
        return Err(format!("chunk {id} claims {len} bytes").into());
    }
    let bytes = match *codec {
        CODEC_RAW => body.to_vec(),
        CODEC_ZSTD => zstd::bulk::decompress(body, len)?,
        c => return Err(format!("chunk {id} has unknown codec {c}").into()),
    };
    if bytes.len() != len || Id::of(&bytes) != *id {
        return Err(format!("chunk {id} does not hash to its id").into());
    }
    Ok(bytes)
}

/// A directory of chunk files.
#[derive(Clone, Debug)]
pub struct Store {
    root: PathBuf,
}

impl Store {
    /// The store at `root` (made on first write).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    fn path(&self, id: &Id) -> PathBuf {
        let hex = id.hex();
        self.root.join(hex.chars().take(2).collect::<String>()).join(hex)
    }

    /// Whether it holds `id`.
    pub fn has(&self, id: &Id) -> bool {
        self.path(id).is_file()
    }

    /// The bytes of `id`, checked.
    pub fn get(&self, id: &Id) -> Result<Vec<u8>> {
        decode(&std::fs::read(self.path(id))?, id)
    }

    /// Store `bytes` as `id` (checked), compressed at [`LEVEL`].
    pub fn put(&self, id: &Id, bytes: &[u8]) -> Result<()> {
        if Id::of(bytes) != *id {
            return Err(format!("bytes are not chunk {id}").into());
        }
        self.put_file(id, &encode(bytes, LEVEL)?)
    }

    /// Store a chunk file received from a peer or a pack, after checking it decodes to `id`.
    pub fn receive(&self, id: &Id, file: &[u8]) -> Result<()> {
        decode(file, id)?;
        self.put_file(id, file)
    }

    /// The chunk file of `id` as stored (compressed), to send to a peer that checks it with
    /// [`Store::receive`]. Not checked here: the receiver checks every file it takes.
    pub fn file(&self, id: &Id) -> Result<Vec<u8>> {
        Ok(std::fs::read(self.path(id))?)
    }

    fn put_file(&self, id: &Id, file: &[u8]) -> Result<()> {
        let path = self.path(id);
        if path.is_file() {
            return Ok(());
        }
        let dir = path.parent().ok_or("a chunk path has no parent")?;
        std::fs::create_dir_all(dir)?;
        write_atomic(dir, &path, file)
    }

    /// Its root.
    pub fn root(&self) -> &Path {
        &self.root
    }
}

/// Write `bytes` beside `path` in `dir` and rename it into place.
pub fn write_atomic(dir: &Path, path: &Path, bytes: &[u8]) -> Result<()> {
    let mut tmp = tempfile_in(dir)?;
    tmp.1.write_all(bytes)?;
    tmp.1.sync_all()?;
    std::fs::rename(&tmp.0, path)?;
    Ok(())
}

fn tempfile_in(dir: &Path) -> Result<(PathBuf, std::fs::File)> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let name = format!(".tmp-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed));
    let path = dir.join(name);
    let f = std::fs::OpenOptions::new().write(true).create_new(true).open(&path)?;
    Ok((path, f))
}
