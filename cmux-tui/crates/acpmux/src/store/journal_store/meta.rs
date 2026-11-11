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
//! A run without the journal (an older build) can
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
//!
//! A change journals only the fields it changed ([`KIND_META_PATCH`]): the fields whose value
//! differs from the chat's previous record of this process, and the fields it no longer has, over
//! that record (its base). A save that changes nothing journals nothing. Before, every change
//! journaled the whole image: 26 KB on average on a busy machine (2026-11-11: 463
//! records in 16 minutes, 45% of the journal's bytes), mostly fields that never change
//! (`cmuxContext`, `contextBreakdown`, `configOptions`), for a change of one counter or flag
//! (`hibernatedMs`, `seenSeq`, `idleLaunch`): the `pwrite` and `write` of disk-write reports
//! against the daemon (cmuxterm-hq#9262, #9263). A chat's first record in a process, one in a
//! new folder, one whose save saw a `session.json` this store did not write, and a chat's first
//! change after the checkpoint wrote its `session.json` are whole images: a chain starts at a
//! whole image in the journal, never at a file a transfer's swap may replace.
//!
//! The replay rebuilds a chain: the patches over the whole image before them. A patch journaled
//! while the checkpoint was writing its base through has that base retired: it applies over the
//! `session.json` the checkpoint wrote (it holds the base or a newer image of the same chain: a
//! checkpoint retires a record only after it wrote that chat's newest image through it). A chain
//! whose base it cannot find goes aside, as an image whose `session.json` moved on does.

use super::*;

/// A chat's metadata image: chat id, flags, its folder's identity, the stamp of the
/// `session.json` its save saw (with [`SAW_FILE`]), the image as compact JSON.
pub(super) const KIND_META: u16 = 4;
/// A chat's metadata change over its previous record: the header of [`KIND_META`], then the
/// base record's LSN (8 bytes), then `{"set": {field: value, ...}, "unset": [field, ...]}`.
/// (Kind 5 was planned for S3 and never used; 6 is `frozen`.)
pub(super) const KIND_META_PATCH: u16 = 7;
/// Flag: the save saw a `session.json`; its stamp follows the folder's identity.
const SAW_FILE: u8 = 1;
/// The key `session.json` keeps the LSN of the image it holds under (absent without the journal):
/// the replay never writes an older image over a newer one.
const JOURNAL_LSN_KEY: &str = "journalLsn";
/// The key beside it with the id of the journal that gave the LSN, as 16 hex digits (a string: a
/// JSON reader may keep a number only to 2^53).
const JOURNAL_ID_KEY: &str = "journalId";

#[cfg(test)]
type SettleHold = (String, std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>);

/// Tests: a `settle_meta` of the chat this names stops right after it read the chat's image,
/// says so on the first channel and waits for the second. Only [`on_settle_hold`] sets it.
///
/// One per process, not per thread: the settle it stops runs on another thread than the test's.
/// So [`on_settle_hold`] holds [`SETTLE_HOLD_TEST`] until its guard drops, and a second test's
/// hold waits for the first instead of replacing or clearing it before its settle ran.
// test-hook-allow: serialized by SETTLE_HOLD_TEST, held by on_settle_hold until its guard drops
#[cfg(test)]
static SETTLE_HOLD: std::sync::Mutex<Option<SettleHold>> = std::sync::Mutex::new(None);
/// The tests that hold a settle run one at a time ([`SETTLE_HOLD`]).
#[cfg(test)]
static SETTLE_HOLD_TEST: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The hold [`on_settle_hold`] set; dropping it takes the hold off and lets the next test's in.
#[cfg(test)]
pub(crate) struct SettleHoldGuard {
    _serial: std::sync::MutexGuard<'static, ()>,
}

#[cfg(test)]
impl Drop for SettleHoldGuard {
    fn drop(&mut self) {
        SETTLE_HOLD.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    }
}

/// Stops the next settle of `chat` right after it read the chat's image: it sends on `arrived`
/// and waits on `release`. Waits for another test's hold to end first.
#[cfg(test)]
pub(crate) fn on_settle_hold(
    chat: &str,
    arrived: std::sync::mpsc::Sender<()>,
    release: std::sync::mpsc::Receiver<()>,
) -> SettleHoldGuard {
    let serial = SETTLE_HOLD_TEST.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    *SETTLE_HOLD.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
        Some((chat.to_owned(), arrived, release));
    SettleHoldGuard { _serial: serial }
}

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

