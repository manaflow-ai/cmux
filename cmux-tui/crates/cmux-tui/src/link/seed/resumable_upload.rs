//! Resumable, parallel upload of one file (a snapshot bundle) from the laptop straight to the
//! per-user store (RFD 0066, "What to build next" 10): a cut-off upload carries on from the
//! parts the store already has instead of starting over, and the VM is not kept awake to
//! receive it.
//!
//! - **Parts.** The file is cut into fixed-size parts ([`PART_SIZE`]); each is sent whole and
//!   named by its index, size and sha256. A part the store holds is never a torn one: the store
//!   makes a part visible only when it is whole.
//! - **Resume without a local record.** The store is the record. [`upload`] asks the store which
//!   parts it holds for this upload ([`PartStore::list`]), re-reads each of those locally and
//!   keeps a part only when its size and sha256 match, then sends the rest, up to `parallel` at
//!   a time. A part that differs (the file changed, or a bad part) is sent again.
//! - **Identity.** An upload is named by the key, the file's size and mtime, and the part size
//!   ([`upload_id`]), so an edited file never resumes into another file's parts.
//! - **Completion.** [`PartStore::complete`] gets the whole ordered list of part digests, makes the
//!   object at `key` in one step (the object is never seen half-made) and drops the parts. A
//!   second `complete` of an object whose digest is already there is a no-op, so a cut-off
//!   between "assembled" and "answered" resumes cleanly.
//!
//! The real store needs infrastructure that is not built (RFD 0067's lane); [`DirPartStore`] (a
//! folder) stands in for tests and drills, and the switch [`ENV`] keeps the module off until
//! something calls it.

use std::io::{Read as _, Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use anyhow::{Context as _, bail};
use sha2::{Digest as _, Sha256};

/// The switch for the direct upload (off by default).
pub(crate) const ENV: &str = "CMUX_LINK_RESUMABLE_UPLOAD";

/// Whether the direct upload is on ([`ENV`] is `1` or `true`).
pub(crate) fn enabled() -> bool {
    matches!(std::env::var(ENV).ok().as_deref(), Some("1" | "true"))
}

/// The size of one part: 8 MiB, so a 17 GB bundle is ~2,000 parts and a cut-off loses at most
/// one part per connection.
pub(crate) const PART_SIZE: u64 = 8 * 1024 * 1024;

/// One part the store holds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Part {
    pub(crate) index: u32,
    pub(crate) size: u64,
    pub(crate) sha256: String,
}

/// The store's side of a multipart upload.
pub(crate) trait PartStore: Sync {
    /// Makes `bytes` the part `index` of `upload`, visible only once whole.
    fn put(&self, upload: &str, index: u32, bytes: &[u8]) -> anyhow::Result<()>;
    /// The parts of `upload` the store holds.
    fn list(&self, upload: &str) -> anyhow::Result<Vec<Part>>;
    /// Makes the object `key` from `parts` (in order) in one step, then drops the parts.
    /// `digest` is [`object_digest`] of them; an object already there with it is left as is.
    fn complete(&self, upload: &str, key: &str, parts: &[Part], digest: &str)
    -> anyhow::Result<()>;
}

/// What an [`upload`] did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Outcome {
    pub(crate) parts: usize,
    /// Parts the store already had whole (kept from an earlier, cut-off upload).
    pub(crate) resumed: usize,
    /// Parts sent now.
    pub(crate) sent: usize,
    pub(crate) bytes_sent: u64,
    pub(crate) digest: String,
}

/// The upload's name: key, size, mtime and part size, hashed.
pub(crate) fn upload_id(key: &str, size: u64, mtime_ns: u128, part_size: u64) -> String {
    let mut hash = Sha256::new();
    for field in
        [key.as_bytes(), &size.to_le_bytes(), &mtime_ns.to_le_bytes(), &part_size.to_le_bytes()]
    {
        hash.update((field.len() as u64).to_le_bytes());
        hash.update(field);
    }
    hex(&hash.finalize())
}

/// The digest of the whole object: sha256 over the parts' sizes and digests in order.
pub(crate) fn object_digest(parts: &[Part]) -> String {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update(part.size.to_le_bytes());
        hash.update(part.sha256.as_bytes());
    }
    hex(&hash.finalize())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn read_part(
    file: &mut std::fs::File,
    index: u32,
    part_size: u64,
    total: u64,
) -> anyhow::Result<Vec<u8>> {
    let start = u64::from(index) * part_size;
    let len = part_size.min(total - start);
    let mut bytes = vec![0u8; len as usize];
    file.seek(SeekFrom::Start(start))?;
    file.read_exact(&mut bytes).with_context(|| format!("cannot read part {index}"))?;
    Ok(bytes)
}

