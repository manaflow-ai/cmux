//! Registry premigration: the next build's binary does, beside the running
//! owner, the work its own start would otherwise do while the app waits.
//!
//! A build that bumps the agent roster reducer version makes its first start
//! re-fold the whole journal (26-30 min on a 59 GB registry, 2026-11-08). The
//! app runs `server premigrate-registry` with the new binary before it hands
//! the old daemon off, so that fold happens while the old owner still serves.
//!
//! The premigration only reads the registry: a read-only connection with
//! `query_only`, no session lock (the owner holds them), and one short read
//! transaction per journal page, so the owner's WAL checkpoints are never
//! pinned for long. Its result is a side file beside the registry. The new
//! owner adopts it under its own locks at open (`adopt`) when it names the
//! same registry, the current reducer version and a cursor within the live
//! journal; any other file is dropped. A partial fold is as good as a whole
//! one: the fold is pure, so the owner folds only the tail after its cursor.

use std::fs::{self, File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::Context as _;
use fs4::FileExt;
use rusqlite::Connection;
use serde_json::Value;

use super::open_guard::sidecar_path;
use super::session_journal::kind_read::query_session_journal_kinds_after;
use super::session_journal::{query_journal_head, query_session_journal_after, unproven_kind_maps};
use super::{
    WORKSPACE_REGISTRY_FILE, WorkspaceRegistry, meta_value, open_registry_database_read_only,
    persistent_session_state_dir,
};
use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, AgentRoster};
use crate::platform;

/// Beside the registry: `workspace-registry.sqlite3.premigrate-agent-roster.json`.
pub const ROSTER_SIDE_FILE_SUFFIX: &str = ".premigrate-agent-roster.json";
const ROSTER_SIDE_FILE_FORMAT: u64 = 1;
/// One premigration per registry at a time.
const LOCK_FILE_SUFFIX: &str = ".premigrate.lock";
/// Records per journal page, as the owner's restore reads them.
const PAGE: usize = 512;
/// How often a running fold saves its side file and prints its progress.
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(5);

/// How long a premigration may run and when it stops.
pub struct PremigrateControl<'a> {
    /// Stop once this long has passed; the progress so far is saved.
    pub max_duration: Option<Duration>,
    /// Whether the process was asked to stop (SIGTERM, SIGINT); checked
    /// between pages.
    pub stopped: &'a dyn Fn() -> bool,
    page: usize,
    stop_after_pages: Option<usize>,
}

impl<'a> PremigrateControl<'a> {
    pub fn new(max_duration: Option<Duration>, stopped: &'a dyn Fn() -> bool) -> Self {
        Self { max_duration, stopped, page: PAGE, stop_after_pages: None }
    }

    /// Test seam: `page` records per read, stopping after `pages` reads.
    #[cfg(test)]
    pub(crate) fn pages(mut self, page: usize, pages: Option<usize>) -> Self {
        self.page = page;
        self.stop_after_pages = pages;
        self
    }
}

#[derive(Debug)]
pub enum PremigrateOutcome {
    /// The session has no saved registry: nothing to do.
    NoRegistry(PathBuf),
    /// Another premigration of this registry runs.
    AlreadyRunning(PathBuf),
    Done(RosterPremigration),
}

/// The agent roster part of a premigration.
#[derive(Debug, Clone)]
pub struct RosterPremigration {
    pub registry: PathBuf,
    pub side_file: PathBuf,
    /// The reducer version folded.
    pub version: u32,
    /// The registry's roster snapshot already has `version`: nothing folded.
    pub up_to_date: bool,
    /// Where this run started (a side file of an earlier run, or 0).
    pub from_cursor: u64,
    /// Folded through this sequence; saved in the side file.
    pub cursor: u64,
    /// The journal head when this run started.
    pub head: u64,
    pub complete: bool,
    pub records_folded: u64,
    pub elapsed_ms: u64,
    /// Why an incomplete fold stopped: `max_seconds`, `stopped` or `read_failed`.
    pub stop_reason: Option<&'static str>,
}

