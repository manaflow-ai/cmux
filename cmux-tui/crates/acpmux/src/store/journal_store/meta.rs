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

use super::*;

/// A chat's metadata image: chat id, flags, its folder's identity, the image as compact JSON.
pub(super) const KIND_META: u16 = 4;
/// Flag: the chat's folder did not exist when its record was appended (its first save).
const CREATED: u8 = 1;
/// The key `session.json` keeps the LSN of the image it holds under (absent without the journal):
/// the replay never writes an older image over a newer one.
const JOURNAL_LSN_KEY: &str = "journalLsn";

/// One chat folder: its file id and birth time (0 where the file system has none). A folder
/// renamed away and back keeps it; another folder made under the same path does not.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) struct FolderId {
    ino: u64,
    birth_ns: u64,
}

/// A folder's file id (its inode); 0 where the platform gives none (its birth time then tells
/// two folders apart).
#[cfg(unix)]
fn file_id(meta: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.ino()
}

#[cfg(not(unix))]
fn file_id(_meta: &std::fs::Metadata) -> u64 {
    0
}

/// The identity of the folder at `dir`; `None` when there is none.
fn folder_id(dir: &Path) -> std::io::Result<Option<FolderId>> {
    match std::fs::symlink_metadata(dir) {
        Ok(meta) => {
            let birth_ns = meta
                .created()
                .ok()
                .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX));
            Ok(Some(FolderId { ino: file_id(&meta), birth_ns }))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
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
    /// A record of the replay made the chat (its folder may be lost with it).
    created: bool,
}

/// The size of a `meta` record's payload: chat id length, chat id, flags, folder, image.
fn meta_payload_len(id: &str, image: &[u8]) -> usize {
    21usize.saturating_add(id.len()).saturating_add(image.len())
}

fn encode_meta(id: &str, created: bool, folder: FolderId, image: &[u8]) -> Vec<u8> {
    let len = u32::try_from(id.len()).unwrap_or(u32::MAX);
    let mut payload = Vec::with_capacity(meta_payload_len(id, image));
    payload.extend_from_slice(&len.to_le_bytes());
    payload.extend_from_slice(id.as_bytes());
    payload.push(if created { CREATED } else { 0 });
    payload.extend_from_slice(&folder.ino.to_le_bytes());
    payload.extend_from_slice(&folder.birth_ns.to_le_bytes());
    payload.extend_from_slice(image);
    payload
}

fn decode_meta(payload: &[u8]) -> Option<(String, bool, FolderId, &[u8])> {
    let len = usize::try_from(u32::from_le_bytes(payload.get(..4)?.try_into().ok()?)).ok()?;
    let end = 4usize.checked_add(len)?;
    let id = std::str::from_utf8(payload.get(4..end)?).ok()?;
    let flags = *payload.get(end)?;
    let at = end.checked_add(1)?;
    let ino = u64::from_le_bytes(payload.get(at..at.checked_add(8)?)?.try_into().ok()?);
    let at = at.checked_add(8)?;
    let birth_ns = u64::from_le_bytes(payload.get(at..at.checked_add(8)?)?.try_into().ok()?);
    let image = payload.get(at.checked_add(8)?..)?;
    Some((id.to_owned(), flags & CREATED != 0, FolderId { ino, birth_ns }, image))
}

/// `session.json` for `meta`, written as `LocalStore::save` writes it, with the image's LSN.
fn session_json(meta: &SessionMeta, lsn: Lsn) -> Result<Vec<u8>> {
    let mut text = serde_json::to_string_pretty(meta)?;
    // The struct's field order kept: the key goes before the closing brace of a non-empty object.
    let Some(close) = text.rfind('}') else { anyhow::bail!("a chat's metadata is not an object") };
    let body = text.get(..close).unwrap_or_default().trim_end().to_owned();
    text = format!("{body},\n  \"{JOURNAL_LSN_KEY}\": {lsn}\n}}");
    Ok(text.into_bytes())
}

