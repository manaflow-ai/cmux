//! The rebuild at a retention floor (`stage_registry(db_path, floor, ..)`):
//! a registry written by the real journal writers (agent hook ingress,
//! checkpoints, sealing) with most of its records below a floor is built
//! again beside itself without them, swapped in at the next open, and read
//! by every reader. The kill tests stop the pass at each step and start
//! again: each restart ends with one valid registry and every record above
//! the floor.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::json;

use super::stage::{PUT_RECORDS_LIMIT, StageControl, StageOutcome, stage_registry};
use super::*;

const SESSION: &str = "floor-rebuild";

struct Root(PathBuf);

impl Root {
    fn new(label: &str) -> Self {
        Self(std::env::temp_dir().join(format!(
            "cmux-floor-rebuild-{label}-{}",
            crate::workspace_registry::new_uuid_v4()
        )))
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn open(root: &Path) -> Arc<crate::Mux> {
    crate::Mux::open_persistent(SESSION, crate::SurfaceOptions::default(), root).unwrap()
}

/// One agent hook through the journal ingress path, as the daemon takes it.
fn hook(mux: &Arc<crate::Mux>, terminal: &str, event: &str) {
    let ingress = crate::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal),
        json!({ "session_id": "floor-session" }),
    )
    .unwrap();
    let key = format!("floor-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// Checkpoints the journal at its head and seals all of it, as journal
/// maintenance does. Returns the sealed head.
fn seal_all(mux: &crate::Mux, label: &str) -> u64 {
    let checkpoint =
        mux.create_journal_checkpoint("client_test", &format!("floor_checkpoint_{label}")).unwrap();
    let through = checkpoint.checkpoint.source_sequence;
    for batch in 0..64 {
        let sealed = mux
            .seal_journal_segments(through, "client_test", &format!("floor_seal_{label}_{batch}"))
            .unwrap();
        if sealed.through_sequence >= through {
            return through;
        }
    }
    panic!("sealing never reached sequence {through}");
}

struct Fixture {
    root: Root,
    db_path: PathBuf,
    terminal: String,
    /// The roster state of the terminal after a restart on the old file.
    roster: Option<String>,
    /// The end of the last sealed segment of the old records.
    floor: u64,
    head: u64,
    /// (sequence, event id, kind) of every record after the floor.
    kept: Vec<(u64, String, String)>,
}

/// The roster state of `terminal` once the start's replay is done.
fn roster_state(mux: &Arc<crate::Mux>, terminal: &str) -> Option<String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    while mux.agent_roster_settling() && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(mux.settle_agent_roster_for_test());
    mux.agent_roster_state_now_for_test(terminal)
}

/// The background build's step in the staging file of `db_path`.
fn build_step(db_path: &Path) -> String {
    let Ok(staging) = Connection::open_with_flags(
        staging_path(db_path),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    ) else {
        return String::new();
    };
    staging
        .query_row("SELECT value FROM output_cleanup_state WHERE key = 'build_step'", [], |row| {
            row.get(0)
        })
        .unwrap_or_default()
}

/// A closed registry: `below` hook records sealed at or below the floor,
/// then a sealed run and live rows above it that end with the agent working.
/// The rebuild's bounds are set for a small fixture: 1,000 records at or
/// below the floor are worth a rebuild, and no free-space margin.
fn fixture(label: &str, below: usize) -> Fixture {
    PUT_RECORDS_LIMIT.with(|limit| limit.set(1_000));
    DISK_MARGIN_FOR_TEST.with(|margin| margin.set(Some(0)));
    let root = Root::new(label);
    let mux = open(&root.0);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap().to_string();
    for index in 0..below {
        hook(&mux, &terminal, ["SessionStart", "UserPromptSubmit", "Stop"][index % 3]);
    }
    seal_all(&mux, "below");
    let floor = mux.workspace_registry.lock().unwrap().journal_segments_end().unwrap();
    hook(&mux, &terminal, "SessionStart");
    for _ in 0..20 {
        hook(&mux, &terminal, "UserPromptSubmit");
        hook(&mux, &terminal, "Stop");
    }
    seal_all(&mux, "above");
    hook(&mux, &terminal, "UserPromptSubmit");
    hook(&mux, &terminal, "Stop");
    hook(&mux, &terminal, "UserPromptSubmit");
    assert!(mux.settle_agent_roster_for_test());
    assert_eq!(mux.agent_roster_state_now_for_test(&terminal).as_deref(), Some("working"));
    let db_path = mux.workspace_registry.lock().unwrap().session_journal_database_path().unwrap();
    mux.shutdown();
    drop(mux);
    // A restart on the old file: what the roster shows after one.
    let mux = open(&root.0);
    let roster = roster_state(&mux, &terminal);
    eprintln!("floor rebuild fixture: roster after a restart: {roster:?}");
    mux.shutdown();
    drop(mux);
    let head = journal_head(&db_path);
    let kept = records_after(&db_path, floor, head);
    assert!(kept.len() >= 44, "the records above the floor: {}", kept.len());
    assert!(floor as usize >= below, "the floor {floor} is above the {below} old records");
    Fixture { root, db_path, terminal, roster, floor, head, kept }
}

fn read_only(db_path: &Path) -> Connection {
    super::super::open_registry_database_read_only(db_path).unwrap()
}

fn journal_head(db_path: &Path) -> u64 {
    super::super::session_journal::query_session_journal_after(&read_only(db_path), 0, 1)
        .unwrap()
        .head_sequence
}

/// (sequence, event id, kind) of every record in `(after, through]`, read
/// the way the owner's readers read the journal.
fn records_after(db_path: &Path, after: u64, through: u64) -> Vec<(u64, String, String)> {
    let connection = read_only(db_path);
    let mut cursor = after;
    let mut records = Vec::new();
    loop {
        let page =
            super::super::session_journal::query_session_journal_after(&connection, cursor, 1024)
                .unwrap();
        let Some(last) = page.records.last() else { break };
        cursor = last.sequence;
        records.extend(
            page.records
                .iter()
                .filter(|record| record.sequence <= through)
                .map(|record| (record.sequence, record.event_id.clone(), record.kind.clone())),
        );
    }
    records
}

fn count(db_path: &Path, sql: &str) -> i64 {
    read_only(db_path).query_row(sql, [], |row| row.get(0)).unwrap()
}

fn pruned_ranges(db_path: &Path) -> Vec<(i64, i64)> {
    let connection = read_only(db_path);
    let mut statement = connection
        .prepare("SELECT start_sequence, end_sequence FROM journal_pruned_ranges ORDER BY 1")
        .unwrap();
    statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

/// Runs the pass on `db_path` to its outcome; `next` is the stop check.
fn stage(db_path: &Path, floor: u64, next: &dyn Fn() -> bool) -> StageOutcome {
    stage_registry(
        db_path,
        floor,
        &StageControl {
            on_pending: &|| {},
            next_segment: next,
            catch_up: &|| false,
            stopped: Arc::new(|| false),
        },
    )
    .unwrap()
}

/// The registry at `db_path` is the rebuilt one: every record above the
/// floor, nothing at or below it, and the removed run as one pruned range.
fn assert_rebuilt(fixture: &Fixture) {
    let Fixture { db_path, floor, head, kept, .. } = fixture;
    assert!(db_path.is_file(), "no registry is left");
    assert!(!staging_path(db_path).exists(), "the staging file stays");
    assert!(previous_path(db_path).is_file(), "the old file is not kept as the backup");
    assert_eq!(
        records_after(db_path, 0, *head),
        *kept,
        "a read from sequence 0 returns the records above the floor"
    );
    assert_eq!(
        pruned_ranges(db_path),
        vec![(1, i64::try_from(*floor).unwrap())],
        "all that is at or below the floor is one pruned range"
    );
}

/// Tables the swap copies as they are, with the same row count afterwards.
const COPIED_TABLES: [&str; 6] = [
    "journal_producers",
    "journal_hooks",
    "journal_hook_deliveries",
    "journal_checkpoints",
    "journal_operation_receipts",
    "journal_content_blobs",
];

#[test]
fn a_rebuild_at_a_floor_leaves_a_small_registry_that_every_reader_reads() {
    let fixture = fixture("readers", 2_100);
    let Fixture { root, db_path, terminal, roster, floor, .. } = &fixture;
    let floor = *floor;
    let before_bytes = file_len(db_path);
    let receipts_above = count(
        db_path,
        &format!("SELECT COUNT(*) FROM journal_ingress_receipts WHERE journal_sequence > {floor}"),
    );
    assert!(receipts_above >= 44);

    // A floor inside the next segment: the cut is the segment end below it.
    let outcome = stage(db_path, floor + 3, &|| true);
    assert_eq!(outcome, StageOutcome::Built, "no rebuild ran for the floor {floor}");
    assert!(staging_path(db_path).is_file(), "the new file is built beside the registry");
    assert!(!previous_path(db_path).exists());
    assert_eq!(file_len(db_path), before_bytes, "the registry file changed before the swap");

    // The next open swaps by rename; the old file is the backup.
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert_rebuilt(&fixture);
    let previous = previous_path(db_path);
    let after_bytes = file_len(db_path);
    eprintln!(
        "floor rebuild: {before_bytes} bytes before, {after_bytes} bytes after, floor {floor}, \
         head {}",
        fixture.head
    );
    assert!(after_bytes < before_bytes, "{after_bytes} bytes after, {before_bytes} before");
    for table in COPIED_TABLES {
        let sql = format!("SELECT COUNT(*) FROM {table}");
        assert_eq!(count(db_path, &sql), count(&previous, &sql), "rows of {table}");
    }
    assert_eq!(count(db_path, "SELECT COUNT(*) FROM journal_ingress_receipts"), receipts_above);
    for (table, column) in [
        ("journal_ingress_receipts", "journal_sequence"),
        ("journal_subject_index", "sequence"),
        ("journal_event_index", "sequence"),
    ] {
        let sql = format!("SELECT COUNT(*) FROM {table} WHERE {column} <= {floor}");
        assert_eq!(count(db_path, &sql), 0, "{table} keeps rows at or below the floor");
        assert!(count(&previous, &sql) > 0, "the backup lost its {table} rows");
    }
    assert_eq!(count(db_path, "SELECT COUNT(*) FROM journal_segment_reducer_records"), 0);
    // A later rebuild reads the segments this one packed: the removed run
    // inside the first one is a pruned range, not damage.
    let (id, start, end, records): (String, i64, i64, i64) = read_only(db_path)
        .query_row(
            "SELECT segment_id, start_sequence, end_sequence, record_count FROM journal_segments
             ORDER BY start_sequence LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(start, 1, "the first packed segment starts at the first sequence");
    let inflated = super::stage::inflated_segment_records(
        &read_only(db_path),
        &id,
        1,
        u64::try_from(end).unwrap(),
        records,
    )
    .unwrap();
    assert_eq!(inflated.first().map(|record| record.0), Some(floor + 1));

    // A full owner start on the new registry: restore, the roster, and a
    // journal read from a cursor inside the removed run.
    let mux = open(&root.0);
    assert_eq!(&roster_state(&mux, terminal), roster, "the roster after the rebuild");
    let page = mux.session_journal_after(floor / 2, 16).unwrap();
    assert_eq!(page.records.first().map(|record| record.sequence), Some(floor + 1));
    assert!(previous.is_file(), "the backup went before a full start was recorded");
    mux.shutdown();
    drop(mux);

    // The rule: the first open after one full start removes the backup.
    let mux = open(&root.0);
    let deadline = Instant::now() + Duration::from_secs(20);
    while previous.exists() && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(!previous.exists(), "the backup stays after a full start on the new registry");
    assert_eq!(&roster_state(&mux, terminal), roster, "the roster without the backup");
    mux.shutdown();
}

#[test]
fn a_rebuild_killed_while_it_stages_leaves_the_registry_and_resumes() {
    let fixture = fixture("kill-stage", 1_100);
    let Fixture { root, db_path, floor, head, .. } = &fixture;
    let all = records_after(db_path, 0, *head);

    let steps = std::cell::Cell::new(0_u32);
    let outcome = stage(db_path, *floor, &|| {
        steps.set(steps.get() + 1);
        steps.get() <= 2
    });
    assert_eq!(outcome, StageOutcome::Stopped, "the pass did not stop inside its staging");
    assert!(staging_path(db_path).is_file());

    // A start beside the half-staged file opens the unchanged registry.
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert!(!previous_path(db_path).exists(), "a half-staged file was swapped in");
    assert_eq!(records_after(db_path, 0, *head), all, "the registry lost records");

    // A second kill, inside the build: the staged work stays again.
    let outcome = stage(db_path, *floor, &|| build_step(db_path) != "pack");
    assert_eq!(outcome, StageOutcome::Stopped, "the pass did not stop inside its build");
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert!(!previous_path(db_path).exists(), "a half-built file was swapped in");
    assert_eq!(records_after(db_path, 0, *head), all, "the registry lost records");

    assert_eq!(stage(db_path, *floor, &|| true), StageOutcome::Built);
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert_rebuilt(&fixture);
}

/// The file states a kill leaves after the swap's transaction committed.
#[derive(Clone, Copy, Debug)]
enum KilledSwap {
    /// Before the old file was linked as the backup.
    Committed,
    /// After the link, before the rename over the registry.
    Linked,
    /// Without hard links: after the registry was renamed aside.
    RenamedAside,
}

#[test]
fn a_swap_killed_at_its_renames_ends_with_one_rebuilt_registry() {
    for state in [KilledSwap::Committed, KilledSwap::Linked, KilledSwap::RenamedAside] {
        let fixture = fixture("kill-swap", 1_100);
        let Fixture { root, db_path, floor, .. } = &fixture;
        assert_eq!(stage(db_path, *floor, &|| true), StageOutcome::Built);
        // The swap without an owner, then its files moved back to where a
        // kill at `state` leaves them: the new registry is the staging file.
        assert!(swap_at_open(db_path, &|_| Ok(())), "{state:?}: no swap");
        let (staging, previous) = (staging_path(db_path), previous_path(db_path));
        std::fs::rename(db_path, &staging).unwrap();
        match state {
            KilledSwap::Committed => std::fs::rename(&previous, db_path).unwrap(),
            KilledSwap::Linked => std::fs::hard_link(&previous, db_path).unwrap(),
            KilledSwap::RenamedAside => {}
        }

        drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
        assert_rebuilt(&fixture);
    }
}

#[test]
fn a_rebuild_without_free_space_is_refused_and_changes_nothing() {
    let fixture = fixture("space", 1_100);
    let Fixture { root, db_path, floor, head, .. } = &fixture;
    let all = records_after(db_path, 0, *head);
    // More than any disk has free beside the new file.
    DISK_MARGIN_FOR_TEST.with(|margin| margin.set(Some(u64::MAX / 2)));
    let outcome = stage(db_path, *floor, &|| true);
    assert!(matches!(outcome, StageOutcome::Refused(_)), "not refused: {outcome:?}");
    assert!(!staging_path(db_path).exists(), "a refused rebuild left a staging file");
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert!(!previous_path(db_path).exists());
    assert_eq!(records_after(db_path, 0, *head), all, "the registry lost records");

    // With the space back, the next start's pass runs.
    DISK_MARGIN_FOR_TEST.with(|margin| margin.set(Some(0)));
    assert_eq!(stage(db_path, *floor, &|| true), StageOutcome::Built);
}
