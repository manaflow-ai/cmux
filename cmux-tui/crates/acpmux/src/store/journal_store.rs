//! The event log through one append-only journal (`store.journal`, R-DURABILITY S2;
//! `handoff/rewrites/R-DURABILITY/DESIGN.md` 3.3b and 3.3c).
//!
//! Without it, no event-log append is synced: a line a client was told about reaches the disk at
//! the next `flush` (shutdown), so an OS crash or a power loss takes back every line since. With
//! it, each line goes to the chat's `events/*.ndjson` as before, and then one record with the same
//! line goes to `<home>/journal/` (`cmux-journal`: group commit, one sync per batch, a power loss
//! takes back at most the last second, always a suffix). Readers, segments and every file format
//! stay as they are: the logs are the journal's projection, read as before.
//!
//! - Order: one lock holds from the journal's check to its append, with the log write between,
//!   so for each chat the log's lines are in LSN order. The journal's refusals (closed, behind)
//!   come before the log write and a log's refusal comes before the record, so every record's
//!   line went to the log. A log line may lack its record: a crash between the two, or a record
//!   still in memory at a kill.
//! - Checkpoint (`<home>/journal-projected.json`, the journal's compaction point): every 30 s while
//!   the journal grew, past 64 MiB of it, at `flush` (shutdown) and before a retention rewrite. It
//!   syncs every log written since the last one and the sessions folder, then writes, durably, an
//!   LSN at or before the journal's durable end that every record up to has its log effect, then
//!   retires the journal segments before it. A failed log sync (in it, or at a log's close)
//!   freezes it: a later sync may report success for pages the kernel dropped, so the journal
//!   keeps every line and the store asks the daemon to stop ([`Store::stop_reason`]); the next
//!   start's replay writes the logs again. Ten failed checkpoints in a row ask the same.
//! - Recovery (open) repairs each log and never deletes a whole line or a folder: see
//!   [`Inner::repair`]. A chat whose folder is gone is not written again. A log that moved on
//!   without the journal (a run with the switch off, or an older build, after a crash) is left as
//!   it is, and the journal's lines for it go to `<home>/journal-unapplied/`, as do the lines of a
//!   chat whose log cannot be read or written. A crash in the middle is repaired by the next open
//!   the same way.
//! - Delete: a `forget` record (the replay then drops the chat's earlier journaled lines, so a
//!   chat made again under the same id gets only its own), then the folder's removal, off the
//!   appends' lock and without waiting for the record.
//! - With the switch off, [`catch_up`] runs this recovery once on a journal left by a run with it
//!   on, so every acknowledged line is in the logs before they are written alone.
//!
//! Not yet (S2c): replies and events do not wait for their records to be durable, and the daemon
//! does not stop when the journal closes (a panic on its writer). Session metadata is S3.

use super::*;
use cmux_journal::{AppendError, Class, Damage, Journal, Lsn, OpenError, Record};
use std::sync::atomic::Ordering as AtomicOrdering;
use std::sync::{Arc, Condvar};
use std::time::{Duration, Instant};

/// The journal record kinds. (Kind 3, a `cancel` of a line the log refused, was used before the
/// review of #34901 and never shipped: a refused line is never journaled now.)
const KIND_LOG: u16 = 1;
const KIND_FORGET: u16 = 2;

const JOURNAL_DIR: &str = "journal";
const CHECKPOINT_NAME: &str = "journal-projected.json";
const CHECKPOINT_SCHEMA: &str = "acpmux.journal-projected.v1";
/// Where the journaled lines of a log that recovery leaves as it is go.
const UNAPPLIED_DIR: &str = "journal-unapplied";
const CHECKPOINT_EVERY: Duration = Duration::from_secs(30);
/// Journal bytes past the last checkpoint that wake the checkpointer at once.
const CHECKPOINT_BYTES: u64 = 64 * 1024 * 1024;
/// Checkpoints in a row that fail before the store asks the daemon to stop: the journal past the
/// last one (what the next open holds in memory) must not grow without end.
const CHECKPOINT_FAILURES_TO_STOP: u32 = 10;
/// The longest a seal waits for the journal's last full sync.
const SEAL_WAIT: Duration = Duration::from_secs(5);
/// The longest an open waits for the journal's lock: a restart overlaps the old daemon's exit.
const LOCK_WAIT: Duration = Duration::from_secs(5);
/// The longest a repair waits for the lines it journals before it cuts a log.
const REPAIR_WAIT: Duration = Duration::from_secs(60);

