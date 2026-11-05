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
//!   retires the journal segments before it. A failed log sync (in it, at a log's close, or in
//!   `flush_session`) freezes it: a later sync may report success for pages the kernel dropped,
//!   so the journal keeps every line and the store asks the daemon to stop
//!   ([`Store::stop_reason`]). The freeze is a `frozen` record in the journal (a control record
//!   that a full queue never refuses; the journal closes only after the shutdown's last
//!   checkpoint): the open that replays it writes every replayed chat's lines again. A record the
//!   journal still refuses (its writer stopped) leaves a durable marker, `<home>/journal-frozen`,
//!   that the open reads the same way. Ten failed checkpoints in a row ask the daemon to stop
//!   too.
//! - Recovery (open) repairs each log and never deletes a whole line or a folder: see
//!   [`Inner::repair`]. It writes every replayed chat's lines again from the point the journal
//!   takes over, so the first checkpoint after it syncs bytes this process wrote (a killed
//!   daemon's writes may be in the page cache only, and a failed sync's dropped pages still read
//!   back). A chat whose folder is gone is not written again. A log that moved on
//!   without the journal (a run with the switch off, or an older build, after a crash) is left as
//!   it is, and the journal's lines for it go to `<home>/journal-unapplied/`. A chat whose log
//!   cannot be read or written now keeps its lines there in a repair file
//!   (`<id>.<lsn>.repair.ndjson`), which the next open journals again and repairs the chat with;
//!   the checkpoint of every other chat goes on (review of #35562: a hold of the global checkpoint
//!   kept every chat's records). A crash in the middle is repaired by the next open the same way.
//! - Delete: a `forget` record (the replay then drops the chat's earlier journaled lines, so a
//!   chat made again under the same id gets only its own), then the folder's removal, off the
//!   appends' lock and without waiting for the record, then the chat's repair file.
//! - With the switch off, [`catch_up`] runs this recovery once on a journal left by a run with it
//!   on, so every acknowledged line is in the logs before they are written alone.
//!
//! - Durability (S2c): [`Store::durability`] gives the last acknowledged LSN and the journal's
//!   durable LSN, for which each connection's outbound gate waits (`server/durable_gate.rs`). A
//!   writer that ends while the store is not dropped (a panic on its thread) closes that watch
//!   and asks the daemon to stop (DESIGN.md decision 9.8).
//!
//! - Chat metadata (S3a, [`meta`]): a change is a `meta` record with the chat's whole metadata
//!   image, not a `session.json` write: reads see the newest image in an overlay, the checkpoint
//!   writes `session.json` once the record is durable, and the replay writes the newest image of
//!   each chat unless its `session.json` moved on without the journal. The replay never makes a
//!   folder that is gone again: a new chat's first record is acknowledged only once its folder's
//!   entry is synced too ([`new_folders`]), so a folder that is gone was removed, not lost.

use super::*;
use cmux_journal::{AppendError, Class, Damage, Journal, Lsn, OpenError};
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Condvar};
use std::time::{Duration, Instant};

mod checkpoint;
mod fenced;
mod meta;
mod new_folders;
mod repair;

use checkpoint::{frozen_marker, read_checkpoint, remove_checkpoint_temporaries};
pub(super) use fenced::FencedStorage;
#[cfg(test)]
pub(super) use meta::SETTLE_HOLD;
use repair::Replay;
#[cfg(test)]
pub(super) use repair::STOP_AFTER_CUT;

/// The journal record kinds. (Kind 3, a `cancel` of a line the log refused, was used before the
/// review of #34901 and never shipped: a refused line is never journaled now. Kind 4 is `meta`,
/// `journal_store/meta.rs`; kind 5 was planned for S3 and never used.)
const KIND_LOG: u16 = 1;
const KIND_FORGET: u16 = 2;
/// A freeze (a failed sync of the store's files; its reason as text): the open that replays it
/// writes every replayed chat's lines again (`Inner::freeze`).
const KIND_FROZEN: u16 = 6;

