//! What a maintenance pass reports as work left, and the cadence the worker
//! takes from it: an interval while a ledger drains, segments wait to seal,
//! free pages wait to go back or a corrupt ledger waits to be set aside;
//! the idle pass once nothing is left (p06-scheduler-228).

use super::*;
use crate::workspace_registry::WorkspaceRegistry;
use crate::workspace_registry::mutation_ledger_retention::MUTATION_LEDGERS;
use ledger_maintenance::LedgerMaintenance;
use rusqlite::{Connection, params};
use std::path::{Path, PathBuf};

/// A persistent session whose own maintenance worker is stopped, so only
/// the test runs passes.
struct IdleSession {
    root: PathBuf,
    name: String,
    database: PathBuf,
    mux: Option<Arc<Mux>>,
}

impl IdleSession {
    /// Creates the registry; [`Self::open`] starts the session on it.
    fn new(label: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "cmux-maintenance-work-{label}-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let database = WorkspaceRegistry::open(&root, label)
            .unwrap()
            .session_journal_database_path()
            .expect("a persistent registry has a database");
        Self { root, name: label.to_owned(), database, mux: None }
    }

    fn database(&self) -> PathBuf {
        self.database.clone()
    }

    fn open(mut self) -> Self {
        let registry = WorkspaceRegistry::open(&self.root, &self.name).unwrap();
        let mux = Mux::from_workspace_registry(
            self.name.clone(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        mux.stop_journal_maintenance();
        self.mux = Some(mux);
        self
    }

    fn mux(&self) -> &Arc<Mux> {
        self.mux.as_ref().expect("the session is open")
    }

    fn reader(&self) -> Connection {
        Connection::open(self.database()).unwrap()
    }

    fn rows(&self, table: &str) -> usize {
        self.reader()
            .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row.get::<_, i64>(0))
            .map(|rows| usize::try_from(rows).unwrap())
            .unwrap()
    }

    fn free_pages(&self) -> i64 {
        self.reader().query_row("PRAGMA freelist_count", [], |row| row.get(0)).unwrap()
    }

    fn quarantined(&self, table: &str) -> usize {
        self.reader()
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name LIKE ?1",
                [format!("{table}_quarantined_%")],
                |row| row.get::<_, i64>(0),
            )
            .map(|rows| usize::try_from(rows).unwrap())
            .unwrap()
    }
}

