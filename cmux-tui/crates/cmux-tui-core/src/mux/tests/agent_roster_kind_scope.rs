//! An agent roster replay costs the records the roster folds, not the
//! journal's history around them.
//!
//! Leo's restore on 2026-11-08 took 26 min: the agent roster's reducer
//! version changed, so the daemon's start replayed the journal from its
//! first record, about 12M rows other than terminal output, 96.6% of them
//! `personal.session.put`, which the roster discards. The replay now reads
//! only the kinds the roster folds ([`AgentRoster::folds_kind`]). These
//! tests check that the scoped read drops nothing the roster uses, and
//! count SQLite VM steps (deterministic, unlike wall time) for its cost.

use std::time::{Duration, Instant};

use super::open_persistent_test_mux;

use serde_json::{Value, json};

use crate::journal_reducers::{
    AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, AgentRoster, RosterEvent,
};
use crate::mux::agent_roster_restore::restore_agent_roster;
use crate::workspace_registry::session_journal::kind_read_tests::TestJournalRecord;
use crate::workspace_registry::{SessionJournalReader, SessionJournalRecord, WorkspaceRegistry};
use crate::{JournalProducer, JournalSubject, Mux};

/// Terminals with an agent in the cost test; each has a fixed lifecycle.
const AGENT_TERMINALS: usize = 8;

fn terminal_id(index: usize) -> String {
    format!("term_{index:032x}")
}

fn terminal_subjects(terminal: &str) -> Vec<JournalSubject> {
    vec![JournalSubject { kind: "terminal".into(), id: terminal.into() }]
}

fn hook_producer() -> JournalProducer {
    JournalProducer { kind: "agent_adapter".into(), id: crate::AGENT_HOOK_PRODUCER_ID.into() }
}

/// An agent hook event as `agent_hook_journal_ingress` builds it.
fn hook_record(terminal: &str, native_event: &str, session: &str) -> TestJournalRecord {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        native_event,
        Some(terminal),
        json!({ "session_id": session }),
    )
    .unwrap();
    TestJournalRecord {
        kind: ingress.kind,
        producer: hook_producer(),
        subjects: ingress.subjects,
        payload: ingress.payload,
    }
}

/// The presentation store's record of one `personal.session.put`: a peer
/// session announcing itself, the journal's churn on a long-lived machine.
fn session_put(index: usize) -> TestJournalRecord {
    let session = format!("sess_{:032x}", index % 64);
    TestJournalRecord {
        kind: "personal.session.put".into(),
        producer: JournalProducer { kind: "presentation".into(), id: "cmux-tui".into() },
        subjects: vec![JournalSubject { kind: "session".into(), id: session.clone() }],
        payload: json!({
            "session": {"session_id": session, "last_seen_ms": index},
            "created": false,
            "personal_revision": index,
        }),
    }
}

/// Each agent terminal starts a session and a turn.
fn agent_lifecycles() -> Vec<TestJournalRecord> {
    (0..AGENT_TERMINALS)
        .flat_map(|index| {
            let terminal = terminal_id(index);
            let session = format!("agent-{index}");
            [
                hook_record(&terminal, "SessionStart", &session),
                hook_record(&terminal, "UserPromptSubmit", &session),
            ]
        })
        .collect()
}

/// `agents` spread evenly through `churn` session puts.
fn interleave(agents: Vec<TestJournalRecord>, churn: usize) -> Vec<TestJournalRecord> {
    let stride = churn / agents.len().max(1) + 1;
    let mut agents = agents.into_iter();
    let mut records = Vec::with_capacity(churn + agents.len());
    for index in 0..churn {
        if index % stride == 0
            && let Some(agent) = agents.next()
        {
            records.push(agent);
        }
        records.push(session_put(index));
    }
    records.extend(agents);
    records
}

/// What one roster restore after a reducer version change cost.
struct ReplayCost {
    steps: u64,
    elapsed: Duration,
}

