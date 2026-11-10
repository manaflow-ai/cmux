//! A registry whose journal is one output record and 10,000 puts of two
//! flapping sessions is cleaned: each session keeps its latest put and the
//! put that created it, the personal state reads the same, and puts appended
//! after staging began stay.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::super::stage::{
    BEFORE_LIVE_COUNT, PUT_RECORDS_LIMIT, StageControl, StageOutcome, stage_registry,
};
use super::super::{DONE_META_KEY, V1_DONE_META_KEY, previous_path, staging_path};
use super::*;

/// Flaps the first session only before the seal, so its latest put is in a
/// sealed segment (held while staging); the second before and after it, so
/// its latest is a live row.
const FLAPPING_PUTS: usize = 10_000;
const SEALED_PUTS: usize = 6_000;
const HELD: &str = "session-held";
const LIVE: &str = "session-live";

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-output-cleanup-puts-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |time| time.as_nanos())
    ))
}

fn open(root: &Path) -> Arc<crate::Mux> {
    crate::Mux::open_persistent("session-puts", crate::SurfaceOptions::default(), root).unwrap()
}

/// One `put-session` whose transport flips with `round`, so every put
/// changes the row and journals a fact.
fn put(mux: &crate::Mux, session: &str, round: usize) {
    mux.workspace_registry
        .lock()
        .unwrap()
        .put_session(
            session,
            Some("mac"),
            Some(session),
            &json!({"kind": "ssh", "host": format!("host-{}", round % 2)}),
            None,
            None,
        )
        .unwrap();
}

/// Every session put a reader sees: sequence to (session id, created).
fn puts_read(mux: &crate::Mux) -> BTreeMap<u64, (String, bool)> {
    let mut puts = BTreeMap::new();
    let mut cursor = 0;
    loop {
        let page = mux.session_journal_after(cursor, 1024).unwrap();
        let Some(last) = page.records.last() else { break };
        cursor = last.sequence;
        for record in &page.records {
            if record.kind == SESSION_PUT_KIND {
                let session = record.payload["session"]["session_id"].as_str().unwrap();
                let created = record.payload["created"].as_bool().unwrap();
                puts.insert(record.sequence, (session.to_owned(), created));
            }
        }
    }
    puts
}

fn journal_head(mux: &crate::Mux) -> u64 {
    mux.session_journal_after(0, 1).unwrap().head_sequence
}

/// The background build's step in the staging file of `db_path` (empty
/// before the build).
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

/// Seals the whole journal through a new checkpoint.
fn seal_all(mux: &crate::Mux, label: &str) {
    let checkpoint =
        mux.create_journal_checkpoint("client_test", &format!("puts_checkpoint_{label}")).unwrap();
    let through = checkpoint.checkpoint.source_sequence;
    for batch in 0..64 {
        let sealed = mux
            .seal_journal_segments(through, "client_test", &format!("puts_seal_{label}_{batch}"))
            .unwrap();
        if sealed.through_sequence >= through {
            return;
        }
    }
    panic!("sealing never reached sequence {through}");
}

/// One live `terminal.output` row the way an older build wrote it, with
/// its index rows. The registry is closed.
fn seed_output(db_path: &Path) {
    let db = Connection::open(db_path).unwrap();
    let terminal = "terminal_00000000000000000000000000000001";
    let event_id = "event_terminal_00000000000000000000000000000001";
    db.execute(
        "INSERT INTO session_journal(
           event_id, schema_version, kind, class, replay_policy, occurred_at_ms,
           committed_at_ms, producer_json, authority_json, causation_depth, subjects_json,
           sensitivity, payload_json, content
         ) VALUES(?1, 1, 'terminal.output', 'observation', 'required', 1, 1, ?2, ?3, 0, ?4,
                  'sensitive', ?5, ?6)",
        params![
            event_id,
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
        ],
    )
    .unwrap();
    let sequence = db.last_insert_rowid();
    db.execute(
        "INSERT INTO journal_event_index(event_id, sequence, causation_depth) VALUES(?1, ?2, 0)",
        params![event_id, sequence],
    )
    .unwrap();
    db.execute(
        "INSERT INTO journal_subject_index(sequence, kind, id) VALUES(?1, 'terminal', ?2)",
        params![sequence, terminal],
    )
    .unwrap();
    db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
}

