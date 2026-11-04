//! The event log through one append-only journal (`store.journal`, R-DURABILITY S2;
//! `handoff/rewrites/R-DURABILITY/DESIGN.md` 3.3b).
//!
//! Without it, no event-log append is synced: a line a client was told about reaches the disk at
//! the next `flush` (shutdown), so an OS crash or a power loss takes back every line since. With
//! it, each append is one record in `<home>/journal/` (`cmux-journal`: group commit, one sync per
//! batch, a power loss takes back at most the last second, always a suffix), and then the same
//! line goes to the chat's `events/*.ndjson`, as before. Readers, segments and every file format
//! stay as they are: the logs are the journal's projection, read as before.
//!
//! - Order: one lock holds from the journal append to the log write, so for each chat the log's
//!   lines are in LSN order, and a log line always has its record. A line the log refuses gets a
//!   `cancel` record, so no replay writes it.
//! - Checkpoint (`<home>/journal-projected.json`, the journal's compaction point): every 30 s while
//!   the journal grew, past 64 MiB of it, at `flush` (shutdown) and before a retention rewrite. It
//!   syncs every log written since the last one and the sessions folder, then writes the LSN
//!   that every record up to has its log effect, durably, then retires the journal segments
//!   before it. A log sync that failed on its own (`LocalStore::sync_failed`) freezes the
//!   checkpoint: the journal then keeps every line until a restart writes them again.
//! - Recovery (open): the records after the checkpoint are read. For each chat with lines among
//!   them, its log is cut right after its last readable line below the first such line's `seq`
//!   (lines before it were synced by the checkpoint; after it are torn writes, lines an OS crash
//!   dropped, or lines the journal holds), and the journal's lines are written again, in order.
//!   A chat with a `forget` record (a delete) is deleted again. Exact and idempotent: a second
//!   crash in the middle is repaired by the next open the same way.
//! - Delete: a `forget` record, then the folder's removal, then a wait (bounded) until the record
//!   is durable, so a crash never brings a deleted chat back.
//!
//! Not yet (S2c): replies and events do not wait for their records to be durable, and the daemon
//! does not stop when the journal closes (a panic on its writer). Session metadata is S3.

use super::*;
use cmux_journal::{AppendError, Class, Journal, Lsn, Record};
use std::sync::atomic::Ordering as AtomicOrdering;
use std::sync::{Arc, Condvar};
use std::time::Duration;

/// The journal record kinds.
const KIND_LOG: u16 = 1;
const KIND_FORGET: u16 = 2;
const KIND_CANCEL: u16 = 3;

const CHECKPOINT_NAME: &str = "journal-projected.json";
const CHECKPOINT_SCHEMA: &str = "acpmux.journal-projected.v1";
const CHECKPOINT_EVERY: Duration = Duration::from_secs(30);
/// Journal bytes past the last checkpoint that wake the checkpointer at once.
const CHECKPOINT_BYTES: u64 = 64 * 1024 * 1024;
/// The longest a seal waits for the journal's last full sync, and a delete for its record.
const SEAL_WAIT: Duration = Duration::from_secs(5);
const FORGET_WAIT: Duration = Duration::from_secs(5);

pub struct JournalStore {
    inner: Arc<Inner>,
    checkpointer: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// What the journal's open reported (the tests read it).
    #[cfg(test)]
    opened: cmux_journal::OpenReport,
}

/// The journal's storage, refusing every write under a lost home: `fence` (in the daemon,
/// `config::refuse_lost_home`) is asked before each operation that makes, writes, renames or
/// removes a file or folder.
pub(super) struct FencedStorage {
    inner: Arc<dyn cmux_journal::Storage>,
    fence: Box<dyn Fn(&Path) -> Result<()> + Send + Sync>,
}

impl FencedStorage {
    pub(super) fn new(
        inner: Arc<dyn cmux_journal::Storage>,
        fence: Box<dyn Fn(&Path) -> Result<()> + Send + Sync>,
    ) -> Self {
        Self { inner, fence }
    }
}

