//! Chat metadata through the journal (R-DURABILITY S3a; DESIGN.md 3.3e): a metadata change is a
//! `meta` record that carries the chat's whole metadata image; an overlay keeps every read
//! current until a checkpoint writes `session.json`; the replay writes the newest image of each
//! chat ([module docs](super)).
//!
//! Code outside the store reads and moves chat folders directly (a transfer puts the live folder
//! aside and installs another chat under the same id). So each image is bound to its folder: the
//! folder's file id and birth time when the image was saved. A read, the checkpoint and the
//! replay use an image only for that same folder; an image whose folder was replaced or removed
//! goes to `journal-unapplied/`. `session_dir` and `flush_session`, which hand the folder to such
//! code or make it durable, first write the chat's image (`settle_meta`).
//!
//! A run without the journal (the switch off after a catch-up that failed, or an older build) can
//! write `session.json` after the journal's records (review of #35483, F1). Every write of the
//! store's own carries `journalLsn` and the journal's id (`journalId`): an LSN means something
//! only in the journal that gave it, and a chat folder can come from another home's journal
//! (build adoption moves folders between homes) or outlive a journal made again (review of
//! #35483 at `8301994b135`, N1). A file without this journal's id is one the journal did not
//! write. So each
//! record also says which `session.json` there was when its image was saved: that file's id,
//! modification time and length (its stamp), or none. The replay writes an image over a file the
//! journal did not write only when one of the chat's replayed records saw that same file;
//! otherwise the file moved on without the journal, and the image goes aside, as a log's
//! journaled lines do when the log moved on.
//!
//! The replay never makes a chat's folder again: a new chat is acknowledged only once its
//! folder's entry is durable ([`super::new_folders`]), so a folder that is gone was removed (by a
//! delete, a run without the journal, the transfer recovery), and its images go aside.

use super::*;

/// A chat's metadata image: chat id, flags, its folder's identity, the stamp of the
/// `session.json` its save saw (with [`SAW_FILE`]), the image as compact JSON.
pub(super) const KIND_META: u16 = 4;
/// Flag: the save saw a `session.json`; its stamp follows the folder's identity.
const SAW_FILE: u8 = 1;
/// The key `session.json` keeps the LSN of the image it holds under (absent without the journal):
/// the replay never writes an older image over a newer one.
const JOURNAL_LSN_KEY: &str = "journalLsn";
/// The key beside it with the id of the journal that gave the LSN, as 16 hex digits (a string: a
/// JSON reader may keep a number only to 2^53).
const JOURNAL_ID_KEY: &str = "journalId";

/// Tests: a `settle_meta` of the chat this names stops right after it read the chat's image,
/// says so on the first channel and waits for the second.
#[cfg(test)]
type SettleHold = (String, std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>);
#[cfg(test)]
pub(crate) static SETTLE_HOLD: std::sync::Mutex<Option<SettleHold>> = std::sync::Mutex::new(None);

/// Tests: the stop of [`SETTLE_HOLD`].
#[cfg(test)]
fn hold_settle(id: &str) {
    let held = {
        let mut slot = SETTLE_HOLD.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if slot.as_ref().is_some_and(|(chat, _, _)| chat == id) { slot.take() } else { None }
    };
    if let Some((_, arrived, release)) = held {
        let _ = arrived.send(());
        let _ = release.recv();
    }
}

/// One chat folder: its file id and birth time (0 where the file system has none). A folder
/// renamed away and back keeps it; another folder made under the same path does not. A repair
/// file keeps it too (`journal_store/repair.rs`).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub(super) struct FolderId {
    ino: u64,
    birth_ns: u64,
}

/// A file's id (its inode); 0 where the platform gives none (its times then tell two apart).
#[cfg(unix)]
fn file_id(meta: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.ino()
}

#[cfg(not(unix))]
fn file_id(_meta: &std::fs::Metadata) -> u64 {
    0
}

/// Nanoseconds since 1970 of `at`; 0 when the platform gives none.
fn nanos(at: std::io::Result<std::time::SystemTime>) -> u64 {
    at.ok()
        .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX))
}