/// The puts a cleanup keeps of `before` (puts read before staging, the
/// journal head then `bound`): per session its created puts and its latest
/// put at or before the bound, and every put after the bound.
fn expected_kept(before: &BTreeMap<u64, (String, bool)>, bound: u64) -> BTreeSet<u64> {
    let mut latest: BTreeMap<&str, u64> = BTreeMap::new();
    let mut kept = BTreeSet::new();
    for (sequence, (session, created)) in before {
        if *sequence > bound || *created {
            kept.insert(*sequence);
        }
        if *sequence <= bound {
            latest.insert(session.as_str(), *sequence);
        }
    }
    kept.extend(latest.values());
    kept
}

#[test]
fn flapping_session_puts_compact_to_the_latest_and_the_created_put() {
    flapping_puts_compact("flapping", SealAt::Never);
}

#[test]
fn puts_sealed_while_the_live_rows_stage_are_not_counted_or_held_twice() {
    // The owner seals the live puts during the live step: the build restarts
    // and Phase A stages them again, now from sealed segments.
    flapping_puts_compact("restart", SealAt::LiveStep);
}

#[test]
fn puts_sealed_before_the_live_count_are_not_held_twice() {
    // The owner seals the live puts between Phase A's staging pass and its
    // live count: Phase A stages the new segments and counts again, after
    // the held puts were released.
    flapping_puts_compact("live-count", SealAt::LiveCount);
}

/// When the owner seals the whole journal while the cleanup runs.
#[derive(Clone, Copy, PartialEq, Eq)]
enum SealAt {
    Never,
    /// Once the build's live step begins (the build restarts).
    LiveStep,
    /// Between Phase A's staging pass and its live count (Phase A stages
    /// again and counts again).
    LiveCount,
}