pub struct JournalStore {
    inner: Arc<Inner>,
    checkpointer: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// What the journal's open reported (the tests read it).
    #[cfg(test)]
    opened: cmux_journal::OpenReport,
}

/// The journal's storage, refusing every write under a lost home: `fence` (in the daemon,
/// `config::refuse_lost_home`) is asked before each operation that makes, writes, renames or
/// removes a file or folder. Reads, syncs and the lock are not writes.
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

    /// The daemon's: the real file system behind `config::refuse_lost_home`.
    pub(super) fn daemon() -> Self {
        Self::new(Arc::new(cmux_journal::FsStorage), Box::new(crate::config::refuse_lost_home))
    }

    fn check(&self, path: &Path) -> std::io::Result<()> {
        (self.fence)(path).map_err(|error| std::io::Error::other(format!("{error:#}")))
    }
}

impl cmux_journal::Storage for FencedStorage {
    fn create_dir_all(&self, dir: &Path) -> std::io::Result<()> {
        self.check(dir)?;
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
        if mode != cmux_journal::OpenMode::Read {
            self.check(path)?;
        }
        self.inner.open(path, mode)
    }
    fn rename(&self, from: &Path, to: &Path) -> std::io::Result<()> {
        self.check(from)?;
        self.check(to)?;
        self.inner.rename(from, to)
    }
    fn remove_file(&self, path: &Path) -> std::io::Result<()> {
        self.check(path)?;
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
    /// Tests: a repair on this thread stops the open with an error right after it cut a log, as a
    /// crash there would.
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
    /// Why the daemon must stop (`Store::stop_reason`).
    stop: tokio::sync::watch::Sender<Option<String>>,
}

#[derive(Default)]
struct Order {
    /// Every journal record up to this LSN has its log effect done (a line written, a chat
    /// deleted).
    applied: Lsn,
    /// The LSN of the last checkpoint.
    checkpointed: Lsn,
    /// Chats whose log was written since the last checkpoint.
    dirty: BTreeSet<String>,
    /// Journal payload bytes since the last checkpoint.
    bytes: u64,
    /// A log sync failed: the checkpoint stays until a restart writes the logs again.
    frozen: bool,
    /// Checkpoints in a row that failed.
    failures: u32,
    /// The open reported damage: cleared (`Journal::clear_damage`) after the next checkpoint.
    damage: bool,
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
        remove_checkpoint_temporaries(home);
        let local = LocalStore::new(home.join("sessions"), config.segment_bytes)?;
        let from = read_checkpoint(home)?;
        let (journal, report, replay) =
            open_journal(storage, &home.join(JOURNAL_DIR), journal_config, from)?;
        for damage in &report.damage {
            match damage {
                // The checkpoint is never past the journal's durable end, so only a journal that
                // lost synced records or a checkpoint file put back from elsewhere says this.
                Damage::Ahead { .. } => {
                    tracing::warn!(?damage, "the event journal ends before its checkpoint");
                }
                _ => tracing::error!(?damage, "the event journal could not read some records"),
            }
        }
        let (stop, _) = tokio::sync::watch::channel(None);
        let inner = Arc::new(Inner {
            local,
            journal,
            home: home.to_path_buf(),
            order: Mutex::new(Order {
                checkpointed: from,
                damage: !report.damage.is_empty(),
                ..Order::default()
            }),
            checkpointing: Mutex::new(()),
            timer: Mutex::new(Timer::default()),
            wake: Condvar::new(),
            stop,
        });
        inner.apply(replay)?;
        if let Err(error) = inner.checkpoint() {
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

/// Opens the journal, replaying the records after `from`; waits up to [`LOCK_WAIT`] while another
/// process holds it (the daemon before a restart, still exiting).
fn open_journal(
    storage: Arc<dyn cmux_journal::Storage>,
    dir: &Path,
    config: cmux_journal::Config,
    from: Lsn,
) -> Result<(Journal, cmux_journal::OpenReport, Replay)> {
    let deadline = Instant::now() + LOCK_WAIT;
    loop {
        let mut replay = Replay::default();
        let opened =
            Journal::open(Arc::clone(&storage), dir, config.clone(), from, &mut |record| {
                replay.take(record)
            });
        match opened {
            Ok((journal, report)) => return Ok((journal, report, replay)),
            Err(OpenError::Locked) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(error) => anyhow::bail!("open the event journal: {error}"),
        }
    }
}

/// With `store.journal` off: a journal that a run with it on left behind is replayed into the logs,
/// checkpointed and retired first, so a crash with the switch on and a start with it off keep
/// every acknowledged line, and turning it on again replays nothing old (DESIGN.md 3.3c, the
/// catch-up of 3.6). Nothing to do when there is no journal.
pub(super) fn catch_up(config: &StoreConfig, home: &Path) -> Result<()> {
    if std::fs::symlink_metadata(home.join(JOURNAL_DIR)).is_err() {
        return Ok(());
    }
    let store = JournalStore::open(
        config,
        home,
        Arc::new(FencedStorage::daemon()),
        cmux_journal::Config::default(),
    )?;
    store.inner.checkpoint()?;
    Store::seal(&store);
    Ok(())
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

/// The checkpoint's LSN; 0 when there is none. One that does not read fails the open: a replay
/// from the journal's oldest record could undo a retention rewrite.
fn read_checkpoint(home: &Path) -> Result<Lsn> {
    let path = home.join(CHECKPOINT_NAME);
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => {
            anyhow::bail!("read the event journal's checkpoint {}: {error}", path.display())
        }
    };
    match serde_json::from_slice::<Checkpoint>(&bytes) {
        Ok(checkpoint) if checkpoint.schema == CHECKPOINT_SCHEMA => Ok(checkpoint.lsn),
        _ => anyhow::bail!(
            "the event journal's checkpoint {} does not read; move it aside to replay the whole journal",
            path.display()
        ),
    }
}

/// Removes the temporary files of checkpoints a crash interrupted (`write_checkpoint`).
fn remove_checkpoint_temporaries(home: &Path) {
    let Ok(entries) = std::fs::read_dir(home) else { return };
    let prefix = format!("{CHECKPOINT_NAME}.tmp-");
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().starts_with(&prefix) {
            continue;
        }
        let path = entry.path();
        if let Err(error) = crate::config::refuse_lost_home(&path)
            .and_then(|()| std::fs::remove_file(&path).map_err(anyhow::Error::from))
        {
            tracing::warn!("remove {}: {error:#}", path.display());
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
    chats: BTreeMap<String, Vec<(Lsn, Vec<u8>)>>,
}

impl Replay {
    fn take(&mut self, record: Record<'_>) -> std::result::Result<(), String> {
        match record.kind {
            KIND_LOG => {
                let (chat, line) = decode_log(record.payload)
                    .ok_or_else(|| format!("log record {} does not read", record.lsn))?;
                self.chats.entry(chat).or_default().push((record.lsn, line.to_vec()));
            }
            // The chat's earlier lines are not its own any more: a chat made again under the same
            // id gets only the lines after this.
            KIND_FORGET => {
                let chat = std::str::from_utf8(record.payload)
                    .map_err(|_| format!("forget record {} does not read", record.lsn))?;
                self.chats.entry(chat.to_owned()).or_default().clear();
            }
            other => return Err(format!("unknown event journal record kind {other}")),
        }
        Ok(())
    }
}

/// What a repair did with one chat's log.
enum Repaired {
    /// It holds every journaled line now (nothing was missing, or they were written).
    Done,
    /// Its folder is gone: the chat was deleted, or lost with its `session.json`. Not written.
    Gone,
    /// The log moved on without the journal: left as it is.
    MovedOn(String),
}

/// Why a repair stopped.
enum RepairError {
    /// The chat's log could not be read or written; `keep` are the lines that only the journal
    /// may hold now.
    Chat { error: anyhow::Error, keep: Vec<Vec<u8>> },
    /// Tests: stopped right after its cut, as a crash would.
    #[cfg(test)]
    Stopped,
}

/// One piece of a log read back from a repair's start: a whole line with its `seq`, or bytes
/// that do not read (a torn tail, a hole of zeros, a line that does not parse).
struct Piece {
    segment: u32,
    offset: u64,
    line: Option<(u64, Vec<u8>)>,
}

impl Inner {
    /// Writes the replayed records' effects to the logs ([module docs](self)). One chat's failure
    /// keeps its lines in `journal-unapplied/` and the open goes on; only a failure to keep them
    /// fails it.
    fn apply(&self, replay: Replay) -> Result<()> {
        for (chat, journaled) in replay.chats {
            let Some(first_lsn) = journaled.first().map(|(lsn, _)| *lsn) else { continue };
            match self.repair(&chat, &journaled) {
                Ok(Repaired::Done) => {
                    self.order.lock_or_recover().dirty.insert(chat);
                }
                Ok(Repaired::Gone) => {
                    tracing::info!(session = %chat, "journaled lines of a chat whose folder is gone: not written again");
                }
                Ok(Repaired::MovedOn(why)) => {
                    let lines: Vec<Vec<u8>> = journaled.into_iter().map(|(_, line)| line).collect();
                    let kept = self.keep_aside(&chat, first_lsn, &lines)?;
                    tracing::error!(session = %chat, kept = %kept.display(), "the chat's log moved on without the event journal ({why}); left as it is");
                }
                Err(RepairError::Chat { error, keep }) => {
                    let kept = self.keep_aside(&chat, first_lsn, &keep)?;
                    tracing::error!(session = %chat, kept = %kept.display(), "the chat's log could not be repaired: {error:#}");
                }
                #[cfg(test)]
                Err(RepairError::Stopped) => anyhow::bail!("stopped after the cut (a test)"),
            }
        }
        let mut order = self.order.lock_or_recover();
        order.applied = self.journal.last_lsn();
        Ok(())
    }

    /// Repairs `id`'s log with its journaled lines (`journaled`, in LSN order): it never deletes a
    /// whole line or a folder.
    ///
    /// The log is read from just after its last line with a `seq` below the first journaled one.
    /// Its lines and the journal's merge by `seq`: a line in both must be the same bytes; a line
    /// only the log has stays; a line only the journal has goes in its place. If that only adds
    /// lines after the log's last one, they are appended. Otherwise (bytes that do not read, or a
    /// line to put before a later one), the lines that only the log has from that point are
    /// journaled and made durable first; then the log is cut there and the merged lines written,
    /// so a crash at any step loses no line: the next open repairs the same way.
    fn repair(
        &self,
        id: &str,
        journaled: &[(Lsn, Vec<u8>)],
    ) -> std::result::Result<Repaired, RepairError> {
        let keep_journaled = || journaled.iter().map(|(_, line)| line.clone()).collect::<Vec<_>>();
        let chat_error = |error: anyhow::Error| RepairError::Chat { error, keep: keep_journaled() };
        match std::fs::symlink_metadata(self.local.dir(id)) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Repaired::Gone);
            }
            Err(error) => return Err(chat_error(error.into())),
        }
        let mut wanted: BTreeMap<u64, &[u8]> = BTreeMap::new();
        for (_, line) in journaled {
            let Some(seq) = line_seq(line) else {
                return Ok(Repaired::MovedOn("a journaled line has no seq".into()));
            };
            if wanted.insert(seq, line).is_some_and(|other| other != line.as_slice()) {
                return Ok(Repaired::MovedOn(format!("two journaled lines with seq {seq}")));
            }
        }
        let Some(&first) = wanted.keys().next() else { return Ok(Repaired::Done) };
        let pieces = self.read_from(id, first).map_err(chat_error)?;
        let mut merged = wanted.clone();
        let mut last = None;
        for (seq, bytes) in pieces.iter().filter_map(|piece| piece.line.as_ref()) {
            if last.is_some_and(|last| *seq <= last) {
                return Ok(Repaired::MovedOn(format!("its line {seq} is out of seq order")));
            }
            last = Some(*seq);
            if wanted.get(seq).is_some_and(|held| *held != bytes.as_slice()) {
                return Ok(Repaired::MovedOn(format!("its line {seq} differs from the journal's")));
            }
            merged.insert(*seq, bytes);
        }
        let merged: Vec<(u64, &[u8])> = merged.into_iter().collect();
        // How far the log already is the merged lines, and the first piece that is not.
        let mut same = 0usize;
        let mut cut = None;
        for piece in &pieces {
            let next = merged.get(same).copied();
            match (&piece.line, next) {
                (Some((seq, bytes)), Some((want, line)))
                    if *seq == want && bytes.as_slice() == line =>
                {
                    same = same.saturating_add(1);
                }
                _ => {
                    cut = Some((piece.segment, piece.offset));
                    break;
                }
            }
        }
        let rest = merged.get(same..).unwrap_or_default();
        if let Some((segment, offset)) = cut {
            // The lines only the log holds from the cut on: into the journal first.
            let only_logged: Vec<&[u8]> = rest
                .iter()
                .filter(|(seq, _)| !wanted.contains_key(seq))
                .map(|(_, line)| *line)
                .collect();
            self.journal_lines(id, &only_logged).map_err(chat_error)?;
            let keep_rest = || rest.iter().map(|(_, line)| line.to_vec()).collect::<Vec<_>>();
            self.cut_at(id, segment, offset)
                .map_err(|error| RepairError::Chat { error, keep: keep_rest() })?;
            #[cfg(test)]
            if STOP_AFTER_CUT.with(std::cell::Cell::get) {
                return Err(RepairError::Stopped);
            }
            for (_, line) in rest {
                self.local
                    .append_line(id, line)
                    .map_err(|error| RepairError::Chat { error, keep: keep_rest() })?;
            }
        } else {
            for (_, line) in rest {
                self.local.append_line(id, line).map_err(chat_error)?;
            }
        }
        Ok(Repaired::Done)
    }

