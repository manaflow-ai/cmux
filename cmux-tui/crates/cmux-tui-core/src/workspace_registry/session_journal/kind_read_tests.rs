//! Test seams for kind-scoped journal reads: raw records and a VM step count.

use serde_json::json;

use super::*;

/// One record a test appends as its writer would.
#[derive(Clone)]
pub(crate) struct TestJournalRecord {
    pub(crate) kind: String,
    pub(crate) producer: JournalProducer,
    pub(crate) subjects: Vec<JournalSubject>,
    pub(crate) payload: Value,
}

impl WorkspaceRegistry {
    /// Test seam: append `records` to the active journal in one transaction,
    /// as their writers would. Returns their sequences.
    pub(crate) fn append_journal_records_for_test(
        &self,
        records: &[TestJournalRecord],
    ) -> Vec<u64> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction().unwrap();
        let sequences = records
            .iter()
            .map(|record| {
                let event_id = format!("event_test_{}", new_uuid_v4().replace('-', ""));
                append_journal_record(
                    &tx,
                    &JournalAppend {
                        event_id: &event_id,
                        schema_version: 1,
                        kind: &record.kind,
                        class: JournalClass::Observation,
                        replay: JournalReplayPolicy::Advisory,
                        occurred_at_ms: 1,
                        producer: &record.producer,
                        authority: None,
                        causation_id: None,
                        correlation_id: None,
                        causation_depth: 0,
                        subjects: &record.subjects,
                        sensitivity: JournalSensitivity::Metadata,
                        payload: &record.payload,
                        content: None,
                        resource_revision: None,
                        previous_resource_revision: None,
                        actor: None,
                    },
                )
                .unwrap()
            })
            .collect();
        tx.commit().unwrap();
        sequences
    }

    /// SQLite VM steps `run` takes on the registry connection, counted in
    /// batches of 16 (deterministic, unlike wall time; see open_cost_tests.rs).
    /// `run` takes the connection itself, through the registry.
    pub(crate) fn vm_steps_for_test(&self, run: impl FnOnce()) -> u64 {
        let steps = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counter = Arc::clone(&steps);
        self.connection
            .get()
            .progress_handler(
                16,
                Some(move || {
                    counter.fetch_add(16, std::sync::atomic::Ordering::Relaxed);
                    false
                }),
            )
            .unwrap();
        run();
        self.connection.get().progress_handler(0, None::<fn() -> bool>).unwrap();
        steps.load(std::sync::atomic::Ordering::Relaxed)
    }
}

impl WorkspaceRegistry {
    /// Test seam: checkpoint the journal at its head and seal all of it,
    /// a bounded segment batch per call, as the maintenance worker does.
    pub(crate) fn seal_journal_for_test(&mut self, key: &str) {
        let head = self.session_journal_head().unwrap();
        self.create_journal_checkpoint(
            head,
            1,
            &json!({
                "session_snapshot":{"cursor":{"revision":"1"}},
                "journal_extensions":{"producers":[],"hooks":[]},
            }),
            &[],
            "client_test",
            &format!("{key}_checkpoint"),
        )
        .unwrap();
        let reader =
            SessionJournalReader::open(&self.session_journal_database_path().unwrap()).unwrap();
        for batch in 0.. {
            if self.journal_segments_end().unwrap() >= head {
                break;
            }
            let seal_key = format!("{key}_seal_{batch}");
            let plan =
                match self.begin_journal_segment_seal(head, "client_test", &seal_key).unwrap() {
                    JournalSegmentSealStart::Prepare(plan) => plan,
                    JournalSegmentSealStart::Replay(_) => panic!("a fresh seal key replayed"),
                };
            let prepared = plan.prepare(&reader).unwrap();
            self.commit_journal_segment_seal(prepared, "client_test", &seal_key)
                .unwrap()
                .expect("the segment boundary held");
        }
    }
}

/// Agent records in the sealed-history cost test.
const SEALED_AGENT_RECORDS: usize = 16;

fn sealed_agent_record(index: usize) -> TestJournalRecord {
    TestJournalRecord {
        kind: "agent.turn.started".into(),
        producer: JournalProducer {
            kind: "agent_adapter".into(),
            id: crate::AGENT_HOOK_PRODUCER_ID.into(),
        },
        subjects: vec![JournalSubject {
            kind: "terminal".into(),
            id: format!("term_{index:032x}"),
        }],
        payload: json!({"turn": index}),
    }
}