/// The identity of the folder at `dir`; `None` when there is none.
pub(super) fn folder_id(dir: &Path) -> std::io::Result<Option<FolderId>> {
    match std::fs::symlink_metadata(dir) {
        Ok(meta) => Ok(Some(FolderId { ino: file_id(&meta), birth_ns: nanos(meta.created()) })),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// A `session.json` file: its id, modification time and length. A write of the file by rename
/// (every writer's way) gives it a new id; one in place a new modification time.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) struct FileStamp {
    ino: u64,
    modified_ns: u64,
    len: u64,
}

impl FileStamp {
    fn of(meta: &std::fs::Metadata) -> Self {
        Self { ino: file_id(meta), modified_ns: nanos(meta.modified()), len: meta.len() }
    }
}

/// What a chat's `session.json` is.
enum SessionFile {
    Missing,
    /// A file this journal wrote, holding the image of this LSN.
    Journaled(Lsn),
    /// A file this journal did not write (before the switch went on, with it off, by an older
    /// build, or by another journal: another home's, or this home's before its journal was made
    /// again); one that does not parse is one too.
    Plain(FileStamp),
}

/// A journal id as `session.json` keeps it.
fn journal_id_text(id: u64) -> String {
    format!("{id:016x}")
}

/// Reads what `dir`'s `session.json` is for the journal `journal`: its stamp and its bytes from
/// one open file.
fn session_file(dir: &Path, journal: u64) -> std::io::Result<SessionFile> {
    #[derive(Deserialize)]
    struct Only {
        #[serde(default, rename = "journalLsn")]
        journal_lsn: Lsn,
        #[serde(default, rename = "journalId")]
        journal_id: Option<String>,
    }
    let path = dir.join("session.json");
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = match options.open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(SessionFile::Missing);
        }
        Err(error) => return Err(error),
    };
    let meta = file.metadata()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    let ours = journal_id_text(journal);
    Ok(match serde_json::from_slice::<Only>(&bytes) {
        Ok(Only { journal_lsn: lsn @ 1.., journal_id: Some(id) }) if id == ours => {
            SessionFile::Journaled(lsn)
        }
        _ => SessionFile::Plain(FileStamp::of(&meta)),
    })
}

/// The stamp of `dir`'s `session.json` for a save's record: one `lstat`, no read. `None` when
/// there is none, or when it does not stat (a file there at the replay then counts as moved on).
fn saw_file(dir: &Path) -> Option<FileStamp> {
    std::fs::symlink_metadata(dir.join("session.json")).ok().map(|meta| FileStamp::of(&meta))
}

/// The newest image of a chat that its `session.json` does not hold yet.
#[derive(Clone)]
pub(super) struct Pending {
    pub(super) lsn: Lsn,
    pub(super) meta: SessionMeta,
    /// The folder this image belongs to.
    folder: FolderId,
}

/// The newest replayed image of a chat, after its last `forget`.
pub(super) struct Replayed {
    lsn: Lsn,
    image: Vec<u8>,
    folder: FolderId,
    /// The `session.json` files the chat's replayed records (for this folder) saw: a file the
    /// journal did not write is written over only when it is one of them.
    saw: Vec<FileStamp>,
}

/// One `meta` record, read.
struct Decoded<'a> {
    chat: String,
    folder: FolderId,
    saw: Option<FileStamp>,
    image: &'a [u8],
}

/// The size of a `meta` record's payload: chat id length, chat id, flags, folder, the stamp of
/// the file its save saw, image.
fn meta_payload_len(id: &str, saw: Option<FileStamp>, image: &[u8]) -> usize {
    let stamp = if saw.is_some() { 24usize } else { 0 };
    21usize.saturating_add(stamp).saturating_add(id.len()).saturating_add(image.len())
}