    /// Appends `lines` of chat `id` to the journal and waits until they are durable.
    fn journal_lines(&self, id: &str, lines: &[&[u8]]) -> Result<()> {
        let mut last = None;
        for line in lines {
            let lsn = self
                .journal
                .append(KIND_LOG, Class::Ack, &encode_log(id, line))
                .map_err(|error| anyhow::anyhow!("journal a line only the log held: {error}"))?;
            last = Some(lsn);
        }
        if let Some(lsn) = last {
            self.journal
                .wait_durable(lsn, REPAIR_WAIT)
                .map_err(|error| anyhow::anyhow!("journal the lines only the log held: {error}"))?;
        }
        Ok(())
    }

    /// The pieces of `id`'s log from just after its last whole line with a `seq` below `first`.
    fn read_from(&self, id: &str, first: u64) -> Result<Vec<Piece>> {
        let segments = self.local.segments(id)?;
        // The last segment whose first readable line is below `first`; else the first segment.
        let mut start = 0usize;
        for (at, (_, path)) in segments.iter().enumerate().rev() {
            if first_seq(path)?.is_some_and(|seq| seq < first) {
                start = at;
                break;
            }
        }
        let mut pieces = Vec::new();
        for (at, (index, path)) in segments.iter().enumerate().skip(start) {
            let from = if at == start { end_of_last_line_before(path, first)? } else { 0 };
            read_pieces(path, *index, from, &mut pieces)?;
        }
        Ok(pieces)
    }

