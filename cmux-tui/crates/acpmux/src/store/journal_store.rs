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
//! - Durability (S2c): [`Store::durability`] gives the last acknowledged LSN and the journal's
//!   durable LSN, for which each connection's outbound gate waits (`server/durable_gate.rs`). A
//!   writer that ends while the store is not dropped (a panic on its thread) closes that watch
//!   and asks the daemon to stop (DESIGN.md decision 9.8).
//!
//! Session metadata is S3.

use super::*;
use cmux_journal::{AppendError, Class, Damage, Journal, Lsn, OpenError};
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Condvar};
use std::time::{Duration, Instant};

mod checkpoint;
mod fenced;
mod repair;

use checkpoint::{read_checkpoint, remove_checkpoint_temporaries};
pub(super) use fenced::FencedStorage;
use repair::Replay;
#[cfg(test)]
pub(super) use repair::STOP_AFTER_CUT;

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
    /// The journal's durable LSN, fed by its writer; closed when the writer ends.
    durable: tokio::sync::watch::Receiver<u64>,
    /// The store is being dropped: its writer's end is not a failure.
    dropping: Arc<AtomicBool>,
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
        let dropping = Arc::new(AtomicBool::new(false));
        let (durable_tx, durable) = tokio::sync::watch::channel(journal.durable_lsn());
        let ended = WriterEnded { stop: stop.clone(), dropping: Arc::clone(&dropping) };
        journal.on_durable(move |lsn| {
            let _owned = &ended;
            durable_tx.send_if_modified(|was| {
                let moved = lsn > *was;
                if moved {
                    *was = lsn;
                }
                moved
            });
        });
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
            acked: Arc::new(AtomicU64::new(0)),
            durable,
            dropping,
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
        if class == Class::Ack {
            inner.acked.store(lsn, std::sync::atomic::Ordering::SeqCst);
        }
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
    fn durability(&self) -> Option<Durability> {
        Some(Durability {
            acked: Arc::clone(&self.inner.acked),
            durable: self.inner.durable.clone(),
        })
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
            inner.acked.store(lsn, std::sync::atomic::Ordering::SeqCst);
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
        self.inner.dropping.store(true, std::sync::atomic::Ordering::SeqCst);
        self.inner.timer.lock_or_recover().stop = true;
        self.inner.wake.notify_all();
        if let Some(handle) = self.checkpointer.lock_or_recover().take() {
            let _ = handle.join();
        }
    }
}