/// Premigrates the registry of `session_name` under the state root `root`
/// while its owner may serve it. Runs at background priority on the calling
/// thread.
pub fn premigrate_registry(
    root: &Path,
    session_name: &str,
    control: &PremigrateControl<'_>,
) -> anyhow::Result<PremigrateOutcome> {
    let started = Instant::now();
    let root = platform::normalize_filesystem_path(root.to_path_buf());
    let db_path = platform::normalize_filesystem_path(
        persistent_session_state_dir(&root, session_name).join(WORKSPACE_REGISTRY_FILE),
    );
    if !db_path.is_file() {
        return Ok(PremigrateOutcome::NoRegistry(db_path));
    }
    lower_thread_priority();
    let lock_path = sidecar_path(&db_path, LOCK_FILE_SUFFIX);
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)
        .with_context(|| format!("open premigration lock {}", lock_path.display()))?;
    let _ = platform::restrict_file(&lock_path);
    match FileExt::try_lock(&lock) {
        Ok(()) => {}
        Err(fs4::TryLockError::WouldBlock) => {
            return Ok(PremigrateOutcome::AlreadyRunning(db_path));
        }
        Err(error) => {
            return Err(error)
                .with_context(|| format!("lock premigration {}", lock_path.display()));
        }
    }
    let source = open_registry_database_read_only(&db_path)
        .with_context(|| format!("open workspace registry {}", db_path.display()))?;
    source.busy_timeout(Duration::from_secs(5))?;
    source.execute_batch("PRAGMA query_only=1;")?;
    let report = fold_roster(&source, &db_path, control, started)?;
    let _ = FileExt::unlock(&lock);
    Ok(PremigrateOutcome::Done(report))
}

/// The registry file of `session_name` under the state root `root`.
#[cfg(test)]
pub(crate) fn registry_file(root: &Path, session_name: &str) -> PathBuf {
    platform::normalize_filesystem_path(
        persistent_session_state_dir(
            &platform::normalize_filesystem_path(root.to_path_buf()),
            session_name,
        )
        .join(WORKSPACE_REGISTRY_FILE),
    )
}

/// The side file of the registry at `db_path`.
pub fn roster_side_file(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, ROSTER_SIDE_FILE_SUFFIX)
}

/// A roster folded at `version` through `cursor` of registry `registry_id`.
#[derive(Debug, Clone, PartialEq)]
struct SideSnapshot {
    registry_id: String,
    version: u32,
    cursor: u64,
    snapshot: String,
}

impl SideSnapshot {
    fn read(path: &Path) -> anyhow::Result<Option<Self>> {
        let bytes = match fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
        };
        let value: Value = serde_json::from_slice(&bytes)
            .with_context(|| format!("{} is not JSON", path.display()))?;
        let field = |name: &str| value.get(name);
        anyhow::ensure!(
            field("format").and_then(Value::as_u64) == Some(ROSTER_SIDE_FILE_FORMAT),
            "{} has another format",
            path.display()
        );
        anyhow::ensure!(
            field("reducer_id").and_then(Value::as_str) == Some(AGENT_ROSTER_REDUCER_ID),
            "{} names another reducer",
            path.display()
        );
        let text = |name: &str| {
            field(name)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .with_context(|| format!("{} has no {name}", path.display()))
        };
        Ok(Some(Self {
            registry_id: text("registry_id")?,
            version: field("version")
                .and_then(Value::as_u64)
                .and_then(|version| u32::try_from(version).ok())
                .with_context(|| format!("{} has no version", path.display()))?,
            cursor: text("cursor")?
                .parse()
                .with_context(|| format!("{} has an invalid cursor", path.display()))?,
            snapshot: text("snapshot")?,
        }))
    }

    /// Replaces `path` atomically and durably: a temporary file beside it,
    /// synced, renamed over it, and the directory synced.
    fn write(&self, path: &Path) -> anyhow::Result<()> {
        let value = serde_json::json!({
            "format": ROSTER_SIDE_FILE_FORMAT,
            "registry_id": self.registry_id,
            "reducer_id": AGENT_ROSTER_REDUCER_ID,
            "version": self.version,
            // A string, as in the registry's meta, so 64-bit cursors survive JSON.
            "cursor": self.cursor.to_string(),
            "snapshot": self.snapshot,
        });
        let temporary = sidecar_path(path, ".tmp");
        let mut file =
            File::create(&temporary).with_context(|| format!("create {}", temporary.display()))?;
        platform::restrict_file(&temporary)?;
        file.write_all(value.to_string().as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path).with_context(|| format!("replace {}", path.display()))?;
        #[cfg(unix)]
        if let Some(directory) = path.parent() {
            File::open(directory)?.sync_all()?;
        }
        Ok(())
    }
}