fn encode_meta(id: &str, folder: FolderId, saw: Option<FileStamp>, image: &[u8]) -> Vec<u8> {
    let len = u32::try_from(id.len()).unwrap_or(u32::MAX);
    let mut payload = Vec::with_capacity(meta_payload_len(id, saw, image));
    payload.extend_from_slice(&len.to_le_bytes());
    payload.extend_from_slice(id.as_bytes());
    payload.push(if saw.is_some() { SAW_FILE } else { 0 });
    payload.extend_from_slice(&folder.ino.to_le_bytes());
    payload.extend_from_slice(&folder.birth_ns.to_le_bytes());
    if let Some(stamp) = saw {
        payload.extend_from_slice(&stamp.ino.to_le_bytes());
        payload.extend_from_slice(&stamp.modified_ns.to_le_bytes());
        payload.extend_from_slice(&stamp.len.to_le_bytes());
    }
    payload.extend_from_slice(image);
    payload
}

/// The little-endian `u64` at `at`, which moves past it.
fn take_u64(payload: &[u8], at: &mut usize) -> Option<u64> {
    let end = at.checked_add(8)?;
    let value = u64::from_le_bytes(payload.get(*at..end)?.try_into().ok()?);
    *at = end;
    Some(value)
}

fn decode_meta(payload: &[u8]) -> Option<Decoded<'_>> {
    let len = usize::try_from(u32::from_le_bytes(payload.get(..4)?.try_into().ok()?)).ok()?;
    let end = 4usize.checked_add(len)?;
    let chat = std::str::from_utf8(payload.get(4..end)?).ok()?.to_owned();
    let flags = *payload.get(end)?;
    let mut at = end.checked_add(1)?;
    let folder =
        FolderId { ino: take_u64(payload, &mut at)?, birth_ns: take_u64(payload, &mut at)? };
    let saw = if flags & SAW_FILE != 0 {
        Some(FileStamp {
            ino: take_u64(payload, &mut at)?,
            modified_ns: take_u64(payload, &mut at)?,
            len: take_u64(payload, &mut at)?,
        })
    } else {
        None
    };
    let image = payload.get(at..)?;
    Some(Decoded { chat, folder, saw, image })
}

/// `session.json` for `meta`, written as `LocalStore::save` writes it, with the image's LSN and
/// its journal's id.
fn session_json(meta: &SessionMeta, lsn: Lsn, journal: u64) -> Result<Vec<u8>> {
    let mut text = serde_json::to_string_pretty(meta)?;
    // The struct's field order kept: the keys go before the closing brace of a non-empty object.
    let Some(close) = text.rfind('}') else { anyhow::bail!("a chat's metadata is not an object") };
    let body = text.get(..close).unwrap_or_default().trim_end().to_owned();
    let id = journal_id_text(journal);
    text =
        format!("{body},\n  \"{JOURNAL_LSN_KEY}\": {lsn},\n  \"{JOURNAL_ID_KEY}\": \"{id}\"\n}}");
    Ok(text.into_bytes())
}

/// Writes `meta` (the image of LSN `lsn`) to `dir`'s `session.json`: whole under a temporary
/// name (owner-only, never through a symlink), synced in write order, renamed into place, the
/// folder synced in write order. The checkpoint that writes it (or recovery's, which ends the
/// open) flushes the drive once afterward (`write_checkpoint`), so a power loss keeps it too:
/// one drive flush per checkpoint, not two per chat (29 ms per replayed chat on macOS before,
/// fleet ead05e82). A failed sync of either is a [`SyncFailed`] (review of #35483, F3): what it
/// was to make durable may be lost, and a later sync of the same file may report success
/// without it.
#[cfg(unix)]
fn write_session_json(dir: &Path, meta: &SessionMeta, lsn: Lsn, journal: u64) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let path = dir.join("session.json");
    crate::config::refuse_lost_home(&path)?;
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_extension(format!("tmp-{}-{n}", std::process::id()));
    let written = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)
            .with_context(|| format!("write {}", tmp.display()))?;
        file.write_all(&session_json(meta, lsn, journal)?)
            .with_context(|| format!("write {}", tmp.display()))?;
        log_sync::sync_segment_ordered(&file)
            .map_err(SyncFailed)
            .with_context(|| format!("sync {}", tmp.display()))?;
        drop(file);
        std::fs::rename(&tmp, &path).with_context(|| format!("rename to {}", path.display()))?;
        log_sync::sync_directory_ordered(dir).with_context(|| format!("sync {}", dir.display()))
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