const JOURNAL_DIR: &str = "journal";
const CHECKPOINT_NAME: &str = "journal-projected.json";
/// The checkpoint file's schema.
const CHECKPOINT_SCHEMA: &str = "acpmux.journal-projected.v1";
/// A durable marker of a freeze whose `frozen` record may not have reached the journal (refused,
/// or not durable when the journal closed): the next open writes every replayed chat's lines
/// again, as for the record (fail closed; delta review of #35866, D1;
/// `journal_store/checkpoint.rs`).
const FROZEN_NAME: &str = "journal-frozen";
/// Where the journaled lines of a log that recovery leaves as it is go.
const UNAPPLIED_DIR: &str = "journal-unapplied";
const CHECKPOINT_EVERY: Duration = Duration::from_secs(30);
/// Journal bytes past the last checkpoint that wake the checkpointer at once.
const CHECKPOINT_BYTES: u64 = 64 * 1024 * 1024;
/// The end of a repair file's name in `journal-unapplied/` ([`Inner::keep_for_repair`]).
const REPAIR_SUFFIX: &str = ".repair.ndjson";
/// In the name of a kept file's temporary copy, before its rename (`Inner::write_kept`).
const KEPT_TEMPORARY: &str = ".ndjson.tmp-";
/// A repair file's first line: `{"schema": REPAIR_SCHEMA, "chat": <id>, "folder": <its identity>}`.
const REPAIR_SCHEMA: &str = "acpmux.journal-repair.v1";
/// Checkpoints in a row that fail before the store asks the daemon to stop: the journal past the
/// last one (what the next open holds in memory) must not grow without end.
const CHECKPOINT_FAILURES_TO_STOP: u32 = 10;
/// The longest a seal waits for the journal's last full sync.
const SEAL_WAIT: Duration = Duration::from_secs(5);
/// The longest an open waits for the journal's lock: a restart overlaps the old daemon's exit.
const LOCK_WAIT: Duration = Duration::from_secs(5);
/// The longest a repair waits for the lines it journals before it cuts a log.
const REPAIR_WAIT: Duration = Duration::from_secs(60);

/// Tests: the seams of one store's checkpointer (`journal_store/checkpoint.rs`), by the store's
/// home: under `cargo test` the tests are threads of one process, and each sees only its own.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct CheckpointerSeams {
    /// The checkpoint period in milliseconds when not 0 (`Inner::checkpoint_every`).
    pub(crate) every_ms: u64,
    /// How many times the checkpointer's loop woke to checkpoint.
    pub(crate) wakes: u64,
    /// Stops the checkpointer once, right after it marked itself idle (before its second look).
    pub(crate) idle_hold: Option<Hold>,
    /// Stops `Inner::touched` once, right after it took the idle flag (before the timer lock).
    pub(crate) touch_hold: Option<Hold>,
}

/// Tests: a stop on one thread: it says so on the first channel, then waits on the second.
#[cfg(test)]
pub(crate) type Hold = (std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>);

#[cfg(test)]
static CHECKPOINTER_SEAMS: Mutex<BTreeMap<PathBuf, CheckpointerSeams>> =
    Mutex::new(BTreeMap::new());

/// Tests: runs `with` on the checkpointer seams of the store at `home`.
#[cfg(test)]
pub(crate) fn checkpointer_seams<T>(
    home: &Path,
    with: impl FnOnce(&mut CheckpointerSeams) -> T,
) -> T {
    let mut seams = CHECKPOINTER_SEAMS.lock_or_recover();
    with(seams.entry(home.to_path_buf()).or_default())
}

#[cfg(test)]
thread_local! {
    /// Tests: the next removal of a chat's folder in `Store::delete` on this thread fails.
    pub(crate) static FAIL_NEXT_FOLDER_REMOVAL: std::cell::Cell<bool> =
        const { std::cell::Cell::new(false) };
    /// Tests: a failed sync on this thread stops right before it freezes the store.
    pub(crate) static HOLD_BEFORE_FREEZE: log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: the next sync of the store's files on this thread (`Inner::counted_sync`) stops
    /// once it is under way, before it syncs.
    pub(crate) static HOLD_IN_SYNC: log_sync::HoldSlot = const { std::cell::RefCell::new(None) };
    /// Tests: a checkpoint on this thread stops right after its start, where it read `frozen`,
    /// the LSN and the chats to sync.
    pub(crate) static HOLD_AFTER_START: log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: the next `frozen` record a freeze on this thread appends is refused, as when the
    /// journal's writer stopped (`AppendError::Closed`).
    pub(crate) static FAIL_FROZEN_RECORD: std::cell::Cell<bool> =
        const { std::cell::Cell::new(false) };
    /// Tests: a freeze on this thread stops right before it writes its fallback marker (off any
    /// sync's count).
    pub(crate) static HOLD_BEFORE_FROZEN_MARKER: log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
}