/// A peer session's `personal.session.put` with a padded payload: most of a
/// long-lived journal, and nearly all of its bytes.
fn sealed_session_put(index: usize) -> TestJournalRecord {
    let session = format!("sess_{:032x}", index % 64);
    TestJournalRecord {
        kind: "personal.session.put".into(),
        producer: JournalProducer { kind: "presentation".into(), id: "cmux-tui".into() },
        subjects: vec![JournalSubject { kind: "session".into(), id: session.clone() }],
        payload: json!({
            "session": {"session_id": session, "last_seen_ms": index, "pad": "x".repeat(1024)},
            "personal_revision": index,
        }),
    }
}

/// The agent records spread evenly through `puts` session puts.
fn sealed_history(puts: usize) -> Vec<TestJournalRecord> {
    let stride = puts / SEALED_AGENT_RECORDS + 1;
    let mut agents = (0..SEALED_AGENT_RECORDS).map(sealed_agent_record);
    let mut records = Vec::with_capacity(puts + SEALED_AGENT_RECORDS);
    for index in 0..puts {
        if index % stride == 0
            && let Some(agent) = agents.next()
        {
            records.push(agent);
        }
        records.push(sealed_session_put(index));
    }
    records.extend(agents);
    records
}

/// Every record of the folded kinds in `(0, head]`, a page of 512 at a time.
fn read_agent_records(registry: &WorkspaceRegistry) -> Vec<SessionJournalRecord> {
    let head = registry.session_journal_head().unwrap();
    let (mut cursor, mut records) = (0, Vec::new());
    while cursor < head {
        let (page, reached) = registry
            .session_journal_kinds_after(
                cursor,
                head,
                crate::journal_reducers::AgentRoster::folds_kind,
                512,
            )
            .unwrap();
        assert!(reached > cursor, "each page makes progress");
        records.extend(page);
        cursor = reached;
    }
    records
}

/// Replace the content of every sealed segment: a read that decodes one
/// fails, so a read that succeeds decoded none.
fn destroy_sealed_segments(registry: &WorkspaceRegistry) {
    let connection = Connection::open(registry.session_journal_database_path().unwrap()).unwrap();
    connection.execute_batch("DROP TRIGGER IF EXISTS journal_segments_reject_update;").unwrap();
    connection.execute("UPDATE journal_segments SET content = x'00112233'", []).unwrap();
}

/// What a kind-scoped read of sealed history cost on a journal of `puts`
/// session puts: VM steps, and whether it decoded a segment.
struct SealedReadCost {
    steps: u64,
    segments: usize,
}

fn sealed_read_cost(puts: usize) -> SealedReadCost {
    let root = std::env::temp_dir()
        .join(format!("cmux-sealed-reducer-records-{}", new_uuid_v4().replace('-', "")));
    let mut registry = WorkspaceRegistry::open(&root, "sealed-reducer-records").unwrap();
    registry.append_journal_records_for_test(&sealed_history(puts));
    registry.seal_journal_for_test("sealed_cost");
    let segments = registry.journal_segments().unwrap().len();
    destroy_sealed_segments(&registry);
    let mut read = Vec::new();
    let steps = registry.vm_steps_for_test(|| read = read_agent_records(&registry));
    let turns = read.iter().filter(|record| record.kind == "agent.turn.started").count();
    assert_eq!(turns, SEALED_AGENT_RECORDS, "every sealed agent record is read");
    drop(registry);
    fs::remove_dir_all(root).unwrap();
    SealedReadCost { steps, segments }
}