/// Writes `meta` (the image of LSN `lsn`) to `dir`'s `session.json`, durably (NTFS journals its
/// folder changes).
#[cfg(not(unix))]
fn write_session_json(dir: &Path, meta: &SessionMeta, lsn: Lsn, journal: u64) -> Result<()> {
    crate::config::write_atomic(&dir.join("session.json"), &session_json(meta, lsn, journal)?)
}

impl super::repair::Replay {
    /// A `meta` record: the chat's newest image so far, and the files its records saw.
    pub(super) fn take_meta(
        &mut self,
        record: &cmux_journal::Record<'_>,
    ) -> std::result::Result<(), String> {
        let decoded = decode_meta(record.payload)
            .ok_or_else(|| format!("meta record {} does not read", record.lsn))?;
        // What earlier records of this replay saw, for the same folder (a record for another
        // folder starts over: that folder replaced this one).
        let mut saw = self
            .metas
            .remove(&decoded.chat)
            .filter(|replayed| replayed.folder == decoded.folder)
            .map(|replayed| replayed.saw)
            .unwrap_or_default();
        if let Some(stamp) = decoded.saw
            && !saw.contains(&stamp)
        {
            saw.push(stamp);
        }
        self.metas.insert(
            decoded.chat,
            Replayed {
                lsn: record.lsn,
                image: decoded.image.to_vec(),
                folder: decoded.folder,
                saw,
            },
        );
        Ok(())
    }
}

impl Inner {
    /// `Store::save` with the journal: the `meta` record and the overlay, no file written
    /// ([module docs](self)).
    pub(super) fn save_meta(&self, meta: &SessionMeta) -> Result<()> {
        let image = serde_json::to_vec(meta)?;
        let dir = self.local.dir(&meta.id);
        // The file there now, stamped before the appends' lock: only the store's own writes
        // change it meanwhile, and a stamp of a file the store wrote is harmless (the replay
        // compares such a file's `journalLsn`, never its stamp).
        let saw = saw_file(&dir);
        let mut order = self.order.lock_or_recover();
        drop(self.local.writable()?);
        // Checked before the folder is made: a refused save makes nothing.
        self.journal
            .check_append(meta_payload_len(&meta.id, saw, &image))
            .map_err(JournalStore::journal_error)?;
        let made = folder_id(&dir)?.is_none();
        if made {
            crate::config::private_state_dir(&dir)?;
        }
        let Some(folder) = folder_id(&dir)? else {
            anyhow::bail!("the folder of chat {} is gone", meta.id);
        };
        // A folder made now holds no `session.json`.
        let saw = if made { None } else { saw };
        let payload = encode_meta(&meta.id, folder, saw, &image);
        let append = || {
            self.journal
                .append(KIND_META, Class::Ack, &payload)
                .map_err(JournalStore::journal_error)
        };
        // A new folder's record is held back from the gate until the folder's entry is synced.
        let lsn = if made { self.new_folders.append_made(append)? } else { append()? };
        self.acked.store(lsn, std::sync::atomic::Ordering::SeqCst);
        order.applied = lsn;
        order.bytes = order.bytes.saturating_add(u64::try_from(payload.len()).unwrap_or(u64::MAX));
        order.metas.insert(meta.id.clone(), Pending { lsn, meta: meta.clone(), folder });
        let full = order.bytes > CHECKPOINT_BYTES && !order.frozen;
        drop(order);
        if full {
            self.want_checkpoint();
        }
        self.touched();
        Ok(())
    }

    /// The overlay's image of `id`, when its `session.json` does not hold it yet and its folder
    /// is still the one it was saved for.
    pub(super) fn pending_meta(&self, id: &str) -> Option<SessionMeta> {
        let pending = self.order.lock_or_recover().metas.get(id).cloned()?;
        let here = folder_id(&self.local.dir(id)).ok().flatten();
        (here == Some(pending.folder)).then_some(pending.meta)
    }