impl Drop for IdleSession {
    fn drop(&mut self) {
        drop(self.mux.take());
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Appends `rows` ledger rows straight through SQL, with no commit and no
/// projection write, so nothing arms a pass.
fn fill_ledger(database: &Path, table: &str, rows: usize, result_bytes: usize) {
    let connection = Connection::open(database).unwrap();
    connection.busy_timeout(Duration::from_secs(5)).unwrap();
    let transaction = connection.unchecked_transaction().unwrap();
    let (columns, values) =
        if table == "projection_mutations" { ("", "") } else { (", committed_revision", ", 1") };
    let result = format!("\"{}\"", "r".repeat(result_bytes));
    for index in 0..rows {
        transaction
            .execute(
                &format!(
                    "INSERT INTO {table}(origin, mutation_id, fingerprint, result_json{columns})
                     VALUES('fill', ?1, 'fingerprint', ?2{values})"
                ),
                params![format!("fill-{index}"), result],
            )
            .unwrap();
    }
    transaction.commit().unwrap();
}

fn capacity(table: &str) -> usize {
    MUTATION_LEDGERS.iter().find(|ledger| ledger.table == table).unwrap().capacity
}

/// A large projection ledger past its bound, more than one pass's batches.
fn session_with_a_large_ledger(label: &str) -> IdleSession {
    let session = IdleSession::new(label);
    fill_ledger(
        &session.database(),
        "projection_mutations",
        capacity("projection_mutations") + 300,
        16 * 1024,
    );
    session.open()
}

/// A drained ledger leaves its rows' pages on the freelist, and only the
/// worker's incremental vacuum returns them, 256 per pass. Passes must keep
/// their interval cadence until the freelist is empty: with the idle pass
/// they would return 1 MiB per hour.
#[test]
fn a_drained_ledger_keeps_passes_coming_until_its_free_pages_are_returned() {
    let session = session_with_a_large_ledger("ledger-freelist");
    let bound = capacity("projection_mutations");
    let mut ledgers = LedgerMaintenance::default();
    let mut passes = Vec::new();
    loop {
        let left = session.mux().run_journal_maintenance(&mut ledgers);
        passes.push((left, session.rows("projection_mutations"), session.free_pages()));
        if !left {
            break;
        }
        assert!(passes.len() < 64, "maintenance never settled: {passes:?}");
    }
    let &(_, rows, free) = passes.last().unwrap();
    assert_eq!(rows, bound, "the ledger drained to its bound: {passes:?}");
    assert_eq!(free, 0, "every free page went back before the passes stopped: {passes:?}");
    for &(left, rows, free) in &passes {
        if rows > bound || free > 0 {
            assert!(left, "a pass that left rows or free pages reported no work: {passes:?}");
        }
    }
    let after_drain: Vec<i64> =
        passes.iter().skip_while(|(_, rows, _)| *rows > bound).map(|(_, _, free)| *free).collect();
    assert!(after_drain.len() >= 2, "the free pages outlast the drain: {passes:?}");
    assert!(
        after_drain.windows(2).all(|pair| pair[1] < pair[0]),
        "the freelist shrinks pass by pass with no commit: {passes:?}"
    );
}

fn append_records(mux: &Mux, count: usize) {
    mux.put_journal_producer(
        &crate::JournalProducerManifest {
            producer_id: "maintenance_work".into(),
            namespace: "plugin.maintenance_work".into(),
            manifest_version: 1,
            max_sensitivity: crate::JournalSensitivity::Metadata,
            permissions: vec!["journal.append.plugin.maintenance_work".into()],
            events: vec![crate::JournalEventSchema {
                kind: "plugin.maintenance_work.event".into(),
                schema_version: 1,
                class: crate::JournalClass::Observation,
                replay: crate::JournalReplayPolicy::Advisory,
                sensitivity: crate::JournalSensitivity::Metadata,
                payload_schema: serde_json::json!({"type":"object"}),
            }],
        },
        "client_test",
        "maintenance_work_producer",
    )
    .unwrap();
    for index in 0..count {
        mux.append_journal_ingress(
            &crate::JournalIngress {
                producer_id: "maintenance_work".into(),
                manifest_version: 1,
                kind: "plugin.maintenance_work.event".into(),
                schema_version: 1,
                occurred_at_ms: None,
                subjects: vec![],
                sensitivity: None,
                payload: serde_json::json!({"index": index}),
                causation_id: None,
                correlation_id: None,
            },
            "client_test",
            &format!("maintenance_work_{index}"),
        )
        .unwrap();
    }
}

fn sealed_through(mux: &Mux) -> u64 {
    mux.workspace_registry
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .journal_segments_end()
        .unwrap()
}

fn latest_checkpoint(mux: &Mux) -> u64 {
    mux.workspace_registry
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .journal_checkpoints()
        .unwrap()
        .into_iter()
        .next()
        .map_or(0, |checkpoint| checkpoint.source_sequence)
}

/// One pass seals at most its batches of segments; the rest of a
/// checkpoint's records are work left, not an idle hour.
#[test]
fn a_seal_past_one_pass_leaves_work_until_the_checkpoint_is_sealed() {
    let session = IdleSession::new("pending-seal").open();
    let mux = session.mux();
    append_records(mux, JOURNAL_MAINTENANCE_SEAL_BATCHES_PER_TICK * 1_024 + 200);
    let mut ledgers = LedgerMaintenance::default();
    assert!(mux.run_journal_maintenance(&mut ledgers), "the first pass leaves segments to seal");
    let checkpoint = latest_checkpoint(mux);
    assert!(checkpoint > 0, "the pass took a checkpoint");
    assert!(sealed_through(mux) < checkpoint, "one pass does not seal the whole checkpoint");
    let mut passes = 1;
    while mux.run_journal_maintenance(&mut ledgers) {
        passes += 1;
        assert!(passes < 16, "sealing never settled");
    }
    assert_eq!(sealed_through(mux), checkpoint, "the passes sealed through the checkpoint");
}

/// An idle session has nothing to drain, seal or return.
#[test]
fn a_pass_with_nothing_to_do_reports_no_work() {
    let session = IdleSession::new("nothing-to-do").open();
    let mut ledgers = LedgerMaintenance::default();
    assert!(!session.mux().run_journal_maintenance(&mut ledgers), "the first pass finds nothing");
    assert!(!session.mux().run_journal_maintenance(&mut ledgers), "nor does the next one");
}

/// A corrupt ledger page fails every commit that writes there, and no
/// failed commit arms a pass: a quarantine a pause stopped is work left,
/// and the next pass sets the ledger aside.
#[test]
fn a_quarantine_a_pause_stopped_is_work_left() {
    let session = IdleSession::new("paused-quarantine");
    let database = session.database();
    fill_ledger(&database, "terminal_mutations", capacity("terminal_mutations") + 100, 200);
    corrupt_first_leaf(&database, "terminal_mutations");
    let session = session.open();
    let mux = session.mux();
    let mut ledgers = LedgerMaintenance::default();
    ledgers.after_scan =
        Some(Box::new(|mux: &Mux| mux.shutting_down.store(true, Ordering::Release)));
    assert!(mux.run_ledger_maintenance(&mut ledgers), "the paused quarantine is work left");
    assert_eq!(
        session.quarantined("terminal_mutations"),
        0,
        "the pause came before the quarantine"
    );

    mux.shutting_down.store(false, Ordering::Release);
    assert!(!mux.run_ledger_maintenance(&mut ledgers), "the next pass sets the ledger aside");
    assert_eq!(session.quarantined("terminal_mutations"), 1);
}

/// Overwrites the first leaf of `table`; the open check reads only the
/// newest rows, which sit on the last leaf.
fn corrupt_first_leaf(database: &Path, table: &str) {
    let (page_size, root_page) = {
        let connection = Connection::open(database).unwrap();
        let busy: i64 =
            connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0)).unwrap();
        assert_eq!(busy, 0, "the main file holds every commit before it is edited");
        let page_size: i64 =
            connection.query_row("PRAGMA page_size", [], |row| row.get(0)).unwrap();
        let root_page: i64 = connection
            .query_row("SELECT rootpage FROM sqlite_master WHERE name = ?1", [table], |row| {
                row.get(0)
            })
            .unwrap();
        (usize::try_from(page_size).unwrap(), usize::try_from(root_page).unwrap())
    };
    let mut bytes = std::fs::read(database).unwrap();
    let root_offset = (root_page - 1) * page_size;
    assert_eq!(bytes[root_offset], 0x05, "the ledger's root is an interior table page");
    let cell = usize::from(u16::from_be_bytes([bytes[root_offset + 12], bytes[root_offset + 13]]));
    let child =
        u32::from_be_bytes(bytes[root_offset + cell..root_offset + cell + 4].try_into().unwrap())
            as usize;
    let child_offset = (child - 1) * page_size;
    bytes[child_offset..child_offset + page_size].fill(0xAB);
    std::fs::write(database, bytes).unwrap();
}