/// The reducer version of the registry's persisted roster, as the owner's
/// restore reads it (a missing or unreadable version is 0).
/// Whether the registry's roster is marked stale: a start of this build
/// served a roster migrated from an older reducer version and has not
/// finished rebuilding it from the whole journal (`agent_roster_rebuild.rs`).
/// Such a roster is saved at the current version, so the version alone does
/// not tell it from a fold.
fn roster_rebuild_pending(source: &Connection) -> anyhow::Result<bool> {
    Ok(meta_value(source, &format!("journal_reducer_rebuild.{AGENT_ROSTER_REDUCER_ID}"))?.is_some())
}

fn stored_roster_version(source: &Connection) -> anyhow::Result<Option<u32>> {
    let raw = meta_value(source, &format!("journal_reducer.{AGENT_ROSTER_REDUCER_ID}"))?;
    Ok(raw.map(|raw| {
        serde_json::from_str::<Value>(&raw)
            .ok()
            .and_then(|value| value.get("version").and_then(Value::as_u64))
            .and_then(|version| u32::try_from(version).ok())
            .unwrap_or(0)
    }))
}

/// The registry's saved roster as this build reads it (restored at the
/// current reducer version, migrated from an older one) with its cursor.
/// `None` when there is none, it does not restore, or its cursor is not in
/// the journal.
fn saved_roster(source: &Connection, head: u64) -> anyhow::Result<Option<(AgentRoster, u64)>> {
    let Some(raw) = meta_value(source, &format!("journal_reducer.{AGENT_ROSTER_REDUCER_ID}"))?
    else {
        return Ok(None);
    };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else { return Ok(None) };
    let version = value
        .get("version")
        .and_then(Value::as_u64)
        .and_then(|version| u32::try_from(version).ok())
        .unwrap_or(0);
    let cursor =
        value.get("cursor").and_then(Value::as_str).and_then(|cursor| cursor.parse::<u64>().ok());
    let (Some(cursor), Some(snapshot)) = (cursor, value.get("snapshot").and_then(Value::as_str))
    else {
        return Ok(None);
    };
    if cursor > head {
        return Ok(None);
    }
    let roster = if version == AGENT_ROSTER_REDUCER_VERSION {
        AgentRoster::restore(snapshot)
    } else {
        AgentRoster::migrate(version, snapshot)
    };
    Ok(roster.map(|roster| (roster, cursor)))
}