    /// Cuts `id`'s log at `offset` of segment `segment`: later segments go, and that one is
    /// shortened. The kind-index copy of each segment that changes goes first: a crash between a
    /// cut and its copy's removal would leave a copy that a log written back to the same length
    /// passes for current.
    fn cut_at(&self, id: &str, segment: u32, offset: u64) -> Result<()> {
        let segments = self.local.segments(id)?;
        for (index, _) in segments.iter().filter(|(index, _)| *index >= segment) {
            self.forget_index_copy(id, *index)?;
        }
        for (index, path) in segments.iter().rev() {
            if *index > segment {
                crate::config::refuse_lost_home(path)?;
                std::fs::remove_file(path).with_context(|| format!("remove {}", path.display()))?;
            } else if *index == segment {
                truncate_private(path, offset)?;
            }
        }
        Ok(())
    }

    fn forget_index_copy(&self, id: &str, index: u32) -> Result<()> {
        let copy = self.local.dir(id).join(kind_index::DIR).join(format!("{index:06}.ndjson"));
        crate::config::refuse_lost_home(&copy)?;
        match std::fs::remove_file(&copy) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => {
                Err(anyhow::Error::from(error).context(format!("remove {}", copy.display())))
            }
        }
    }

    /// Keeps `lines` of chat `id` (its journaled lines from LSN `first_lsn` on) in
    /// `<home>/journal-unapplied/<id>.<first_lsn>.ndjson`, owner-only and synced, and returns
    /// that path.
    fn keep_aside(&self, id: &str, first_lsn: Lsn, lines: &[Vec<u8>]) -> Result<PathBuf> {
        let dir = self.home.join(UNAPPLIED_DIR);
        crate::config::refuse_lost_home(&dir)?;
        crate::config::private_state_dir(&dir)?;
        let name: String = id
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') { c } else { '_' })
            .collect();
        let path = dir.join(format!("{name}.{first_lsn}.ndjson"));
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(&path).with_context(|| format!("write {}", path.display()))?;
        for line in lines {
            file.write_all(line)?;
        }
        file.sync_all()?;
        drop(file);
        sync_directory(&dir)?;
        Ok(path)
    }

