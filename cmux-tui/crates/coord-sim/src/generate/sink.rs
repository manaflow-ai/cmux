//! Streaming writers: a script file, an acpmux session directory (segments rolled the way acpmux's
//! `LocalStore::append_line` rolls them), attachment files. Memory stays constant: a line's filler is
//! copied from one shared buffer in chunks, never built whole.

use super::render::Line;
use super::sha256::Sha256;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

/// acpmux's default `store.segmentBytes` (`config/store_config.rs`).
pub const SEGMENT_BYTES: u64 = 8 * 1024 * 1024;

/// One megabyte of `event::filler` text that every line's filler is cut from, at an offset its seq picks.
pub struct FillerPool(Vec<u8>);

impl FillerPool {
    pub fn new(seed: u64) -> FillerPool {
        FillerPool(crate::event::filler(seed, 1 << 20).into_bytes())
    }

    pub fn write(&self, w: &mut impl Write, mut n: u64, pick: u64) -> std::io::Result<()> {
        let len = self.0.len() as u64;
        if len == 0 {
            return Ok(());
        }
        let mut at = (pick.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 20) % len;
        while n > 0 {
            let take = (len - at).min(n);
            if let Some(part) = self.0.get(at as usize..(at + take) as usize) {
                w.write_all(part)?;
            }
            n -= take;
            at = 0;
        }
        Ok(())
    }
}

fn io(path: &Path) -> impl Fn(std::io::Error) -> String + '_ {
    move |e| format!("{}: {e}", path.display())
}

/// Creates `dir` and its missing parents owner-only (0700), as acpmux keeps its state: the daemon refuses
/// a home with a writable ancestor that is not sticky.
pub fn mkdirs(dir: &Path) -> Result<(), String> {
    let mut b = std::fs::DirBuilder::new();
    b.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut b, 0o700);
    b.create(dir).map_err(io(dir))
}

/// A new file only its owner reads (0600), truncated if it is there.
fn private_file(path: &Path) -> std::io::Result<File> {
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut o, 0o600);
    o.open(path)
}

pub fn create(path: &Path) -> Result<BufWriter<File>, String> {
    if let Some(dir) = path.parent() {
        mkdirs(dir)?;
    }
    let f = private_file(path).map_err(io(path))?;
    Ok(BufWriter::with_capacity(1 << 20, f))
}

/// One chat's `events/NNNNNN.ndjson`, from `000001`, a new segment once the open one holds
/// `segment_bytes` or more.
pub struct SegmentWriter {
    dir: PathBuf,
    segment_bytes: u64,
    index: u32,
    written: u64,
    file: Option<BufWriter<File>>,
    pub total: u64,
    pub segments: u32,
}

impl SegmentWriter {
    pub fn new(session_dir: &Path, segment_bytes: u64) -> SegmentWriter {
        SegmentWriter {
            dir: session_dir.join("events"),
            segment_bytes: segment_bytes.max(64 * 1024),
            index: 0,
            written: 0,
            file: None,
            total: 0,
            segments: 0,
        }
    }

    pub fn write(&mut self, line: &Line, pool: &FillerPool, pick: u64) -> Result<(), String> {
        if self.file.is_none() || self.written >= self.segment_bytes {
            if let Some(mut f) = self.file.take() {
                f.flush().map_err(|e| format!("{}: {e}", self.dir.display()))?;
            }
            self.index += 1;
            self.segments += 1;
            self.written = 0;
            let path = self.dir.join(format!("{:06}.ndjson", self.index));
            self.file = Some(create(&path)?);
        }
        let dir = self.dir.clone();
        let Some(f) = self.file.as_mut() else { return Err("no open segment".into()) };
        let err = |e: std::io::Error| format!("{}: {e}", dir.display());
        f.write_all(line.head().as_bytes()).map_err(err)?;
        pool.write(f, line.fill, pick).map_err(err)?;
        f.write_all(line.tail().as_bytes()).map_err(err)?;
        f.write_all(b"\n").map_err(err)?;
        let n = line.len();
        self.written += n;
        self.total += n;
        Ok(())
    }

    pub fn finish(&mut self) -> Result<(), String> {
        if let Some(mut f) = self.file.take() {
            f.flush().map_err(|e| format!("{}: {e}", self.dir.display()))?;
        }
        Ok(())
    }
}

/// An attachment under `<home>/attachments/<sha256>`: a PNG signature then filler, `bytes` long.
/// Returns its id (the hash).
pub fn write_attachment(
    home: &Path,
    bytes: u64,
    pool: &FillerPool,
    pick: u64,
) -> Result<String, String> {
    let dir = home.join("attachments");
    mkdirs(&dir)?;
    let tmp = dir.join(format!(".coord-sim-{pick:016x}.tmp"));
    let mut sha = Sha256::default();
    {
        let mut f = create(&tmp)?;
        let magic: &[u8] = b"\x89PNG\r\n\x1a\n";
        let head = magic.get(..(bytes as usize).min(magic.len())).unwrap_or(magic);
        f.write_all(head).map_err(io(&tmp))?;
        sha.update(head);
        let mut tee = Tee { w: &mut f, sha: &mut sha };
        pool.write(&mut tee, bytes.saturating_sub(head.len() as u64), pick).map_err(io(&tmp))?;
        f.flush().map_err(io(&tmp))?;
    }
    let id = sha.hex();
    let path = dir.join(&id);
    std::fs::rename(&tmp, &path).map_err(io(&path))?;
    Ok(id)
}

struct Tee<'a, W: Write> {
    w: &'a mut W,
    sha: &'a mut Sha256,
}

impl<W: Write> Write for Tee<'_, W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.w.write(buf)?;
        self.sha.update(buf.get(..n).unwrap_or(buf));
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.w.flush()
    }
}

/// Writes `path` whole, through a temporary file beside it.
pub fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    {
        let mut f = create(&tmp)?;
        f.write_all(text.as_bytes()).map_err(io(&tmp))?;
        f.flush().map_err(io(&tmp))?;
    }
    std::fs::rename(&tmp, path).map_err(io(path))
}