fn fold_roster(
    source: &Connection,
    db_path: &Path,
    control: &PremigrateControl<'_>,
    started: Instant,
) -> anyhow::Result<RosterPremigration> {
    let side_file = roster_side_file(db_path);
    let registry_id =
        meta_value(source, "registry_id")?.context("the workspace registry has no registry_id")?;
    let head = query_journal_head(source)?;
    let mut report = RosterPremigration {
        registry: db_path.to_path_buf(),
        side_file: side_file.clone(),
        version: AGENT_ROSTER_REDUCER_VERSION,
        up_to_date: false,
        from_cursor: 0,
        cursor: 0,
        head,
        complete: false,
        records_folded: 0,
        elapsed_ms: 0,
        stop_reason: None,
    };
    // A snapshot of another version, or none, makes the next start re-fold
    // the whole journal; one of this version leaves it only the tail.
    if stored_roster_version(source)? == Some(AGENT_ROSTER_REDUCER_VERSION)
        && !roster_rebuild_pending(source)?
    {
        report.up_to_date = true;
        report.complete = true;
        let _ = fs::remove_file(&side_file);
        return Ok(report);
    }
    // Journal retention deleted the records through this sequence: a fold
    // from the first record does not see them.
    let pruned_through = super::journal_retention::journal_pruned_through(source)?;
    let resumed = match SideSnapshot::read(&side_file) {
        Ok(Some(side))
            if side.registry_id == registry_id
                && side.version == AGENT_ROSTER_REDUCER_VERSION
                && side.cursor <= head
                // A side file that stopped below the deleted records cannot
                // go on: the records after its cursor are gone.
                && (pruned_through == 0 || side.cursor >= pruned_through) =>
        {
            AgentRoster::restore(&side.snapshot).map(|roster| (roster, side.cursor))
        }
        Ok(_) => None,
        Err(error) => {
            eprintln!("cmux-tui: premigrate: ignoring the side snapshot: {error:#}");
            None
        }
    };
    // With records deleted, the saved roster is the one copy of an agent
    // whose records were all below the floor: the fold goes on from it (the
    // rule of the owner's background rebuild, `agent_roster_rebuild.rs`).
    // Retention never passes the saved roster's cursor, so no record
    // between that cursor and the head is missing.
    let resumed = match resumed {
        None if pruned_through > 0 => saved_roster(source, head)?,
        resumed => resumed,
    };
    let (mut roster, mut cursor) = resumed.unwrap_or_default();
    report.from_cursor = cursor;
    let deadline = control.max_duration.map(|limit| started + limit);
    let save = |roster: &AgentRoster, cursor: u64| {
        SideSnapshot {
            registry_id: registry_id.clone(),
            version: AGENT_ROSTER_REDUCER_VERSION,
            cursor,
            snapshot: roster.snapshot().to_string(),
        }
        .write(&side_file)
    };
    let mut last_checkpoint = Instant::now();
    let mut saved_at = None;
    let mut pages = 0usize;
    while cursor < head {
        if (control.stopped)() {
            report.stop_reason = Some("stopped");
            break;
        }
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            report.stop_reason = Some("max_seconds");
            break;
        }
        if control.stop_after_pages == Some(pages) {
            report.stop_reason = Some("stopped");
            break;
        }
        pages += 1;
        match read_page(source, cursor, head, control.page) {
            Ok((records, reached)) if reached > cursor => {
                for record in &records {
                    roster.apply(&crate::journal_reducers::RosterEvent::from_record(record));
                }
                report.records_folded += records.len() as u64;
                cursor = reached;
            }
            outcome => {
                // The owner's salvaging restore skips what does not decode;
                // this fold stops at the last good cursor and leaves the
                // rest to it.
                let reason = match outcome {
                    Err(error) => format!("{error:#}"),
                    Ok(_) => "the journal read made no progress".to_owned(),
                };
                eprintln!(
                    "cmux-tui: premigrate: agent roster fold stopped at sequence {cursor}: {reason}"
                );
                report.stop_reason = Some("read_failed");
                break;
            }
        }
        if last_checkpoint.elapsed() >= CHECKPOINT_INTERVAL {
            save(&roster, cursor)?;
            saved_at = Some(cursor);
            last_checkpoint = Instant::now();
            print_progress(cursor, head);
        }
    }
    if saved_at != Some(cursor) && (cursor != report.from_cursor || !side_file.exists()) {
        save(&roster, cursor)?;
    }
    print_progress(cursor, head);
    report.cursor = cursor;
    report.complete = cursor >= head;
    if report.complete {
        report.stop_reason = None;
    }
    report.elapsed_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    Ok(report)
}

