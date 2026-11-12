//! Cold archive of an old chat's event log (`hub/cold_archive.rs`): the chat's `events/` folder
//! becomes one zstd file, `<session>/cold.zst`, and comes back byte for byte on the first read.
//!
//! Leo, 2026-11-09: "is there a way for us to compress super hard? potentially auto compress old
//! history to save disk? some sort of cold archival thing, like a TRUE \"archive chat\" type thing
//! that you can stil preview a sliver of".
//!
//! The archive holds every file of `events/` (its segments and a compaction's record), whole and
//! in order, framed by a header that names each file with its length and a trailer with each
//! file's SHA-256, all in one zstd frame with its own checksum. `session.json` stays as it is, so
//! the chat lists from it as before (with the preview the hub keeps there, `SessionMeta::cold`);
//! listing never opens the archive. The search and kind copies beside the log
//! (`store/text_index.rs`, `store/kind_index.rs`) are not kept: they name the segments' inodes,
//! which a rehydrated log does not have, and a later read makes them again.
//!
//! Archiving ([`LocalStore::stage_cold`], [`LocalStore::commit_cold`]) mirrors a retention
//! rewrite (`store/compact.rs`): the archive is written beside the log under a temporary name with
//! no lock held, synced, and decoded back once to check every file against the hashes taken while
//! it was read. The commit, under the writers' lock and only when no segment changed since, renames
//! the archive into place and syncs the folder, then renames `events/` aside and syncs again, then
//! removes what it renamed aside. Rehydrating ([`LocalStore::rehydrate`]) decodes into a folder
//! beside the log, syncs every file, renames it to `events/`, syncs the folder, and only then
//! removes the archive. A crash at any point leaves a whole log or a verified archive:
//!
//! - `events/` with a segment in it is the log, whatever else is there. An archive beside it was
//!   left by a crash before the commit's second rename or before a rehydrate removed it, or the
//!   log is an older build's new one. The archive is removed once each of its files starts the
//!   log's file of that name byte for byte (checked against its hashes,
//!   [`LocalStore::settle_cold`]), and otherwise kept under another name and never read.
//! - No segment and an archive: the chat is archived. Its first read of the log rehydrates it
//!   ([`LocalStore::segments`]); so does its next append, before the line is written.
//! - A temporary archive, a rehydrate's folder or a folder renamed aside is only ever a leftover,
//!   removed by the next archive or rehydrate of that chat.
//!
//! The format is forward-only. An acpmux build before this one does not read `cold.zst` and
//! deletes nothing it does not recognize: it lists an archived idle chat from `session.json` with
//! its history empty, and does not list an archived closed chat at all, since a closed chat with no
//! log reads to it as a purged one (`has_records`). Either way the archive stays as it is, and the
//! chat and its history come back once a build with this change opens the store again.

use super::*;
use sha2::{Digest, Sha256};

/// A cold-archived chat's log, in its folder beside `session.json`.
pub const COLD_FILE: &str = "cold.zst";
/// The folder a rehydrate decodes into, renamed to `events/` once every file is on the disk.
const THAW_DIR: &str = "cold-thaw.tmp";
/// Where a commit renames `events/` before removing it, and a rehydrate any `events/` without a
/// segment that was there.
const DROP_DIR: &str = "events.cold-drop";
/// The header's schema.
const SCHEMA: &str = "acpmux.cold.v1";
/// zstd's strongest level that needs no large window to decode (19). Event logs are JSON lines
/// that repeat their keys and much of their text, so it pays: about 10x on a Claude chat
/// (`store/cold_tests.rs` prints a fixture's numbers). Archiving is rare and runs on a blocking
/// thread, one chat at a time; decoding at any level is fast.
const LEVEL: i32 = 19;
/// The longest header or trailer line read back.
const LINE_MAX: u64 = 4 * 1024 * 1024;