/// The image `dir`'s `session.json` holds when this journal (`journal`) wrote it: its LSN and the
/// image as compact JSON, without the journal's keys. `None` for any other file, or none.
fn journaled_image(dir: &Path, journal: u64) -> Option<(Lsn, Vec<u8>)> {
    let path = dir.join("session.json");
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut crate::config::private_state_file(&path).ok()?, &mut bytes)
        .ok()?;
    let mut object: serde_json::Map<String, Value> = serde_json::from_slice(&bytes).ok()?;
    let lsn = object.remove(JOURNAL_LSN_KEY)?.as_u64().filter(|lsn| *lsn > 0)?;
    let id = object.remove(JOURNAL_ID_KEY)?;
    (id.as_str() == Some(journal_id_text(journal).as_str())).then_some(())?;
    Some((lsn, serde_json::to_vec(&object).ok()?))
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
    image: Image,
    folder: FolderId,
    /// The `session.json` files the chat's replayed records (for this folder) saw: a file the
    /// journal did not write is written over only when it is one of them.
    saw: Vec<FileStamp>,
}

/// A replayed chat's image through its newest record.
enum Image {
    /// Whole: a whole image, with the patches after it applied.
    Whole(Vec<u8>),
    /// Patches over the image of `base`, a record the checkpoint retired: its `session.json`
    /// holds that image or a newer one of the same chain.
    Chain { base: Lsn, patches: Vec<(Lsn, Vec<u8>)> },
    /// A chain that does not read (a patch whose base is not the record before it, or a body
    /// that does not parse): kept aside, never applied.
    Broken { why: String, bodies: Vec<Vec<u8>> },
}

impl Image {
    /// What goes aside for it: the image, or the patches (one JSON body per line).
    fn aside(&self) -> Vec<u8> {
        match self {
            Self::Whole(image) => image.clone(),
            Self::Chain { patches, .. } => {
                patches.iter().flat_map(|(_, body)| body.iter().copied().chain([b'\n'])).collect()
            }
            Self::Broken { bodies, .. } => {
                bodies.iter().flat_map(|body| body.iter().copied().chain([b'\n'])).collect()
            }
        }
    }
}

/// What this process last journaled of a chat: the base of its next patch.
pub(super) struct LastImage {
    lsn: Lsn,
    folder: FolderId,
    /// The image's top-level field names, sorted: one shared list for every chat with the same
    /// fields (the store holds every chat's metadata for the sidebar's list).
    names: Arc<[Arc<str>]>,
    /// Each field's value hash, in `names`' order.
    hashes: Box<[u64]>,
    /// The `session.json` that record saw, or the one this store wrote since.
    saw: Option<FileStamp>,
    /// The checkpoint wrote `session.json` since: the next change journals a whole image, so a
    /// patch's base is a record in the journal, never a file a later swap may replace.
    whole_next: bool,
}

impl LastImage {
    /// Whether a record whose save saw `saw` in folder `folder` may skip or patch over this one.
    fn base_for(&self, folder: FolderId, saw: Option<FileStamp>) -> bool {
        self.folder == folder && saw == self.saw
    }
}

/// The interned name list of `fields`, sorted, and their value hashes in that order.
fn shape(fields: &[(String, &serde_json::value::RawValue)]) -> (Arc<[Arc<str>]>, Box<[u64]>) {
    static SHAPES: std::sync::LazyLock<Mutex<std::collections::HashSet<Arc<[Arc<str>]>>>> =
        std::sync::LazyLock::new(Default::default);
    let mut sorted: Vec<&(String, &serde_json::value::RawValue)> = fields.iter().collect();
    sorted.sort_unstable_by(|a, b| a.0.cmp(&b.0));
    let names: Vec<Arc<str>> = sorted.iter().map(|(name, _)| intern(name)).collect();
    let hashes = sorted.iter().map(|(_, value)| fnv(value.get().as_bytes())).collect();
    let mut shapes = SHAPES.lock_or_recover();
    if let Some(known) = shapes.get(names.as_slice()) {
        return (Arc::clone(known), hashes);
    }
    let names: Arc<[Arc<str>]> = Arc::from(names);
    shapes.insert(Arc::clone(&names));
    (names, hashes)
}