    // ------------------------------------------------------------ checkpoints

    /// One checkpoint ([module docs](self)); ten failures in a row ask the daemon to stop.
    fn checkpoint(&self) -> Result<()> {
        let _one = self.checkpointing.lock_or_recover();
        let result = self.checkpoint_once();
        let mut order = self.order.lock_or_recover();
        match &result {
            Ok(()) => order.failures = 0,
            Err(error) if !order.frozen => {
                order.failures = order.failures.saturating_add(1);
                if order.failures >= CHECKPOINT_FAILURES_TO_STOP {
                    drop(order);
                    self.ask_to_stop(format!(
                        "{CHECKPOINT_FAILURES_TO_STOP} event journal checkpoints failed in a row, the last: {error:#}"
                    ));
                }
            }
            Err(_) => {}
        }
        result
    }

    fn checkpoint_once(&self) -> Result<()> {
        let (lsn, dirty) = {
            let mut order = self.order.lock_or_recover();
            anyhow::ensure!(
                !order.frozen,
                "the event journal's checkpoint is frozen (a log sync failed): a restart writes the logs again"
            );
            if order.applied <= order.checkpointed && order.dirty.is_empty() {
                let checkpointed = order.checkpointed;
                drop(order);
                self.retire(checkpointed);
                return Ok(());
            }
            // A failed checkpoint waits for the timer or another `CHECKPOINT_BYTES`.
            order.bytes = 0;
            // Never past the journal's durable end: a crash right after is a normal one.
            (order.applied.min(self.journal.durable_lsn()), std::mem::take(&mut order.dirty))
        };
        if let Err(error) = self.sync_logs(&dirty) {
            self.order.lock_or_recover().dirty.extend(dirty);
            return Err(error);
        }
        if self.local.sync_failed.load(AtomicOrdering::SeqCst) {
            self.freeze("an event log failed to sync at its close".into());
            anyhow::bail!(
                "an event log failed to sync: the journal keeps every line until a restart"
            );
        }
        write_checkpoint(&self.home, lsn)?;
        let damage = {
            let mut order = self.order.lock_or_recover();
            order.checkpointed = order.checkpointed.max(lsn);
            std::mem::take(&mut order.damage)
        };
        if damage && let Err(error) = self.journal.clear_damage() {
            tracing::warn!("clear the event journal's damage report: {error}");
        }
        self.retire(lsn);
        Ok(())
    }