impl cmux_journal::Storage for FencedStorage {
    fn create_dir_all(&self, dir: &Path) -> std::io::Result<()> {
        let _ = &self.fence;
        self.inner.create_dir_all(dir)
    }
    fn list(&self, dir: &Path) -> std::io::Result<Vec<String>> {
        self.inner.list(dir)
    }
    fn open(
        &self,
        path: &Path,
        mode: cmux_journal::OpenMode,
    ) -> std::io::Result<Box<dyn cmux_journal::StorageFile>> {
        self.inner.open(path, mode)
    }
    fn rename(&self, from: &Path, to: &Path) -> std::io::Result<()> {
        self.inner.rename(from, to)
    }
    fn remove_file(&self, path: &Path) -> std::io::Result<()> {
        self.inner.remove_file(path)
    }
    fn sync_dir(&self, dir: &Path) -> std::io::Result<()> {
        self.inner.sync_dir(dir)
    }
    fn try_lock(&self, path: &Path) -> std::io::Result<Option<Box<dyn cmux_journal::StorageLock>>> {
        self.inner.try_lock(path)
    }
}

#[cfg(test)]
thread_local! {
    /// Tests: a repair on this thread stops with an error right after it cut a log, as a crash
    /// there would.
    pub(super) static STOP_AFTER_CUT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

struct Inner {
    local: LocalStore,
    journal: Journal,
    home: PathBuf,
    order: Mutex<Order>,
    /// One checkpoint at a time.
    checkpointing: Mutex<()>,
    timer: Mutex<Timer>,
    wake: Condvar,
}

#[derive(Default)]
struct Order {
    /// Every journal record up to this LSN has its log effect done (a line written, a chat
    /// deleted) or none to do (a cancel).
    applied: Lsn,
    /// The LSN of the last checkpoint.
    checkpointed: Lsn,
    /// Chats whose log was written since the last checkpoint.
    dirty: BTreeSet<String>,
    /// Journal payload bytes since the last checkpoint.
    bytes: u64,
    /// A log sync failed: the checkpoint stays until a restart writes the logs again.
    frozen: bool,
}

#[derive(Default)]
struct Timer {
    stop: bool,
    /// A checkpoint is wanted now (the journal grew past `CHECKPOINT_BYTES`).
    wanted: bool,
}

impl JournalStore {
    pub(super) fn open(
        config: &StoreConfig,
        home: &Path,
        storage: Arc<dyn cmux_journal::Storage>,
        journal_config: cmux_journal::Config,
    ) -> Result<Self> {
        let local = LocalStore::new(home.join("sessions"), config.segment_bytes)?;
        let from = read_checkpoint(home);
        let mut replay = Replay::default();
        let (journal, report) =
            Journal::open(storage, &home.join("journal"), journal_config, from, &mut |record| {
                replay.take(record)
            })
            .map_err(|error| anyhow::anyhow!("open the event journal: {error}"))?;
        for damage in &report.damage {
            tracing::error!(?damage, "the event journal could not read some records");
        }
        let inner = Arc::new(Inner {
            local,
            journal,
            home: home.to_path_buf(),
            order: Mutex::new(Order { checkpointed: from, ..Order::default() }),
            checkpointing: Mutex::new(()),
            timer: Mutex::new(Timer::default()),
            wake: Condvar::new(),
        });
        inner.apply(replay)?;
        if inner.journal.last_lsn() > from
            && let Err(error) = inner.checkpoint()
        {
            tracing::warn!("event journal checkpoint after the replay: {error:#}");
        }
        let worker = Arc::clone(&inner);
        let checkpointer = std::thread::Builder::new()
            .name("acpmux-journal-checkpoint".into())
            .spawn(move || worker.run_checkpointer())
            .context("start the event journal's checkpointer")?;
        Ok(Self {
            inner,
            checkpointer: Mutex::new(Some(checkpointer)),
            #[cfg(test)]
            opened: report,
        })
    }

    /// What the journal's open reported.
    #[cfg(test)]
    pub(super) fn opened(&self) -> &cmux_journal::OpenReport {
        &self.opened
    }
}

impl Drop for JournalStore {
    /// Stops the checkpointer. No checkpoint here: a drop is not a shutdown (`flush` is).
    fn drop(&mut self) {
        self.inner.timer.lock_or_recover().stop = true;
        self.inner.wake.notify_all();
        if let Some(handle) = self.checkpointer.lock_or_recover().take() {
            let _ = handle.join();
        }
    }
}

// ---------------------------------------------------------------- records

fn encode_log(id: &str, line: &[u8]) -> Vec<u8> {
    let len = u32::try_from(id.len()).unwrap_or(u32::MAX);
    let mut payload =
        Vec::with_capacity(4usize.saturating_add(id.len()).saturating_add(line.len()));
    payload.extend_from_slice(&len.to_le_bytes());
    payload.extend_from_slice(id.as_bytes());
    payload.extend_from_slice(line);
    payload
}

fn decode_log(payload: &[u8]) -> Option<(String, &[u8])> {
    let len = usize::try_from(u32::from_le_bytes(payload.get(..4)?.try_into().ok()?)).ok()?;
    let end = 4usize.checked_add(len)?;
    let id = std::str::from_utf8(payload.get(4..end)?).ok()?;
    Some((id.to_owned(), payload.get(end..)?))
}

/// A streamed agent line: synced with the next acked batch or a second later (`Class::Stream`).
fn streamed(record: &EventRecord) -> bool {
    record.dir == "in"
        && (record.kind == crate::rpc::method::SESSION_UPDATE
            || record.kind.starts_with("claude.")
            || record.kind.starts_with("codex."))
}

/// The `seq` of a whole log line, or `None` when it does not read.
fn line_seq(line: &[u8]) -> Option<u64> {
    record_seq(line).or_else(|| parse_record(line).ok().map(|record| record.seq))
}

// ---------------------------------------------------------------- the checkpoint file

#[derive(Serialize, Deserialize)]
struct Checkpoint {
    schema: String,
    lsn: Lsn,
}

/// The checkpoint's LSN; 0 when there is none or it does not read (the replay then starts at the
/// journal's oldest record, which rewrites lines the logs already hold, the same bytes).
fn read_checkpoint(home: &Path) -> Lsn {
    let path = home.join(CHECKPOINT_NAME);
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return 0,
        Err(error) => {
            tracing::warn!("read {}: {error}", path.display());
            return 0;
        }
    };
    match serde_json::from_slice::<Checkpoint>(&bytes) {
        Ok(checkpoint) if checkpoint.schema == CHECKPOINT_SCHEMA => checkpoint.lsn,
        _ => {
            tracing::warn!(
                "{} does not read; the replay starts at the oldest record",
                path.display()
            );
            0
        }
    }
}

