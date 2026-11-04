//! Chat metadata through the journal (R-DURABILITY S3a; DESIGN.md 3.3e): a metadata change is a
//! `meta` record that carries the chat's whole metadata image; an overlay keeps every read
//! current until a checkpoint writes `session.json`; the replay writes the newest image of each
//! chat ([module docs](super)).

use super::*;

/// A chat's metadata image: chat id, flags, the image as compact JSON.
pub(super) const KIND_META: u16 = 4;
/// Flag: the chat's folder did not exist when its record was appended (its first save).
const CREATED: u8 = 1;
/// The key `session.json` keeps the LSN of the image it holds under (absent without the journal):
/// the replay never writes an older image over a newer one.
const JOURNAL_LSN_KEY: &str = "journalLsn";

/// The newest image of a chat that its `session.json` does not hold yet.
#[derive(Clone)]
pub(super) struct Pending {
    pub(super) lsn: Lsn,
    pub(super) meta: SessionMeta,
    /// The LSN of the first image of this entry: a chat deleted and made again under the same id
    /// gets a new entry, so a checkpoint never writes the old chat's image into the new folder.
    since: Lsn,
}

/// The newest replayed image of a chat, after its last `forget`.
pub(super) struct Replayed {
    lsn: Lsn,
    image: Vec<u8>,
    /// A record of the replay made the chat (its folder may be lost with it).
    created: bool,
}

fn encode_meta(id: &str, created: bool, image: &[u8]) -> Vec<u8> {
    let len = u32::try_from(id.len()).unwrap_or(u32::MAX);
    let mut payload =
        Vec::with_capacity(5usize.saturating_add(id.len()).saturating_add(image.len()));
    payload.extend_from_slice(&len.to_le_bytes());
    payload.extend_from_slice(id.as_bytes());
    payload.push(if created { CREATED } else { 0 });
    payload.extend_from_slice(image);
    payload
}

