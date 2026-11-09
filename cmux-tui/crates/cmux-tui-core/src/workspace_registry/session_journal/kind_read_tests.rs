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
    let connection =
        Connection::open(registry.session_journal_database_path().unwrap()).unwrap();
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