/// Writes the checkpoint whole under a temporary name, syncs it, renames it into place and syncs
/// the home folder; an error at any step (the folder's sync too) is returned.
fn write_checkpoint(home: &Path, lsn: Lsn) -> Result<()> {
    let path = home.join(CHECKPOINT_NAME);
    crate::config::refuse_lost_home(&path)?;
    let tmp = home.join(format!("{CHECKPOINT_NAME}.tmp-{}", std::process::id()));
    let bytes = serde_json::to_vec(&Checkpoint { schema: CHECKPOINT_SCHEMA.into(), lsn })?;
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(&tmp).with_context(|| format!("write {}", tmp.display()))?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&tmp, &path).with_context(|| format!("rename to {}", path.display()))?;
    sync_directory(home)
}

// ---------------------------------------------------------------- recovery

/// The records after the checkpoint, by chat.
#[derive(Default)]
struct Replay {
    chats: BTreeMap<String, ChatReplay>,
    cancelled: BTreeSet<Lsn>,
}

#[derive(Default)]
struct ChatReplay {
    /// Its lines after its last `forget`, in LSN order.
    lines: Vec<(Lsn, Vec<u8>)>,
    forgotten: bool,
}

impl Replay {
    fn take(&mut self, record: Record<'_>) -> std::result::Result<(), String> {
        match record.kind {
            KIND_LOG => {
                let (chat, line) = decode_log(record.payload)
                    .ok_or_else(|| format!("log record {} does not read", record.lsn))?;
                self.chats.entry(chat).or_default().lines.push((record.lsn, line.to_vec()));
            }
            KIND_FORGET => {
                let chat = std::str::from_utf8(record.payload)
                    .map_err(|_| format!("forget record {} does not read", record.lsn))?;
                let entry = self.chats.entry(chat.to_owned()).or_default();
                entry.lines.clear();
                entry.forgotten = true;
            }
            KIND_CANCEL => {
                let lsn = record
                    .payload
                    .try_into()
                    .map(u64::from_le_bytes)
                    .map_err(|_| format!("cancel record {} does not read", record.lsn))?;
                self.cancelled.insert(lsn);
            }
            other => return Err(format!("unknown event journal record kind {other}")),
        }
        Ok(())
    }
}

