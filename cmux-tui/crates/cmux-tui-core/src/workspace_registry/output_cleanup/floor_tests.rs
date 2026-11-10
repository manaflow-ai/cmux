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
    // The starts of these tests take the floor that the test stages at.
    START_FLOOR_FOR_TEST.with(|start| start.set(Some(floor)));
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
    let inflated = stage::inflated_segment_records(
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

/// A registry that an earlier swap made (a long-lived one is of this kind):
/// its first segment spans the removed run, it has a pruned range, the done
/// mark and the backup of that swap. A second rebuild at a higher floor reads
/// those packed segments and swaps again.
#[test]
fn a_second_rebuild_at_a_higher_floor_swaps_a_registry_that_a_swap_made() {
    let fixture = fixture("second", 1_100);
    let Fixture { root, db_path, terminal, floor, .. } = &fixture;
    assert_eq!(stage(db_path, *floor, &|| true), StageOutcome::Built);
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert_rebuilt(&fixture);

    // A full start on the first rebuilt registry, and a newer run on it.
    let mux = open(&root.0);
    for index in 0..1_200 {
        hook(&mux, terminal, ["UserPromptSubmit", "Stop"][index % 2]);
    }
    seal_all(&mux, "second_below");
    let second_floor = mux.workspace_registry.lock().unwrap().journal_segments_end().unwrap();
    for _ in 0..10 {
        hook(&mux, terminal, "UserPromptSubmit");
        hook(&mux, terminal, "Stop");
    }
    seal_all(&mux, "second_above");
    hook(&mux, terminal, "UserPromptSubmit");
    assert!(mux.settle_agent_roster_for_test());
    mux.shutdown();
    drop(mux);
    // The second full start: it removes the backup of the first swap.
    let mux = open(&root.0);
    let roster = roster_state(&mux, terminal);
    let previous = previous_path(db_path);
    let deadline = Instant::now() + Duration::from_secs(20);
    while previous.exists() && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(!previous.exists(), "the backup of the first swap stays after a full start");
    mux.shutdown();
    drop(mux);
    assert!(second_floor > *floor);
    let head = journal_head(db_path);
    let kept = records_after(db_path, second_floor, head);
    assert!(kept.len() >= 21, "the records above the second floor: {}", kept.len());

    START_FLOOR_FOR_TEST.with(|start| start.set(Some(second_floor)));
    assert_eq!(
        stage(db_path, second_floor, &|| true),
        StageOutcome::Built,
        "no second rebuild ran at the floor {second_floor}"
    );
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert!(!staging_path(db_path).exists(), "the staging file stays");
    assert!(previous_path(db_path).is_file(), "the first rebuilt file is not kept as the backup");
    assert_eq!(
        records_after(db_path, 0, head),
        kept,
        "a read from sequence 0 returns the records above the second floor"
    );
    assert_eq!(pruned_ranges(db_path), vec![(1, i64::try_from(second_floor).unwrap())]);
    assert_eq!(
        super::super::journal_retention::journal_pruned_through(&read_only(db_path)).unwrap(),
        second_floor
    );
    let mux = open(&root.0);
    assert_eq!(roster_state(&mux, terminal), roster, "the roster after the second rebuild");
    mux.shutdown();
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

/// What retention deleted through is in `meta` (`journal_pruned_through`):
/// the agent history restore after a version change and the `cursor.gap`
/// answer of `session.journal.subscribe` read it. A swap at a floor deletes
/// through its cut, so the new registry must say so, or those readers take
/// it for a registry that lost nothing.
#[test]
fn a_swap_at_a_floor_records_what_it_deleted_through() {
    let fixture = fixture("meta", 1_100);
    let Fixture { root, db_path, floor, .. } = &fixture;
    assert_eq!(stage(db_path, *floor, &|| true), StageOutcome::Built);
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert_rebuilt(&fixture);
    let pruned_through =
        super::super::journal_retention::journal_pruned_through(&read_only(db_path)).unwrap();
    assert_eq!(
        pruned_through, *floor,
        "the swapped registry does not say that the records through the floor are gone"
    );
}

/// The floor can be lower at the next start than at the build: an update
/// whose roster or agent history reducer has another version folds from the
/// first record it finds (`journal_retention::reducer_cursor` is then 0), and
/// so does a hook that is enabled again. A file built at the higher floor
/// left out records that this start reads: the swap must not install it, or
/// each agent whose records are all at or below that floor is gone from the
/// roster the new build folds.
#[test]
fn a_swap_does_not_install_a_file_built_above_the_floor_of_this_start() {
    let fixture = fixture("floor-moved", 1_100);
    let Fixture { root, db_path, floor, head, .. } = &fixture;
    assert_eq!(stage(db_path, *floor, &|| true), StageOutcome::Built);
    // The saved roster is of another version, as after an update: this start
    // reads its floor from the registry, as the product does.
    {
        let writer = Connection::open(db_path).unwrap();
        writer
            .execute(
                "UPDATE meta SET value = json_set(value, '$.version', 0) WHERE key = ?1",
                [format!("journal_reducer.{}", crate::journal_reducers::AGENT_ROSTER_REDUCER_ID)],
            )
            .unwrap();
    }
    START_FLOOR_FOR_TEST.with(|start| start.set(None));
    let start_floor =
        super::super::journal_retention::journal_retention_floor(&read_only(db_path)).unwrap();
    assert!(
        start_floor < *floor,
        "the fixture is wrong: the floor of this start is {start_floor}, the file was built at \
         {floor}"
    );
    let all = records_after(db_path, 0, *head);
    assert!(all.len() as u64 > *head - *floor, "the fixture is wrong: no record below the floor");

    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert!(
        !previous_path(db_path).exists(),
        "the swap installed a file built at floor {floor}; this start keeps the journal after \
         {start_floor}"
    );
    assert_eq!(
        records_after(db_path, 0, *head).len(),
        all.len(),
        "records at or below the floor of the build are gone"
    );
    assert!(
        !staging_path(db_path).exists(),
        "the file built above this start's floor stays, for a later start to install"
    );
    assert!(!failed_path(db_path).exists(), "the cleanup was stopped for this build");
}

/// The swap folds a log left by a killed owner into the registry first. A
/// reader that holds the log (another process that reads the registry) makes
/// that checkpoint busy: the swap waits for a later start. It must not throw
/// away the staged work, and it must not stop the cleanup for this build.
#[test]
fn a_swap_behind_a_reader_of_the_log_keeps_the_staged_work() {
    let fixture = fixture("busy-log", 1_100);
    let Fixture { root, db_path, floor, .. } = &fixture;
    assert_eq!(stage(db_path, *floor, &|| true), StageOutcome::Built);
    // A reader with an open snapshot, then a commit after it: the log holds
    // a frame that no checkpoint can move past the reader.
    let reader = read_only(db_path);
    reader.execute_batch("BEGIN").unwrap();
    let _: i64 = reader.query_row("SELECT COUNT(*) FROM meta", [], |row| row.get(0)).unwrap();
    {
        let writer = Connection::open(db_path).unwrap();
        writer
            .execute(
                "INSERT INTO meta(key, value) VALUES('floor_test_busy_log', '1')
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [],
            )
            .unwrap();
    }
    assert!(!swap_at_open(db_path, &|_| Ok(())), "the swap ran behind a reader of the log");
    assert!(staging_path(db_path).is_file(), "the staged work was thrown away");
    assert!(!failed_path(db_path).exists(), "the cleanup was stopped for this build");
    assert!(!previous_path(db_path).exists());
    reader.execute_batch("ROLLBACK").unwrap();
    drop(reader);

    // With the reader gone the next start swaps. The commit above came after
    // the background build: it is in the copied tables of the swap.
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    assert!(previous_path(db_path).is_file(), "no swap after the reader left");
    assert_eq!(
        count(db_path, "SELECT COUNT(*) FROM meta WHERE key = 'floor_test_busy_log'"),
        1,
        "the swap lost a commit of the log"
    );
}

/// A cleanup that would keep most of the journal is refused, and a memo
/// stops later starts from staging the same journal again. That memo is of
/// a pass that left out nothing below a floor (a long-lived registry: agent
/// and progress records, almost no output). A rebuild at a retention floor
/// leaves the old run out, so the memo must not cover it: or the registry
/// that needs the rebuild most never gets it.
#[test]
fn a_refused_cleanup_without_a_floor_does_not_stop_a_rebuild_at_a_floor() {
    let fixture = fixture("memo", 1_100);
    let Fixture { db_path, floor, head, .. } = &fixture;
    let registry_id: String = read_only(db_path)
        .query_row("SELECT value FROM meta WHERE key = 'registry_id'", [], |row| row.get(0))
        .unwrap();
    // What a pass at floor 0 leaves when it is refused at this head.
    std::fs::write(
        refused_path(db_path),
        format!(
            "format {}\nregistry {registry_id}\nhead {head}\na test: most records are kept\n",
            super::stage::STAGING_FORMAT
        ),
    )
    .unwrap();
    let without_floor = stage(db_path, 0, &|| true);
    assert!(
        matches!(without_floor, StageOutcome::Skipped(_)),
        "the memo no longer covers the pass it was written for: {without_floor:?}"
    );
    assert_eq!(
        stage(db_path, *floor, &|| true),
        StageOutcome::Built,
        "the refusal of a pass without a floor stopped the rebuild at the floor"
    );
}

/// A session for the join with retention: a sealed run of old hook records,
/// then enough newer records and checkpoints that the retention floor
/// passes the old run (the newest 1,024 records and the newest 16
/// checkpoints always stay). Returns the end of the old run. 1,000 records
/// at or below the floor are worth a rebuild in this test.
fn old_run_below_the_retention_floor(mux: &Arc<crate::Mux>) -> u64 {
    // Also for the daemon's cleanup worker, which starts after 60 s: with
    // the product's 100,000 it would find nothing to rebuild at the floor
    // and end, and the next tick would then delete in place.
    mux.set_rebuild_records_limit_for_test(1_000);
    // The worker ticks each 30 s; these tests run the same tick themselves.
    mux.stop_journal_maintenance();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().unwrap().to_string();
    for index in 0..2_100 {
        hook(mux, &terminal, ["SessionStart", "UserPromptSubmit", "Stop"][index % 3]);
    }
    seal_all(mux, "below");
    let old_run = mux.workspace_registry.lock().unwrap().journal_segments_end().unwrap();
    for round in 0..20 {
        for _ in 0..30 {
            hook(mux, &terminal, "UserPromptSubmit");
            hook(mux, &terminal, "Stop");
        }
        mux.create_journal_checkpoint("client_test", &format!("floor_join_checkpoint_{round}"))
            .unwrap();
    }
    seal_all(mux, "above");
    old_run
}

fn retention_floor(mux: &crate::Mux) -> u64 {
    mux.workspace_registry.lock().unwrap().journal_retention_floor().unwrap()
}

/// The join with retention. Deleting a long run in place leaves the file at
/// its size (the freed pages stay in it), so when the sealed segments at or
/// below the floor hold enough records for a rebuild, the maintenance tick
/// deletes none of them: the cleanup worker builds the registry again
/// without them and the next start swaps it in.
#[test]
fn retention_leaves_a_run_worth_a_rebuild_to_the_rebuild() {
    let root = Root::new("join");
    let mux = open(&root.0);
    let old_run = old_run_below_the_retention_floor(&mux);
    // The ticks save the roster and the agent history at the head and keep
    // the newest 16 checkpoints: the floor then passes the old run.
    for _ in 0..16 {
        if retention_floor(&mux) >= old_run {
            break;
        }
        mux.run_journal_maintenance_for_test();
    }
    let floor = retention_floor(&mux);
    assert!(floor >= old_run, "the fixture is wrong: floor {floor}, old run ends at {old_run}");
    for _ in 0..4 {
        mux.run_journal_maintenance_for_test();
    }
    let pruned_through = mux.journal_pruned_through().unwrap();
    mux.shutdown();
    drop(mux);
    assert_eq!(
        pruned_through, 0,
        "retention deleted in place a run of {old_run} records that is worth a rebuild"
    );
}

/// The rebuild is not the only way down: when no rebuild can run in this
/// start (here: an earlier attempt of this build failed, so no cleanup
/// worker starts), the tick deletes the run in place, as it does a run too
/// small for a rebuild.
#[test]
fn retention_deletes_in_place_when_no_rebuild_can_run() {
    let root = Root::new("join-in-place");
    let mux = open(&root.0);
    let db_path = mux.workspace_registry.lock().unwrap().session_journal_database_path().unwrap();
    mux.shutdown();
    drop(mux);
    write_failure_marker(&db_path, "a test: no rebuild in this start");
    let mux = open(&root.0);
    let old_run = old_run_below_the_retention_floor(&mux);
    for _ in 0..24 {
        if mux.journal_pruned_through().unwrap() >= old_run {
            break;
        }
        mux.run_journal_maintenance_for_test();
    }
    let pruned_through = mux.journal_pruned_through().unwrap();
    mux.shutdown();
    drop(mux);
    assert!(
        pruned_through >= old_run,
        "retention deleted through {pruned_through}; the old run ends at {old_run}"
    );
}