/// Tests: the stop of [`HOLD_BEFORE_FROZEN_MARKER`].
#[cfg(test)]
fn hold_before_frozen_marker() {
    log_sync::hold(&HOLD_BEFORE_FROZEN_MARKER);
}

/// Tests: the stop of [`HOLD_AFTER_START`].
#[cfg(test)]
fn hold_after_start() {
    log_sync::hold(&HOLD_AFTER_START);
}

/// Tests: the stop of [`HOLD_BEFORE_FREEZE`].
#[cfg(test)]
fn hold_before_freeze() {
    log_sync::hold(&HOLD_BEFORE_FREEZE);
}

/// Tests: the stop of [`HOLD_IN_SYNC`].
#[cfg(test)]
fn hold_in_sync() {
    log_sync::hold(&HOLD_IN_SYNC);
}

/// Tests: the next append stops right after its log write, says so on the first channel and
/// waits for the second (the appends' lock held, as at that point in a real append).
#[cfg(test)]
pub(crate) static PAUSE_AFTER_LOG_WRITE: Mutex<
    Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>,
> = Mutex::new(None);

impl Inner {
    /// Runs `read`, then waits for an append under way to end (`order` taken and let go): every
    /// line `read` saw has its record appended by the time this returns.
    fn fenced<T>(&self, read: impl FnOnce() -> T) -> T {
        let out = read();
        drop(self.order.lock_or_recover());
        out
    }
}

#[cfg(test)]
fn pause_after_log_write() {
    let pause =
        PAUSE_AFTER_LOG_WRITE.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    if let Some((arrived, release)) = pause {
        let _ = arrived.send(());
        let _ = release.recv();
    }
}

pub struct JournalStore {
    inner: Arc<Inner>,
    checkpointer: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// `acpmux-journal-folders` ([`new_folders`]).
    folder_syncer: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// What the journal's open reported (the tests read it).
    #[cfg(test)]
    opened: cmux_journal::OpenReport,
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
    /// The LSN of the last `Ack` record appended (`Store::durability`).
    acked: Arc<AtomicU64>,
    /// The durable LSN the outbound gate waits for: the journal's, fed by its writer, held below
    /// a new chat's record until its folder is synced ([`new_folders`]); closed when the writer
    /// ends.
    durable: tokio::sync::watch::Receiver<u64>,
    /// New chats' folders not synced yet, and the syncer's state ([`new_folders`]).
    new_folders: Arc<new_folders::NewFolders>,
    /// The store is being dropped: its writer's end is not a failure.
    dropping: Arc<AtomicBool>,
    /// Syncs of the store's files under way that freeze it when they fail
    /// (`Inner::counted_sync`): a checkpoint waits for those under way before it writes its LSN.
    syncs: checkpoint::SyncsUnderWay,
    /// The checkpointer sleeps until a change (`Inner::touched`), with nothing to checkpoint.
    idle: AtomicBool,
    /// Held while a chat's folder is removed or its `session.json` written from the overlay
    /// (`journal_store/meta.rs`).
    folders: Mutex<()>,
}

/// Owned by the journal's durable listener, which the writer drops when it ends: a writer that
/// ended while the store was not being dropped (a panic on its thread) asks the daemon to stop
/// (DESIGN.md decision 9.8), and the durable watch it fed closes.
struct WriterEnded {
    stop: tokio::sync::watch::Sender<Option<String>>,
    dropping: Arc<AtomicBool>,
}