/// The flapping fixture through Phase A, the build and the swap, the owner
/// sealing the journal at `seal_at`.
fn flapping_puts_compact(label: &str, seal_at: SealAt) {
    let root = temp_root(label);
    let db_path = {
        let mux = open(&root);
        for round in 0..SEALED_PUTS {
            put(&mux, if round % 2 == 0 { HELD } else { LIVE }, round / 2);
        }
        seal_all(&mux, "fixture");
        for round in SEALED_PUTS..FLAPPING_PUTS {
            put(&mux, LIVE, round);
        }
        let db_path = mux.workspace_registry.lock().unwrap().session_journal_database_path();
        mux.shutdown();
        db_path.unwrap()
    };
    seed_output(&db_path);

    // Phase A while an owner serves, as the cleanup's own thread runs it.
    let mux = open(&root);
    let bound = journal_head(&mux);
    if seal_at == SealAt::LiveCount {
        let owner = mux.clone();
        BEFORE_LIVE_COUNT.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move || seal_all(&owner, "before-count")));
        });
    }
    let sealed_during_live = std::cell::Cell::new(false);
    let next_step = || {
        if seal_at == SealAt::LiveStep
            && !sealed_during_live.get()
            && build_step(&db_path) == "live"
        {
            sealed_during_live.set(true);
            seal_all(&mux, "during-live");
        }
        true
    };
    let outcome = stage_registry(
        &db_path,
        0,
        &StageControl {
            on_pending: &|| {},
            next_segment: &next_step,
            catch_up: &|| false,
            stopped: Arc::new(|| false),
        },
    )
    .unwrap();
    assert_eq!(
        outcome,
        StageOutcome::Built,
        "the guards refused a journal of superseded puts and output"
    );
    assert_eq!(sealed_during_live.get(), seal_at == SealAt::LiveStep, "the live step never ran");
    assert!(
        BEFORE_LIVE_COUNT.with(|hook| hook.borrow().is_none()),
        "the seal before the live count never ran"
    );
    // The live tail: puts after staging began are never dropped.
    // The last put before was host-1 (round 9,999); these flip from host-0.
    for round in 0..3 {
        put(&mux, LIVE, round);
    }
    let before = puts_read(&mux);
    assert!(before.len() >= FLAPPING_PUTS + 3, "every put is journaled: {}", before.len());
    let personal_before = serde_json::to_value(mux.personal_snapshot().unwrap()).unwrap();
    mux.shutdown();
    drop(mux);

    // The next start swaps.
    let mux = open(&root);
    assert!(previous_path(&db_path).is_file(), "the registry was not swapped");
    assert!(!staging_path(&db_path).exists());
    // Puts this start made itself (if any) are not the cleanup's.
    let last_before = before.keys().next_back().copied().unwrap();
    let mut after = puts_read(&mux);
    after.retain(|sequence, _| *sequence <= last_before);
    let kept: BTreeSet<u64> = after.keys().copied().collect();
    assert_eq!(kept, expected_kept(&before, bound));
    for session in [HELD, LIVE] {
        let created = after.values().filter(|(id, created)| id == session && *created).count();
        assert_eq!(created, 1, "{session} keeps the put that created it");
    }
    assert_eq!(
        after.values().filter(|(id, _)| id == HELD).count(),
        2,
        "the sealed-only session keeps its created and latest put"
    );
    assert_eq!(
        after.iter().filter(|(sequence, (id, _))| id == LIVE && **sequence > bound).count(),
        3,
        "the puts after the bound stay"
    );
    for (sequence, put) in &after {
        assert_eq!(before.get(sequence), Some(put), "a kept put changed");
    }
    // Reader-visible personal state is the same.
    let personal_after = serde_json::to_value(mux.personal_snapshot().unwrap()).unwrap();
    assert_eq!(personal_after, personal_before);
    let registry = mux.workspace_registry.lock().unwrap();
    let db = registry.connection.get();
    let done: String = db
        .query_row("SELECT value FROM meta WHERE key = ?1", [DONE_META_KEY], |row| row.get(0))
        .unwrap();
    assert!(done.contains("\"kept\""), "{done}");
    let pruned: i64 =
        db.query_row("SELECT COUNT(*) FROM journal_pruned_ranges", [], |row| row.get(0)).unwrap();
    assert!(pruned > 0, "the dropped puts are recorded as pruned ranges");
    // The index rows name only kept records.
    let orphaned: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM journal_subject_index AS subject
             WHERE NOT EXISTS (SELECT 1 FROM journal_event_index AS event
                               WHERE event.sequence = subject.sequence)",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(orphaned, 0);
    drop(db);
    drop(registry);
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_registry_the_v1_cleanup_finished_compacts_its_put_flood_once() {
    // A registry with no stored output that the version 1 cleanup marked
    // done ("not-needed"), whose journal is a put flood.
    let root = temp_root("v1-done");
    PUT_RECORDS_LIMIT.with(|limit| limit.set(1_000));
    let db_path = {
        let mux = open(&root);
        for round in 0..2_000 {
            put(&mux, LIVE, round);
        }
        seal_all(&mux, "fixture");
        for round in 2_000..3_000 {
            put(&mux, LIVE, round);
        }
        let registry = mux.workspace_registry.lock().unwrap();
        registry
            .connection
            .get()
            .execute("INSERT INTO meta(key, value) VALUES(?1, 'not-needed')", [V1_DONE_META_KEY])
            .unwrap();
        let db_path = registry.session_journal_database_path();
        drop(registry);
        mux.shutdown();
        db_path.unwrap()
    };

    let mux = open(&root);
    assert!(
        !mux.workspace_registry.lock().unwrap().output_cleanup_done().unwrap(),
        "a v1-done registry counts as done for the put compaction"
    );
    let outcome = stage_registry(
        &db_path,
        0,
        &StageControl {
            on_pending: &|| {},
            next_segment: &|| true,
            catch_up: &|| false,
            stopped: Arc::new(|| false),
        },
    )
    .unwrap();
    assert_eq!(outcome, StageOutcome::Built, "not staged");
    let before = puts_read(&mux);
    mux.shutdown();
    drop(mux);

    let mux = open(&root);
    assert!(previous_path(&db_path).is_file(), "the registry was not swapped");
    let last_before = before.keys().next_back().copied().unwrap();
    let mut after = puts_read(&mux);
    after.retain(|sequence, _| *sequence <= last_before);
    assert_eq!(after.len(), 2, "the created and the latest put stay: {after:?}");
    assert!(after.values().any(|(_, created)| *created));
    assert!(after.contains_key(&last_before), "the latest put stays");
    // One-time: the swap recorded version 2, so no later start stages again.
    assert!(mux.workspace_registry.lock().unwrap().output_cleanup_done().unwrap());
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

fn record(sequence: u64, session: &str, created: bool) -> StagedRecord {
    let json = json!({
        "sequence": sequence,
        "kind": SESSION_PUT_KIND,
        "payload": {"session": {"session_id": session}, "created": created},
    });
    (sequence, SESSION_PUT_KIND.to_owned(), json.to_string().into_bytes(), None)
}

fn other(sequence: u64) -> StagedRecord {
    let json = json!({"sequence": sequence, "kind": "terminal.title", "payload": {}});
    (sequence, "terminal.title".to_owned(), json.to_string().into_bytes(), None)
}

fn puts(bound: u64, archive_end: u64, latest: &[(&str, u64)]) -> SessionPuts {
    SessionPuts {
        bound,
        archive_end,
        live_kept: 0,
        released: false,
        latest: latest
            .iter()
            .map(|(session, sequence)| ((*session).to_owned(), *sequence))
            .collect(),
        held: HashMap::new(),
    }
}

fn sequences(records: &[StagedRecord]) -> Vec<u64> {
    records.iter().map(|record| record.0).collect()
}

#[test]
fn a_segment_split_holds_the_latest_put_and_drops_the_superseded_ones() {
    // Session a has a live put at 100; session b has none.
    let mut puts = puts(200, 50, &[("a", 100)]);
    let first = puts.split_segment(
        vec![
            record(1, "a", true),
            record(2, "a", false),
            record(3, "b", true),
            other(4),
            record(5, "b", false),
            record(6, "b", false),
        ],
        1,
    );
    // a's created put stays, its other one is dropped (a later live put);
    // b's created put stays and its latest so far is held.
    assert_eq!(sequences(&first.staged), vec![1, 3, 4]);
    assert_eq!((first.held, first.superseded), (1, Vec::new()));
    let second = puts.split_segment(vec![record(7, "b", false), record(8, "c", false)], 7);
    assert_eq!(sequences(&second.staged), Vec::<u64>::new());
    assert_eq!(second.held, 2, "b's and c's latest are held here");
    assert_eq!(second.superseded, vec![6], "b's put in the first segment is superseded");
    // Past the archive end the live record decides: b has no live put, so
    // its put stays; past the bound nothing is dropped.
    let third = puts.split_segment(vec![record(60, "b", false), record(201, "a", false)], 60);
    assert_eq!(sequences(&third.staged), vec![60, 201]);
    assert_eq!(third.held, 0);
}

#[test]
fn a_put_without_a_session_or_created_flag_is_kept() {
    let json = |payload: Value| {
        json!({"sequence": 1, "kind": SESSION_PUT_KIND, "payload": payload}).to_string()
    };
    assert_eq!(
        Put::from_record(SESSION_PUT_KIND, json(json!({"created": false})).as_bytes()),
        None
    );
    assert_eq!(
        Put::from_record(
            SESSION_PUT_KIND,
            json(json!({"session": {"session_id": "s"}})).as_bytes()
        ),
        None
    );
    assert_eq!(
        Put::from_record(
            SESSION_PUT_KIND,
            json(json!({"session": {"session_id": "s"}, "created": false})).as_bytes()
        ),
        Some(Put { session: "s".into(), droppable: true })
    );
    assert_eq!(Put::from_record("personal.session.forgotten", json(json!({})).as_bytes()), None);
    let puts = puts(10, 0, &[("s", 5)]);
    let put = Put { session: "s".into(), droppable: true };
    assert!(puts.drops(4, &put));
    assert!(!puts.drops(5, &put), "the latest put stays");
    assert!(!puts.drops(4, &Put { session: "s".into(), droppable: false }), "a created put stays");
    assert!(!puts.drops(4, &Put { session: "t".into(), droppable: true }));
}