/// [`Store::on_rehydrate`]'s hook.
pub type RehydrateHook = std::sync::Arc<dyn Fn(&str) + Send + Sync>;

#[cfg(test)]
thread_local! {
    /// Tests: a commit on this thread stops right after the archive is in place and synced, before
    /// `events/` is renamed aside: both are there, as after a crash at that point.
    pub(crate) static HOLD_AFTER_COLD_PUBLISH: super::log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: a rehydrate on this thread stops under the cold lock, once it found no segment and
    /// before it decodes.
    pub(crate) static HOLD_BEFORE_THAW: super::log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: a fork's history write on this thread stops right after its log's rehydrate, before
    /// it makes `events/` and writes there (`LocalStore::history_writer`).
    pub(crate) static HOLD_AFTER_HISTORY_REHYDRATE: super::log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: this thread says so, once, right before it takes the cold lock to rehydrate or settle.
    pub(crate) static NOTE_BEFORE_COLD_LOCK: super::log_sync::Note =
        const { std::cell::RefCell::new(None) };
}

/// What archiving a log saved.
#[derive(Debug, Default, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ColdStats {
    /// The log's files, as they were on the disk.
    pub bytes_before: u64,
    /// The archive.
    pub bytes_after: u64,
    pub files: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Header {
    schema: String,
    files: Vec<Entry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Entry {
    name: String,
    len: u64,
}

#[derive(Serialize, Deserialize)]
struct Trailer {
    sha256: Vec<String>,
}

/// An archive written and checked beside a log, not yet in place. Dropping it removes it.
pub struct StagedCold {
    pub stats: ColdStats,
    tmp: PathBuf,
    files: Vec<Entry>,
}

impl Drop for StagedCold {
    fn drop(&mut self) {
        let _ = crate::home_fs::remove_file(&self.tmp);
    }
}

/// A file `events/` may hold in an archived log: a segment or a compaction's record.
fn log_file(name: &str) -> bool {
    name == super::compact::MARKER
        || name
            .strip_suffix(".ndjson")
            .is_some_and(|stem| stem.len() == 6 && stem.bytes().all(|b| b.is_ascii_digit()))
}

fn hex(digest: &[u8]) -> String {
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// Copies `from` to `to` through `hash`; the bytes copied.
fn copy_hashed(from: &mut dyn Read, to: &mut dyn Write, hash: &mut Sha256) -> Result<u64> {
    let mut buf = vec![0u8; 256 * 1024];
    let mut copied = 0u64;
    loop {
        let n = match from.read(&mut buf) {
            Ok(0) => return Ok(copied),
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.into()),
        };
        let read = buf.get(..n).unwrap_or_default();
        hash.update(read);
        to.write_all(read)?;
        copied += n as u64;
    }
}

fn read_line(reader: &mut dyn BufRead, what: &str) -> Result<Vec<u8>> {
    let mut line = Vec::new();
    reader.take(LINE_MAX).read_until(b'\n', &mut line)?;
    anyhow::ensure!(line.last() == Some(&b'\n'), "the cold archive's {what} is cut short");
    line.pop();
    Ok(line)
}

/// Decodes the archive at `path`, handing each file to `open` (a file to write it to, or None to
/// only check it), and checks each file's length and SHA-256 against the header and trailer and
/// that nothing follows. Each file written is synced before the next. The header and the hashes.
fn decode(
    path: &Path,
    open: &mut dyn FnMut(&Entry) -> Result<Option<File>>,
) -> Result<(Header, Vec<String>)> {
    // Read in the held home (#41462 review F1): an archive a replacement home holds at the same
    // path is never what a removal here decides by.
    let file = crate::home_fs::private_state_file(path)?;
    let mut reader = BufReader::with_capacity(256 * 1024, zstd::stream::read::Decoder::new(file)?);
    let header: Header = serde_json::from_slice(&read_line(&mut reader, "header")?)
        .context("the cold archive's header does not read")?;
    anyhow::ensure!(header.schema == SCHEMA, "a cold archive of schema {:?}", header.schema);
    let mut hashes = Vec::with_capacity(header.files.len());
    for entry in &header.files {
        anyhow::ensure!(log_file(&entry.name), "a cold archive names {:?}", entry.name);
        let mut hash = Sha256::new();
        let mut part = (&mut reader).take(entry.len);
        let copied = match open(entry)? {
            Some(out) => {
                let mut out = std::io::BufWriter::with_capacity(256 * 1024, out);
                let copied = copy_hashed(&mut part, &mut out, &mut hash)?;
                let out = out.into_inner().map_err(|e| e.into_error())?;
                out.sync_all()?;
                copied
            }
            None => copy_hashed(&mut part, &mut std::io::sink(), &mut hash)?,
        };
        anyhow::ensure!(copied == entry.len, "{} is cut short in the cold archive", entry.name);
        hashes.push(hex(&hash.finalize()));
    }
    let trailer: Trailer = serde_json::from_slice(&read_line(&mut reader, "trailer")?)
        .context("the cold archive's trailer does not read")?;
    anyhow::ensure!(trailer.sha256 == hashes, "the cold archive does not match its hashes");
    let mut rest = [0u8; 1];
    anyhow::ensure!(reader.read(&mut rest)? == 0, "the cold archive goes on past its trailer");
    Ok((header, hashes))
}

/// Whether every file of the archive at `archive` is in `events` as the start of the file
/// there: the same bytes, checked against the archive's hashes. Length alone is no proof: an
/// older build that does not read the archive starts a new `000001.ndjson` of its own, which can
/// be as long (review of #39141). The archive and the log are both read in the held home
/// (`home_fs`), the folder the removal this decides acts on (#41462 review F1).
fn log_holds(archive: &Path, events: &Path) -> Result<bool> {
    let (header, hashes) = decode(archive, &mut |_| Ok(None))?;
    for (entry, archived) in header.files.iter().zip(&hashes) {
        let Ok(file) = crate::home_fs::private_state_file(events.join(&entry.name)) else {
            return Ok(false);
        };
        let mut hash = Sha256::new();
        let copied = copy_hashed(&mut file.take(entry.len), &mut std::io::sink(), &mut hash)?;
        if copied != entry.len || hex(&hash.finalize()) != *archived {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Removes the tree at `path` when there is one, through the held home (`home_fs`): a home
/// replaced meanwhile never loses a tree of the new daemon's (#41372 review F2).
fn remove_dir_if_there(path: &Path) -> Result<()> {
    match crate::home_fs::remove_dir_all(path) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
        _ => Ok(()),
    }
}

impl LocalStore {
    pub(super) fn cold_path(&self, id: &str) -> PathBuf {
        self.dir(id).join(COLD_FILE)
    }

    /// The chat's log is in its archive: an archive and no segment.
    pub(super) fn is_cold(&self, id: &str) -> bool {
        std::fs::symlink_metadata(self.cold_path(id)).is_ok()
            && self.segment_files(id).is_ok_and(|segments| segments.is_empty())
    }

    /// The files of `events/` with their paths, or None when there is no log to archive: no
    /// segment, or a file a log does not hold (a retention rewrite's copy, a fork's history being
    /// written), which leaves the chat as it is for now.
    /// Listed in the held home (`home_fs`): the commit renames that `events/` aside.
    fn log_files(&self, id: &str) -> Result<Option<Vec<(String, PathBuf)>>> {
        let events = self.dir(id).join("events");
        let Ok(rd) = crate::home_fs::read_dir(&events) else { return Ok(None) };
        let mut out = Vec::new();
        for entry in rd {
            let name = entry.name.to_string_lossy().into_owned();
            if !entry.is_file || !log_file(&name) {
                return Ok(None);
            }
            out.push((name, events.join(&entry.name)));
        }
        out.sort();
        if !out.iter().any(|(name, _)| name != super::compact::MARKER) {
            return Ok(None);
        }
        Ok(Some(out))
    }

    /// Whether the chat's `events/` holds a segment, read in the held home (`home_fs`): the
    /// settle and the rehydrate decide by it what to remove there (#41462 review F1).
    fn held_has_segment(&self, id: &str) -> Result<bool> {
        match crate::home_fs::read_dir(self.dir(id).join("events")) {
            Ok(entries) => Ok(entries.iter().any(|entry| {
                entry
                    .name
                    .to_str()
                    .and_then(|name| name.strip_suffix(".ndjson"))
                    .is_some_and(|stem| stem.parse::<u32>().is_ok())
            })),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    /// An archive beside a log ([module docs](self)): removed when every file it holds starts the
    /// log's file of that name byte for byte, else kept as `cold.zst.orphan-<ms>` and never read. Leftovers of a
    /// crash (a temporary archive of another process, a rehydrate's folder, a folder renamed
    /// aside) go too. Nothing to do for an archived chat or one with no archive. Refused once the
    /// store is sealed.
    pub(super) fn settle_cold(&self, id: &str) -> Result<()> {
        #[cfg(test)]
        super::log_sync::note(&NOTE_BEFORE_COLD_LOCK, "settle");
        let cold = self.cold.lock_or_recover();
        // Held through the settlement, so a seal waits for it: an archive task that outlives a
        // handover would otherwise take the next daemon's archive, published but with `events/`
        // not yet moved aside, for a crash's leftover and remove it (review of #39141).
        let _sealed = self.unsealed(id)?;
        self.settle_cold_locked(id, &cold)
    }

    /// The seal's read side, for work that removes a file of the chat's folder: refused once the
    /// store is sealed, since the next daemon may already own the home. `try_read`: an append
    /// holds the read side already, and a second read on the same thread may wait forever behind
    /// a seal that waits for the first; a seal under way refuses it too.
    fn unsealed(&self, id: &str) -> Result<std::sync::RwLockReadGuard<'_, bool>> {
        let sealed = match self.sealed.try_read() {
            Ok(sealed) => sealed,
            Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                anyhow::bail!("the store is sealing: {id} stays as it is")
            }
        };
        anyhow::ensure!(!*sealed, "the store is sealed: the daemon has shut down");
        Ok(sealed)
    }

    /// [`Self::settle_cold`] under the cold lock, which a commit holds from the archive's rename
    /// into place to the rename of `events/` aside: an archive and a log beside it are a crash's
    /// leftover only when no commit is between the two (review of #39141: a second archive of the
    /// chat removed the first one's archive as covered, and the first then removed the log).
    fn settle_cold_locked(&self, id: &str, _cold: &std::sync::MutexGuard<'_, ()>) -> Result<()> {
        let dir = self.dir(id);
        // Every removal and rename below goes through the held home (`home_fs`), and so does
        // every read it decides by: the folder's names, the archive and the log it checks the
        // archive against. Read by path, a home replaced after this check would show its own
        // archive and the log that holds it, and the removal would take the held home's archive,
        // its only copy of the chat (#41462 review F1).
        crate::config::refuse_lost_home(&dir)?;
        if let Ok(rd) = crate::home_fs::read_dir(&dir) {
            let mine = format!("{COLD_FILE}.tmp-{}-", std::process::id());
            for entry in rd {
                let name = entry.name.to_string_lossy().into_owned();
                if name.starts_with(&format!("{COLD_FILE}.tmp-")) && !name.starts_with(&mine) {
                    let _ = crate::home_fs::remove_file(dir.join(&entry.name));
                }
            }
        }
        let archive = self.cold_path(id);
        if !crate::home_fs::exists_nofollow(&archive) || !self.held_has_segment(id)? {
            return Ok(());
        }
        remove_dir_if_there(&dir.join(THAW_DIR))?;
        remove_dir_if_there(&dir.join(DROP_DIR))?;
        let events = dir.join("events");
        let covered = log_holds(&archive, &events).unwrap_or(false);
        if covered {
            crate::home_fs::remove_file(&archive)?;
        } else {
            let kept = dir.join(format!("{COLD_FILE}.orphan-{}", now_ms()));
            tracing::warn!(session = %id, "a cold archive beside a log that does not hold it is kept as {}", kept.display());
            crate::home_fs::rename(&archive, &kept)?;
        }
        sync_directory(&dir)
    }

    /// Writes the archive of `id`'s log beside it and checks it decodes to the same bytes. None
    /// when there is no log to archive (`log_files`).
    pub(super) fn stage_cold(&self, id: &str) -> Result<Option<StagedCold>> {
        self.settle_cold(id)?;
        let Some(files) = self.log_files(id)? else { return Ok(None) };
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let tmp = self.dir(id).join(format!("{COLD_FILE}.tmp-{}-{n}", std::process::id()));
        let _ = crate::home_fs::remove_file(&tmp);
        // Every file is opened, and its length taken, before a byte is written: a line appended
        // since is not in the archive, and the commit refuses the log.
        let mut opened = Vec::with_capacity(files.len());
        for (name, path) in files {
            let file = crate::home_fs::private_state_file(&path)?;
            let len = file.metadata()?.len();
            opened.push((Entry { name, len }, file));
        }
        let mut staged = StagedCold {
            stats: ColdStats::default(),
            tmp: tmp.clone(),
            files: opened.iter().map(|(entry, _)| entry.clone()).collect(),
        };
        let header = Header { schema: SCHEMA.into(), files: staged.files.clone() };
        let out = std::io::BufWriter::with_capacity(256 * 1024, open_private_append(&tmp)?);
        let mut encoder = zstd::stream::write::Encoder::new(out, LEVEL)?;
        encoder.include_checksum(true)?;
        serde_json::to_writer(&mut encoder, &header)?;
        encoder.write_all(b"\n")?;
        let mut hashes = Vec::with_capacity(opened.len());
        for (entry, file) in &opened {
            let mut hash = Sha256::new();
            let copied = copy_hashed(&mut Read::take(file, entry.len), &mut encoder, &mut hash)?;
            anyhow::ensure!(
                copied == entry.len,
                "{} got shorter while it was archived",
                entry.name
            );
            hashes.push(hex(&hash.finalize()));
            staged.stats.bytes_before += entry.len;
        }
        serde_json::to_writer(&mut encoder, &Trailer { sha256: hashes.clone() })?;
        encoder.write_all(b"\n")?;
        let out = encoder.finish()?.into_inner().map_err(|e| e.into_error())?;
        out.sync_all()?;
        staged.stats.bytes_after = out.metadata()?.len();
        staged.stats.files = opened.len() as u64;
        drop(opened);
        // Read back from the disk: what a rehydrate will read.
        let (read, read_hashes) = decode(&tmp, &mut |_| Ok(None))?;
        anyhow::ensure!(
            read == header && read_hashes == hashes,
            "the cold archive of {id} does not decode to its log"
        );
        Ok(Some(staged))
    }

    /// Puts `staged` in place of the log it was read from, unless the log changed since (false).
    /// The caller holds the chat's append lock; the writers' lock is held from the check to the
    /// rename of `events/`, so no line lands meanwhile from any writer.
    pub(super) fn commit_cold(&self, id: &str, staged: StagedCold) -> Result<bool> {
        let dir = self.dir(id);
        {
            let mut writers = self.writers.lock_or_recover();
            let _cold = self.cold.lock_or_recover();
            let unchanged = self.log_files(id)?.is_some_and(|now| {
                now.len() == staged.files.len()
                    && now.iter().zip(&staged.files).all(|((name, path), entry)| {
                        *name == entry.name
                            && crate::home_fs::private_state_file(path)
                                .is_ok_and(|f| f.metadata().is_ok_and(|m| m.len() == entry.len))
                    })
            });
            if !unchanged {
                return Ok(false);
            }
            if let Some(w) = writers.open.remove(id) {
                w.close(id, &self.sync_failed);
            }
            // The renames go through the held home (`home_fs`).
            crate::config::refuse_lost_home(&dir)?;
            crate::home_fs::rename(&staged.tmp, self.cold_path(id))?;
            sync_directory(&dir)?;
            #[cfg(test)]
            super::log_sync::hold(&HOLD_AFTER_COLD_PUBLISH);
            let aside = dir.join(DROP_DIR);
            remove_dir_if_there(&aside)?;
            crate::home_fs::rename(dir.join("events"), &aside)?;
            sync_directory(&dir)?;
        }
        let _ = crate::home_fs::remove_dir_all(dir.join(DROP_DIR));
        let _ = crate::home_fs::remove_dir_all(dir.join(super::kind_index::DIR));
        let _ = crate::home_fs::remove_dir_all(dir.join(super::text_index::DIR));
        Ok(true)
    }

    /// Puts an archived chat's log back as `events/`, byte for byte, and removes the archive.
    /// False when the chat is not archived (no archive, or a log beside it: `settle_cold`), and
    /// when another thread's rehydrate brought it back first: a caller lists the segments again
    /// either way (`LocalStore::segments`).
    /// Refused once the store is sealed: the next daemon may already own the home.
    pub(super) fn rehydrate(&self, id: &str) -> Result<bool> {
        let archive = self.cold_path(id);
        // The cost to every read of a chat with no segment: one `lstat`.
        if std::fs::symlink_metadata(&archive).is_err() {
            return Ok(false);
        }
        #[cfg(test)]
        super::log_sync::note(&NOTE_BEFORE_COLD_LOCK, "rehydrate");
        let cold = self.cold.lock_or_recover();
        // From here on, read in the held home (`home_fs`), where the rehydrate writes and
        // removes: the archive it decodes and removes is the held home's (#41462 review F1).
        if !crate::home_fs::exists_nofollow(&archive) {
            return Ok(false);
        }
        let _sealed = self.unsealed(id)?;
        if self.held_has_segment(id)? {
            self.settle_cold_locked(id, &cold)?;
            return Ok(false);
        }
        #[cfg(test)]
        super::log_sync::hold(&HOLD_BEFORE_THAW);
        let started = std::time::Instant::now();
        let dir = self.dir(id);
        let thaw = dir.join(THAW_DIR);
        remove_dir_if_there(&thaw)?;
        crate::config::private_state_dir(&thaw)?;
        let (header, _) =
            decode(&archive, &mut |entry| Ok(Some(open_private_append(&thaw.join(&entry.name))?)))?;
        sync_directory(&thaw)?;
        let events = dir.join("events");
        let aside = dir.join(DROP_DIR);
        // Read and changed in the held home (`home_fs`): a home replaced since the decode's
        // checks keeps its `events/` and its archive (#41372 review F2).
        if crate::home_fs::exists_nofollow(&events) {
            // No segment in it (checked above): an empty folder an append made, or a lone record.
            remove_dir_if_there(&aside)?;
            crate::home_fs::rename(&events, &aside)?;
        }
        crate::home_fs::rename(&thaw, &events)?;
        sync_directory(&dir)?;
        crate::home_fs::remove_file(&archive)?;
        sync_directory(&dir)?;
        let _ = crate::home_fs::remove_dir_all(&aside);
        if let Some(hook) = self.rehydrate_hook.get() {
            hook(id);
        }
        tracing::info!(
            session = %id,
            bytes = header.files.iter().map(|e| e.len).sum::<u64>(),
            ms = started.elapsed().as_millis() as u64,
            "rehydrated a cold-archived chat"
        );
        Ok(true)
    }
}

#[cfg(test)]
#[path = "cold_tests.rs"]
mod tests;