impl Drop for WriterEnded {
    fn drop(&mut self) {
        if self.dropping.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        tracing::error!("the event journal's writer ended: no change can be acknowledged");
        self.stop.send_if_modified(|reason| {
            let unset = reason.is_none();
            if unset {
                *reason = Some("the event journal's writer ended".into());
            }
            unset
        });
    }
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
    /// The repair files of the chats whose repair failed at the open (`journal-unapplied/`): a
    /// delete removes its chat's.
    repairs: BTreeMap<String, PathBuf>,
    /// Each chat's newest metadata image that its `session.json` does not hold yet (S3a,
    /// `journal_store/meta.rs`): reads see it first, the checkpoint writes it.
    metas: BTreeMap<String, meta::Pending>,
    /// The log ranges the open's repair read and kept as they were, each with the bytes it found
    /// there (equal to the journal's merged lines): the next checkpoint writes those bytes back
    /// over the range and syncs it before it retires their records. A killed daemon's writes may
    /// be in the page cache only, and a previous run's failed sync may have dropped pages that
    /// still read back; the write marks the range dirty again, so its sync puts the bytes on the
    /// disk whatever happened before (delta review 2 of #35866, D2).
    read_segments: BTreeMap<PathBuf, repair::Verified>,
    /// The open replayed a `frozen` record (a previous run's failed sync) or found the freeze
    /// marker: its repair writes every replayed chat's lines again.
    rewrite_all: bool,
    /// The open found the freeze marker (`FROZEN_NAME`): the first checkpoint that succeeds
    /// removes it.
    marker: bool,
    /// Chats whose lines the open took from a repair file (`journal_store/repair.rs`): written
    /// again too, as their earlier repair could not write them.
    rewrite: BTreeSet<String>,
    /// An upper bound of the LSN of each chat's newest log record in this process (an append, or
    /// the open's replay and repair). A chat without one has no log record past the checkpoint
    /// the open started from: a retention rewrite of a chat at or below the checkpoint needs no
    /// checkpoint of its own (`Store::commit_compaction`).
    log_lsn: HashMap<String, Lsn>,
}

impl Order {
    /// Whether a checkpoint has anything to do.
    fn has_work(&self) -> bool {
        self.applied > self.checkpointed
            || !self.dirty.is_empty()
            || !self.metas.is_empty()
            || !self.read_segments.is_empty()
            || self.marker
    }
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
        let marker = frozen_marker(home);
        let (journal, report, mut replay) =
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
        let dropping = Arc::new(AtomicBool::new(false));
        let (durable_tx, durable) = tokio::sync::watch::channel(journal.durable_lsn());
        // The listener owns the only strong handle: the watch closes when the writer ends.
        let durable_tx = Arc::new(durable_tx);
        let new_folders = Arc::new(new_folders::NewFolders::new(
            Arc::downgrade(&durable_tx),
            journal.durable_lsn(),
        ));
        let ended = WriterEnded { stop: stop.clone(), dropping: Arc::clone(&dropping) };
        let reported = Arc::clone(&new_folders);
        journal.on_durable(move |lsn| {
            let _owned = &ended;
            reported.journal_durable(lsn, &durable_tx);
        });
        let inner = Arc::new(Inner {
            local,
            journal,
            home: home.to_path_buf(),
            order: Mutex::new(Order {
                checkpointed: from,
                damage: !report.damage.is_empty(),
                rewrite_all: replay.frozen || marker,
                marker,
                ..Order::default()
            }),
            checkpointing: Mutex::new(()),
            timer: Mutex::new(Timer::default()),
            wake: Condvar::new(),
            stop,
            acked: Arc::new(AtomicU64::new(0)),
            durable,
            new_folders,
            dropping,
            syncs: checkpoint::SyncsUnderWay::default(),
            folders: Mutex::new(()),
            idle: AtomicBool::new(false),
        });
        // The lines of chats whose repair failed at an earlier open, journaled again first.
        inner.take_repairs(&mut replay);
        inner.apply(replay)?;
        // The checkpoint after the replay runs on the checkpointer's thread at once, not here: the
        // daemon binds its socket after this open returns, and the checkpoint's syncs are the
        // open's cost per replayed chat (6.1 s for 300 chats on a loaded Mac, fleet 59175d6b).
        if inner.order.lock_or_recover().has_work() {
            inner.timer.lock_or_recover().wanted = true;
        }
        let store = Self {
            inner,
            checkpointer: Mutex::new(None),
            folder_syncer: Mutex::new(None),
            #[cfg(test)]
            opened: report,
        };
        // A thread that does not start drops `store`, which stops and joins the other.
        let worker = Arc::clone(&store.inner);
        let folder_syncer = std::thread::Builder::new()
            .name("acpmux-journal-folders".into())
            // At the daemon's disk tier, as the journal writer: a new chat's reply waits for it.
            .spawn(move || worker.run_folder_syncer())
            .context("start the event journal's folder syncer")?;
        *store.folder_syncer.lock_or_recover() = Some(folder_syncer);
        let worker = Arc::clone(&store.inner);
        let checkpointer = std::thread::Builder::new()
            .name("acpmux-journal-checkpoint".into())
            .spawn(move || {
                // Its syncs and retirements are background work: they yield the disk to the
                // person's apps (`qos::background_thread`), while replies wait only on the
                // journal writer, which keeps the daemon's tier.
                crate::qos::background_thread();
                worker.run_checkpointer()
            })
            .context("start the event journal's checkpointer")?;
        *store.checkpointer.lock_or_recover() = Some(checkpointer);
        Ok(store)
    }

    /// What the journal's open reported.
    #[cfg(test)]
    pub(super) fn opened(&self) -> &cmux_journal::OpenReport {
        &self.opened
    }
}