/// A field name, shared by every chat's [`LastImage`]: the names are the metadata's own keys.
fn intern(name: &str) -> Arc<str> {
    static NAMES: std::sync::LazyLock<Mutex<std::collections::HashSet<Arc<str>>>> =
        std::sync::LazyLock::new(Default::default);
    let mut names = NAMES.lock_or_recover();
    if let Some(known) = names.get(name) {
        return Arc::clone(known);
    }
    let name: Arc<str> = Arc::from(name);
    names.insert(Arc::clone(&name));
    name
}

/// FNV-1a 64 of `bytes`: stable, nothing allocated.
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, &b| {
        (hash ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// The top-level fields of a compact image, each with its raw JSON value.
fn raw_fields(image: &[u8]) -> Result<Vec<(String, &serde_json::value::RawValue)>> {
    struct Fields<'a>(Vec<(String, &'a serde_json::value::RawValue)>);
    impl<'de> Deserialize<'de> for Fields<'de> {
        fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
            struct Visit;
            impl<'de> serde::de::Visitor<'de> for Visit {
                type Value = Fields<'de>;
                fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                    f.write_str("a JSON object")
                }
                fn visit_map<A: serde::de::MapAccess<'de>>(
                    self,
                    mut map: A,
                ) -> std::result::Result<Self::Value, A::Error> {
                    let mut out = Vec::new();
                    while let Some(entry) = map.next_entry()? {
                        out.push(entry);
                    }
                    Ok(Fields(out))
                }
            }
            d.deserialize_map(Visit)
        }
    }
    Ok(serde_json::from_slice::<Fields<'_>>(image)?.0)
}

/// The patch body of `fields` (a new image's) over `last` (sorted by name): `None` when no
/// field changed.
fn patch_body(
    fields: &[(String, &serde_json::value::RawValue)],
    last: &LastImage,
) -> Result<Option<Vec<u8>>> {
    let was = |name: &str| {
        last.names
            .binary_search_by(|have| (**have).cmp(name))
            .ok()
            .and_then(|at| last.hashes.get(at))
    };
    let mut set = Vec::new();
    for (name, value) in fields {
        if was(name).copied() != Some(fnv(value.get().as_bytes())) {
            set.push((name, value));
        }
    }
    let unset: Vec<&str> = last
        .names
        .iter()
        .map(|name| &**name)
        .filter(|name| !fields.iter().any(|(have, _)| have == name))
        .collect();
    if set.is_empty() && unset.is_empty() {
        return Ok(None);
    }
    let mut body = Vec::from(&b"{\"set\":{"[..]);
    for (index, (name, value)) in set.iter().enumerate() {
        if index > 0 {
            body.push(b',');
        }
        serde_json::to_writer(&mut body, name)?;
        body.push(b':');
        body.extend_from_slice(value.get().as_bytes());
    }
    body.extend_from_slice(b"},\"unset\":");
    serde_json::to_writer(&mut body, &unset)?;
    body.push(b'}');
    Ok(Some(body))
}

/// A patch's body as written: the fields it sets and the fields it removes.
#[derive(Deserialize)]
struct PatchBody {
    set: serde_json::Map<String, Value>,
    #[serde(default)]
    unset: Vec<String>,
}

/// `image` (a compact JSON object) with the patch `body` applied.
fn apply_patch(image: &[u8], body: &[u8]) -> std::result::Result<Vec<u8>, String> {
    let mut object: serde_json::Map<String, Value> =
        serde_json::from_slice(image).map_err(|e| format!("the base image does not read: {e}"))?;
    let patch: PatchBody =
        serde_json::from_slice(body).map_err(|e| format!("a patch does not read: {e}"))?;
    for name in patch.unset {
        object.remove(&name);
    }
    object.extend(patch.set);
    serde_json::to_vec(&object).map_err(|e| format!("the patched image does not write: {e}"))
}