impl Inner {
    /// Writes the replayed records' effects to the logs ([module docs](self)).
    fn apply(&self, replay: Replay) -> Result<()> {
        let Replay { chats, cancelled } = replay;
        for (chat, mut entry) in chats {
            // Deleted again, unless lines follow its forget: then the chat was made again under
            // the same id (a transfer back), and its folder holds that chat's own files.
            if entry.forgotten && entry.lines.is_empty() && self.local.dir(&chat).exists() {
                Store::delete(&self.local, &chat)
                    .with_context(|| format!("delete {chat} again (its forget record)"))?;
            }
            entry.lines.retain(|(lsn, _)| !cancelled.contains(lsn));
            let Some(from_seq) = entry.lines.first().and_then(|(_, line)| line_seq(line)) else {
                if !entry.lines.is_empty() {
                    tracing::error!(session = %chat, "a journaled line has no seq; not written again");
                }
                continue;
            };
            self.cut_from(&chat, from_seq)
                .with_context(|| format!("cut the log of {chat} for its replay"))?;
            for (_, line) in &entry.lines {
                self.local.append_line(&chat, line)?;
            }
            self.order.lock_or_recover().dirty.insert(chat);
        }
        let mut order = self.order.lock_or_recover();
        order.applied = self.journal.last_lsn();
        Ok(())
    }

    /// Cuts `id`'s log right after its last readable line with a `seq` below `from_seq`: later
    /// segments go, and the boundary segment is shortened. Each such segment's kind-index copy goes
    /// too (a cache, made again by the next scan).
    fn cut_from(&self, id: &str, from_seq: u64) -> Result<()> {
        let segments = self.local.segments(id)?;
        for (index, path) in segments.iter().rev() {
            let starts_before = first_seq(path)?.is_some_and(|seq| seq < from_seq);
            if !starts_before {
                std::fs::remove_file(path).with_context(|| format!("remove {}", path.display()))?;
                self.forget_index_copy(id, *index);
                continue;
            }
            let keep = end_of_last_line_before(path, from_seq)?;
            let len = std::fs::metadata(path)?.len();
            if keep < len {
                truncate_private(path, keep)?;
                self.forget_index_copy(id, *index);
            }
            #[cfg(test)]
            if STOP_AFTER_CUT.with(std::cell::Cell::get) {
                anyhow::bail!("stopped after the cut (a test)");
            }
            break;
        }
        Ok(())
    }