    fn retire(&self, lsn: Lsn) {
        if let Err(error) = self.journal.retire_through(lsn) {
            tracing::warn!("retire the event journal before {lsn}: {error}");
        }
    }

    /// Syncs the logs of `dirty` (their open segment and folders) and the sessions folder (a
    /// delete's removal, a new chat's folder). A chat deleted meanwhile is passed. A failed sync
    /// call freezes the checkpoint; another error (a folder that does not open) fails only this
    /// checkpoint, and the next one tries again.
    fn sync_logs(&self, dirty: &BTreeSet<String>) -> Result<()> {
        let failed = |error: anyhow::Error| {
            if error.chain().any(|cause| cause.is::<SyncFailed>()) {
                self.freeze(format!("an event log failed to sync: {error:#}"));
            }
            error
        };
        for chat in dirty {
            match self.local.sync_log(chat) {
                Ok(()) => {}
                Err(error) if is_not_found(&error) => {}
                Err(error) => {
                    return Err(failed(error.context(format!("sync the log of {chat}"))));
                }
            }
        }
        sync_directory(&self.local.root).map_err(failed)
    }

    /// A log sync failed: no checkpoint until a restart, and the daemon is asked to stop.
    fn freeze(&self, why: String) {
        self.order.lock_or_recover().frozen = true;
        self.ask_to_stop(why);
    }