/// One page of the records the roster folds ([`AgentRoster::folds_kind`]),
/// in its own short read transaction: a consistent view of the active
/// journal and its sealed segments while the owner appends and seals,
/// released before the next page.
///
/// The kind read skips a sealed segment whose kind map names none of the
/// roster's kinds. A map is whole only once the legacy kind backfill has
/// finished: one an older build stopped partway can map a segment as only
/// `personal.session.put` while it holds an agent event, and the kind read
/// would skip that event and pass the cursor over it for good. Until the
/// backfill's marker says it finished ([`unproven_kind_maps`], the one rule
/// the kind read uses too), the sealed range is read with the full
/// validating decoder instead; a read-only connection never runs the
/// backfill itself. The active journal's kind index is always whole.
fn read_page(
    source: &Connection,
    cursor: u64,
    head: u64,
    page: usize,
) -> anyhow::Result<(Vec<super::SessionJournalRecord>, u64)> {
    let transaction = source.unchecked_transaction()?;
    let read = (|| {
        if cursor < archive_head(&transaction)? && unproven_kind_maps(&transaction)?.is_some() {
            return full_decode_page(&transaction, cursor, head, page);
        }
        query_session_journal_kinds_after(&transaction, cursor, head, AgentRoster::folds_kind, page)
    })();
    transaction.finish()?;
    read
}

/// The last sequence held by a sealed segment (0 with none).
fn archive_head(connection: &Connection) -> anyhow::Result<u64> {
    let end: i64 = connection.query_row(
        "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
        [],
        |row| row.get(0),
    )?;
    u64::try_from(end).context("archived journal sequence is negative")
}

/// Every record after `cursor` through the validating decoder, at most
/// `page`, keeping the roster's kinds; the cursor reaches the last record
/// read, so no record is passed over unread.
fn full_decode_page(
    connection: &Connection,
    cursor: u64,
    head: u64,
    page: usize,
) -> anyhow::Result<(Vec<super::SessionJournalRecord>, u64)> {
    let read = query_session_journal_after(connection, cursor, page)?;
    let records =
        read.records.into_iter().take_while(|record| record.sequence <= head).collect::<Vec<_>>();
    let reached = records.last().map_or(cursor, |record| record.sequence);
    let records = records.into_iter().filter(|record| AgentRoster::folds_kind(&record.kind));
    Ok((records.collect(), reached))
}

fn print_progress(cursor: u64, head: u64) {
    eprintln!("cmux-tui: premigrate: agent roster folded through {cursor} of {head}");
}

/// At the end of the owner's open, under its session locks. A side file
/// that names this registry, the current reducer version, a cursor within the
/// live journal and a snapshot that restores is used one of two ways; any
/// other side file is removed.
///
/// - Complete: its cursor is at or past the registry's own saved cursor. It
///   replaces the saved roster and clears the stale mark (it is a fold from
///   the first record, so it is the rebuild), and the start folds only the
///   tail after it, as after any save.
/// - Partial (a premigration cut short by its time limit, a stop or a read
///   failure): the registry is left as it is, so the start serves exactly
///   what it would without a premigration (the migrated saved roster, marked
///   stale), and the file stays as the seed of the background rebuild
///   ([`rebuild_seed`]), which folds only the journal after it. Served in
///   place of the saved roster, a partial fold would show an old prefix of
///   the history until the start's replay caught up.
///
/// A registry whose roster is current and not marked stale has no use for
/// the file, and it is removed. A failed write keeps it for the next start.
pub(crate) fn adopt(registry: &WorkspaceRegistry) {
    let Some(db_path) = registry.database_path.as_deref() else { return };
    let side_file = roster_side_file(db_path);
    if !side_file.exists() {
        return;
    }
    let stored = registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).ok().flatten();
    let rebuild_pending =
        registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).ok().flatten().is_some();
    if !rebuild_pending
        && stored.as_ref().is_some_and(|(version, _, _)| *version == AGENT_ROSTER_REDUCER_VERSION)
    {
        let _ = fs::remove_file(&side_file);
        return;
    }
    let Some((side, head)) = usable_side_snapshot(registry, &side_file) else { return };
    let saved_cursor = stored.map_or(0, |(_, cursor, _)| cursor);
    if side.cursor < saved_cursor {
        eprintln!(
            "cmux-tui: premigrated agent roster at cursor {} is behind the saved roster's {}; \
             it seeds the background rebuild",
            side.cursor, saved_cursor
        );
        return;
    }
    match registry.finish_journal_reducer_rebuild(
        AGENT_ROSTER_REDUCER_ID,
        AGENT_ROSTER_REDUCER_VERSION,
        side.cursor,
        &side.snapshot,
    ) {
        Ok(()) => {
            eprintln!(
                "cmux-tui: adopted premigrated agent roster at cursor {} of head {head}",
                side.cursor
            );
            let _ = fs::remove_file(&side_file);
        }
        Err(error) => {
            eprintln!("cmux-tui: adopting the premigrated agent roster failed: {error:#}");
        }
    }
}