#[test]
fn a_pass_with_work_left_comes_an_interval_later_and_an_idle_one_an_idle_pass_later() {
    let interval = Duration::from_secs(30);
    let idle = Duration::from_secs(60 * 60);
    let busy = JournalMaintenanceControl::with_cadence(interval, idle);
    let before = Instant::now();
    busy.pass_finished(true);
    let due = busy.due().expect("work left arms the next pass");
    assert!(due >= before + interval && due <= Instant::now() + interval + Duration::from_secs(1));

    let quiet = JournalMaintenanceControl::with_cadence(interval, idle);
    let before = Instant::now();
    quiet.pass_finished(false);
    let due = quiet.due().expect("an idle pass is still armed");
    assert!(due >= before + idle && due <= Instant::now() + idle + Duration::from_secs(1));
}

/// The real worker on a large ledger: it keeps its interval cadence while
/// rows or free pages are left and takes the idle pass only once both are
/// gone.
#[test]
fn the_worker_keeps_its_interval_until_the_ledger_and_freelist_are_done() {
    let session = session_with_a_large_ledger("worker-cadence");
    let control = JournalMaintenanceControl::with_cadence(
        Duration::from_millis(20),
        JOURNAL_MAINTENANCE_IDLE_PASS,
    );
    let worker = JournalMaintenance::start(session.mux(), control.clone()).unwrap();
    let idle =
        control.wait_for_due_beyond(JOURNAL_MAINTENANCE_IDLE_PASS / 2, Duration::from_secs(120));
    worker.stop();
    assert!(idle.is_some(), "the worker never reached its idle pass");
    assert_eq!(session.rows("projection_mutations"), capacity("projection_mutations"));
    assert_eq!(session.free_pages(), 0, "the worker went idle with free pages left");
}