    fn ask_to_stop(&self, why: String) {
        tracing::error!(
            "{why}: the event journal keeps every line; the daemon stops so that its restart writes the logs again"
        );
        self.stop.send_if_modified(|reason| {
            if reason.is_some() {
                return false;
            }
            *reason = Some(why);
            true
        });
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

/// Whether `error` comes from a file or folder that is not there.
fn is_not_found(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound)
    })
}

/// Reads `path` (segment `segment`) from `from` into `out`, piece by piece.
fn read_pieces(path: &Path, segment: u32, from: u64, out: &mut Vec<Piece>) -> Result<()> {
    use std::io::{Seek, SeekFrom};
    let mut file = crate::config::private_state_file(path)?;
    file.seek(SeekFrom::Start(from))?;
    let mut reader = BufReader::new(file);
    let mut line = Vec::new();
    let mut offset = from;
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line)?;
        if read == 0 {
            return Ok(());
        }
        let len = u64::try_from(read).unwrap_or(u64::MAX);
        let whole = line.last() == Some(&b'\n');
        // A hole of zeros an OS crash left runs into the next line: the zeros are one piece, the
        // line after them another.
        let zeros = line.iter().take_while(|byte| **byte == 0).count();
        let after_zeros = line.get(zeros..).unwrap_or_default();
        if whole && let Some(seq) = line_seq(&line) {
            out.push(Piece { segment, offset, line: Some((seq, line.clone())) });
        } else if whole
            && zeros > 0
            && let Some(seq) = line_seq(after_zeros)
        {
            out.push(Piece { segment, offset, line: None });
            let at = offset.saturating_add(u64::try_from(zeros).unwrap_or(u64::MAX));
            out.push(Piece { segment, offset: at, line: Some((seq, after_zeros.to_vec())) });
        } else {
            out.push(Piece { segment, offset, line: None });
        }
        offset = offset.saturating_add(len);
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
    /// The line to the log first, then its record ([module docs](self)).
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        let class = if streamed(record) { Class::Stream } else { Class::Ack };
        let payload = encode_log(id, line.as_bytes());
        let inner = &self.inner;
        let mut order = inner.order.lock_or_recover();
        // Every append is under this lock, and only the writer empties the journal's queue, so
        // the append below is taken unless the writer stops in between.
        inner.journal.check_append(payload.len()).map_err(JournalStore::journal_error)?;
        // Refused once the store is sealed (under the same lock, so exact).
        inner.local.append_line(id, line.as_bytes())?;
        if !order.dirty.contains(id) {
            order.dirty.insert(id.to_owned());
        }
        // Refused only if the writer stopped since the check: the line is in the log without its
        // record, as after a crash between the two.
        let lsn =
            inner.journal.append(KIND_LOG, class, &payload).map_err(JournalStore::journal_error)?;
        order.applied = lsn;
        order.bytes = order.bytes.saturating_add(u64::try_from(payload.len()).unwrap_or(u64::MAX));
        let full = order.bytes > CHECKPOINT_BYTES && !order.frozen;
        drop(order);
        if full {
            inner.want_checkpoint();
        }
        Ok(())
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
    fn stop_reason(&self) -> Option<tokio::sync::watch::Receiver<Option<String>>> {
        Some(self.inner.stop.subscribe())
    }
    /// The logs refuse writes, and the journal fully syncs every record (the shutdown's `flush`
    /// then checkpoints).
    fn seal(&self) {
        // Under the appends' lock: an append lands in the log and the journal, or in neither.
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
    /// the lines a retention rewrite cut back into its log. A frozen or failed checkpoint stops
    /// the rewrite.
    fn commit_compaction(&self, id: &str, staged: Staged) -> Result<bool> {
        self.inner.checkpoint()?;
        Store::commit_compaction(&self.inner.local, id, staged)
    }
    /// The `forget` record under the appends' lock, then the folder's removal off it, without a
    /// wait for the record: the replay never makes a folder that is gone again.
    fn delete(&self, id: &str) -> Result<()> {
        let inner = &self.inner;
        {
            let mut order = inner.order.lock_or_recover();
            drop(inner.local.writable()?);
            let lsn = inner
                .journal
                .append(KIND_FORGET, Class::Ack, id.as_bytes())
                .map_err(JournalStore::journal_error)?;
            order.applied = lsn;
        }
        Store::delete(&inner.local, id)
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