/// Where the background rebuild of a stale roster starts: a premigrated
/// roster folded from the first record through its cursor, so the rebuild
/// folds only the journal after it. `None` (the rebuild folds from the first
/// record) without a usable side file; an unusable one is removed.
pub(crate) fn rebuild_seed(registry: &WorkspaceRegistry) -> Option<(AgentRoster, u64)> {
    let side_file = roster_side_file(registry.database_path.as_deref()?);
    if !side_file.exists() {
        return None;
    }
    let (side, head) = usable_side_snapshot(registry, &side_file)?;
    let roster = AgentRoster::restore(&side.snapshot)?;
    eprintln!(
        "cmux-tui: the agent roster rebuild resumes from the premigrated roster at cursor {} of \
         head {head}",
        side.cursor
    );
    Some((roster, side.cursor))
}

/// The side snapshot at `side_file` and the journal head, when the snapshot
/// names this registry, the current reducer version, a cursor within the
/// live journal and restores; otherwise the file is removed.
fn usable_side_snapshot(
    registry: &WorkspaceRegistry,
    side_file: &Path,
) -> Option<(SideSnapshot, u64)> {
    let side = match SideSnapshot::read(side_file) {
        Ok(Some(side)) => side,
        Ok(None) => return None,
        Err(error) => {
            eprintln!("cmux-tui: premigrated agent roster dropped: {error:#}");
            let _ = fs::remove_file(side_file);
            return None;
        }
    };
    let head = registry.session_journal_head();
    let refusal = if side.registry_id != registry.registry_id() {
        Some("it names another registry".to_owned())
    } else if side.version != AGENT_ROSTER_REDUCER_VERSION {
        Some(format!("it is of reducer version {}", side.version))
    } else if !matches!(head, Ok(head) if side.cursor <= head) {
        Some(format!("its cursor {} is past the journal head", side.cursor))
    } else if AgentRoster::restore(&side.snapshot).is_none() {
        Some("its snapshot does not restore".to_owned())
    } else {
        None
    };
    match (refusal, head) {
        (None, Ok(head)) => Some((side, head)),
        (refusal, _) => {
            let refusal = refusal.unwrap_or_else(|| "the journal head is unreadable".to_owned());
            eprintln!("cmux-tui: premigrated agent roster dropped: {refusal}");
            let _ = fs::remove_file(side_file);
            None
        }
    }
}

/// Background QoS on macOS; lowest CPU and idle IO priority for this thread
/// on Linux. Elsewhere the thread keeps its default priority.
fn lower_thread_priority() {
    #[cfg(target_vendor = "apple")]
    // SAFETY: sets the calling thread's own QoS class; no pointers.
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_BACKGROUND, 0);
    }
    #[cfg(target_os = "linux")]
    // SAFETY: plain syscalls on the calling thread's own id.
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
        libc::setpriority(libc::PRIO_PROCESS, tid, 19);
        // ioprio_set(IOPRIO_WHO_PROCESS, tid, IOPRIO_CLASS_IDLE).
        libc::syscall(libc::SYS_ioprio_set, 1, tid, 3 << 13);
    }
}