fn digest_of(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// Uploads `file` as `key` to `store` in `part_size` parts, `parallel` at a time, carrying on
/// from the parts the store already holds. Any failure leaves the sent parts in the store for
/// the next call; it never leaves a partial object at `key`.
pub(crate) fn upload(
    store: &dyn PartStore,
    key: &str,
    file: &Path,
    part_size: u64,
    parallel: usize,
) -> anyhow::Result<Outcome> {
    if part_size == 0 {
        bail!("part size must be above zero");
    }
    let meta =
        std::fs::metadata(file).with_context(|| format!("cannot read {}", file.display()))?;
    let total = meta.len();
    let mtime_ns = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |since| since.as_nanos());
    let id = upload_id(key, total, mtime_ns, part_size);
    let count = usize::try_from(total.div_ceil(part_size)).context("file too large")?;
    let held = store.list(&id)?;

    // Hash every part (reading the file once), keeping the store's copy only on an exact match.
    let mut parts = Vec::with_capacity(count);
    let mut todo = Vec::new();
    {
        let mut reader = std::fs::File::open(file)?;
        for index in 0..count as u32 {
            let bytes = read_part(&mut reader, index, part_size, total)?;
            let part = Part { index, size: bytes.len() as u64, sha256: digest_of(&bytes) };
            if !held.iter().any(|have| *have == part) {
                todo.push(index);
            }
            parts.push(part);
        }
    }
    let resumed = count - todo.len();

    let next = AtomicUsize::new(0);
    let failure: Mutex<Option<anyhow::Error>> = Mutex::new(None);
    let sent = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..parallel.clamp(1, todo.len().max(1)) {
            scope.spawn(|| {
                let run = || -> anyhow::Result<()> {
                    let mut reader = std::fs::File::open(file)?;
                    loop {
                        if failure.lock().map_or(true, |f| f.is_some()) {
                            return Ok(());
                        }
                        let slot = next.fetch_add(1, Ordering::SeqCst);
                        let Some(&index) = todo.get(slot) else { return Ok(()) };
                        let bytes = read_part(&mut reader, index, part_size, total)?;
                        store.put(&id, index, &bytes).with_context(|| format!("part {index}"))?;
                        sent.fetch_add(1, Ordering::SeqCst);
                    }
                };
                if let Err(error) = run() {
                    if let Ok(mut slot) = failure.lock() {
                        slot.get_or_insert(error);
                    }
                }
            });
        }
    });
    if let Some(error) = failure.into_inner().ok().flatten() {
        return Err(error.context("upload cut off; the parts sent stay for the next try"));
    }

    let digest = object_digest(&parts);
    store.complete(&id, key, &parts, &digest)?;
    let bytes_sent =
        todo.iter().filter_map(|&index| parts.get(index as usize)).map(|part| part.size).sum();
    Ok(Outcome { parts: count, resumed, sent: sent.load(Ordering::SeqCst), bytes_sent, digest })
}

/// The store as a folder: tests, drills and a local stand-in until the real store is built.
/// Parts are `uploads/<id>/<index>-<size>-<sha256>`, written under a `.tmp` name and renamed;
/// the object at `<key>` is made the same way and carries `<key>.digest` beside it.
pub(crate) struct DirPartStore(pub PathBuf);

impl DirPartStore {
    fn dir(&self, upload: &str) -> PathBuf {
        self.0.join("uploads").join(upload)
    }
}

impl PartStore for DirPartStore {
    fn put(&self, upload: &str, index: u32, bytes: &[u8]) -> anyhow::Result<()> {
        let dir = self.dir(upload);
        std::fs::create_dir_all(&dir)?;
        let name = format!("{index}-{}-{}", bytes.len(), digest_of(bytes));
        let part = dir.join(format!("{name}.{index}.tmp"));
        let mut out = std::fs::File::create(&part)?;
        out.write_all(bytes)?;
        out.sync_all()?;
        std::fs::rename(&part, dir.join(name))?;
        Ok(())
    }

    fn list(&self, upload: &str) -> anyhow::Result<Vec<Part>> {
        let mut parts = Vec::new();
        let entries = match std::fs::read_dir(self.dir(upload)) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(parts),
            Err(error) => return Err(error.into()),
        };
        for entry in entries {
            let name = entry?.file_name().to_string_lossy().into_owned();
            let mut fields = name.splitn(3, '-');
            if let (Some(index), Some(size), Some(sha256)) =
                (fields.next(), fields.next(), fields.next())
            {
                if let (Ok(index), Ok(size)) = (index.parse(), size.parse()) {
                    if !sha256.contains('.') {
                        parts.push(Part { index, size, sha256: sha256.to_string() });
                    }
                }
            }
        }
        Ok(parts)
    }

    fn complete(
        &self,
        upload: &str,
        key: &str,
        parts: &[Part],
        digest: &str,
    ) -> anyhow::Result<()> {
        let object = self.0.join(key);
        let sidecar = self.0.join(format!("{key}.digest"));
        if std::fs::read_to_string(&sidecar).is_ok_and(|have| have == digest) && object.is_file() {
            let _ = std::fs::remove_dir_all(self.dir(upload));
            return Ok(());
        }
        std::fs::create_dir_all(object.parent().context("no store folder")?)?;
        let tmp = self.0.join(format!("{key}.assembling"));
        let mut out = std::fs::File::create(&tmp)?;
        for part in parts {
            let path =
                self.dir(upload).join(format!("{}-{}-{}", part.index, part.size, part.sha256));
            let mut bytes = Vec::new();
            std::fs::File::open(&path)
                .with_context(|| format!("part {} is missing", part.index))?
                .read_to_end(&mut bytes)?;
            if digest_of(&bytes) != part.sha256 {
                bail!("part {} is not whole", part.index);
            }
            out.write_all(&bytes)?;
        }
        out.sync_all()?;
        std::fs::rename(&tmp, &object)?;
        std::fs::write(&sidecar, digest)?;
        std::fs::remove_dir_all(self.dir(upload))?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "resumable_upload_tests.rs"]
mod tests;