/// The LSN `dir`'s `session.json` holds an image under; 0 without one.
fn session_json_lsn(dir: &Path) -> Lsn {
    #[derive(Deserialize)]
    struct Only {
        #[serde(default, rename = "journalLsn")]
        journal_lsn: Lsn,
    }
    std::fs::read(dir.join("session.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Only>(&bytes).ok())
        .map_or(0, |only| only.journal_lsn)
}

/// Writes `meta` (the image of LSN `lsn`) to `dir`'s `session.json`: whole under a temporary
/// name (owner-only, never through a symlink), synced in write order, renamed into place, the
/// folder synced in write order. The checkpoint that writes it (or recovery's, which ends the
/// open) flushes the drive once afterward (`write_checkpoint`), so a power loss keeps it too:
/// one drive flush per checkpoint, not two per chat (29 ms per replayed chat on macOS before,
/// fleet ead05e82).
#[cfg(unix)]
fn write_session_json(dir: &Path, meta: &SessionMeta, lsn: Lsn) -> Result<()> {
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
        file.write_all(&session_json(meta, lsn)?)
            .with_context(|| format!("write {}", tmp.display()))?;
        log_sync::sync_segment_ordered(&file).with_context(|| format!("sync {}", tmp.display()))?;
        drop(file);
        std::fs::rename(&tmp, &path).with_context(|| format!("rename to {}", path.display()))?;
        log_sync::sync_directory_ordered(dir)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

/// Writes `meta` (the image of LSN `lsn`) to `dir`'s `session.json`, durably.
#[cfg(not(unix))]
fn write_session_json(dir: &Path, meta: &SessionMeta, lsn: Lsn) -> Result<()> {
    crate::config::write_atomic(&dir.join("session.json"), &session_json(meta, lsn)?)
}

impl super::repair::Replay {
    /// A `meta` record: the chat's newest image so far.
    pub(super) fn take_meta(
        &mut self,
        record: &cmux_journal::Record<'_>,
    ) -> std::result::Result<(), String> {
        let (chat, created, folder, image) = decode_meta(record.payload)
            .ok_or_else(|| format!("meta record {} does not read", record.lsn))?;
        // Made by an earlier record of this replay, for the same folder.
        let created = created
            || self
                .metas
                .get(&chat)
                .is_some_and(|replayed| replayed.created && replayed.folder == folder);
        self.metas
            .insert(chat, Replayed { lsn: record.lsn, image: image.to_vec(), folder, created });
        Ok(())
    }
}

impl Inner {
    /// `Store::save` with the journal: the `meta` record and the overlay, no file written
    /// ([module docs](self)).
    pub(super) fn save_meta(&self, meta: &SessionMeta) -> Result<()> {
        let image = serde_json::to_vec(meta)?;
        let dir = self.local.dir(&meta.id);
        let mut order = self.order.lock_or_recover();
        drop(self.local.writable()?);
        // Checked before the folder is made: a refused save makes nothing.
        self.journal
            .check_append(meta_payload_len(&meta.id, &image))
            .map_err(JournalStore::journal_error)?;
        let created = folder_id(&dir)?.is_none();
        if created {
            // The checkpoint syncs the sessions folder; the replay makes a lost one again.
            crate::config::private_state_dir(&dir)?;
        }
        let Some(folder) = folder_id(&dir)? else {
            anyhow::bail!("the folder of chat {} is gone", meta.id);
        };
        let payload = encode_meta(&meta.id, created, folder, &image);
        let lsn = self
            .journal
            .append(KIND_META, Class::Ack, &payload)
            .map_err(JournalStore::journal_error)?;
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
    /// The overlay is read first and the files after: a checkpoint writes a file before it drops
    /// the file's overlay entry, so either read has the newest image.
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
            write_session_json(&dir, &pending.meta, pending.lsn)
                .with_context(|| format!("write the metadata of {id}"))?;
        } else {
            let image = serde_json::to_vec(&pending.meta)?;
            let kept = self.keep_aside_meta(id, pending.lsn, &image)?;
            tracing::warn!(session = %id, kept = %kept.display(), "the chat's folder was removed or replaced outside the store: its metadata is kept aside");
        }
        let mut order = self.order.lock_or_recover();
        if order.metas.get(id).is_some_and(|now| now.lsn == pending.lsn) {
            order.metas.remove(id);
        }
        Ok(())
    }

    /// The replay's part: each chat's newest image into the overlay (the checkpoint writes it to
    /// `session.json`) when its folder is the one the image was saved for and the file holds an
    /// older image. A missing folder is made again only for a chat a replayed record made; else
    /// the chat was deleted or removed outside the daemon, and its image goes aside, as does the
    /// image of a folder replaced since.
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
                    if session_json_lsn(&dir) >= replayed.lsn {
                        continue;
                    }
                    None
                }
                Ok(Some(_)) => Some("its folder was replaced since"),
                Ok(None) if replayed.created => None,
                Ok(None) => Some("its folder is gone"),
                Err(_) => Some("its folder does not read"),
            };
            if let Some(why) = why {
                let kept = self.keep_aside_meta(&chat, replayed.lsn, &replayed.image)?;
                tracing::error!(session = %chat, kept = %kept.display(), "journaled metadata of a chat not written again: {why}");
                continue;
            }
            // A folder a crash lost is made again here (the log repair after this writes its lines
            // into it); the image goes to the overlay, and the checkpoint on its own thread writes
            // `session.json` (no sync per replayed chat before the daemon serves).
            if let Err(error) = crate::config::private_state_dir(&dir) {
                let kept = self.keep_aside_meta(&chat, replayed.lsn, &replayed.image)?;
                tracing::error!(session = %chat, kept = %kept.display(), "the chat's folder could not be made: {error:#}");
                continue;
            }
            let folder = match folder_id(&dir) {
                Ok(Some(folder)) => folder,
                _ => {
                    let kept = self.keep_aside_meta(&chat, replayed.lsn, &replayed.image)?;
                    tracing::error!(session = %chat, kept = %kept.display(), "the chat's folder does not read after it was made");
                    continue;
                }
            };
            self.order
                .lock_or_recover()
                .metas
                .insert(chat, Pending { lsn: replayed.lsn, meta, folder });
        }
        Ok(())
    }

    /// Keeps a chat's metadata image beside the logs:
    /// `<home>/journal-unapplied/<id>.<lsn>.session.json`, owner-only and synced.
    fn keep_aside_meta(&self, id: &str, lsn: Lsn, image: &[u8]) -> Result<PathBuf> {
        let dir = self.home.join(UNAPPLIED_DIR);
        crate::config::refuse_lost_home(&dir)?;
        crate::config::private_state_dir(&dir)?;
        let name: String = id
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') { c } else { '_' })
            .collect();
        let path = dir.join(format!("{name}.{lsn}.session.json"));
        crate::config::write_atomic(&path, image)?;
        Ok(path)
    }
}
