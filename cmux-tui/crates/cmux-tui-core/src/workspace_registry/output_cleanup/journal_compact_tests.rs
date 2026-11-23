//! The journal compaction through the real pipeline (stage, build, swap):
//! a registry whose resource records restate every tab shrinks, replays to
//! the same state at every resource revision, resumes after a stop, rolls
//! back to the same bytes, runs at 1.6 million records, and is not staged
//! without the opt-in.

use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::Connection;
use serde_json::{Value, json};

use super::super::session_journal::{
    JournalAppend, JournalClass, JournalProducer, JournalReplayPolicy, JournalSensitivity,
    JournalSubject, append_journal_record, query_session_journal_after,
};
use super::super::{
    SessionJournalRecord, WorkspaceRegistry, current_resource_revision,
    open_registry_database_read_only, required_meta,
};
use super::stage::{StageControl, StageOutcome, stage_registry, stage_registry_in};
use super::*;

/// Tabs every record of the fixture restates.
const TABS: usize = 128;
/// Resource records sealed before staging, in [`SEALED_BATCHES`] seals.
const SEALED: usize = 400;
const SEALED_BATCHES: usize = 4;
/// Resource records left as live rows.
const LIVE: usize = 200;
const WORKSPACE: &str = "ws_000000000000000000000000000000aa";
/// A subject no change names (the live path takes such ids from the patch).
const PANE: &str = "pane_000000000000000000000000000000bb";
const NOTIFICATION: &str = "notif_000000000000000000000000000000cc";

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-journal-compact-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |time| time.as_nanos())
    ))
}

fn tab_id(tab: usize) -> String {
    format!("tab_{tab:032x}")
}

fn tab_upsert(tab: usize, version: usize) -> Value {
    let id = tab_id(tab);
    json!({
        "kind": "upsert",
        "resource": "tab",
        "id": id,
        "value": {
            "id": id,
            "workspace_id": WORKSPACE,
            "index": tab,
            "title": format!("title {version} of tab {tab}"),
        },
    })
}

/// The fixture's writer: what an old build journaled for each commit.
struct Restating {
    /// Each tab's title version.
    versions: Vec<usize>,
    /// The tab a record deleted, until a later record states it again.
    absent: Option<usize>,
    records: usize,
}

impl Restating {
    fn new() -> Self {
        Self { versions: vec![0; TABS], absent: None, records: 0 }
    }

    /// The changes of the next record: one tab changes, every other live tab
    /// is restated as it is.
    fn next_changes(&mut self) -> Vec<Value> {
        let round = self.records;
        self.records += 1;
        // Some records change nothing at all.
        let changed = round % TABS;
        if round % 5 != 4 && self.absent != Some(changed) {
            self.versions[changed] = round + 1;
        }
        // A deleted tab comes back with the value it had: not a restatement.
        if round % 7 == 5 {
            self.absent = None;
        }
        let mut changes: Vec<Value> = (0..TABS)
            .filter(|tab| self.absent != Some(*tab))
            .map(|tab| tab_upsert(tab, self.versions[tab]))
            .collect();
        // Two upserts of one tab in one record: the second one restates
        // nothing (the first changed the value), so both stay.
        if round.is_multiple_of(11) {
            changes.push(tab_upsert(1, usize::MAX));
            changes.push(tab_upsert(1, self.versions[1]));
        }
        if round % 7 == 3 {
            let deleted = 2 + (round * 3) % (TABS - 2);
            changes.push(json!({"kind": "delete", "resource": "tab", "id": tab_id(deleted)}));
            self.absent = Some(deleted);
        }
        // A resource the fold does not track: restated, and never removed.
        if round % 10 != 9 {
            changes.push(json!({
                "kind": "upsert",
                "resource": "notification",
                "id": NOTIFICATION,
                "value": {"id": NOTIFICATION, "text": "the same every time"},
            }));
        }
        for (index, change) in changes.iter_mut().enumerate() {
            change["sequence"] = json!(index);
        }
        changes
    }

