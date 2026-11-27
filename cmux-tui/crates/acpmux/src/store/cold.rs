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

#[path = "cold_pack.rs"]
mod packed;

/// A cold-archived chat's log, in its folder beside `session.json`.
pub const COLD_FILE: &str = "cold.zst";
/// The stub `cmux-session-cloud` leaves when a chat's archive is offloaded to the person's cloud
/// history store: the archive's blob, size and hash. A chat with a stub and no segment is cold; its
/// first read fetches the archive back into `cold.zst` and thaws it as any archive.
pub const CLOUD_STUB: &str = "cold.zst.cloud";
/// What stays on this disk of an offloaded chat for search: its archive's lines the search
/// projector reads (`text_index::wanted`), in order, in one zstd file. Written before the upload,
/// so an offloaded chat stays findable by `acpmux search` with no fetch; removed with the stub at
/// the thaw. Leo, 2026-11-27: "if things are completed/idle we should just be moving them off to
/// r2 if we really want to keep the session histories and whatnot".
pub const SEARCH_COPY: &str = "cold-search.zst";
/// The folder a rehydrate decodes into, renamed to `events/` once every file is on the disk.
const THAW_DIR: &str = "cold-thaw.tmp";
/// Where a commit renames `events/` before removing it, and a rehydrate any `events/` without a
/// segment that was there.
const DROP_DIR: &str = "events.cold-drop";
/// Where a commit renames `cold-segments/` (`store/cold_segments.rs`) before removing it.
const COLD_SEGMENTS_DROP_DIR: &str = "cold-segments.cold-drop";
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
    /// Tests: this thread says so, once, when the chat's cold lock it asks for is held by another.
    pub(crate) static NOTE_COLD_LOCK_WAITS: super::log_sync::Note =
        const { std::cell::RefCell::new(None) };
}

/// One lock per chat for every change that removes one of its log's copies (`LocalStore::cold`):
/// each holds it from the checks it decides by through the removal, so no two of them act on
/// what the other is about to change (#43562 review F1, P2-F1). A chat's id is in `busy` while a
/// thread holds its lock.
#[derive(Default)]
pub(crate) struct ChatLocks {
    busy: Mutex<std::collections::BTreeSet<String>>,
    free: std::sync::Condvar,
}

/// A chat's cold lock, held until it drops ([`ChatLocks::lock`]).
pub(crate) struct ChatLock<'a> {
    locks: &'a ChatLocks,
    id: String,
}

impl ChatLocks {
    /// Waits until no other thread holds `id`'s lock, then holds it.
    pub(crate) fn lock(&self, id: &str) -> ChatLock<'_> {
        let mut busy = self.busy.lock_or_recover();
        #[cfg(test)]
        if busy.contains(id) {
            super::log_sync::note(&NOTE_COLD_LOCK_WAITS, "waits");
        }
        while busy.contains(id) {
            busy = self.free.wait(busy).unwrap_or_else(std::sync::PoisonError::into_inner);
        }
        busy.insert(id.to_owned());
        ChatLock { locks: self, id: id.to_owned() }
    }
}

impl Drop for ChatLock<'_> {
    fn drop(&mut self) {
        self.locks.busy.lock_or_recover().remove(&self.id);
        self.locks.free.notify_all();
    }
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
    decode_files(path, &mut |entry, part, hash| match open(entry)? {
        Some(out) => {
            let mut out = std::io::BufWriter::with_capacity(256 * 1024, out);
            let copied = copy_hashed(part, &mut out, hash)?;
            out.into_inner().map_err(|e| e.into_error())?.sync_all()?;
            Ok(copied)
        }
        None => copy_hashed(part, &mut std::io::sink(), hash),
    })
}