/// A registry whose journal holds the agent lifecycles among `churn`
/// session puts, and a roster snapshot of the previous reducer version at
/// the head: the start replays from the first record.
fn replay_after_version_bump(churn: usize) -> ReplayCost {
    let registry = WorkspaceRegistry::in_memory("roster-kind-scope-cost").unwrap();
    registry.append_journal_records_for_test(&interleave(agent_lifecycles(), churn));
    let head = registry.session_journal_head().unwrap();
    registry
        .put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION - 1,
            head,
            "{}",
        )
        .unwrap();
    let mut restored = None;
    let started = Instant::now();
    let steps = registry.vm_steps_for_test(|| {
        restored = Some(restore_agent_roster(&registry));
    });
    let elapsed = started.elapsed();
    let restored = restored.unwrap().unwrap();
    assert_eq!(restored.host.cursor, head, "the replay reaches the head");
    let working =
        restored.host.roster.entries.values().filter(|entry| entry.state == "working").count();
    assert_eq!(working, AGENT_TERMINALS, "every agent's turn is folded");
    ReplayCost { steps, elapsed }
}

/// A roster replay after a version bump costs its agent events: 50x the
/// session churn adds less than one VM step per churn record. Reading every
/// record other than terminal output cost tens of steps for each one.
#[test]
fn roster_replay_after_a_version_bump_skips_session_churn() {
    let sizes = [1_000, 10_000, 50_000];
    let costs = sizes.map(replay_after_version_bump);
    let table = sizes
        .iter()
        .zip(&costs)
        .map(|(churn, cost)| {
            format!(
                "{churn} session puts + {} agent events: {} VM steps, {:?}",
                AGENT_TERMINALS * 2,
                cost.steps,
                cost.elapsed
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let (small, large) = (&costs[0], &costs[2]);
    let added = (sizes[2] - sizes[0]) as u64;
    let per_record = large.steps.saturating_sub(small.steps) / added;
    assert!(
        per_record < 1,
        "a roster replay costs {per_record} VM steps per session put it skips:\n{table}"
    );
}

/// A record of `producer` (a plugin's, or another writer's) with `payload`.
fn record(producer: (&str, &str), kind: &str, terminal: &str, payload: Value) -> TestJournalRecord {
    TestJournalRecord {
        kind: kind.into(),
        producer: JournalProducer { kind: producer.0.into(), id: producer.1.into() },
        subjects: terminal_subjects(terminal),
        payload,
    }
}

/// A hook producer event with an explicit adapter and native event: the
/// daemon's program status evidence, a socket report echo, or the legacy
/// in-core screen detector's report.
fn hook_envelope(
    terminal: &str,
    adapter: &str,
    native_event: &str,
    normalized: Value,
) -> TestJournalRecord {
    record(
        ("agent_adapter", crate::AGENT_HOOK_PRODUCER_ID),
        "agent.state.changed",
        terminal,
        json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter": {"id": adapter, "version": 1},
            "native_event": native_event,
            "normalized": normalized,
            "native": {},
        }),
    )
}

/// The screen detector plugin's event `event` (`state.changed` or
/// `session.ended`) under journal kind `kind`.
fn plugin_record(
    kind: &str,
    terminal: &str,
    event: &str,
    state: &str,
    observed: u64,
) -> TestJournalRecord {
    record(
        ("plugin", "screen_detector"),
        kind,
        terminal,
        json!({
            "format": crate::journal_reducers::AGENT_PLUGIN_FORMAT,
            "plugin": {"id": "screen_detector", "version": 1},
            "adapter": {"id": "codex", "version": 1},
            "event": event,
            "normalized": {
                "state": state,
                "source_session": "pid:42",
                "observed_at_ms": observed.to_string(),
                "plugin_generation": "1",
            },
        }),
    )
}

/// Every record shape the roster folds, and records it must not fold,
/// including ones that look like agent records to a careless filter.
fn mixed_stream(part: usize) -> Vec<TestJournalRecord> {
    let terminal = |index: usize| terminal_id(part * 10 + index);
    let mut agents = vec![
        hook_record(&terminal(0), "SessionStart", &format!("a-{part}")),
        hook_record(&terminal(0), "UserPromptSubmit", &format!("a-{part}")),
        hook_record(&terminal(1), "SessionStart", &format!("b-{part}")),
        hook_record(&terminal(1), "PermissionRequest", &format!("b-{part}")),
        // The program's own status: blocked, then working again.
        hook_envelope(
            &terminal(1),
            "cmux",
            crate::journal_reducers::PROGRAM_STATUS_NATIVE_EVENT,
            json!({"state": "blocked", "observed_at_ms": "1000"}),
        ),
        hook_envelope(
            &terminal(1),
            "cmux",
            crate::journal_reducers::PROGRAM_STATUS_NATIVE_EVENT,
            json!({"state": "working", "observed_at_ms": "2000"}),
        ),
        hook_envelope(
            &terminal(2),
            crate::journal_reducers::SOCKET_REPORT_ADAPTER,
            crate::journal_reducers::SOCKET_REPORT_NATIVE_EVENT,
            json!({"state": "working", "source": "socket", "updated_at_ms": "1500"}),
        ),
        hook_envelope(
            &terminal(3),
            "claude",
            crate::journal_reducers::LEGACY_SCREEN_DETECT_NATIVE_EVENT,
            json!({"state": "working"}),
        ),
        plugin_record(
            "plugin.screen_detector.agent.state.changed",
            &terminal(4),
            "state.changed",
            "working",
            1_000,
        ),
        plugin_record(
            "plugin.screen_detector.agent.state.changed",
            &terminal(5),
            "state.changed",
            "working",
            1_000,
        ),
        plugin_record(
            "plugin.screen_detector.agent.session.ended",
            &terminal(5),
            "session.ended",
            "done",
            2_000,
        ),
        hook_record(&terminal(0), "Stop", &format!("a-{part}")),
    ];
    if part == 1 {
        let exit =
            crate::agent_hooks::journal_plugin_exit_journal_ingress("screen_detector", 1).unwrap();
        agents.push(TestJournalRecord {
            kind: exit.kind,
            producer: hook_producer(),
            subjects: exit.subjects,
            payload: exit.payload,
        });
        agents.push(hook_record(&terminal(1), "SessionEnd", &format!("b-{part}")));
    }
    let noise = vec![
        session_put(part),
        // A plugin's own kind with an agent plugin payload: not an agent event.
        plugin_record(
            "plugin.screen_detector.telemetry",
            &terminal(6),
            "state.changed",
            "working",
            1_000,
        ),
        // Writers that name a producer by its origin, here the hook producer's id.
        record(
            ("journal_admin", crate::AGENT_HOOK_PRODUCER_ID),
            "journal.producer.installed",
            &terminal(7),
            json!({"producer_id": "screen_detector", "manifest_version": 1}),
        ),
        record(
            ("resource_operation", crate::AGENT_HOOK_PRODUCER_ID),
            "workspace.rename",
            &terminal(7),
            json!({"idempotency_key": "k", "result": {}, "changes": []}),
        ),
    ];
    let mut noise = noise.into_iter().cycle();
    let mut stream = Vec::new();
    for agent in agents {
        for _ in 0..3 {
            stream.push(noise.next().unwrap());
        }
        stream.push(agent);
    }
    stream.extend(noise.take(4));
    stream
}

/// Checkpoint and seal the whole journal; returns the new segment ids.
fn seal_journal(mux: &Mux, key: &str) -> Vec<String> {
    let checkpoint =
        mux.create_journal_checkpoint("client_test", &format!("{key}_checkpoint")).unwrap();
    let sealed = mux
        .seal_journal_segments(
            checkpoint.checkpoint.source_sequence,
            "client_test",
            &format!("{key}_seal"),
        )
        .unwrap();
    assert!(!sealed.segments.is_empty());
    sealed.segments.into_iter().map(|segment| segment.segment_id).collect()
}

fn fold(records: &[SessionJournalRecord]) -> AgentRoster {
    let mut roster = AgentRoster::default();
    for record in records {
        roster.apply(&RosterEvent::from_record(record));
    }
    roster
}

/// Pages of a kind-scoped read from 0 to the head, `limit` at a time.
fn read_scoped(
    read: impl Fn(u64, u64, usize) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)>,
    head: u64,
    limit: usize,
) -> Vec<SessionJournalRecord> {
    let (mut cursor, mut records) = (0, Vec::new());
    while cursor < head {
        let (page, reached) = read(cursor, head, limit).unwrap();
        assert!(reached > cursor, "each page makes progress");
        assert!(page.iter().all(|record| record.sequence > cursor && record.sequence <= reached));
        records.extend(page);
        cursor = reached;
    }
    records
}