    /// `Store::list` with the journal: the folders' listing with the overlay's images over it.
    /// The overlay is read first and the files after, with no lock across the two: a checkpoint
    /// writes a file before it drops the file's overlay entry, so either read has the newest
    /// image.
    pub(super) fn list_metas(&self) -> Result<Vec<SessionMeta>> {
        let pending: Vec<Pending> = self.order.lock_or_recover().metas.values().cloned().collect();
        let mut listed = Store::list(&self.local)?;
        let mut at: HashMap<String, usize> =
            listed.iter().enumerate().map(|(index, meta)| (meta.id.clone(), index)).collect();
        for pending in pending {
            let here = folder_id(&self.local.dir(&pending.meta.id)).ok().flatten();
            if here != Some(pending.folder) {
                continue;
            }
            match at.get(&pending.meta.id) {
                Some(&index) => {
                    if let Some(slot) = listed.get_mut(index) {
                        *slot = pending.meta;
                    }
                }
                None => {
                    at.insert(pending.meta.id.clone(), listed.len());
                    listed.push(pending.meta);
                }
            }
        }
        Ok(listed)
    }

    /// Writes `id`'s overlay image to its `session.json` now, once its record is durable: for
    /// `session_dir` and `flush_session`, which hand the folder to code that reads or moves its
    /// files ([module docs](self)). Nothing to do without one.
    pub(super) fn settle_meta(&self, id: &str) -> Result<()> {
        let Some(pending) = self.order.lock_or_recover().metas.get(id).cloned() else {
            return Ok(());
        };
        #[cfg(test)]
        hold_settle(id);
        // Durable first (E13: an image names only lines the journal holds). The journal syncs in
        // write order (macOS `F_BARRIERFSYNC`, a barrier on the drive), and so does the image,
        // after the record's sync: a power loss that keeps the image keeps the record, so an
        // image never holds a `journalLsn` the journal lost (review of #35483, refuted item). A
        // sync of `session.json` that orders nothing must first wait for
        // `Journal::full_durable_lsn`.
        self.journal
            .wait_durable(pending.lsn, SEAL_WAIT)
            .map_err(|error| anyhow::anyhow!("the event journal: {error}"))?;
        self.write_through(id, &pending)
    }

    /// The checkpoint's part: each image the overlay held when the checkpoint read its LSN (all
    /// durable by now) to its `session.json`.
    pub(super) fn project_metas(&self, metas: BTreeMap<String, Pending>) -> Result<()> {
        for (id, pending) in metas {
            self.write_through(&id, &pending)?;
        }
        Ok(())
    }

    /// Writes `pending` (a durable image of chat `id`) to its folder's `session.json` and drops
    /// it from the overlay unless a newer one came. A folder that is gone or replaced is never
    /// made or written: the image goes aside. A chat deleted since (no overlay entry) is passed.
    /// A file that holds this image or a newer one is not written again (F2 of the review of
    /// #35483: a settle that read its image before a checkpoint wrote a newer one). A failed sync
    /// freezes the checkpoint, as a failed log sync does (F3).
    fn write_through(&self, id: &str, pending: &Pending) -> Result<()> {
        // Against a delete's removal of the folder (`Store::delete` drops the entry first).
        let _folder = self.folders.lock_or_recover();
        // Deleted since, or deleted and made again in another folder: nothing of this image.
        let current = self.order.lock_or_recover().metas.get(id).map(|now| now.folder);
        if current != Some(pending.folder) {
            return Ok(());
        }
        let dir = self.local.dir(id);
        let here = folder_id(&dir).with_context(|| format!("stat {}", dir.display()))?;
        if here == Some(pending.folder) {
            let held = matches!(
                session_file(&dir, self.journal.journal_id()),
                Ok(SessionFile::Journaled(lsn)) if lsn >= pending.lsn
            );
            if !held {
                // Counted, the checkpoint's own write too: a failed sync freezes the store (F3),
                // and a checkpoint under way never writes an LSN past it.
                self.counted_sync("a chat's metadata failed to sync", || {
                    write_session_json(&dir, &pending.meta, pending.lsn, self.journal.journal_id())
                })
                .with_context(|| format!("write the metadata of {id}"))?;
            }
        } else {
            let image = serde_json::to_vec(&pending.meta)?;
            // Counted as the image's write is: a failed sync of the kept file or its folder
            // freezes the store, so no checkpoint retires the image's record (#35905).
            let kept = self.counted_sync("a kept-aside chat's metadata failed to sync", || {
                self.keep_aside_meta(id, pending.lsn, &image)
            })?;
            tracing::warn!(session = %id, kept = %kept.display(), "the chat's folder was removed or replaced outside the store: its metadata is kept aside");
        }
        let mut order = self.order.lock_or_recover();
        if order.metas.get(id).is_some_and(|now| now.lsn == pending.lsn) {
            order.metas.remove(id);
        }
        Ok(())
    }