/// The base LSN and the body of a [`KIND_META_PATCH`] record's image part.
fn split_patch(image: &[u8]) -> Option<(Lsn, &[u8])> {
    let base = u64::from_le_bytes(image.get(..8)?.try_into().ok()?);
    Some((base, image.get(8..)?))
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

/// `session.json` for `meta`, written as `LocalStore::save` writes it (its large fields in the
/// parts file, `parts` their fingerprint: `store/meta_parts.rs`), with the image's LSN and its
/// journal's id.
fn session_json(meta: &SessionMeta, parts: &str, lsn: Lsn, journal: u64) -> Result<Vec<u8>> {
    let mut text = meta_parts::to_string_pretty(meta, parts)?;
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
fn write_session_json(
    dir: &Path,
    meta: &SessionMeta,
    parts: &str,
    lsn: Lsn,
    journal: u64,
) -> Result<()> {
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
        file.write_all(&session_json(meta, parts, lsn, journal)?)
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
fn write_session_json(
    dir: &Path,
    meta: &SessionMeta,
    parts: &str,
    lsn: Lsn,
    journal: u64,
) -> Result<()> {
    crate::config::write_atomic(
        &dir.join("session.json"),
        &session_json(meta, parts, lsn, journal)?,
    )
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
        let prior =
            self.metas.remove(&decoded.chat).filter(|replayed| replayed.folder == decoded.folder);
        let (mut saw, prior) = match prior {
            Some(replayed) => (replayed.saw, Some((replayed.lsn, replayed.image))),
            None => (Vec::new(), None),
        };
        if let Some(stamp) = decoded.saw
            && !saw.contains(&stamp)
        {
            saw.push(stamp);
        }
        let image = if record.kind == KIND_META_PATCH {
            let (base, body) = split_patch(decoded.image)
                .ok_or_else(|| format!("meta patch {} does not read", record.lsn))?;
            match prior {
                // Its base was retired by the checkpoint: `session.json` holds it.
                None => Image::Chain { base, patches: vec![(record.lsn, body.to_vec())] },
                Some((lsn, Image::Whole(image))) if lsn == base => {
                    match apply_patch(&image, body) {
                        Ok(image) => Image::Whole(image),
                        Err(why) => Image::Broken { why, bodies: vec![image, body.to_vec()] },
                    }
                }
                Some((lsn, Image::Chain { base: first, mut patches })) if lsn == base => {
                    patches.push((record.lsn, body.to_vec()));
                    Image::Chain { base: first, patches }
                }
                Some((_, Image::Broken { why, mut bodies })) => {
                    bodies.push(body.to_vec());
                    Image::Broken { why, bodies }
                }
                Some((lsn, prior)) => Image::Broken {
                    why: format!(
                        "meta patch {} names base {base}, the record before it is {lsn}",
                        record.lsn
                    ),
                    bodies: vec![prior.aside(), body.to_vec()],
                },
            }
        } else {
            Image::Whole(decoded.image.to_vec())
        };
        self.metas
            .insert(decoded.chat, Replayed { lsn: record.lsn, image, folder: decoded.folder, saw });
        Ok(())
    }
}

impl Inner {
    /// `Store::save` with the journal: the `meta` record and the overlay, no file written
    /// ([module docs](self)). A kept change's record (`keep`, `super::durability`) is a `Stream`
    /// record, except the save that makes the chat's folder: a new chat is shown only once
    /// durable ([`super::new_folders`]).
    pub(super) fn save_meta(&self, meta: &SessionMeta, keep: ShowAfter) -> Result<()> {
        let dir = self.local.dir(&meta.id);
        // The large fields go to the parts file, only when they changed (`store/meta_parts.rs`),
        // before the record: the record's image is the rest. A new chat's folder is made below,
        // and its parts file after the record.
        let parts = match std::fs::symlink_metadata(&dir) {
            Ok(_) => {
                let _open = self.local.writable()?;
                Some(self.local.parts.write(&dir, meta)?)
            }
            Err(_) => None,
        };
        let image = match &parts {
            Some(parts) => meta_parts::to_vec(meta, parts)?,
            None => meta_parts::to_vec(meta, &meta_parts::fingerprint(meta))?,
        };
        // The file there now, stamped before the appends' lock: only the store's own writes
        // change it meanwhile, and a stamp of a file the store wrote is harmless (the replay
        // compares such a file's `journalLsn`, never its stamp).
        let saw = saw_file(&dir);
        let fields = raw_fields(&image)?;
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
        let kept = keep == ShowAfter::Written && !made;
        let shown = if kept { &self.kept } else { &self.acked };
        // Only the fields that changed since this chat's previous record ([module docs](self)).
        let base = order.images.get(&meta.id).filter(|last| last.base_for(folder, saw));
        let patch = match base {
            Some(last) => patch_body(&fields, last)?.map(|body| (last.lsn, body)),
            None => None,
        };
        if let Some(last) = base
            && patch.is_none()
            && saw == last.saw
        {
            // Nothing changed: no record. A reply that waits for this save waits for the record
            // that holds this image; the overlay keeps the fields no image holds.
            shown.fetch_max(last.lsn, std::sync::atomic::Ordering::SeqCst);
            if let Some(pending) = order.metas.get_mut(&meta.id)
                && pending.folder == folder
            {
                pending.meta = meta.clone();
            }
            return Ok(());
        }
        let (kind, payload) = match (base, patch) {
            (Some(last), Some((base_lsn, body)))
                if !last.whole_next && body.len().saturating_add(8) < image.len() =>
            {
                let mut part = Vec::with_capacity(body.len().saturating_add(8));
                part.extend_from_slice(&base_lsn.to_le_bytes());
                part.extend_from_slice(&body);
                (KIND_META_PATCH, encode_meta(&meta.id, folder, saw, &part))
            }
            _ => (KIND_META, encode_meta(&meta.id, folder, saw, &image)),
        };
        meta_parts::note_written(payload.len());
        // A kept record is a `Stream` record synced in the journal's idle time, so the next acked
        // change (a prompt) does not sync a burst of drafts in its own turn.
        let append = || {
            if kept {
                self.journal.append_kept(kind, &payload)
            } else {
                self.journal.append(kind, Class::Ack, &payload)
            }
            .map_err(JournalStore::journal_error)
        };
        // A new folder's record is held back from the gate until the folder's entry is synced.
        let lsn = if made { self.new_folders.append_made(append)? } else { append()? };
        shown.store(lsn, std::sync::atomic::Ordering::SeqCst);
        order.applied = lsn;
        order.bytes = order.bytes.saturating_add(u64::try_from(payload.len()).unwrap_or(u64::MAX));
        order.metas.insert(meta.id.clone(), Pending { lsn, meta: meta.clone(), folder });
        let (names, hashes) = shape(&fields);
        order.images.insert(
            meta.id.clone(),
            LastImage { lsn, folder, names, hashes, saw, whole_next: false },
        );
        let full = order.bytes > CHECKPOINT_BYTES && !order.frozen;
        drop(order);
        if parts.is_none()
            && let Err(error) = self.local.parts.write(&dir, meta)
        {
            // Its record holds no parts: the next save, or the checkpoint's write of this image
            // (`ensure`), writes them.
            self.local.parts.forget(&meta.id);
            tracing::warn!(session = %meta.id, "write the chat's metadata parts: {error}");
        }
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
        // Against a delete's removal of the folder (`Store::delete` drops the entry first), and
        // against the seal (`Inner::last_checkpoint`).
        let _folder = self.folders.lock_or_recover();
        let current = {
            let order = self.order.lock_or_recover();
            // Sealed: the home is the next daemon's, whose open applies the journaled image.
            if order.sealed {
                return Ok(());
            }
            order.metas.get(id).map(|now| now.folder)
        };
        // Deleted since, or deleted and made again in another folder: nothing of this image.
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
                // An image no save of this run split (replayed from an older build's journal)
                // writes its parts first (`store/meta_parts.rs`).
                let parts = self
                    .local
                    .parts
                    .ensure(&dir, &pending.meta)
                    .with_context(|| format!("write the metadata parts of {id}"))?;
                // Counted, the checkpoint's own write too: a failed sync freezes the store (F3),
                // and a checkpoint under way never writes an LSN past it.
                self.counted_sync("a chat's metadata failed to sync", || {
                    write_session_json(
                        &dir,
                        &pending.meta,
                        &parts,
                        pending.lsn,
                        self.journal.journal_id(),
                    )
                })
                .with_context(|| format!("write the metadata of {id}"))?;
                // A save that sees this file and changes nothing journals nothing (the file
                // holds this chain's image); one that changes something journals a whole image,
                // so no patch's base is this file ([module docs](self)).
                let stamp = saw_file(&dir);
                let mut order = self.order.lock_or_recover();
                if let Some(last) = order.images.get_mut(id)
                    && last.folder == pending.folder
                {
                    if stamp.is_some() {
                        last.saw = stamp;
                    }
                    last.whole_next = true;
                }
            }
        } else {
            let image = serde_json::to_vec(&pending.meta)?;
            // Counted as the image's write is: a failed sync of the kept file or its folder
            // freezes the store, so no checkpoint retires the image's record (#35905).
            let kept = self.counted_sync("a kept-aside chat's metadata failed to sync", || {
                self.keep_aside_meta(id, pending.lsn, &image)
            })?;
            tracing::warn!(session = %id, kept = %kept.display(), "the chat's folder was removed or replaced outside the store: its metadata is kept aside");
            // The folder's `session.json` never got this image, and the folder may come back
            // (a failed transfer renames it back, same identity): no patch may name this record
            // as its base, so the chat's next change journals a whole image.
            if let Some(last) = self.order.lock_or_recover().images.get_mut(id) {
                last.whole_next = true;
            }
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
            let image = match &replayed.image {
                Image::Whole(image) => image.clone(),
                Image::Chain { base, patches } => {
                    let here = folder_id(&dir).ok().flatten();
                    let held = (here == Some(replayed.folder))
                        .then(|| journaled_image(&dir, self.journal.journal_id()))
                        .flatten();
                    match held {
                        // The file holds the newest image already.
                        Some((lsn, _)) if lsn >= replayed.lsn => continue,
                        // The file holds the chain's base or a newer image of it: the patches
                        // after it, over it.
                        Some((lsn, image)) if lsn >= *base => {
                            let rebuilt = patches
                                .iter()
                                .filter(|(at, _)| *at > lsn)
                                .try_fold(image, |image, (_, body)| apply_patch(&image, body));
                            match rebuilt {
                                Ok(image) => image,
                                Err(why) => {
                                    let kept = self.keep_aside_image(
                                        &chat,
                                        replayed.lsn,
                                        &replayed.image,
                                    )?;
                                    tracing::error!(session = %chat, kept = %kept.display(), "journaled metadata changes of a chat do not apply: {why}");
                                    continue;
                                }
                            }
                        }
                        _ => {
                            let kept =
                                self.keep_aside_image(&chat, replayed.lsn, &replayed.image)?;
                            tracing::error!(session = %chat, kept = %kept.display(), "journaled metadata changes of a chat not written again: its session.json does not hold the image they change (its folder or file changed without this journal since)");
                            continue;
                        }
                    }
                }
                Image::Broken { why, .. } => {
                    let kept = self.keep_aside_image(&chat, replayed.lsn, &replayed.image)?;
                    tracing::error!(session = %chat, kept = %kept.display(), "journaled metadata changes of a chat do not read: {why}");
                    continue;
                }
            };
            let meta: SessionMeta = match serde_json::from_slice(&image) {
                Ok(mut meta) => {
                    // A split image's large fields are in its folder's parts file.
                    self.local.parts.merge(&dir, &image, &mut meta);
                    meta
                }
                Err(error) => {
                    let kept = self.keep_aside_meta(&chat, replayed.lsn, &image)?;
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
                            "its session.json changed without this journal since (an older build, or another journal)",
                        ),
                        Err(_) => Some("its session.json does not read"),
                    }
                }
                Ok(Some(_)) => Some("its folder was replaced since"),
                Ok(None) => Some("its folder is gone"),
                Err(_) => Some("its folder does not read"),
            };
            if let Some(why) = why {
                let kept = self.keep_aside_meta(&chat, replayed.lsn, &image)?;
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

    /// Keeps a replayed image aside: a whole one as [`Self::keep_aside_meta`] does, the changes
    /// of one that does not rebuild as `<id>.<lsn>.session-changes.ndjson`, one JSON body per
    /// line, oldest first.
    fn keep_aside_image(&self, id: &str, lsn: Lsn, image: &Image) -> Result<PathBuf> {
        match image {
            Image::Whole(image) => self.keep_aside_meta(id, lsn, image),
            _ => self.write_kept(
                id,
                &format!("{lsn}.session-changes.ndjson"),
                None,
                &[image.aside()],
            ),
        }
    }
}