/// The roster's kind-scoped replay drops nothing `apply` uses. A mixed
/// stream of every record shape the roster folds, among records it must
/// not (session churn, a plugin's other kinds, other writers named by the
/// hook producer's id), is sealed in part and live in part. Folding every
/// record and folding the scoped read give the same roster, and every
/// record the scope leaves out is a no-op for `apply`. A sealed segment
/// that holds no roster kind is never decoded: the read passes over it
/// after its content is destroyed.
#[test]
fn roster_kind_scope_folds_the_same_roster_as_every_record() {
    let session = "roster-kind-scope";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-kind-scope-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let append = |records: &[TestJournalRecord]| {
        mux.workspace_registry.lock().unwrap().append_journal_records_for_test(records);
    };
    append(&(0..40).map(session_put).collect::<Vec<_>>());
    let churn_only = seal_journal(&mux, "kind_scope_churn");
    append(&mixed_stream(0));
    seal_journal(&mux, "kind_scope_mixed");
    append(&mixed_stream(1));
    let head = mux.session_journal_head().unwrap();
    let mut every = Vec::new();
    loop {
        let page = mux
            .session_journal_after(
                every.last().map_or(0, |r: &SessionJournalRecord| r.sequence),
                1024,
            )
            .unwrap();
        if page.records.is_empty() {
            break;
        }
        every.extend(page.records);
    }
    assert_eq!(every.last().unwrap().sequence, head);
    mux.shutdown();
    drop(mux);

    // Every record the scope leaves out is a no-op, wherever it comes.
    let mut roster = AgentRoster::default();
    for record in &every {
        if AgentRoster::folds_kind(&record.kind) {
            roster.apply(&RosterEvent::from_record(record));
            continue;
        }
        let before = roster.snapshot();
        assert!(
            roster.apply(&RosterEvent::from_record(record)).is_empty(),
            "{} changed the roster",
            record.kind
        );
        assert_eq!(roster.snapshot(), before, "{} changed the roster", record.kind);
    }
    let full = fold(&every);
    assert_eq!(roster.snapshot(), full.snapshot());
    assert!(
        full.entries.len() >= 4,
        "the stream leaves agents in the roster: {:?}",
        full.entries.keys().collect::<Vec<_>>()
    );

    // Destroy the churn-only segments: a read that decodes one fails.
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let database = registry.session_journal_database_path().unwrap();
    {
        let connection = rusqlite::Connection::open(&database).unwrap();
        for segment_id in &churn_only {
            let kinds = connection
                .prepare("SELECT kind FROM journal_segment_kinds WHERE segment_id = ?1")
                .unwrap()
                .query_map([segment_id], |row| row.get::<_, String>(0))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap();
            assert!(!kinds.is_empty() && !kinds.iter().any(|kind| AgentRoster::folds_kind(kind)));
        }
        connection.execute_batch("DROP TRIGGER IF EXISTS journal_segments_reject_update;").unwrap();
        for segment_id in &churn_only {
            connection
                .execute(
                    "UPDATE journal_segments SET content = x'00112233' WHERE segment_id = ?1",
                    [segment_id],
                )
                .unwrap();
        }
    }
    assert!(registry.session_journal_after(0, 1024).is_err(), "the churn segments are destroyed");

    let expected = every
        .iter()
        .filter(|record| AgentRoster::folds_kind(&record.kind))
        .map(|record| record.sequence)
        .collect::<Vec<_>>();
    let reader = SessionJournalReader::open(&database).unwrap();
    for limit in [1, 2, 5, 512] {
        let scoped = read_scoped(
            |cursor, through, limit| {
                registry.session_journal_kinds_after(
                    cursor,
                    through,
                    AgentRoster::folds_kind,
                    limit,
                )
            },
            head,
            limit,
        );
        assert_eq!(scoped.iter().map(|record| record.sequence).collect::<Vec<_>>(), expected);
        assert_eq!(fold(&scoped).snapshot(), full.snapshot(), "page limit {limit}");
        let scoped = read_scoped(
            |cursor, through, limit| {
                reader.kinds_after(cursor, through, AgentRoster::folds_kind, limit)
            },
            head,
            limit,
        );
        assert_eq!(scoped.iter().map(|record| record.sequence).collect::<Vec<_>>(), expected);
    }
    drop(reader);
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// A kind-scoped read inflates several sealed segments at once
/// (`segment_decode_workers`). It returns what a read one segment at a time
/// returns, at any page size. A segment that does not decode, in the middle
/// of a batch, ends the page before it: the segments ahead of it still
/// count, and the next page fails at its start, so the roster's salvaging
/// read skips only that segment.
#[test]
fn a_parallel_kind_read_matches_one_at_a_time_and_stops_before_a_bad_segment() {
    use crate::workspace_registry::session_journal::kind_read::SEGMENT_DECODE_WORKERS;
    let session = "roster-kind-parallel";
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-kind-parallel-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let mut seals = Vec::new();
    for part in 0..6 {
        mux.workspace_registry
            .lock()
            .unwrap()
            .append_journal_records_for_test(&mixed_stream(part % 2));
        seals.push(seal_journal(&mux, &format!("kind_parallel_{part}")));
    }
    let head = mux.session_journal_head().unwrap();
    mux.shutdown();
    drop(mux);

    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let database = registry.session_journal_database_path().unwrap();
    let read = |workers: usize, limit: usize| {
        SEGMENT_DECODE_WORKERS.with(|cell| cell.set(Some(workers)));
        let records = read_scoped(
            |cursor, through, limit| {
                registry.session_journal_kinds_after(
                    cursor,
                    through,
                    AgentRoster::folds_kind,
                    limit,
                )
            },
            head,
            limit,
        );
        SEGMENT_DECODE_WORKERS.with(|cell| cell.set(None));
        records
    };
    // Sealing kept the agent records, so the read decodes no segment. Drop
    // them, as for segments an older build sealed: every segment with an
    // agent record now decodes, which is what this test exercises.
    let from_kept_records = read(4, 512);
    rusqlite::Connection::open(&database)
        .unwrap()
        .execute("DELETE FROM journal_segment_reducer_records", [])
        .unwrap();
    let one_at_a_time = read(1, 512);
    assert!(one_at_a_time.iter().any(|record| AgentRoster::folds_kind(&record.kind)));
    assert_eq!(from_kept_records, one_at_a_time, "the kept records read as the segments");
    for (workers, limit) in [(4, 512), (4, 1), (3, 5), (8, 512)] {
        assert_eq!(read(workers, limit), one_at_a_time, "{workers} workers, page limit {limit}");
    }

    // Destroy the third seal's segments.
    let bad_start = {
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection.execute_batch("DROP TRIGGER IF EXISTS journal_segments_reject_update;").unwrap();
        let mut bad_start = u64::MAX;
        for segment_id in &seals[2] {
            connection
                .execute(
                    "UPDATE journal_segments SET content = x'00112233' WHERE segment_id = ?1",
                    [segment_id],
                )
                .unwrap();
            let start: i64 = connection
                .query_row(
                    "SELECT start_sequence FROM journal_segments WHERE segment_id = ?1",
                    [segment_id],
                    |row| row.get(0),
                )
                .unwrap();
            bad_start = bad_start.min(u64::try_from(start).unwrap());
        }
        bad_start
    };
    SEGMENT_DECODE_WORKERS.with(|cell| cell.set(Some(4)));
    let (page, reached) =
        registry.session_journal_kinds_after(0, head, AgentRoster::folds_kind, 512).unwrap();
    assert_eq!(reached, bad_start - 1, "the page ends before the bad segment");
    let before = one_at_a_time
        .iter()
        .filter(|record| record.sequence <= reached)
        .cloned()
        .collect::<Vec<_>>();
    assert!(!before.is_empty());
    assert_eq!(page, before);
    assert!(
        registry.session_journal_kinds_after(reached, head, AgentRoster::folds_kind, 512).is_err(),
        "the next page meets the bad segment at its start"
    );
    SEGMENT_DECODE_WORKERS.with(|cell| cell.set(None));
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}