    /// The replay's part: each chat's newest image into the overlay (the checkpoint, on its own
    /// thread, writes it to `session.json`: no sync per replayed chat before the daemon serves)
    /// when its folder is the one the image was saved for and the file holds an older image the
    /// journal wrote, a file one of its records saw, or none. The image goes aside when the
    /// folder is gone (removed: never made again, [module docs](self)) or replaced, or when its
    /// `session.json` moved on without the journal (F1 of the review of #35483).
    pub(super) fn apply_metas(&self, metas: BTreeMap<String, Replayed>) -> Result<()> {
        for (chat, replayed) in metas {
            let dir = self.local.dir(&chat);
            let meta: SessionMeta = match serde_json::from_slice(&replayed.image) {
                Ok(meta) => meta,
                Err(error) => {
                    let kept = self.keep_aside_meta(&chat, replayed.lsn, &replayed.image)?;
                    tracing::error!(session = %chat, kept = %kept.display(), "a journaled metadata image does not read: {error}");
                    continue;
                }
            };
            let why = match folder_id(&dir) {
                Ok(Some(here)) if here == replayed.folder => {
                    match session_file(&dir, self.journal.journal_id()) {
                        Ok(SessionFile::Journaled(lsn)) if lsn >= replayed.lsn => continue,
                        Ok(SessionFile::Journaled(_) | SessionFile::Missing) => None,
                        Ok(SessionFile::Plain(stamp)) if replayed.saw.contains(&stamp) => None,
                        Ok(SessionFile::Plain(_)) => Some(
                            "its session.json changed without this journal since (a run with store.journal off, an older build, or another journal)",
                        ),
                        Err(_) => Some("its session.json does not read"),
                    }
                }
                Ok(Some(_)) => Some("its folder was replaced since"),
                Ok(None) => Some("its folder is gone"),
                Err(_) => Some("its folder does not read"),
            };
            if let Some(why) = why {
                let kept = self.keep_aside_meta(&chat, replayed.lsn, &replayed.image)?;
                tracing::error!(session = %chat, kept = %kept.display(), "journaled metadata of a chat not written again: {why}");
                continue;
            }
            self.order
                .lock_or_recover()
                .metas
                .insert(chat, Pending { lsn: replayed.lsn, meta, folder: replayed.folder });
        }
        Ok(())
    }

    /// Keeps a chat's metadata image beside the logs:
    /// `<home>/journal-unapplied/<id>.<lsn>.session.json`, owner-only, written whole under a
    /// temporary name, synced, renamed into place, the folder synced (`Inner::write_kept`; an
    /// error at any step is returned, as for kept lines). A new file each time, so a restart that
    /// keeps the image aside again after a failed folder sync makes its entry again (review of
    /// #35963, finding 1): the folder's next sync covers that new entry.
    fn keep_aside_meta(&self, id: &str, lsn: Lsn, image: &[u8]) -> Result<PathBuf> {
        self.write_kept(id, &format!("{lsn}.session.json"), None, &[image.to_vec()])
    }
}