    /// Appends `count` resource records as an old build wrote them: every
    /// change journaled, every id a subject.
    fn append(&mut self, registry: &WorkspaceRegistry, count: usize) {
        let db = registry.connection.get();
        let session = required_meta(&db, "session_public_id").unwrap();
        let tx = db.unchecked_transaction().unwrap();
        for _ in 0..count {
            let round = self.records;
            let changes = self.next_changes();
            let revision = current_resource_revision(&tx).unwrap() + 1;
            let mut subjects = BTreeSet::from([
                JournalSubject { kind: "session".into(), id: session.clone() },
                JournalSubject { kind: "workspace".into(), id: WORKSPACE.into() },
                JournalSubject { kind: "pane".into(), id: PANE.into() },
            ]);
            for change in &changes {
                if change["resource"] == "tab" {
                    subjects.insert(JournalSubject {
                        kind: "tab".into(),
                        id: change["id"].as_str().unwrap().into(),
                    });
                }
            }
            let subjects: Vec<JournalSubject> = subjects.into_iter().collect();
            let key = format!("compact-fixture-{round}");
            append_journal_record(
                &tx,
                &JournalAppend {
                    event_id: &format!("event_resource_{revision:020}"),
                    schema_version: 1,
                    kind: "tab.updated",
                    class: JournalClass::State,
                    replay: JournalReplayPolicy::Required,
                    occurred_at_ms: 1,
                    producer: &JournalProducer {
                        kind: "resource_operation".into(),
                        id: "client_test".into(),
                    },
                    authority: None,
                    causation_id: None,
                    correlation_id: Some(&key),
                    causation_depth: 0,
                    subjects: &subjects,
                    sensitivity: JournalSensitivity::Sensitive,
                    payload: &json!({
                        "idempotency_key": key,
                        "result": {"tab_id": tab_id(round % TABS)},
                        "changes": changes,
                    }),
                    content: None,
                    resource_revision: Some(revision),
                    previous_resource_revision: Some(revision - 1),
                    actor: None,
                },
            )
            .unwrap();
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [revision.to_string()],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
}

/// A registry of [`SEALED`] sealed and [`LIVE`] live restating records, in
/// `root` as session `session`. Returns its database path, closed and with
/// an empty WAL.
fn restating_registry(root: &Path, session: &str) -> PathBuf {
    let mut registry = WorkspaceRegistry::open(root, session).unwrap();
    let mut writer = Restating::new();
    for batch in 0..SEALED_BATCHES {
        writer.append(&registry, SEALED / SEALED_BATCHES);
        registry.seal_journal_for_test(&format!("compact_{batch}"));
    }
    writer.append(&registry, LIVE);
    let db_path = registry.session_journal_database_path().unwrap();
    drop(registry);
    let db = Connection::open(&db_path).unwrap();
    db.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(())).unwrap();
    db_path
}

/// A copy of the closed registry `db_path` in its own directory.
fn copy_registry(db_path: &Path, label: &str) -> PathBuf {
    let dir = temp_root(label);
    std::fs::create_dir_all(&dir).unwrap();
    let copy = dir.join("workspace-registry.sqlite3");
    std::fs::copy(db_path, &copy).unwrap();
    copy
}

/// Runs the cleanup thread's work for `mode` until `next` stops it.
fn stage(db_path: &Path, mode: CleanupMode, next: &dyn Fn() -> bool) -> StageOutcome {
    stage_registry_in(
        db_path,
        &StageControl {
            on_pending: &|| {},
            next_segment: next,
            catch_up: &|| false,
            stopped: Arc::new(|| false),
        },
        mode,
    )
    .unwrap()
}

/// A record's sequence, kind, event id and resource revisions, and the
/// record without its subjects and changes.
type RecordIdentity = (u64, String, String, Option<u64>, Option<u64>, Value);
/// The value every `(resource, id)` has at one point of a replay.
type Stated = BTreeMap<(String, String), Value>;

/// What a replay of the journal reads.
#[derive(Debug, PartialEq)]
struct Replay {
    /// Every record in order.
    records: Vec<RecordIdentity>,
    /// After each resource record: its revision and the stated values.
    states: Vec<(u64, Stated)>,
    /// Upserts whose value the journal already stated.
    restated: usize,
    changes: usize,
}

/// Every journal record up to sequence `through`, through the owner's
/// reader.
fn records(db: &Connection, through: u64) -> Vec<SessionJournalRecord> {
    let mut records = Vec::new();
    let mut cursor = 0;
    loop {
        let page = query_session_journal_after(db, cursor, 1024).unwrap();
        let Some(last) = page.records.last() else { break };
        cursor = last.sequence;
        records.extend(page.records.into_iter().filter(|record| record.sequence <= through));
        if cursor >= through {
            break;
        }
    }
    records
}

/// Folds every resource record's changes from the journal's first record up
/// to sequence `through`.
fn replay(db: &Connection, through: u64) -> Replay {
    let mut replay = Replay { records: Vec::new(), states: Vec::new(), restated: 0, changes: 0 };
    let mut state = Stated::new();
    for record in records(db, through) {
        let mut plain = serde_json::to_value(&record).unwrap();
        plain["subjects"] = Value::Null;
        if record.resource_revision.is_some() {
            plain["payload"]["changes"] = Value::Null;
        }
        replay.records.push((
            record.sequence,
            record.kind.clone(),
            record.event_id.clone(),
            record.resource_revision,
            record.previous_resource_revision,
            plain,
        ));
        let Some(revision) = record.resource_revision else { continue };
        let changes = record.payload["changes"].as_array().expect("a change list");
        for (index, change) in changes.iter().enumerate() {
            replay.changes += 1;
            if let Some(sequence) = change.get("sequence") {
                assert_eq!(sequence, &json!(index), "record {}", record.sequence);
            }
            let (Some(kind), Some(resource), Some(id)) =
                (change["kind"].as_str(), change["resource"].as_str(), change["id"].as_str())
            else {
                continue;
            };
            let key = (resource.to_owned(), id.to_owned());
            match kind {
                "upsert" => {
                    if resource == "tab" && state.get(&key) == Some(&change["value"]) {
                        replay.restated += 1;
                    }
                    state.insert(key, change["value"].clone());
                }
                "delete" => {
                    state.remove(&key);
                }
                _ => {}
            }
        }
        replay.states.push((revision, state.clone()));
    }
    replay
}

/// (inflated journal bytes, used pages, subject index rows).
fn sizes(db: &Connection) -> (i64, i64, i64) {
    db.query_row(
        "SELECT (SELECT COALESCE(SUM(uncompressed_bytes), 0) FROM journal_segments)
                + (SELECT COALESCE(SUM(length(payload_json) + length(subjects_json)), 0)
                   FROM session_journal),
                (SELECT page_count FROM pragma_page_count())
                - (SELECT freelist_count FROM pragma_freelist_count()),
                (SELECT COUNT(*) FROM journal_subject_index)",
        [],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .unwrap()
}

fn journal_head(db: &Connection) -> u64 {
    query_session_journal_after(db, 0, 1).unwrap().head_sequence
}

fn meta(db: &Connection, key: &str) -> Option<String> {
    meta_value(db, key).unwrap()
}

/// The packed journal and its index rows, without the seal times.
fn packed(db_path: &Path) -> Vec<String> {
    let db = open_registry_database_read_only(db_path).unwrap();
    let mut rows = Vec::new();
    for sql in [
        "SELECT start_sequence || ' ' || end_sequence || ' ' || record_count || ' '
                || hex(sha256) FROM journal_segments ORDER BY start_sequence",
        "SELECT sequence || ' ' || kind || ' ' || id FROM journal_subject_index
         ORDER BY sequence, kind, id",
        "SELECT sequence || ' ' || event_id || ' ' || COALESCE(resource_revision, '')
         FROM journal_event_index ORDER BY sequence",
    ] {
        let mut statement = db.prepare(sql).unwrap();
        let read = statement.query_map([], |row| row.get::<_, String>(0)).unwrap();
        rows.extend(read.map(Result::unwrap));
    }
    rows
}

#[test]
fn restating_records_shrink_and_replay_to_the_same_state_at_every_revision() {
    let root = temp_root("shrink");
    let session = "journal-compact";
    let db_path = restating_registry(&root, session);
    let (before, head, sizes_before, first_revision) = {
        let db = open_registry_database_read_only(&db_path).unwrap();
        let head = journal_head(&db);
        let before = replay(&db, head);
        let first = before.states.first().unwrap().0;
        (before, head, sizes(&db), first)
    };
    assert_eq!(before.states.len(), SEALED + LIVE);
    assert!(before.restated > (SEALED + LIVE) * (TABS / 2), "the fixture does not restate");

    assert_eq!(stage(&db_path, CleanupMode::Compact, &|| true), StageOutcome::Built);
    // The next start swaps, with the owner's own check of the new file.
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    assert!(previous_path(&db_path).is_file(), "the registry was not swapped");
    assert!(!staging_path(&db_path).exists());
    // A reader's own connection, beside the owner's.
    let db = open_registry_database_read_only(&db_path).unwrap();
    let after = replay(&db, head);

    // Every record is there with its sequence, kind, event id and revisions,
    // and everything but its subjects and changes is the same.
    assert_eq!(after.records.len(), before.records.len());
    for (kept, original) in after.records.iter().zip(&before.records) {
        assert_eq!(kept, original);
    }
    // The stated value of every resource is the same at every revision.
    assert_eq!(after.states.len(), before.states.len());
    for (kept, original) in after.states.iter().zip(&before.states) {
        assert_eq!(kept.0, original.0);
        assert!(kept.1 == original.1, "the state at revision {} changed", kept.0);
    }
    assert_eq!(after.restated, 0, "a restated upsert stayed");
    assert_eq!(after.changes, before.changes - before.restated);

    // The readers of resource records accept the rewritten ones, the
    // records with no change left among them.
    let mut revision = first_revision - 1;
    let mut empty = 0;
    loop {
        let page = registry.resource_events_after(revision).unwrap();
        let Some(last) = page.batches.last() else { break };
        revision = last.revision;
        empty += page
            .batches
            .iter()
            .filter(|batch| batch.changes.as_array().is_some_and(Vec::is_empty))
            .count();
    }
    assert_eq!(revision, before.states.last().unwrap().0, "the resource events stop early");
    assert!(empty > 0, "no record lost every change");

    // A rewritten record's subjects: the session and the patch's pane stay,
    // and a tab is a subject only where the record still names it.
    let session_id = required_meta(&db, "session_public_id").unwrap();
    let mut narrowed = 0;
    for record in records(&db, head).iter().filter(|record| record.resource_revision.is_some()) {
        let ids: BTreeSet<&str> =
            record.subjects.iter().map(|subject| subject.id.as_str()).collect();
        assert!(ids.contains(session_id.as_str()) && ids.contains(PANE), "{ids:?}");
        let payload = record.payload.to_string();
        for id in &ids {
            assert!(
                *id == session_id || *id == PANE || payload.contains(*id),
                "record {} keeps the subject {id} it no longer names",
                record.sequence
            );
        }
        let indexed: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM journal_subject_index WHERE sequence = ?1",
                [i64::try_from(record.sequence).unwrap()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(usize::try_from(indexed).unwrap(), ids.len(), "record {}", record.sequence);
        narrowed += usize::from(ids.len() < 8);
    }
    assert!(narrowed > SEALED, "few records had their subjects narrowed: {narrowed}");

    // It ran once, under its own marker; the output cleanup's is untouched.
    let done = meta(&db, journal_compact::DONE_META_KEY).expect("the compaction marker");
    assert!(done.contains("\"kept\"") && done.contains("\"removed_changes\""), "{done}");
    assert_eq!(meta(&db, DONE_META_KEY), None, "the compaction marked the output cleanup done");
    assert!(registry.cleanup_done(CleanupMode::Compact).unwrap());

    let sizes_after = sizes(&db);
    println!(
        "journal_compact: inflated journal bytes {} -> {}, used pages {} -> {}, subject index \
         rows {} -> {}",
        sizes_before.0, sizes_after.0, sizes_before.1, sizes_after.1, sizes_before.2, sizes_after.2
    );
    assert!(sizes_before.0 >= sizes_after.0 * 10, "the journal is not 10 times smaller");
    assert!(sizes_before.1 >= sizes_after.1 * 5, "the file is not 5 times smaller");
    assert!(sizes_before.2 >= sizes_after.2 * 10, "the subject index is not 10 times smaller");
    drop(db);
    drop(registry);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_compaction_stopped_in_the_middle_resumes_to_the_same_journal() {
    // SAFETY: nextest runs each test in its own process. Under a shared
    // process the value only makes the packed segments smaller.
    unsafe { std::env::set_var("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_RECORDS", "16") };
    let root = temp_root("resume-fixture");
    let fixture = restating_registry(&root, "journal-compact-resume");
    let whole = copy_registry(&fixture, "resume-whole");
    let stopped = copy_registry(&fixture, "resume-stopped");

    assert_eq!(stage(&whole, CleanupMode::Compact, &|| true), StageOutcome::Built);
    // The owner quits after every third step; each start resumes.
    let mut starts = 0;
    loop {
        let steps = Cell::new(0);
        let outcome = stage(&stopped, CleanupMode::Compact, &|| {
            steps.set(steps.get() + 1);
            steps.get() <= 3
        });
        starts += 1;
        match outcome {
            StageOutcome::Built => break,
            StageOutcome::Stopped => assert!(starts < 10_000, "the compaction never finished"),
            other => panic!("the resumed compaction ended as {other:?}"),
        }
    }
    assert!(starts > 10, "the compaction was stopped only {starts} times");
    for db_path in [&whole, &stopped] {
        assert!(swap_at_open(db_path, &|_| Ok(())), "the registry was not swapped");
    }
    let (whole_rows, stopped_rows) = (packed(&whole), packed(&stopped));
    assert!(whole_rows.len() > SEALED + LIVE);
    assert!(whole_rows == stopped_rows, "the resumed compaction packed another journal");
    let head = journal_head(&open_registry_database_read_only(&whole).unwrap());
    assert!(
        replay(&open_registry_database_read_only(&stopped).unwrap(), head)
            == replay(&open_registry_database_read_only(&whole).unwrap(), head),
        "the resumed compaction replays to another state"
    );
    for path in [&root, whole.parent().unwrap(), stopped.parent().unwrap()] {
        let _ = std::fs::remove_dir_all(path);
    }
}

#[test]
fn a_rollback_of_a_compaction_restores_the_registry_byte_for_byte() {
    let root = temp_root("rollback-fixture");
    let fixture = restating_registry(&root, "journal-compact-rollback");
    let db_path = copy_registry(&fixture, "rollback");
    let original = std::fs::read(&db_path).unwrap();

    assert_eq!(stage(&db_path, CleanupMode::Compact, &|| true), StageOutcome::Built);
    assert!(swap_at_open(&db_path, &|_| Ok(())), "the registry was not swapped");
    assert!(std::fs::read(&db_path).unwrap().len() * 2 < original.len(), "nothing was compacted");
    assert!(rollback_possible(&db_path));

    roll_back_swap(&db_path, &anyhow::anyhow!("test: the compacted registry did not serve"))
        .unwrap();
    assert!(std::fs::read(&db_path).unwrap() == original, "the rollback changed the registry");
    assert!(!previous_path(&db_path).exists());
    for path in [&root, db_path.parent().unwrap()] {
        let _ = std::fs::remove_dir_all(path);
    }
}

/// Without the opt-in the owner runs the output cleanup's mode, which leaves
/// a restating registry alone: nothing is staged and the file is unchanged.
/// Makes the event ids of [`append_output`] distinct.
static OUTPUT_EVENTS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// Appends `count` live `terminal.output` rows the way an older build wrote
/// them, with their index rows.
fn append_output(registry: &WorkspaceRegistry, count: usize) {
    let db = registry.connection.get();
    let terminal = "terminal_00000000000000000000000000000001";
    let tx = db.unchecked_transaction().unwrap();
    for _ in 0..count {
        let event_id = format!(
            "event_terminal_{:032}",
            OUTPUT_EVENTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        tx.execute(
            "INSERT INTO session_journal(
               event_id, schema_version, kind, class, replay_policy, occurred_at_ms,
               committed_at_ms, producer_json, authority_json, causation_depth, subjects_json,
               sensitivity, payload_json, content
             ) VALUES(?6, 1, 'terminal.output', 'observation', 'required', 1, 1, ?1, ?2, 0,
                      ?3, 'sensitive', ?4, ?5)",
            rusqlite::params![
                json!({"kind": "terminal_runtime", "id": terminal}).to_string(),
                json!({
                    "principal_id": "cmux.terminal-runtime",
                    "lease_id": format!("terminal:{terminal}"),
                    "generation": "seed-generation",
                    "role": "terminal.runtime",
                })
                .to_string(),
                json!([{"kind": "terminal", "id": terminal}]).to_string(),
                json!({
                    "format": "cmux.terminal-output.v1",
                    "encoding": "raw",
                    "byte_count": "2",
                    "sha256": "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4",
                    "stream_offset_start": "0",
                    "stream_offset_end": "2",
                })
                .to_string(),
                b"hi".to_vec(),
                event_id,
            ],
        )
        .unwrap();
        let sequence = tx.last_insert_rowid();
        tx.execute(
            "INSERT INTO journal_event_index(event_id, sequence, causation_depth)
             VALUES(?1, ?2, 0)",
            rusqlite::params![event_id, sequence],
        )
        .unwrap();
        tx.execute(
            "INSERT INTO journal_subject_index(sequence, kind, id) VALUES(?1, 'terminal', ?2)",
            rusqlite::params![sequence, terminal],
        )
        .unwrap();
    }
    tx.commit().unwrap();
}

#[test]
fn a_registry_an_output_cleanup_already_pruned_is_compacted() {
    // The output of an older build between the restating records: the output
    // cleanup removes it and leaves gaps in every segment it packs.
    const OUTPUT_PER_BATCH: usize = 300;
    let root = temp_root("pruned");
    let session = "journal-compact-pruned";
    let db_path = {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        let mut writer = Restating::new();
        for batch in 0..SEALED_BATCHES {
            append_output(&registry, OUTPUT_PER_BATCH / 2);
            writer.append(&registry, SEALED / SEALED_BATCHES / 2);
            append_output(&registry, OUTPUT_PER_BATCH / 2);
            writer.append(&registry, SEALED / SEALED_BATCHES / 2);
            registry.seal_journal_for_test(&format!("pruned_{batch}"));
        }
        writer.append(&registry, LIVE);
        let db_path = registry.session_journal_database_path().unwrap();
        drop(registry);
        let db = Connection::open(&db_path).unwrap();
        db.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(())).unwrap();
        db_path
    };
    assert_eq!(stage(&db_path, CleanupMode::Output, &|| true), StageOutcome::Built);
    drop(WorkspaceRegistry::open(&root, session).unwrap());
    let pruned_ranges = |db: &Connection| -> i64 {
        db.query_row("SELECT COUNT(*) FROM journal_pruned_ranges", [], |row| row.get(0)).unwrap()
    };
    let (before, head, ranges_before) = {
        let db = open_registry_database_read_only(&db_path).unwrap();
        assert!(meta(&db, DONE_META_KEY).is_some(), "the output cleanup did not run");
        let head = journal_head(&db);
        (replay(&db, head), head, pruned_ranges(&db))
    };
    assert!(ranges_before >= i64::try_from(SEALED_BATCHES).unwrap(), "{ranges_before} ranges");
    assert_eq!(before.states.len(), SEALED + LIVE);
    assert!(before.restated > 0, "the fixture does not restate");

    assert_eq!(stage(&db_path, CleanupMode::Compact, &|| true), StageOutcome::Built);
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    assert!(registry.cleanup_done(CleanupMode::Compact).unwrap(), "the compaction did not swap");
    let db = open_registry_database_read_only(&db_path).unwrap();
    // Every record that was there is there, the removed sequences stay
    // pruned, and the stated values are the same at every revision.
    let after = replay(&db, head);
    assert!(after.records == before.records, "a record changed or went away");
    assert!(after.states == before.states, "the state at a revision changed");
    assert_eq!(after.restated, 0, "a restated upsert stayed");
    assert!(pruned_ranges(&db) > 0, "the pruned ranges went away");
    drop(db);
    drop(registry);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_restating_registry_is_not_staged_without_the_opt_in() {
    let root = temp_root("default-off-fixture");
    let fixture = restating_registry(&root, "journal-compact-off");
    let db_path = copy_registry(&fixture, "default-off");
    let original = std::fs::read(&db_path).unwrap();
    assert_eq!(journal_compact::scheduled_mode(false, false, false), Some(CleanupMode::Output));
    assert_eq!(journal_compact::scheduled_mode(false, false, true), None);

    let outcome = stage_registry(
        &db_path,
        &StageControl {
            on_pending: &|| panic!("a cleanup is pending without the opt-in"),
            next_segment: &|| true,
            catch_up: &|| false,
            stopped: Arc::new(|| false),
        },
    )
    .unwrap();
    assert!(
        matches!(outcome, StageOutcome::NotNeeded | StageOutcome::Skipped(_)),
        "the output cleanup staged a restating registry: {outcome:?}"
    );
    assert!(!staging_path(&db_path).exists(), "a staging file was made without the opt-in");
    assert!(!swap_at_open(&db_path, &|_| Ok(())), "a start swapped without the opt-in");
    assert!(std::fs::read(&db_path).unwrap() == original, "the registry changed");
    let db = open_registry_database_read_only(&db_path).unwrap();
    assert_eq!(meta(&db, journal_compact::DONE_META_KEY), None);
    drop(db);
    for path in [&root, db_path.parent().unwrap()] {
        let _ = std::fs::remove_dir_all(path);
    }
}

/// The registry this was written for kept 1,573,354 records at its last
/// cleanup. The output cleanup's bounds refuse that many (it would copy
/// most of the journal); the compaction stages and swaps them. The records
/// are tiny, so the test measures the bound and not the rewrite. It stages,
/// packs and reads back 1.6 million rows: about a minute, so it has its own
/// nextest limit (`.config/nextest.toml`).
#[test]
fn a_registry_of_1_6_million_records_is_compacted() {
    const RECORDS: i64 = 1_600_000;
    let root = temp_root("bound");
    let db_path = {
        let registry = WorkspaceRegistry::open(&root, "journal-compact-bound").unwrap();
        let db_path = registry.session_journal_database_path().unwrap();
        drop(registry);
        db_path
    };
    let first = {
        let db = Connection::open(&db_path).unwrap();
        let first = i64::try_from(journal_head(&db)).unwrap() + 1;
        db.execute(
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?1)
             INSERT INTO session_journal(
               event_id, schema_version, kind, class, replay_policy, occurred_at_ms,
               committed_at_ms, producer_json, causation_depth, subjects_json, sensitivity,
               payload_json)
             SELECT 'event_bulk_' || i, 1, 'terminal.title', 'observation', 'advisory', 1, 1,
                    '{\"id\":\"cmux-tui\",\"kind\":\"terminal\"}', 0, '[]', 'metadata', '{}'
             FROM n",
            [RECORDS],
        )
        .unwrap();
        db.execute(
            "INSERT INTO journal_event_index(event_id, sequence, causation_depth)
             SELECT event_id, sequence, 0 FROM session_journal WHERE sequence >= ?1",
            [first],
        )
        .unwrap();
        db.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(())).unwrap();
        first
    };
    let records = u64::try_from(RECORDS).unwrap();
    assert!(
        kept_refusal_in(CleanupMode::Output, records, records).is_some(),
        "the output cleanup's bounds changed"
    );
    assert_eq!(kept_refusal_in(CleanupMode::Compact, records, records), None);

    assert_eq!(stage(&db_path, CleanupMode::Compact, &|| true), StageOutcome::Built);
    assert!(swap_at_open(&db_path, &|_| Ok(())), "the registry was not swapped");
    let db = Connection::open(&db_path).unwrap();
    let (packed, live): (i64, i64) = db
        .query_row(
            "SELECT (SELECT COALESCE(SUM(record_count), 0) FROM journal_segments
                     WHERE end_sequence >= ?1),
                    (SELECT COUNT(*) FROM session_journal)",
            [first],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert!(packed >= RECORDS && live == 0, "{packed} records packed, {live} live");
    let last = query_session_journal_after(&db, journal_head(&db) - 1, 8).unwrap();
    assert_eq!(last.records.len(), 1);
    assert_eq!(last.records[0].event_id, format!("event_bulk_{RECORDS}"));
    assert!(meta(&db, journal_compact::DONE_META_KEY).is_some());
    drop(db);
    let _ = std::fs::remove_dir_all(&root);
}

/// What the proof run measures of a registry file.
struct Measured {
    file_bytes: u64,
    journal_bytes: i64,
    segments: i64,
    sealed_records: i64,
    live_records: i64,
    subject_rows: i64,
}

fn measured(db_path: &Path) -> Measured {
    let db = open_registry_database_read_only(db_path).unwrap();
    let (journal_bytes, segments, sealed_records, live_records, subject_rows) = db
        .query_row(
            "SELECT (SELECT COALESCE(SUM(uncompressed_bytes), 0) FROM journal_segments)
                    + (SELECT COALESCE(SUM(length(payload_json) + length(subjects_json)), 0)
                       FROM session_journal),
                    (SELECT COUNT(*) FROM journal_segments),
                    (SELECT COALESCE(SUM(record_count), 0) FROM journal_segments),
                    (SELECT COUNT(*) FROM session_journal),
                    (SELECT COUNT(*) FROM journal_subject_index)",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
        .unwrap();
    Measured {
        file_bytes: file_len(db_path) + file_len(&sidecar_path(db_path, "-wal")),
        journal_bytes,
        segments,
        sealed_records,
        live_records,
        subject_rows,
    }
}

impl Measured {
    fn line(&self) -> String {
        format!(
            "file {} bytes (with its WAL), inflated journal {} bytes, {} segments, {} sealed \
             records, {} live records, {} subject index rows",
            self.file_bytes,
            self.journal_bytes,
            self.segments,
            self.sealed_records,
            self.live_records,
            self.subject_rows
        )
    }
}

/// A replay of a large journal without holding it: per record its identity,
/// and after each resource record a digest of every stated value (a sum of
/// one hash per `(resource, id, value)`, moved as the values change).
#[derive(PartialEq)]
struct ReplayDigest {
    records: u64,
    /// A running SHA-256 of every record's sequence, kind, event id and
    /// resource revisions.
    identities: [u8; 32],
    /// (resource revision, sequence, state digest) of each resource record.
    states: Vec<(u64, u64, [u64; 4])>,
    restated: u64,
    changes: u64,
}

/// `value` as JSON with every object's keys in order: equal values write
/// the same text.
fn write_canonical(value: &Value, text: &mut String) {
    match value {
        Value::Array(items) => {
            text.push('[');
            for item in items {
                write_canonical(item, text);
                text.push(',');
            }
            text.push(']');
        }
        Value::Object(fields) => {
            let mut fields: Vec<_> = fields.iter().collect();
            fields.sort_by(|a, b| a.0.cmp(b.0));
            text.push('{');
            for (name, field) in fields {
                text.push_str(&Value::String(name.clone()).to_string());
                text.push(':');
                write_canonical(field, text);
                text.push(',');
            }
            text.push('}');
        }
        scalar => text.push_str(&scalar.to_string()),
    }
}

/// A SHA-256 of `value`, the same for equal values. The tests' own: it
/// shares no code with the compaction's hash.
fn canonical_hash(value: &Value) -> [u8; 32] {
    use sha2::{Digest as _, Sha256};
    let mut text = String::new();
    write_canonical(value, &mut text);
    Sha256::digest(text.as_bytes()).into()
}

fn replay_digest(db_path: &Path, through: u64) -> ReplayDigest {
    use sha2::{Digest as _, Sha256};
    let db = open_registry_database_read_only(db_path).unwrap();
    let entry = |key: &(String, String), value: &[u8; 32]| -> [u64; 4] {
        let mut hasher = Sha256::new();
        hasher.update((key.0.len() as u64).to_le_bytes());
        hasher.update(key.0.as_bytes());
        hasher.update((key.1.len() as u64).to_le_bytes());
        hasher.update(key.1.as_bytes());
        hasher.update(value);
        let digest: [u8; 32] = hasher.finalize().into();
        std::array::from_fn(|lane| {
            u64::from_le_bytes(digest[lane * 8..lane * 8 + 8].try_into().unwrap())
        })
    };
    let mut identities = Sha256::new();
    let mut replay = ReplayDigest {
        records: 0,
        identities: [0; 32],
        states: Vec::new(),
        restated: 0,
        changes: 0,
    };
    let mut state: std::collections::HashMap<(String, String), [u8; 32]> =
        std::collections::HashMap::new();
    let mut digest = [0_u64; 4];
    let mut cursor = 0;
    loop {
        let page = query_session_journal_after(&db, cursor, 1024).unwrap();
        let Some(last) = page.records.last() else { break };
        cursor = last.sequence;
        for record in page.records.iter().filter(|record| record.sequence <= through) {
            replay.records += 1;
            identities.update(
                format!(
                    "{}\0{}\0{}\0{:?}\0{:?}\n",
                    record.sequence,
                    record.kind,
                    record.event_id,
                    record.resource_revision,
                    record.previous_resource_revision
                )
                .as_bytes(),
            );
            let Some(revision) = record.resource_revision else { continue };
            let changes = record.payload.get("changes").and_then(Value::as_array);
            for change in changes.into_iter().flatten() {
                replay.changes += 1;
                let (Some(kind), Some(resource), Some(id)) =
                    (change["kind"].as_str(), change["resource"].as_str(), change["id"].as_str())
                else {
                    continue;
                };
                let key = (resource.to_owned(), id.to_owned());
                if !matches!(kind, "upsert" | "delete") {
                    continue;
                }
                let hash = (kind == "upsert").then(|| canonical_hash(&change["value"]));
                let tracked = ["workspace", "screen", "pane", "tab", "terminal", "browser"]
                    .contains(&resource);
                if tracked && hash.is_some() && state.get(&key) == hash.as_ref() {
                    replay.restated += 1;
                }
                if let Some(old) = state.remove(&key) {
                    let old = entry(&key, &old);
                    digest = std::array::from_fn(|lane| digest[lane].wrapping_sub(old[lane]));
                }
                if let Some(hash) = hash {
                    let new = entry(&key, &hash);
                    digest = std::array::from_fn(|lane| digest[lane].wrapping_add(new[lane]));
                    state.insert(key, hash);
                }
            }
            replay.states.push((revision, record.sequence, digest));
        }
        if cursor >= through {
            break;
        }
    }
    replay.identities = identities.finalize().into();
    replay
}

/// The proof on a copy of a real registry (never a live one): set
/// `CMUX_TUI_JOURNAL_COMPACT_PROOF_DB` to the copy's path and run this test
/// alone with `--ignored`. It compacts the copy in place (stage, build,
/// swap), checks that a replay reaches the same state at every resource
/// revision as before, and prints sizes, counts and times. It prints no
/// record content.
#[test]
#[ignore = "needs CMUX_TUI_JOURNAL_COMPACT_PROOF_DB, a copy of a real registry"]
fn compact_the_registry_copy_named_by_the_environment() {
    let Some(db_path) = std::env::var_os("CMUX_TUI_JOURNAL_COMPACT_PROOF_DB").map(PathBuf::from)
    else {
        println!("journal_compact_proof: CMUX_TUI_JOURNAL_COMPACT_PROOF_DB is not set");
        return;
    };
    let started = std::time::Instant::now();
    let before = measured(&db_path);
    println!("journal_compact_proof: before: {}", before.line());
    let head = journal_head(&open_registry_database_read_only(&db_path).unwrap());
    let replay_before = replay_digest(&db_path, head);
    println!(
        "journal_compact_proof: replay before: {} records through sequence {head}, {} resource \
         revisions, {} changes of which {} restate, read in {:.1} s",
        replay_before.records,
        replay_before.states.len(),
        replay_before.changes,
        replay_before.restated,
        started.elapsed().as_secs_f64()
    );

    let staging = staging_path(&db_path);
    let peak = Cell::new(0_u64);
    let staging_started = std::time::Instant::now();
    let outcome = stage(&db_path, CleanupMode::Compact, &|| {
        let bytes = file_len(&staging) + file_len(&sidecar_path(&staging, "-wal"));
        peak.set(peak.get().max(bytes));
        true
    });
    let staged_in = staging_started.elapsed();
    println!(
        "journal_compact_proof: staged and built in {:.1} s: {outcome:?}; peak staging file {} \
         bytes (with its WAL), {} bytes at the end",
        staged_in.as_secs_f64(),
        peak.get(),
        file_len(&staging)
    );
    assert_eq!(outcome, StageOutcome::Built);
    let swap_started = std::time::Instant::now();
    assert!(swap_at_open(&db_path, &|_| Ok(())), "the registry was not swapped");
    println!("journal_compact_proof: swapped in {:.1} s", swap_started.elapsed().as_secs_f64());

    let after = measured(&db_path);
    println!("journal_compact_proof: after: {}", after.line());
    let db = open_registry_database_read_only(&db_path).unwrap();
    println!("journal_compact_proof: marker {:?}", meta(&db, journal_compact::DONE_META_KEY));
    let check: String = db.query_row("PRAGMA quick_check", [], |row| row.get(0)).unwrap();
    assert_eq!(check, "ok");
    drop(db);
    let replay_after = replay_digest(&db_path, head);
    println!(
        "journal_compact_proof: replay after: {} records, {} resource revisions, {} changes of \
         which {} restate",
        replay_after.records,
        replay_after.states.len(),
        replay_after.changes,
        replay_after.restated
    );
    assert_eq!(replay_after.records, replay_before.records, "the record count changed");
    assert!(
        replay_after.identities == replay_before.identities,
        "a record's sequence, kind, event id or revisions changed"
    );
    assert_eq!(replay_after.states.len(), replay_before.states.len());
    let differing = replay_after
        .states
        .iter()
        .zip(&replay_before.states)
        .filter(|(after, before)| after != before)
        .count();
    assert_eq!(differing, 0, "the stated values differ at {differing} resource revisions");
    assert_eq!(replay_after.restated, 0, "a restated upsert stayed");
    println!(
        "journal_compact_proof: EQUAL at all {} resource revisions; total {:.1} s",
        replay_after.states.len(),
        started.elapsed().as_secs_f64()
    );
}