fn decode_files(
    path: &Path,
    read: &mut dyn FnMut(&Entry, &mut dyn Read, &mut Sha256) -> Result<u64>,
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
        let copied = read(entry, &mut part, &mut hash)?;
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
        // A segment that went cold since reads from its archive (`store/cold_segments.rs`).
        let Ok(file) = super::cold_segments::open_segment(&events.join(&entry.name)) else {
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

/// A file of the log opened to archive, and its length: a cold segment's raw bytes and raw length
/// through its archive (`store/cold_segments.rs`), any other file as it is.
fn open_log_file(path: &Path) -> Result<(u64, Box<dyn Read>)> {
    if super::cold_segments::is_cold(path) {
        let file = super::cold_segments::open_segment(path)?;
        return Ok((file.len()?, Box::new(file)));
    }
    let file = crate::home_fs::private_state_file(path)?;
    Ok((file.metadata()?.len(), Box::new(file)))
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
    /// Read the search projector's records out of a cold chat, preserving the archive.
    pub(super) fn cold_search_records(
        &self,
        id: &str,
        visit: &mut dyn FnMut(EventRecord),
    ) -> Result<()> {
        if !crate::home_fs::try_exists_nofollow(self.cold_path(id))?
            && crate::home_fs::try_exists_nofollow(self.cloud_stub_path(id))?
        {
            // Offloaded to cloud history: never fetched for a query (one search would pull every
            // offloaded chat back). Its search copy, kept local at the offload, is read instead;
            // one offloaded before the copy existed is not searched.
            let copy = self.dir(id).join(SEARCH_COPY);
            if !crate::home_fs::try_exists_nofollow(&copy)? {
                return Ok(());
            }
            let file = crate::home_fs::private_state_file(&copy)?;
            let mut reader =
                BufReader::with_capacity(256 * 1024, zstd::stream::read::Decoder::new(file)?);
            let mut line = Vec::new();
            while reader.read_until(b'\n', &mut line)? > 0 {
                if let Ok(record) = parse_record(&line) {
                    visit(record);
                }
                line.clear();
            }
            return Ok(());
        }
        decode_files(&self.cold_path(id), &mut |entry, part, hash| {
            if !entry.name.ends_with(".ndjson") {
                return copy_hashed(part, &mut std::io::sink(), hash);
            }
            let mut reader = BufReader::new(part);
            let mut line = Vec::new();
            let mut copied = 0;
            while reader.read_until(b'\n', &mut line)? > 0 {
                hash.update(&line);
                copied += line.len() as u64;
                if super::text_index::wanted(&line)
                    && let Ok(record) = parse_record(&line)
                {
                    visit(record);
                }
                line.clear();
            }
            Ok(copied)
        })?;
        Ok(())
    }

    pub(super) fn cold_path(&self, id: &str) -> PathBuf {
        self.dir(id).join(COLD_FILE)
    }

    /// The chat's log is in its archive: an archive and no segment. The archive is looked for
    /// in the held home (`home_fs`), where the settle and the rehydrate act (#41697 review F1),
    /// on every platform (#41721 review F1). A home that is no longer the held one reads as not
    /// cold here; `rehydrate`, which a read of the chat goes through, answers it with an error.
    pub(super) fn is_cold(&self, id: &str) -> bool {
        (crate::home_fs::try_exists_nofollow(self.cold_path(id)).unwrap_or(false)
            || crate::home_fs::try_exists_nofollow(self.cloud_stub_path(id)).unwrap_or(false))
            && self.segment_files(id).is_ok_and(|segments| segments.is_empty())
    }

    pub(super) fn cloud_stub_path(&self, id: &str) -> PathBuf {
        self.dir(id).join(CLOUD_STUB)
    }

    fn cloud_history(&self, id: &str) -> Result<cmux_session_cloud::stub::History> {
        cmux_session_cloud::stub::parse_history(crate::home_fs::private_state_file(
            self.cloud_stub_path(id),
        )?)
    }

    /// The person's cloud history store, from the config in this store's acpmux home (the
    /// folder above `sessions/`); None when they never turned it on.
    fn cloud(&self) -> Result<Option<std::sync::Arc<cmux_session_cloud::Cloud>>> {
        let state = self.root.parent().unwrap_or(&self.root);
        cmux_session_cloud::Cloud::get_in(state)
    }

    /// See [`Store::offload_cold`]. The upload runs with no lock held; the stub's write and the
    /// archive's removal run under the cold lock, and only when the archive still holds the bytes
    /// uploaded and the chat still has no segment. A crash between the stub and the removal
    /// leaves both: the archive is read, and the stub goes with it at the thaw.
    /// The bytes freed are the archive's less its search copy's ([`SEARCH_COPY`]).
    pub(super) fn offload_cold(&self, id: &str) -> Result<Option<u64>> {
        let archive = self.cold_path(id);
        if !self.is_cold(id) || !crate::home_fs::try_exists_nofollow(&archive)? {
            return Ok(None);
        }
        let Some(cloud) = self.cloud()? else { return Ok(None) };
        let kept = self.write_search_copy(id, &archive)?;
        let record = cmux_session_cloud::offload::upload(&archive, &cloud)?;
        let _cold = self.cold.lock(id);
        let _sealed = self.unsealed(id)?;
        if self.held_has_segment(id)? {
            return Ok(None);
        }
        let freed = cmux_session_cloud::offload::commit(&archive, &record)?
            .map(|bytes| bytes.saturating_sub(kept));
        if let Some(bytes) = freed {
            tracing::info!(session = %id, bytes, stored = record.stored_bytes, "offloaded a cold chat to cloud history");
        }
        Ok(freed)
    }

    /// Writes [`SEARCH_COPY`] from `archive`, checked against its hashes as any decode is: its
    /// size. Atomic, and before any upload, so a stub never stands without it.
    pub(super) fn write_search_copy(&self, id: &str, archive: &Path) -> Result<u64> {
        let mut encoder = zstd::stream::write::Encoder::new(Vec::new(), LEVEL)?;
        decode_files(archive, &mut |entry, part, hash| {
            if !entry.name.ends_with(".ndjson") {
                return copy_hashed(part, &mut std::io::sink(), hash);
            }
            let mut reader = BufReader::new(part);
            let mut line = Vec::new();
            let mut copied = 0;
            while reader.read_until(b'\n', &mut line)? > 0 {
                hash.update(&line);
                copied += line.len() as u64;
                if super::text_index::wanted(&line) {
                    encoder.write_all(&line)?;
                    if !line.ends_with(b"\n") {
                        encoder.write_all(b"\n")?;
                    }
                }
                line.clear();
            }
            Ok(copied)
        })?;
        let bytes = encoder.finish()?;
        crate::config::write_atomic(&self.dir(id).join(SEARCH_COPY), &bytes)?;
        Ok(bytes.len() as u64)
    }

    /// See [`Store::cloud_configured`]. A config that does not read counts as not set up.
    pub(super) fn cloud_configured(&self) -> bool {
        self.cloud().is_ok_and(|cloud| cloud.is_some())
    }

    /// See [`Store::offloaded`].
    pub(super) fn offloaded(&self, id: &str) -> bool {
        crate::home_fs::try_exists_nofollow(self.cloud_stub_path(id)).unwrap_or(false)
            && !crate::home_fs::try_exists_nofollow(self.cold_path(id)).unwrap_or(true)
    }

    /// See [`Store::register_cloud_root`]. Reads every chat folder's stub (one small file each),
    /// so it runs once per batch. A stub that cannot be read is left out, and logged.
    pub(super) fn register_cloud_root(&self) -> Result<Option<usize>> {
        let Some(cloud) = self.cloud()? else { return Ok(None) };
        self.register_cloud_root_in(&cloud, &[]).map(Some)
    }

    fn register_cloud_root_in(
        &self,
        cloud: &cmux_session_cloud::Cloud,
        pending: &[&str],
    ) -> Result<usize> {
        // A root replaces its previous tree. Serialize scans through publication so a
        // concurrent batch cannot overwrite a packed commit with an older snapshot.
        static ROOT: Mutex<()> = Mutex::new(());
        let _root = ROOT.lock_or_recover();
        let mut blobs: Vec<String> = pending.iter().map(|s| (*s).to_owned()).collect();
        let entries = match crate::home_fs::read_dir(&self.root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => {
                return Err(anyhow::Error::from(error).context("list the chats for the cloud root"));
            }
        };
        for entry in entries {
            let Some(id) = entry.name.to_str() else { continue };
            let stub = self.cloud_stub_path(id);
            if !crate::home_fs::try_exists_nofollow(&stub)? {
                continue;
            }
            match self.cloud_history(id) {
                Ok(cmux_session_cloud::stub::History::Archive(record)) => blobs.push(record.blob),
                Ok(cmux_session_cloud::stub::History::Pack(record)) => {
                    blobs.extend(record.blobs().map(str::to_owned))
                }
                Err(error) => {
                    tracing::warn!(session = %id, "cloud history stub unreadable: {error:#}")
                }
            }
        }
        blobs.sort();
        blobs.dedup();
        cloud.store.set_root(&cloud.root_pair(), &blobs)?;
        Ok(blobs.len())
    }

    /// Brings an offloaded chat's archive back into `cold.zst` from the cloud history store. A
    /// failure is an error, never "not archived": an append would otherwise start a new log in
    /// front of the one in the cloud.
    fn fetch_cloud_locked(&self, id: &str) -> Result<()> {
        let stub = self.cloud_stub_path(id);
        let cloud = self.cloud()?.ok_or_else(|| {
            anyhow::anyhow!(
                "chat {id} is in cloud history but cloud history is not set up on this machine: restore session-cloud.json in the acpmux home"
            )
        })?;
        let started = std::time::Instant::now();
        let bytes = cmux_session_cloud::fetch::fetch_file(&stub, &cloud)?;
        tracing::info!(session = %id, bytes, ms = started.elapsed().as_millis() as u64, "fetched a chat's archive from cloud history");
        Ok(())
    }

    /// The files of `events/` with their paths, or None when there is no log to archive: no
    /// segment, or a file a log does not hold (a retention rewrite's copy, a fork's history being
    /// written), which leaves the chat as it is for now.
    /// Listed in the held home (`home_fs`): the commit renames that `events/` aside.
    /// A cold segment (`store/cold_segments.rs`) is in the list under its segment's name, read from
    /// its archive: the archive holds its raw bytes like any other segment's, and a rehydrate
    /// brings it back as a plain segment.
    fn log_files(&self, id: &str) -> Result<Option<Vec<(String, PathBuf)>>> {
        let session = self.dir(id);
        let events = session.join("events");
        let Ok(rd) = crate::home_fs::read_dir(&events) else { return Ok(None) };
        let mut out = Vec::new();
        let mut cold = Vec::new();
        for entry in rd {
            let name = entry.name.to_string_lossy().into_owned();
            if entry.is_file
                && let Some(index) = super::cold_segments::idx_index(&name)
            {
                cold.push(index);
                continue;
            }
            if !entry.is_file || !log_file(&name) {
                return Ok(None);
            }
            out.push((name, events.join(&entry.name)));
        }
        // The commit drops `cold-segments/` whole: only when every file in it is an archive the
        // listing takes (its index is beside the log) or a temporary leftover. A file a settle set
        // aside there (`.orphan-`, `.damaged-`) may be the only copy of a segment, so the chat
        // stays as it is until it is moved out (#43562 review P2-F2).
        let cold_dir = session.join(super::cold_segments::COLD_DIR);
        if let Ok(rd) = crate::home_fs::read_dir(&cold_dir) {
            for entry in rd {
                let name = entry.name.to_string_lossy();
                let indexed = name
                    .strip_suffix(".zst")
                    .and_then(|stem| stem.parse::<u32>().ok())
                    .is_some_and(|index| cold.contains(&index));
                if !indexed && !name.contains(".tmp-") {
                    anyhow::bail!(
                        "{} is kept aside and may be the only copy of part of chat {id}: the \
                         chat is not compressed whole until it is moved out of {}",
                        name,
                        cold_dir.display()
                    );
                }
            }
        }
        for index in cold {
            let name = format!("{index:06}.ndjson");
            if !out.iter().any(|(n, _)| *n == name) {
                out.push((name, super::cold_segments::zst_path(&session, index)));
            }
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
                entry.name.to_str().is_some_and(|name| {
                    name.strip_suffix(".ndjson").is_some_and(|stem| stem.parse::<u32>().is_ok())
                        || super::cold_segments::idx_index(name).is_some()
                })
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
        let cold = self.cold.lock(id);
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
    pub(super) fn unsealed(&self, id: &str) -> Result<std::sync::RwLockReadGuard<'_, bool>> {
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
    fn settle_cold_locked(&self, id: &str, _cold: &ChatLock<'_>) -> Result<()> {
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
        let stub = self.cloud_stub_path(id);
        if crate::home_fs::try_exists_nofollow(&stub)? && self.held_has_segment(id)? {
            // The log is back (a thaw that crashed before removing the stub): the stub is stale.
            crate::home_fs::remove_file(&stub)?;
            sync_directory(&dir)?;
        }
        if !crate::home_fs::try_exists_nofollow(&archive)? || !self.held_has_segment(id)? {
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
            // A cold segment is taken only as its archive decodes whole to its index: the commit
            // drops that archive, so a short or damaged index must stop the archive here.
            if super::cold_segments::is_cold(&path) {
                super::cold_segments::verify_cold(&path)?;
            }
            let (len, file) = open_log_file(&path)?;
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
        for (entry, file) in &mut opened {
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
            let _cold = self.cold.lock(id);
            // Closed first: a write in flight to it finishes, and none lands until `events/` is
            // renamed (a write runs under its segment's lock: `store/segment_writer.rs`).
            self.close_writer_locked(id, &mut writers);
            let unchanged = self.log_files(id)?.is_some_and(|now| {
                now.len() == staged.files.len()
                    && now.iter().zip(&staged.files).all(|((name, path), entry)| {
                        *name == entry.name
                            && open_log_file(path).is_ok_and(|(len, _)| len == entry.len)
                    })
            });
            if !unchanged {
                return Ok(false);
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
            // The cold segments' archives go with it: the archive holds their raw bytes. One a
            // crash leaves before this has no index any more, and the next settle of the
            // rehydrated log removes it (`LocalStore::settle_cold_segments`).
            let cold_segments = dir.join(super::cold_segments::COLD_DIR);
            if crate::home_fs::try_exists_nofollow(&cold_segments)? {
                let cold_aside = dir.join(COLD_SEGMENTS_DROP_DIR);
                remove_dir_if_there(&cold_aside)?;
                crate::home_fs::rename(&cold_segments, &cold_aside)?;
            }
            sync_directory(&dir)?;
        }
        let _ = crate::home_fs::remove_dir_all(dir.join(DROP_DIR));
        let _ = crate::home_fs::remove_dir_all(dir.join(COLD_SEGMENTS_DROP_DIR));
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
        // The cost to every read of a chat with no segment: one `*at` walk in the held home.
        // Read there, not by path (#41697 review F1): a replacement home without the archive
        // would answer "not archived" while the held home still holds it. On every platform:
        // off Unix a home replaced before or during the read is an error (#41721 review F1).
        let stub = self.cloud_stub_path(id);
        if !crate::home_fs::try_exists_nofollow(&archive)?
            && !crate::home_fs::try_exists_nofollow(&stub)?
        {
            return Ok(false);
        }
        #[cfg(test)]
        super::log_sync::note(&NOTE_BEFORE_COLD_LOCK, "rehydrate");
        let cold = self.cold.lock(id);
        // From here on, read in the held home (`home_fs`), where the rehydrate writes and
        // removes: the archive it decodes and removes is the held home's (#41462 review F1).
        let offloaded = crate::home_fs::try_exists_nofollow(&stub)?;
        if !crate::home_fs::try_exists_nofollow(&archive)? && !offloaded {
            return Ok(false);
        }
        let _sealed = self.unsealed(id)?;
        let mut packed = None;
        if offloaded
            && !crate::home_fs::try_exists_nofollow(&archive)?
            && !self.held_has_segment(id)?
        {
            // Under the cold lock, so two reads fetch once and an offload cannot remove the
            // archive mid-thaw.
            match self.cloud_history(id)? {
                cmux_session_cloud::stub::History::Pack(_) => {
                    packed = Some(self.cloud()?.context("cloud history is not configured")?);
                }
                cmux_session_cloud::stub::History::Archive(_) => self.fetch_cloud_locked(id)?,
            }
        }
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
        let header = if let Some(cloud) = &packed {
            self.thaw_packed(id, cloud, &thaw)?
        } else {
            decode(&archive, &mut |entry| Ok(Some(open_private_append(&thaw.join(&entry.name))?)))?
                .0
        };
        sync_directory(&thaw)?;
        let events = dir.join("events");
        let aside = dir.join(DROP_DIR);
        // Read and changed in the held home (`home_fs`): a home replaced since the decode's
        // checks keeps its `events/` and its archive (#41372 review F2).
        if crate::home_fs::try_exists_nofollow(&events)? {
            // No segment in it (checked above): an empty folder an append made, or a lone record.
            remove_dir_if_there(&aside)?;
            crate::home_fs::rename(&events, &aside)?;
        }
        crate::home_fs::rename(&thaw, &events)?;
        sync_directory(&dir)?;
        if packed.is_some() {
            self.remove_packed_cache(id);
        } else {
            crate::home_fs::remove_file(&archive)?;
        }
        if offloaded {
            crate::home_fs::remove_file(&stub)?;
            // The log is back and searched from its segments again.
            let _ = crate::home_fs::remove_file(dir.join(SEARCH_COPY));
        }
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