/// A kind-scoped read of sealed history costs the records of the kinds it
/// reads, not the segments around them. The 2026-11-09 measurement: after a
/// roster version bump, an 8.4 GB registry (1.59M rows, 96% 6 KB session
/// puts, 64k agent records, 769 sealed segments) took 14.0 s to start, 13.9 s
/// of it in the roster replay, because `agent.*` records sit in every sealed
/// segment and the read inflated and parsed each one. Here every segment's
/// content is destroyed after sealing, so the read succeeds only if it
/// decodes none; and 10x the session puts adds less than one VM step each.
#[test]
fn sealed_kind_read_cost_stays_flat_as_session_puts_grow() {
    let sizes = [2_000, 20_000];
    let costs = sizes.map(sealed_read_cost);
    let table = sizes
        .iter()
        .zip(&costs)
        .map(|(puts, cost)| {
            format!(
                "{puts} session puts in {} segments + {SEALED_AGENT_RECORDS} agent records: {} VM steps",
                cost.segments, cost.steps
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    assert!(costs[1].segments > costs[0].segments, "more puts seal more segments:\n{table}");
    let per_put = costs[1].steps.saturating_sub(costs[0].steps) / (sizes[1] - sizes[0]) as u64;
    assert!(per_put < 1, "a sealed kind read costs {per_put} VM steps per session put:\n{table}");
}

/// Run the reducer record backfill on `registry` until it is done or has
/// decoded `limit` segments; returns how many it decoded.
fn run_reducer_record_backfill(registry: &WorkspaceRegistry, limit: usize) -> usize {
    use super::reducer_records::ReducerRecordBackfillStep;
    let reader =
        SessionJournalReader::open(&registry.session_journal_database_path().unwrap()).unwrap();
    let mut decoded = 0;
    while decoded < limit {
        match registry.plan_reducer_record_backfill(4).unwrap() {
            ReducerRecordBackfillStep::Done => break,
            ReducerRecordBackfillStep::Passed => {}
            ReducerRecordBackfillStep::Decode(plan) => {
                let prepared = plan.prepare(&reader).unwrap();
                assert!(registry.commit_reducer_record_backfill(prepared).unwrap());
                decoded += 1;
            }
        }
    }
    decoded
}

fn kept_reducer_records(registry: &WorkspaceRegistry) -> i64 {
    registry
        .connection
        .get()
        .query_row("SELECT COUNT(*) FROM journal_segment_reducer_records", [], |row| row.get(0))
        .unwrap()
}

/// Segments sealed before sealing kept reducer records (simulated by
/// deleting the rows) are read by decoding them, and the backfill fills
/// them a segment per step, resuming after a reopen where it stopped. It
/// decodes each segment that holds a folded kind once and passes over the
/// rest; afterwards the read decodes none.
#[test]
fn reducer_record_backfill_fills_older_segments_and_resumes() {
    let root = std::env::temp_dir()
        .join(format!("cmux-reducer-record-backfill-{}", new_uuid_v4().replace('-', "")));
    let session = "reducer-record-backfill";
    let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
    registry
        .append_journal_records_for_test(&(0..3_000).map(sealed_session_put).collect::<Vec<_>>());
    registry.append_journal_records_for_test(&sealed_history(6_000));
    registry.seal_journal_for_test("backfill");
    let sealed = kept_reducer_records(&registry);
    assert_eq!(sealed, SEALED_AGENT_RECORDS as i64, "sealing keeps every agent record");
    let with_agents = registry
        .connection
        .get()
        .query_row(
            "SELECT COUNT(DISTINCT segment_id) FROM journal_segment_reducer_records",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    let segments = registry.journal_segments().unwrap().len();
    assert!(segments as i64 > with_agents, "some segments hold no agent record");
    registry.connection.get().execute("DELETE FROM journal_segment_reducer_records", []).unwrap();

    // Without kept records the read decodes the segments, and still reads
    // every agent record.
    assert_eq!(read_agent_records(&registry).len(), SEALED_AGENT_RECORDS);

    assert_eq!(run_reducer_record_backfill(&registry, 1), 1);
    drop(registry);
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let rest = run_reducer_record_backfill(&registry, usize::MAX);
    assert_eq!(1 + rest, with_agents as usize, "each segment with an agent record decodes once");
    assert_eq!(kept_reducer_records(&registry), sealed);
    assert_eq!(run_reducer_record_backfill(&registry, usize::MAX), 0, "a done backfill stays done");

    destroy_sealed_segments(&registry);
    assert_eq!(read_agent_records(&registry).len(), SEALED_AGENT_RECORDS);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// A backfill cursor whose segment is gone (an output cleanup rebuilt the
/// segments under new ids, and an older build's cleanup copied the cursor
/// across) starts the backfill over instead of skipping the new segments.
#[test]
fn reducer_record_backfill_starts_over_when_its_segment_is_gone() {
    let root = std::env::temp_dir()
        .join(format!("cmux-reducer-record-restart-{}", new_uuid_v4().replace('-', "")));
    let mut registry = WorkspaceRegistry::open(&root, "reducer-record-restart").unwrap();
    registry.append_journal_records_for_test(&sealed_history(3_000));
    registry.seal_journal_for_test("restart");
    registry.connection.get().execute("DELETE FROM journal_segment_reducer_records", []).unwrap();
    let first = run_reducer_record_backfill(&registry, usize::MAX);
    assert!(first > 0);
    // A cursor naming a segment id that no longer exists.
    registry
        .connection
        .get()
        .execute(
            "UPDATE meta SET value = json_set(value, '$.segment_id', 'segment_gone')
             WHERE key = 'journal_segment_reducer_records_backfill'",
            [],
        )
        .unwrap();
    registry.connection.get().execute("DELETE FROM journal_segment_reducer_records", []).unwrap();
    assert_eq!(run_reducer_record_backfill(&registry, usize::MAX), first);
    assert_eq!(kept_reducer_records(&registry), SEALED_AGENT_RECORDS as i64);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// A downgrade and upgrade around an output cleanup: an older build's swap
/// copies the backfill cursor and the kept records across and repacks the
/// segments, and a repacked segment can keep its id (ids hash the range and
/// content). So the cursor's segment can survive while the earlier segments
/// were rewritten without kept records. Emulated here after a finished
/// backfill: every segment but the cursor's loses its kept records, and the
/// cleanup's done marker changes, as that swap leaves them. The cursor alone
/// would skip them forever; the changed marker starts the backfill over.
#[test]
fn reducer_record_backfill_starts_over_after_an_older_builds_output_cleanup() {
    let root = std::env::temp_dir()
        .join(format!("cmux-reducer-record-downgrade-{}", new_uuid_v4().replace('-', "")));
    let mut registry = WorkspaceRegistry::open(&root, "reducer-record-downgrade").unwrap();
    registry.append_journal_records_for_test(&sealed_history(6_000));
    registry.seal_journal_for_test("downgrade");
    registry.connection.get().execute("DELETE FROM journal_segment_reducer_records", []).unwrap();
    assert!(run_reducer_record_backfill(&registry, usize::MAX) > 1);
    assert_eq!(kept_reducer_records(&registry), SEALED_AGENT_RECORDS as i64);
    let cursor_segment: String = registry
        .connection
        .get()
        .query_row(
            "SELECT json_extract(value, '$.segment_id') FROM meta
             WHERE key = 'journal_segment_reducer_records_backfill'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    registry
        .connection
        .get()
        .execute(
            "DELETE FROM journal_segment_reducer_records WHERE segment_id != ?1",
            [&cursor_segment],
        )
        .unwrap();
    assert!(kept_reducer_records(&registry) < SEALED_AGENT_RECORDS as i64);
    assert_eq!(run_reducer_record_backfill(&registry, usize::MAX), 0, "no cleanup ran yet");

    registry
        .connection
        .get()
        .execute(
            "INSERT INTO meta(key, value) VALUES('output_cleanup_v1', '{\"at_ms\":\"1\",\"kept\":\"1\"}')
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [],
        )
        .unwrap();
    assert!(
        run_reducer_record_backfill(&registry, usize::MAX) > 0,
        "the backfill did not start over"
    );
    assert_eq!(kept_reducer_records(&registry), SEALED_AGENT_RECORDS as i64);
    assert_eq!(run_reducer_record_backfill(&registry, usize::MAX), 0, "a done backfill stays done");
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// A legacy kind backfill stopped partway (its marker still `0`) can leave
/// a segment's kind map without some of its kinds: here, every segment's
/// `agent.*` kinds. The reducer record backfill does not trust such a map
/// to pass a segment over: it decodes the segments that have no kept
/// records, so the records are there once the kind backfill finishes and
/// the map names the agent kinds again. A cursor written before this rule
/// (it may have passed segments over on such a map) starts over.
#[test]
fn reducer_record_backfill_does_not_trust_a_partly_filled_kind_map() {
    let root = std::env::temp_dir()
        .join(format!("cmux-reducer-record-partial-map-{}", new_uuid_v4().replace('-', "")));
    let mut registry = WorkspaceRegistry::open(&root, "reducer-record-partial-map").unwrap();
    registry.append_journal_records_for_test(&sealed_history(6_000));
    registry.seal_journal_for_test("partial_map");
    {
        let db = registry.connection.get();
        db.execute("DELETE FROM journal_segment_reducer_records", []).unwrap();
        db.execute("DELETE FROM journal_segment_kinds WHERE kind LIKE 'agent.%'", []).unwrap();
        db.execute(
            "INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill', '0')
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [],
        )
        .unwrap();
    }
    run_reducer_record_backfill(&registry, usize::MAX);
    // A read finishes the kind backfill: the map names the agent kinds.
    assert_eq!(read_agent_records(&registry).len(), SEALED_AGENT_RECORDS);
    run_reducer_record_backfill(&registry, usize::MAX);
    assert_eq!(
        kept_reducer_records(&registry),
        SEALED_AGENT_RECORDS as i64,
        "the backfill passed over segments on a partly filled kind map"
    );

    // A cursor of a build before the rule, at the last segment.
    {
        let db = registry.connection.get();
        db.execute(
            "UPDATE meta SET value = json_remove(value, '$.kind_map')
             WHERE key = 'journal_segment_reducer_records_backfill'",
            [],
        )
        .unwrap();
        db.execute("DELETE FROM journal_segment_reducer_records", []).unwrap();
    }
    assert!(run_reducer_record_backfill(&registry, usize::MAX) > 0, "an older cursor starts over");
    assert_eq!(kept_reducer_records(&registry), SEALED_AGENT_RECORDS as i64);
    assert_eq!(run_reducer_record_backfill(&registry, usize::MAX), 0, "a done backfill stays done");
    destroy_sealed_segments(&registry);
    assert_eq!(read_agent_records(&registry).len(), SEALED_AGENT_RECORDS);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// A `terminal.output` record: what the output cleanup drops.
fn sealed_terminal_output(index: usize) -> TestJournalRecord {
    TestJournalRecord {
        kind: "terminal.output".into(),
        producer: JournalProducer { kind: "terminal".into(), id: "cmux-tui".into() },
        subjects: vec![JournalSubject {
            kind: "terminal".into(),
            id: format!("term_{:032x}", index % 8),
        }],
        payload: {
            use base64::Engine as _;
            use sha2::Digest as _;
            let bytes = format!("output {index} {}\r\n", "x".repeat(256)).into_bytes();
            let start = index * 512;
            let digest =
                Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect::<String>();
            json!({
                "format": "cmux.terminal-output.v1",
                "encoding": "base64",
                "data": base64::engine::general_purpose::STANDARD.encode(&bytes),
                "byte_count": bytes.len().to_string(),
                "stream_offset_start": start.to_string(),
                "stream_offset_end": (start + bytes.len()).to_string(),
                "sha256": digest,
            })
        },
    }
}

/// What a kind-scoped read returns, without the commit time.
fn agent_read(registry: &WorkspaceRegistry) -> Vec<(u64, String, String, Value)> {
    read_agent_records(registry)
        .into_iter()
        .map(|record| (record.sequence, record.event_id, record.kind, record.payload))
        .collect()
}

/// The output cleanup swap rebuilds the sealed segments (`pack_segments`)
/// under new ids, so the kept reducer records of the old segments must not
/// survive it: the swap empties their table and forgets the backfill
/// cursor, and the backfill fills the new segments. Here a registry whose
/// sealed journal is mostly terminal output, with the reducer records kept
/// and the backfill done, is staged and swapped at the next open. Afterwards
/// the table is empty and the cursor gone; the kind-scoped read decodes the
/// new segments and returns the same agent records; and the backfill keeps
/// every one of them again, after which the read decodes no segment.
#[test]
fn an_output_cleanup_swap_drops_the_kept_reducer_records_and_the_backfill_rebuilds_them() {
    use crate::workspace_registry::output_cleanup::{StageControl, StageOutcome, stage_registry};
    let root = std::env::temp_dir()
        .join(format!("cmux-reducer-record-swap-{}", new_uuid_v4().replace('-', "")));
    let session = "reducer-record-swap";
    let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
    let mut records = Vec::new();
    for (index, record) in sealed_history(400).into_iter().enumerate() {
        records.push(record);
        records.extend((0..4).map(|output| sealed_terminal_output(index * 4 + output)));
    }
    registry.append_journal_records_for_test(&records);
    registry.seal_journal_for_test("swap");
    assert_eq!(kept_reducer_records(&registry), SEALED_AGENT_RECORDS as i64);
    assert_eq!(run_reducer_record_backfill(&registry, usize::MAX), 0, "sealing kept every record");
    let cursor_rows = |registry: &WorkspaceRegistry| -> i64 {
        registry
            .connection
            .get()
            .query_row(
                "SELECT COUNT(*) FROM meta WHERE key = 'journal_segment_reducer_records_backfill'",
                [],
                |row| row.get(0),
            )
            .unwrap()
    };
    assert_eq!(cursor_rows(&registry), 1, "the done backfill wrote its cursor");
    let before = agent_read(&registry);
    assert_eq!(before.len(), SEALED_AGENT_RECORDS);
    let old_segments: Vec<String> = registry
        .journal_segments()
        .unwrap()
        .into_iter()
        .map(|segment| segment.segment_id)
        .collect();
    let db_path = registry.session_journal_database_path().unwrap();
    drop(registry);

    let outcome = stage_registry(
        &db_path,
        &StageControl {
            on_pending: &|| {},
            next_segment: &|| true,
            catch_up: &|| false,
            stopped: Arc::new(|| false),
        },
    )
    .unwrap();
    assert!(matches!(outcome, StageOutcome::Built), "not built: {outcome:?}");
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    assert!(
        output_cleanup::previous_path(&db_path).is_file(),
        "the open did not swap the registry"
    );
    let new_segments: Vec<String> = registry
        .journal_segments()
        .unwrap()
        .into_iter()
        .map(|segment| segment.segment_id)
        .collect();
    assert_ne!(new_segments, old_segments, "the swap packed new segments");

    assert_eq!(kept_reducer_records(&registry), 0, "kept records of the old segments survived");
    assert_eq!(cursor_rows(&registry), 0, "the backfill cursor survived the swap");
    assert_eq!(agent_read(&registry), before, "the read after the swap decodes the segments");

    assert!(run_reducer_record_backfill(&registry, usize::MAX) > 0);
    assert_eq!(kept_reducer_records(&registry), SEALED_AGENT_RECORDS as i64);
    destroy_sealed_segments(&registry);
    assert_eq!(agent_read(&registry), before, "the read decodes no segment after the backfill");
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// A registry with `count` active agent records and a reader on it; the
/// reader's next read meets a seal of all of them between its sealed part
/// and its active rows, as a concurrent maintenance seal would.
fn reader_raced_by_a_seal(label: &str, count: usize) -> (PathBuf, SessionJournalReader) {
    let root = std::env::temp_dir()
        .join(format!("cmux-journal-read-race-{label}-{}", new_uuid_v4().replace('-', "")));
    let mut registry = WorkspaceRegistry::open(&root, label).unwrap();
    registry
        .append_journal_records_for_test(&(0..count).map(sealed_agent_record).collect::<Vec<_>>());
    let reader =
        SessionJournalReader::open(&registry.session_journal_database_path().unwrap()).unwrap();
    let key = label.to_string();
    BETWEEN_JOURNAL_READS_FOR_TEST.with(|slot| {
        *slot.borrow_mut() = Some(Box::new(move || {
            registry.seal_journal_for_test(&key);
            assert!(registry.journal_segments_end().unwrap() > 0, "the hook sealed the journal");
        }));
    });
    (root, reader)
}

/// A page reads from one snapshot: a seal that commits between the page's
/// sealed read and its active read (moving records from the active table
/// into a segment) must not show as a gap.
#[test]
fn a_journal_page_read_during_a_seal_sees_every_record() {
    let (root, reader) = reader_raced_by_a_seal("after", 8);
    let page = reader.after(0, 64);
    let ran = BETWEEN_JOURNAL_READS_FOR_TEST.with(|slot| slot.borrow().is_none());
    assert!(ran, "the seal ran inside the read");
    let page = page.expect("a seal during the read is not a gap");
    assert_eq!(
        page.records.iter().map(|record| record.sequence).collect::<Vec<_>>(),
        (1..=8).collect::<Vec<_>>()
    );
    drop(reader);
    fs::remove_dir_all(root).unwrap();
}

/// The same for a subject-filtered page, which reads the records it found
/// in the subject index from the segments, then from the active table.
#[test]
fn a_subject_page_read_during_a_seal_sees_every_record() {
    let (root, reader) = reader_raced_by_a_seal("subjects", 8);
    let subject = JournalSubject { kind: "terminal".into(), id: format!("term_{:032x}", 3) };
    let page = reader.after_subjects(0, 64, std::slice::from_ref(&subject));
    let ran = BETWEEN_JOURNAL_READS_FOR_TEST.with(|slot| slot.borrow().is_none());
    assert!(ran, "the seal ran inside the read");
    let page = page.expect("a seal during the read loses no record");
    assert_eq!(page.records.len(), 1);
    assert_eq!(page.records[0].subjects, vec![subject]);
    drop(reader);
    fs::remove_dir_all(root).unwrap();
}