    fn forget_index_copy(&self, id: &str, index: u32) {
        let copy = self.local.dir(id).join(kind_index::DIR).join(format!("{index:06}.ndjson"));
        match std::fs::remove_file(&copy) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => tracing::warn!("remove {}: {error}", copy.display()),
        }
    }

    // ------------------------------------------------------------ checkpoints

    fn checkpoint(&self) -> Result<()> {
        let _one = self.checkpointing.lock_or_recover();
        let (lsn, dirty) = {
            let mut order = self.order.lock_or_recover();
            if order.frozen || (order.applied <= order.checkpointed && order.dirty.is_empty()) {
                return Ok(());
            }
            // A failed checkpoint waits for the timer or another `CHECKPOINT_BYTES`.
            order.bytes = 0;
            (order.applied, std::mem::take(&mut order.dirty))
        };
        if let Err(error) = self.sync_logs(&dirty) {
            self.order.lock_or_recover().dirty.extend(dirty);
            return Err(error);
        }
        if self.local.sync_failed.load(AtomicOrdering::SeqCst) {
            self.order.lock_or_recover().frozen = true;
            anyhow::bail!(
                "an event log failed to sync: the journal keeps every line until a restart"
            );
        }
        write_checkpoint(&self.home, lsn)?;
        self.order.lock_or_recover().checkpointed = lsn;
        if let Err(error) = self.journal.retire_through(lsn) {
            tracing::warn!("retire the event journal before {lsn}: {error}");
        }
        Ok(())
    }

    /// Syncs the logs of `dirty` (their open segment and folders) and the sessions folder (a
    /// delete's removal, a new chat's folder).
    fn sync_logs(&self, dirty: &BTreeSet<String>) -> Result<()> {
        for chat in dirty {
            if self.local.dir(chat).exists() {
                self.local.sync_log(chat).with_context(|| format!("sync the log of {chat}"))?;
            }
        }
        sync_directory(&self.local.root)
    }

    fn run_checkpointer(&self) {
        let mut timer = self.timer.lock_or_recover();
        loop {
            if timer.stop {
                return;
            }
            if !timer.wanted {
                timer = self
                    .wake
                    .wait_timeout(timer, CHECKPOINT_EVERY)
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .0;
                if timer.stop {
                    return;
                }
            }
            timer.wanted = false;
            drop(timer);
            if let Err(error) = self.checkpoint() {
                tracing::warn!("event journal checkpoint: {error:#}");
            }
            timer = self.timer.lock_or_recover();
        }
    }

    fn want_checkpoint(&self) {
        let mut timer = self.timer.lock_or_recover();
        if !timer.wanted {
            timer.wanted = true;
            drop(timer);
            self.wake.notify_all();
        }
    }
}

/// The offset right after the last whole line of `path` whose `seq` reads and is below
/// `from_seq`; 0 when there is none.
fn end_of_last_line_before(path: &Path, from_seq: u64) -> Result<u64> {
    let mut reader = BufReader::new(crate::config::private_state_file(path)?);
    let mut line = Vec::new();
    let (mut offset, mut keep) = (0u64, 0u64);
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line)?;
        if read == 0 {
            return Ok(keep);
        }
        offset = offset.saturating_add(u64::try_from(read).unwrap_or(u64::MAX));
        if line.last() != Some(&b'\n') {
            return Ok(keep);
        }
        if line_seq(&line).is_some_and(|seq| seq < from_seq) {
            keep = offset;
        }
    }
}

/// Shortens the log segment at `path` (owner-only, never through a symlink) and syncs it.
fn truncate_private(path: &Path, len: u64) -> Result<()> {
    crate::config::refuse_lost_home(path)?;
    let mut options = OpenOptions::new();
    options.write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path).with_context(|| format!("open {}", path.display()))?;
    file.set_len(len).with_context(|| format!("shorten {}", path.display()))?;
    file.sync_all()?;
    Ok(())
}

// ---------------------------------------------------------------- the store

impl JournalStore {
    fn journal_error(error: AppendError) -> anyhow::Error {
        if error == AppendError::Closed {
            tracing::error!("the event journal is closed: no event is stored");
        }
        anyhow::anyhow!("the event journal: {error}")
    }
}