/// [`super::open`] with the journal on `storage` (a simulated file system in the crash tests) and
/// its own limits, for `store.journal`.
#[cfg(test)]
pub(crate) fn open_with_journal(
    config: &StoreConfig,
    root: &Path,
    storage: Arc<dyn cmux_journal::Storage>,
    journal: cmux_journal::Config,
) -> Result<Box<dyn Store>> {
    Ok(Box::new(JournalStore::open(config, root, storage, journal)?))
}

/// Opens the journal, replaying the records after `from`; waits up to [`LOCK_WAIT`] while another
/// process holds it (the daemon before a restart, still exiting).
fn open_journal(
    storage: Arc<dyn cmux_journal::Storage>,
    dir: &Path,
    config: cmux_journal::Config,
    from: Lsn,
) -> Result<(Journal, cmux_journal::OpenReport, Replay)> {
    let deadline = Instant::now().checked_add(LOCK_WAIT);
    loop {
        let mut replay = Replay::default();
        let opened =
            Journal::open(Arc::clone(&storage), dir, config.clone(), from, &mut |record| {
                replay.take(record)
            });
        match opened {
            Ok((journal, report)) => return Ok((journal, report, replay)),
            Err(OpenError::Locked)
                if deadline.is_some_and(|deadline| Instant::now() < deadline) =>
            {
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

/// [`decode_log`], for the tests that read the journal itself.
#[cfg(test)]
pub(super) fn decode_log_for_test(payload: &[u8]) -> Option<(String, &[u8])> {
    decode_log(payload)
}

fn decode_log(payload: &[u8]) -> Option<(String, &[u8])> {
    let len = usize::try_from(u32::from_le_bytes(payload.get(..4)?.try_into().ok()?)).ok()?;
    let end = 4usize.checked_add(len)?;
    let id = std::str::from_utf8(payload.get(4..end)?).ok()?;
    Some((id.to_owned(), payload.get(end..)?))
}

/// The `seq` of a whole log line, or `None` when it does not read.
fn line_seq(line: &[u8]) -> Option<u64> {
    record_seq(line).or_else(|| parse_record(line).ok().map(|record| record.seq))
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
        self.inner.list_metas()
    }
    /// The overlay's image first ([`meta`]), then `session.json`: a checkpoint drops an image
    /// only after its file holds it.
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        match self.inner.pending_meta(id) {
            Some(meta) => Ok(Some(meta)),
            None => Store::load(&self.inner.local, id),
        }
    }
    fn load_startup(&self, id: &str) -> Result<Option<SessionMeta>> {
        match self.inner.pending_meta(id) {
            Some(meta) => Ok(Some(meta)),
            None => Store::load_startup(&self.inner.local, id),
        }
    }
    /// A `meta` record and the overlay; the checkpoint writes `session.json` ([`meta`]).
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        self.inner.save_meta(meta)
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
        #[cfg(test)]
        pause_after_log_write();
        if !order.dirty.contains(id) {
            order.dirty.insert(id.to_owned());
        }
        // Refused only if the writer stopped since the check: the line is in the log without its
        // record, as after a crash between the two.
        let lsn =
            inner.journal.append(KIND_LOG, class, &payload).map_err(JournalStore::journal_error)?;
        if class == Class::Ack {
            inner.acked.store(lsn, std::sync::atomic::Ordering::SeqCst);
        }
        order.applied = lsn;
        // A chat's first line in this process allocates its entry; every later one reuses it.
        match order.log_lsn.get_mut(id) {
            Some(newest) => *newest = lsn,
            None => {
                order.log_lsn.insert(id.to_owned(), lsn);
            }
        }
        order.bytes = order.bytes.saturating_add(u64::try_from(payload.len()).unwrap_or(u64::MAX));
        let full = order.bytes > CHECKPOINT_BYTES && !order.frozen;
        drop(order);
        if full {
            inner.want_checkpoint();
        }
        inner.touched();
        Ok(())
    }
    /// The chat's log and metadata durable on disk: its overlay image written to `session.json`
    /// first ([`meta`]), then the log, its folders and the sessions folder synced. A failed file
    /// sync freezes the checkpoint, as one in a checkpoint or at a log's close does: a later sync
    /// may report success for the pages it dropped.
    fn flush_session(&self, id: &str) -> Result<()> {
        let inner = &self.inner;
        inner.settle_meta(id)?;
        inner.counted_sync("an event log failed to sync", || Store::flush_session(&inner.local, id))
    }
    // Every read of the logs ends with a fence on the appends' lock (`Inner::fenced`): a line
    // the read saw has its record appended, and its acknowledged LSN set, when the read returns,
    // so a reply built from the read raises its connection's gate past that record (review of
    // #35400, F1). A read that sends as it reads stops at the chat's `last_seq` instead
    // (`Hub::scan_events`).
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.inner.fenced(|| Store::events(&self.inner.local, id, after, limit))
    }
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        self.inner.fenced(|| Store::scan(&self.inner.local, id, after, visit))
    }
    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.inner.fenced(|| Store::scan_strict(&self.inner.local, id, after, visit))
    }
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.inner.fenced(|| Store::scan_back(&self.inner.local, id, after, before, skip, visit))
    }
    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        self.inner.fenced(|| Store::tail_after(&self.inner.local, id, after))
    }
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.inner.fenced(|| Store::scan_kinds(&self.inner.local, id, kinds, visit))
    }
    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.inner.fenced(|| Store::scan_kinds_strict(&self.inner.local, id, kinds, visit))
    }
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        self.inner.fenced(|| Store::scan_heads(&self.inner.local, id, visit))
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
    fn durability(&self) -> Option<Durability> {
        let inner = Arc::downgrade(&self.inner);
        Some(Durability {
            acked: Arc::clone(&self.inner.acked),
            durable: self.inner.durable.clone(),
            stalled: Arc::new(move |why: String| {
                if let Some(inner) = inner.upgrade() {
                    inner.ask_to_stop(why);
                }
            }),
        })
    }
    /// No write lands after this returns; then the shutdown's last checkpoint, while the journal is
    /// still open; then the journal closes, every record fully synced. The last checkpoint runs
    /// here and not after (delta review of #35866, D1): a log sync that fails in it, or in a sync
    /// under way that it waits for, freezes the store, and its `frozen` record must reach the
    /// journal. A checkpoint after this (`Hub::seal`'s flush) finds no work.
    fn seal(&self) {
        {
            // Under the appends' lock: an append lands in the log and the journal, or in neither.
            let _order = self.inner.order.lock_or_recover();
            Store::seal(&self.inner.local);
        }
        if let Err(error) = self.inner.checkpoint() {
            tracing::warn!("the event journal's last checkpoint: {error:#}");
        }
        let order = self.inner.order.lock_or_recover();
        if let Err(error) = self.inner.journal.seal(SEAL_WAIT) {
            tracing::error!("seal the event journal: {error}");
            // Fail closed: a frozen store's record may not be durable.
            let frozen = order.frozen;
            drop(order);
            if frozen {
                self.inner.keep_frozen_marker(
                    "the event journal did not close with its frozen record durable",
                );
            }
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
    /// No journal record of the chat may be past the checkpoint: a replay must never write the
    /// lines a retention rewrite cut back into its log. A chat whose newest log record is at or
    /// below it (`Order::log_lsn`; retention takes chats untouched for days) needs no checkpoint;
    /// any other runs one first, and a frozen or failed checkpoint stops the rewrite. The caller
    /// holds the chat's append lock (no record of it lands meanwhile), so a checkpoint in flight
    /// (the one after a restart's replay takes seconds with many chats) never holds that lock for
    /// an old chat. The commit (its record before and after the renames, the renames, the
    /// folder's sync after them) runs in `counted_sync`, so a failed sync in it freezes the store,
    /// as a failed log sync does (#35905): a later sync of the folder may report success for the
    /// renames a failed one dropped, so no checkpoint may go past it. The rewritten copies are
    /// synced earlier, in `stage_compaction`, before any rename: a failure there only fails the
    /// pass and changes no log.
    fn commit_compaction(&self, id: &str, staged: Staged) -> Result<bool> {
        let inner = &self.inner;
        let covered = {
            let order = inner.order.lock_or_recover();
            !order.frozen
                && order.log_lsn.get(id).is_none_or(|newest| *newest <= order.checkpointed)
        };
        if !covered {
            inner.checkpoint()?;
        }
        inner.counted_sync("a rewritten event log failed to sync", || {
            Store::commit_compaction(&inner.local, id, staged)
        })
    }
    /// The `forget` record under the appends' lock, then the folder's removal off it, without a
    /// wait for the record: the replay never makes a folder that is gone again. Then the chat's
    /// repair file, if its repair failed at the open (after the folder: a crash between the two
    /// leaves the file of a folder that is gone, which no open applies; the other order could
    /// lose the lines of a chat whose delete a crash took back). The file is the store's to
    /// remove until that removal succeeds, so a delete that fails and is tried again still
    /// removes it (review of #35562, D3).
    fn delete(&self, id: &str) -> Result<()> {
        let inner = &self.inner;
        let repair = {
            let mut order = inner.order.lock_or_recover();
            drop(inner.local.writable()?);
            let lsn = inner
                .journal
                .append(KIND_FORGET, Class::Ack, id.as_bytes())
                .map_err(JournalStore::journal_error)?;
            inner.acked.store(lsn, std::sync::atomic::Ordering::SeqCst);
            order.applied = lsn;
            order.metas.remove(id);
            order.repairs.get(id).cloned()
        };
        inner.touched();
        {
            // Not while a checkpoint writes this chat's `session.json` (`journal_store/meta.rs`).
            let _folder = inner.folders.lock_or_recover();
            #[cfg(test)]
            if FAIL_NEXT_FOLDER_REMOVAL.with(|fail| fail.replace(false)) {
                anyhow::bail!("a failed folder removal (a test)");
            }
            Store::delete(&inner.local, id)?;
        }
        if let Some(path) = repair {
            inner.remove_repair(&path)?;
            inner.order.lock_or_recover().repairs.remove(id);
        }
        Ok(())
    }
    /// The chat's folder, for code that reads or moves its files directly: its overlay image is
    /// written to `session.json` first ([`meta`]).
    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        if let Err(error) = self.inner.settle_meta(id) {
            tracing::warn!(session = %id, "write the chat's metadata before handing out its folder: {error:#}");
        }
        Store::session_dir(&self.inner.local, id)
    }
    /// The folder's path only: no lock, no wait, no write (review of #35483, P3 1).
    fn session_path(&self, id: &str) -> Option<PathBuf> {
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
    /// Stops the checkpointer and the folder syncer. No checkpoint here: a drop is not a shutdown
    /// (`flush` is).
    fn drop(&mut self) {
        self.inner.dropping.store(true, std::sync::atomic::Ordering::SeqCst);
        self.inner.timer.lock_or_recover().stop = true;
        self.inner.wake.notify_all();
        self.inner.new_folders.stop();
        if let Some(handle) = self.checkpointer.lock_or_recover().take() {
            let _ = handle.join();
        }
        if let Some(handle) = self.folder_syncer.lock_or_recover().take() {
            let _ = handle.join();
        }
    }
}