fn decode_meta(payload: &[u8]) -> Option<(String, bool, &[u8])> {
    let len = usize::try_from(u32::from_le_bytes(payload.get(..4)?.try_into().ok()?)).ok()?;
    let end = 4usize.checked_add(len)?;
    let id = std::str::from_utf8(payload.get(4..end)?).ok()?;
    let flags = *payload.get(end)?;
    Some((id.to_owned(), flags & CREATED != 0, payload.get(end.checked_add(1)?..)?))
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

/// Writes `meta` (the image of LSN `lsn`) to `dir`'s `session.json`, durably.
fn write_session_json(dir: &Path, meta: &SessionMeta, lsn: Lsn) -> Result<()> {
    crate::config::write_atomic(&dir.join("session.json"), &session_json(meta, lsn)?)
}

impl super::repair::Replay {
    /// A `meta` record: the chat's newest image so far.
    pub(super) fn take_meta(
        &mut self,
        record: &cmux_journal::Record<'_>,
    ) -> std::result::Result<(), String> {
        let (chat, created, image) = decode_meta(record.payload)
            .ok_or_else(|| format!("meta record {} does not read", record.lsn))?;
        let created = created || self.metas.get(&chat).is_some_and(|replayed| replayed.created);
        self.metas.insert(chat, Replayed { lsn: record.lsn, image: image.to_vec(), created });
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
        let created = match std::fs::symlink_metadata(&dir) {
            Ok(_) => false,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
            Err(error) => return Err(error.into()),
        };
        let payload = encode_meta(&meta.id, created, &image);
        self.journal.check_append(payload.len()).map_err(JournalStore::journal_error)?;
        if created {
            // The checkpoint syncs the sessions folder; the replay makes a lost one again.
            crate::config::private_state_dir(&dir)?;
        }
        let lsn = self
            .journal
            .append(KIND_META, Class::Ack, &payload)
            .map_err(JournalStore::journal_error)?;
        self.acked.store(lsn, std::sync::atomic::Ordering::SeqCst);
        order.applied = lsn;
        order.bytes = order.bytes.saturating_add(u64::try_from(payload.len()).unwrap_or(u64::MAX));
        let since = order.metas.get(&meta.id).map_or(lsn, |pending| pending.since);
        order.metas.insert(meta.id.clone(), Pending { lsn, meta: meta.clone(), since });
        let full = order.bytes > CHECKPOINT_BYTES && !order.frozen;
        drop(order);
        if full {
            self.want_checkpoint();
        }
        Ok(())
    }

    /// The overlay's image of `id`, when its `session.json` does not hold it yet.
    pub(super) fn pending_meta(&self, id: &str) -> Option<SessionMeta> {
        self.order.lock_or_recover().metas.get(id).map(|pending| pending.meta.clone())
    }

    /// `Store::list` with the journal: the logs' listing with the overlay's images over it. The
    /// projection lock keeps a checkpoint from writing a file and dropping its overlay entry
    /// between the two reads.
    pub(super) fn list_metas(&self) -> Result<Vec<SessionMeta>> {
        let _reading = self.projection.read().unwrap_or_else(std::sync::PoisonError::into_inner);
        let pending: Vec<SessionMeta> = self
            .order
            .lock_or_recover()
            .metas
            .values()
            .map(|pending| pending.meta.clone())
            .collect();
        let mut listed = Store::list(&self.local)?;
        let mut at: HashMap<String, usize> =
            listed.iter().enumerate().map(|(index, meta)| (meta.id.clone(), index)).collect();
        for meta in pending {
            match at.get(&meta.id) {
                Some(&index) => {
                    if let Some(slot) = listed.get_mut(index) {
                        *slot = meta;
                    }
                }
                None => {
                    at.insert(meta.id.clone(), listed.len());
                    listed.push(meta);
                }
            }
        }
        Ok(listed)
    }

    /// The checkpoint's part: each image the overlay held when the checkpoint read its LSN (all
    /// durable by now) to its `session.json`, then out of the overlay unless a newer one came. A
    /// chat deleted meanwhile is passed.
    pub(super) fn project_metas(&self, metas: BTreeMap<String, Pending>) -> Result<()> {
        let _writing = self.projection.write().unwrap_or_else(std::sync::PoisonError::into_inner);
        for (id, pending) in metas {
            // Against a delete's removal of the folder (`Store::delete`): a chat deleted since
            // has no overlay entry, or one made again has a new one.
            let _folder = self.folders.lock_or_recover();
            let same = self
                .order
                .lock_or_recover()
                .metas
                .get(&id)
                .is_some_and(|now| now.since == pending.since);
            if !same {
                continue;
            }
            let dir = self.local.dir(&id);
            crate::config::private_state_dir(&dir)?;
            write_session_json(&dir, &pending.meta, pending.lsn)
                .with_context(|| format!("write the metadata of {id}"))?;
            let mut order = self.order.lock_or_recover();
            if order.metas.get(&id).is_some_and(|now| now.lsn == pending.lsn) {
                order.metas.remove(&id);
            }
        }
        Ok(())
    }

    /// The replay's part: each chat's newest image to its `session.json` when newer than the
    /// file's. A missing folder is made again only for a chat a replayed record made; else the
    /// chat was deleted or removed outside the daemon, and its image goes aside.
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
            let exists = std::fs::symlink_metadata(&dir).is_ok();
            if !exists && !replayed.created {
                let kept = self.keep_aside_meta(&chat, replayed.lsn, &replayed.image)?;
                tracing::error!(session = %chat, kept = %kept.display(), "journaled metadata of a chat whose folder is gone: not written again");
                continue;
            }
            if exists && session_json_lsn(&dir) >= replayed.lsn {
                continue;
            }
            let written = crate::config::private_state_dir(&dir)
                .and_then(|()| write_session_json(&dir, &meta, replayed.lsn));
            if let Err(error) = written {
                let kept = self.keep_aside_meta(&chat, replayed.lsn, &replayed.image)?;
                tracing::error!(session = %chat, kept = %kept.display(), "the chat's metadata could not be written: {error:#}");
            }
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