impl Store for JournalStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        Store::list(&self.inner.local)
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        Store::load(&self.inner.local, id)
    }
    fn load_startup(&self, id: &str) -> Result<Option<SessionMeta>> {
        Store::load_startup(&self.inner.local, id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        Store::save(&self.inner.local, meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        let class = if streamed(record) { Class::Stream } else { Class::Ack };
        let payload = encode_log(id, line.as_bytes());
        let inner = &self.inner;
        let mut order = inner.order.lock_or_recover();
        // After the seal (under the same lock, so exact): refused as the logs refuse it, and the
        // journal is not touched.
        drop(inner.local.writable()?);
        let lsn =
            inner.journal.append(KIND_LOG, class, &payload).map_err(JournalStore::journal_error)?;
        let written = inner.local.append_line(id, line.as_bytes());
        if written.is_err()
            && let Err(error) = inner.journal.append(KIND_CANCEL, Class::Ack, &lsn.to_le_bytes())
        {
            tracing::error!(session = %id, "the event journal could not cancel record {lsn}: {error}");
        }
        order.applied = inner.journal.last_lsn();
        if written.is_ok() && !order.dirty.contains(id) {
            order.dirty.insert(id.to_owned());
        }
        order.bytes = order.bytes.saturating_add(u64::try_from(payload.len()).unwrap_or(u64::MAX));
        let full = order.bytes > CHECKPOINT_BYTES && !order.frozen;
        drop(order);
        if full {
            inner.want_checkpoint();
        }
        written
    }
    fn flush_session(&self, id: &str) -> Result<()> {
        Store::flush_session(&self.inner.local, id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        Store::events(&self.inner.local, id, after, limit)
    }
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        Store::scan(&self.inner.local, id, after, visit)
    }
    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        Store::scan_strict(&self.inner.local, id, after, visit)
    }
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        Store::scan_back(&self.inner.local, id, after, before, skip, visit)
    }
    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        Store::tail_after(&self.inner.local, id, after)
    }
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        Store::scan_kinds(&self.inner.local, id, kinds, visit)
    }
    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        Store::scan_kinds_strict(&self.inner.local, id, kinds, visit)
    }
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        Store::scan_heads(&self.inner.local, id, visit)
    }
    /// A checkpoint: every log written so far is synced and the journal before it retired.
    fn flush(&self) -> Result<()> {
        self.inner.checkpoint()
    }
    fn wait_durable(&self, timeout: Duration) -> Result<bool> {
        let lsn = self.inner.journal.last_lsn();
        if lsn == 0 {
            return Ok(true);
        }
        match self.inner.journal.wait_durable(lsn, timeout) {
            Ok(()) => Ok(true),
            Err(cmux_journal::WaitError::Timeout) => Ok(false),
            Err(error) => Err(anyhow::anyhow!("the event journal: {error}")),
        }
    }
    /// The logs refuse writes, and the journal fully syncs every record (the shutdown's `flush`
    /// then checkpoints).
    fn seal(&self) {
        // Under the appends' lock: an append either lands in the journal and the logs, or in
        // neither (never a record whose line the sealed logs refused, which a later replay
        // would write).
        let _order = self.inner.order.lock_or_recover();
        Store::seal(&self.inner.local);
        if let Err(error) = self.inner.journal.seal(SEAL_WAIT) {
            tracing::error!("seal the event journal: {error}");
        }
    }
    fn close_log(&self, id: &str) {
        Store::close_log(&self.inner.local, id);
    }
    fn compacted_seq(&self, id: &str) -> Option<u64> {
        Store::compacted_seq(&self.inner.local, id)
    }
    fn log_written_at(&self, id: &str) -> Option<u64> {
        Store::log_written_at(&self.inner.local, id)
    }
    fn stage_compaction(&self, id: &str, mode: CompactMode) -> Result<Option<Staged>> {
        Store::stage_compaction(&self.inner.local, id, mode)
    }
    /// A checkpoint first, so no journal record of the chat is past it: a replay never writes
    /// the lines a retention rewrite cut back into its log.
    fn commit_compaction(&self, id: &str, staged: Staged) -> Result<bool> {
        self.inner.checkpoint()?;
        Store::commit_compaction(&self.inner.local, id, staged)
    }
    fn delete(&self, id: &str) -> Result<()> {
        let inner = &self.inner;
        let forget = {
            let mut order = inner.order.lock_or_recover();
            drop(inner.local.writable()?);
            let lsn = inner
                .journal
                .append(KIND_FORGET, Class::Ack, id.as_bytes())
                .map_err(JournalStore::journal_error)?;
            let removed = Store::delete(&inner.local, id);
            order.applied = inner.journal.last_lsn();
            order.dirty.remove(id);
            removed.map(|()| lsn)
        }?;
        if let Err(error) = inner.journal.wait_durable(forget, FORGET_WAIT) {
            tracing::warn!(session = %id, "the delete's journal record is not durable yet: {error}");
        }
        Ok(())
    }
    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        Store::session_dir(&self.inner.local, id)
    }
    fn handoff_dir(&self) -> Option<PathBuf> {
        Store::handoff_dir(&self.inner.local)
    }
    fn peer_cache_dir(&self) -> Option<PathBuf> {
        Store::peer_cache_dir(&self.inner.local)
    }
    fn briefs_path(&self) -> Option<PathBuf> {
        Store::briefs_path(&self.inner.local)
    }
}
