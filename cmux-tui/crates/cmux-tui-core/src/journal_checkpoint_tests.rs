//! `journal_checkpoint` capture and restore reducer tests.

use super::*;
use crate::{
    JournalAuthority, JournalClass, JournalEventSchema, JournalProducer, JournalProducerManifest,
    JournalSensitivity, JournalSubject,
};
use std::sync::Arc;

thread_local! {
    pub(super) static AFTER_RECOVERY_HOOK: std::cell::RefCell<Option<Box<dyn FnOnce()>>> =
        std::cell::RefCell::new(None);
}

fn terminal_replay_checkpoint() -> JournalCheckpoint {
    JournalCheckpoint {
        checkpoint_id: "checkpoint_terminal_replay".into(),
        source_sequence: 3,
        reducer_version: JOURNAL_REDUCER_VERSION,
        state: json!({
            "session_snapshot":{
                "cursor":{"generation":"generation","revision":"1"},
                "workspaces":[],
            },
            "journal_extensions":{"producers":[],"hooks":[]},
        }),
        content_refs: vec![],
        sha256: "00".repeat(32),
        created_at_ms: 1,
    }
}

fn terminal_replay_record(
    sequence: u64,
    kind: &str,
    payload: Value,
    terminal_output: Option<&[u8]>,
) -> SessionJournalRecord {
    SessionJournalRecord {
        sequence,
        event_id: format!("event_terminal_replay_{sequence}"),
        schema_version: 1,
        kind: kind.into(),
        class: JournalClass::State,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: sequence,
        committed_at_ms: sequence,
        producer: JournalProducer { kind: "terminal_runtime".into(), id: "term_test".into() },
        authority: Some(JournalAuthority {
            principal_id: "cmux.terminal-runtime".into(),
            lease_id: "terminal:term_test".into(),
            generation: "incarnation-one".into(),
            role: "terminal.runtime".into(),
        }),
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject {
            kind: "terminal".into(),
            id: "term_00000000000000000000000000000001".into(),
        }],
        sensitivity: JournalSensitivity::Sensitive,
        payload,
        resource_revision: None,
        previous_resource_revision: None,
        terminal_output: terminal_output.map(Arc::from),
    }
}

#[test]
fn reducer_applies_resource_upserts_and_deletes() {
    let checkpoint = JournalCheckpoint {
        checkpoint_id: "checkpoint_test".into(),
        source_sequence: 3,
        reducer_version: JOURNAL_REDUCER_VERSION,
        state: json!({
            "session_snapshot":{
                "cursor":{"generation":"generation","revision":"1"},
                "workspaces":[{"id":"workspace_old","index":0}],
            },
            "journal_extensions":{"producers":[],"hooks":[]},
        }),
        content_refs: vec![],
        sha256: "00".repeat(32),
        created_at_ms: 1,
    };
    let record = SessionJournalRecord {
        sequence: 4,
        event_id: "event_4".into(),
        schema_version: 1,
        kind: "workspace.create".into(),
        class: JournalClass::State,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "test".into(), id: "test".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "session".into(), id: "session".into() }],
        sensitivity: JournalSensitivity::Sensitive,
        payload: json!({"changes":[
            {"kind":"delete","sequence":0,"resource":"workspace","id":"workspace_old"},
            {"kind":"upsert","sequence":1,"resource":"workspace","id":"workspace_new","value":{"id":"workspace_new","index":0}},
        ]}),
        resource_revision: Some(2),
        previous_resource_revision: Some(1),
        terminal_output: None,
    };
    let preview = restore_preview(&checkpoint, &[record], 4).unwrap();
    assert_eq!(preview["fully_reducible"], true);
    assert_eq!(preview["state"]["session_snapshot"]["workspaces"][0]["id"], "workspace_new");
    assert_eq!(preview["state"]["session_snapshot"]["cursor"]["revision"], "2");
}

/// A workspace create also carries `state_upsert` changes (its sidebar item
/// and placement). The record still restores its resources and the session
/// revision follows the cursor; the state changes are counted, not
/// reduced, so the preview is not `fully_reducible` (a restore keeps the
/// checkpoint's `extra.state`; spec/session-journal.md, p15-oracle task
/// 205, invariant I9).
#[test]
fn reducer_applies_a_record_with_state_changes_and_moves_the_session_revision() {
    let checkpoint = JournalCheckpoint {
        checkpoint_id: "checkpoint_test".into(),
        source_sequence: 3,
        reducer_version: JOURNAL_REDUCER_VERSION,
        state: json!({
            "session_snapshot":{
                "cursor":{"generation":"generation","revision":"1"},
                "session":{"id":"session","revision":"1"},
                "workspaces":[],
            },
            "journal_extensions":{"producers":[],"hooks":[]},
        }),
        content_refs: vec![],
        sha256: "00".repeat(32),
        created_at_ms: 1,
    };
    let record = SessionJournalRecord {
        sequence: 4,
        event_id: "event_4".into(),
        schema_version: 1,
        kind: "workspace.create".into(),
        class: JournalClass::State,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "test".into(), id: "test".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "session".into(), id: "session".into() }],
        sensitivity: JournalSensitivity::Sensitive,
        payload: json!({"changes":[
            {"kind":"upsert","sequence":0,"resource":"workspace","id":"workspace_new","value":{"id":"workspace_new","index":0}},
            {"kind":"state_upsert","sequence":1,"resource":"sidebar_item","id":"itm_w","value":{"id":"itm_w"}},
            {"kind":"state_delete","sequence":2,"resource":"workspace_placement","id":"p"},
        ]}),
        resource_revision: Some(2),
        previous_resource_revision: Some(1),
        terminal_output: None,
    };
    let preview = restore_preview(&checkpoint, std::slice::from_ref(&record), 4).unwrap();
    assert_eq!(preview["fully_reducible"], false, "{preview:#}");
    assert_eq!(preview["applied_required_records"], "1");
    assert_eq!(preview["unsupported_required_record_count"], "0");
    let state = &preview["state"];
    assert_eq!(state["session_snapshot"]["workspaces"][0]["id"], "workspace_new");
    assert_eq!(state["session_snapshot"]["session"]["revision"], "2");
    assert_eq!(state["journal_replay"]["state_changes_not_reduced"], "2");

    let mut resources_only = record.clone();
    resources_only.payload["changes"].as_array_mut().unwrap().truncate(1);
    let preview = restore_preview(&checkpoint, &[resources_only], 4).unwrap();
    assert_eq!(preview["fully_reducible"], true, "{preview:#}");
    assert!(preview["state"].get("journal_replay").is_none(), "{preview:#}");

    let mut malformed = record;
    malformed.payload["changes"][1] =
        json!({"kind":"state_upsert","sequence":1,"resource":"sidebar_item","id":"itm_w"});
    let preview = restore_preview(&checkpoint, &[malformed], 4).unwrap();
    assert_eq!(preview["unsupported_required_record_count"], "1", "a state upsert needs its value");
}

#[test]
fn reducer_rejects_duplicate_and_gapped_sequences() {
    let checkpoint = JournalCheckpoint {
        checkpoint_id: "checkpoint_test".into(),
        source_sequence: 3,
        reducer_version: JOURNAL_REDUCER_VERSION,
        state: json!({"session_snapshot":{"cursor":{}},"journal_extensions":{"producers":[],"hooks":[]}}),
        content_refs: vec![],
        sha256: "00".repeat(32),
        created_at_ms: 1,
    };
    let record = SessionJournalRecord {
        sequence: 4,
        event_id: "event_4".into(),
        schema_version: 1,
        kind: "unknown".into(),
        class: JournalClass::State,
        replay: JournalReplayPolicy::Never,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "test".into(), id: "test".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![],
        sensitivity: JournalSensitivity::Sensitive,
        payload: json!({}),
        resource_revision: None,
        previous_resource_revision: None,
        terminal_output: None,
    };
    assert!(restore_preview(&checkpoint, &[record.clone(), record.clone()], 4).is_err());
    assert!(restore_preview(&checkpoint, std::slice::from_ref(&record), 5).is_err());
    let mut gapped = record;
    gapped.sequence = 5;
    assert!(restore_preview(&checkpoint, &[gapped], 5).is_err());
}

#[test]
fn reducer_rejects_resource_revision_gap_and_stale_predecessor() {
    let checkpoint = JournalCheckpoint {
        checkpoint_id: "checkpoint_invalid".into(),
        source_sequence: 3,
        reducer_version: JOURNAL_REDUCER_VERSION,
        state: json!({"session_snapshot":{"cursor":{"generation":"g","revision":"1"},"workspaces":[]},"journal_extensions":{"producers":[],"hooks":[]}}),
        content_refs: vec![],
        sha256: "00".repeat(32),
        created_at_ms: 1,
    };
    let mut record = SessionJournalRecord {
        sequence: 4,
        event_id: "event_4".into(),
        schema_version: 1,
        kind: "workspace.create".into(),
        class: JournalClass::State,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "test".into(), id: "test".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "session".into(), id: "session".into() }],
        sensitivity: JournalSensitivity::Sensitive,
        payload: json!({"changes":[{"kind":"upsert","resource":"workspace","id":"w","value":{"id":"w","index":0}}]}),
        resource_revision: Some(3),
        previous_resource_revision: Some(2),
        terminal_output: None,
    };
    let preview = restore_preview(&checkpoint, &[record.clone()], 4).unwrap();
    assert_eq!(preview["fully_reducible"], false);
    let mut missing_predecessor = record.clone();
    missing_predecessor.resource_revision = Some(2);
    missing_predecessor.previous_resource_revision = None;
    let preview = restore_preview(&checkpoint, &[missing_predecessor], 4).unwrap();
    assert_eq!(preview["fully_reducible"], false);
    record.previous_resource_revision = Some(1);
    let preview = restore_preview(&checkpoint, &[record], 4).unwrap();
    assert_eq!(preview["fully_reducible"], false);
}

#[test]
fn reducer_rejects_revisioned_records_without_cursor_baseline() {
    let record = SessionJournalRecord {
        sequence: 4,
        event_id: "event_without_cursor_baseline".into(),
        schema_version: 1,
        kind: "workspace.create".into(),
        class: JournalClass::State,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "test".into(), id: "test".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "session".into(), id: "session".into() }],
        sensitivity: JournalSensitivity::Sensitive,
        payload: json!({"changes":[{"kind":"upsert","resource":"workspace","id":"w","value":{"id":"w","index":0}}]}),
        resource_revision: Some(101),
        previous_resource_revision: Some(100),
        terminal_output: None,
    };
    let checkpoint = |cursor: Option<Value>| {
        let mut state = json!({
            "session_snapshot":{"workspaces":[]},
            "journal_extensions":{"producers":[],"hooks":[]},
        });
        if let Some(cursor) = cursor {
            state["session_snapshot"]["cursor"] = cursor;
        }
        JournalCheckpoint {
            checkpoint_id: "checkpoint_without_cursor_baseline".into(),
            source_sequence: 3,
            reducer_version: JOURNAL_REDUCER_VERSION,
            state,
            content_refs: vec![],
            sha256: "00".repeat(32),
            created_at_ms: 1,
        }
    };

    for cursor in [None, Some(Value::Null)] {
        let preview =
            restore_preview(&checkpoint(cursor), std::slice::from_ref(&record), 4).unwrap();
        assert_eq!(preview["fully_reducible"], false);
    }
}

#[test]
fn reducer_rejects_resource_changes_without_revision_chain() {
    let checkpoint = JournalCheckpoint {
        checkpoint_id: "checkpoint_with_cursor_baseline".into(),
        source_sequence: 3,
        reducer_version: JOURNAL_REDUCER_VERSION,
        state: json!({
            "session_snapshot":{"cursor":{"generation":"g","revision":"1"},"workspaces":[]},
            "journal_extensions":{"producers":[],"hooks":[]},
        }),
        content_refs: vec![],
        sha256: "00".repeat(32),
        created_at_ms: 1,
    };
    let record = SessionJournalRecord {
        sequence: 4,
        event_id: "event_without_revision_chain".into(),
        schema_version: 1,
        kind: "workspace.create".into(),
        class: JournalClass::State,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "test".into(), id: "test".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "session".into(), id: "session".into() }],
        sensitivity: JournalSensitivity::Sensitive,
        payload: json!({"changes":[{
            "kind":"upsert",
            "resource":"workspace",
            "id":"w",
            "value":{"id":"w","index":0},
        }]}),
        resource_revision: None,
        previous_resource_revision: None,
        terminal_output: None,
    };

    let preview = restore_preview(&checkpoint, &[record], 4).unwrap();

    assert_eq!(preview["fully_reducible"], false);
}

#[test]
fn reducer_streams_terminal_output_and_resize_into_a_bounded_replay_summary() {
    let output = b"prompt> first line\r\n";
    let output_record = terminal_replay_record(
        4,
        "terminal.output",
        json!({
            "format":"cmux.terminal-output.v1",
            "encoding":"raw",
            "byte_count":output.len().to_string(),
            "sha256":encode_hex(Sha256::digest(output).as_slice()),
            "stream_offset_start":"0",
            "stream_offset_end":output.len().to_string(),
        }),
        Some(output),
    );
    let resize_record = terminal_replay_record(
        5,
        "terminal.resized",
        json!({
            "format":"cmux.terminal-geometry.v1",
            "cols":120,
            "rows":40,
            "cell_width":9,
            "cell_height":18,
        }),
        None,
    );

    let preview =
        restore_preview(&terminal_replay_checkpoint(), &[output_record, resize_record], 5).unwrap();
    assert_eq!(preview["fully_reducible"], true);
    assert_eq!(preview["unsupported_required_record_count"], "0");
    let stream = &preview["state"]["journal_replay"]["terminal_streams"][0];
    assert_eq!(stream["terminal_id"], "term_00000000000000000000000000000001");
    assert_eq!(stream["generation"], "incarnation-one");
    assert_eq!(stream["output_bytes"], output.len().to_string());
    assert_eq!(stream["output_events"], "1");
    assert_eq!(stream["resize_events"], "1");
    assert_eq!(stream["stream_offset_end"], output.len().to_string());
    assert_eq!(stream["last_geometry"]["cols"], 120);
    assert_eq!(stream["last_geometry"]["rows"], 40);
}

#[test]
fn terminal_replay_digest_covers_exact_output_bytes() {
    let checkpoint = terminal_replay_checkpoint();
    let make = |bytes: &'static [u8]| {
        terminal_replay_record(
            4,
            "terminal.output",
            json!({
                "format":"cmux.terminal-output.v1",
                "encoding":"raw",
                "byte_count":bytes.len().to_string(),
                "sha256":encode_hex(Sha256::digest(bytes).as_slice()),
                "stream_offset_start":"0",
                "stream_offset_end":bytes.len().to_string(),
            }),
            Some(bytes),
        )
    };
    let first = restore_preview(&checkpoint, &[make(b"alpha")], 4).unwrap();
    let second = restore_preview(&checkpoint, &[make(b"bravo")], 4).unwrap();
    assert_ne!(first["state_sha256"], second["state_sha256"]);
}

/// A terminal-host reconnect creates its checkpoint while the rest of the
/// session keeps journaling. Capture reads the journal head and the public
/// session snapshot as its consistency cut; a record committed between
/// those two reads is a normal concurrent write, not a torn capture, and
/// must not abort the checkpoint with "session changed during checkpoint
/// capture". On a busy session that spurious abort made every reconnect
/// checkpoint fail and surfaced as repeated status toasts.
#[test]
fn reconnect_checkpoint_capture_tolerates_a_racing_journal_write() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-capture-race-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("checkpoint-race", crate::SurfaceOptions::default(), &root).unwrap();

    let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel::<()>(0);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel::<()>(0);
    let capture_mux = mux.clone();
    let capture = std::thread::spawn(move || {
        crate::resource_api::set_snapshot_before_projection_hook(move || {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
        capture_mux.create_journal_checkpoint("terminal_host_reconnect", "capture_race_1")
    });
    entered_rx.recv().unwrap();

    // The capture thread is paused inside its snapshot cut. Commit a
    // journal record from another writer before letting it proceed.
    mux.put_journal_producer(
        &JournalProducerManifest {
            producer_id: "capture_race".into(),
            namespace: "plugin.capture_race".into(),
            manifest_version: 1,
            max_sensitivity: JournalSensitivity::Metadata,
            permissions: vec!["journal.append.plugin.capture_race".into()],
            events: vec![JournalEventSchema {
                kind: "plugin.capture_race.event".into(),
                schema_version: 1,
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Advisory,
                sensitivity: JournalSensitivity::Metadata,
                payload_schema: json!({"type":"object"}),
            }],
        },
        "client_test",
        "capture_race_producer",
    )
    .unwrap();
    let head_after_write = mux.session_journal_after(0, 1).unwrap().head_sequence;
    release_tx.send(()).unwrap();

    let commit = capture
        .join()
        .unwrap()
        .expect("a journal write racing the snapshot cut must not abort checkpoint capture");
    assert_eq!(
        commit.checkpoint.source_sequence, head_after_write,
        "the checkpoint cut must cover the racing journal write"
    );
    let preview = mux.journal_restore_preview("latest").unwrap();
    assert_eq!(preview["fully_reducible"], true);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn checkpoint_aligned_segments_remain_transparently_replayable() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-segment-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent("checkpoint-segment", crate::SurfaceOptions::default(), &root)
        .unwrap();
    mux.put_journal_producer(
        &JournalProducerManifest {
            producer_id: "segment_test".into(),
            namespace: "plugin.segment_test".into(),
            manifest_version: 1,
            max_sensitivity: JournalSensitivity::Metadata,
            permissions: vec!["journal.append.plugin.segment_test".into()],
            events: vec![JournalEventSchema {
                kind: "plugin.segment_test.event".into(),
                schema_version: 1,
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Advisory,
                sensitivity: JournalSensitivity::Metadata,
                payload_schema: json!({"type":"object"}),
            }],
        },
        "client_test",
        "producer_1",
    )
    .unwrap();
    for index in 0..1_100 {
        mux.append_journal_ingress(
            &crate::JournalIngress {
                producer_id: "segment_test".into(),
                manifest_version: 1,
                kind: "plugin.segment_test.event".into(),
                schema_version: 1,
                occurred_at_ms: None,
                subjects: vec![],
                sensitivity: None,
                payload: json!({"index": index}),
                causation_id: None,
                correlation_id: None,
            },
            "client_test",
            &format!("segment_event_{index}"),
        )
        .unwrap();
    }
    let checkpoint = mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();
    let before = mux.session_journal_after(0, 1024).unwrap().records;
    let seal = mux
        .seal_journal_segments(checkpoint.checkpoint.source_sequence, "client_test", "segment_1")
        .unwrap();
    assert!(seal.through_sequence < checkpoint.checkpoint.source_sequence);
    assert!(seal.segments.iter().all(|segment| segment.record_count <= 1_024));
    assert!(!seal.segments.is_empty());
    let stored_segments = mux.journal_segments().unwrap();
    assert_eq!(stored_segments.len(), seal.segments.len());
    assert!(stored_segments.iter().all(|segment| segment.record_count <= 1_024));
    let second_seal = mux
        .seal_journal_segments(checkpoint.checkpoint.source_sequence, "client_test", "segment_2")
        .unwrap();
    assert_eq!(second_seal.through_sequence, checkpoint.checkpoint.source_sequence);
    let after = mux.session_journal_after(0, 1024).unwrap().records;
    assert_eq!(&after[..before.len()], before.as_slice());
    let preview = mux.journal_restore_preview("latest").unwrap();
    assert_eq!(preview["fully_reducible"], true);

    let replayed = mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();
    assert!(replayed.journal.replayed);
    assert_eq!(replayed.checkpoint.checkpoint_id, checkpoint.checkpoint.checkpoint_id);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn replaying_an_old_producer_put_keeps_the_current_validator() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-producer-replay-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("producer-replay-validator", crate::SurfaceOptions::default(), &root)
            .unwrap();
    let original = JournalProducerManifest {
        producer_id: "producer_replay_test".into(),
        namespace: "plugin.producer_replay_test".into(),
        manifest_version: 1,
        max_sensitivity: JournalSensitivity::Metadata,
        permissions: vec!["journal.append.plugin.producer_replay_test".into()],
        events: vec![JournalEventSchema {
            kind: "plugin.producer_replay_test.event".into(),
            schema_version: 1,
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Metadata,
            payload_schema: json!({
                "type":"object",
                "required":["old"],
                "properties":{"old":{"type":"boolean"}},
                "additionalProperties":false,
            }),
        }],
    };
    mux.put_journal_producer(&original, "client_test", "producer_original").unwrap();
    let mut current = original.clone();
    current.manifest_version = 2;
    current.events[0].payload_schema = json!({
        "type":"object",
        "required":["current"],
        "properties":{"current":{"type":"boolean"}},
        "additionalProperties":false,
    });
    mux.put_journal_producer(&current, "client_test", "producer_current").unwrap();

    let replay = mux.put_journal_producer(&original, "client_test", "producer_original").unwrap();
    assert!(replay.replayed);
    mux.append_journal_ingress(
        &crate::JournalIngress {
            producer_id: current.producer_id.clone(),
            manifest_version: current.manifest_version,
            kind: current.events[0].kind.clone(),
            schema_version: current.events[0].schema_version,
            occurred_at_ms: None,
            subjects: vec![],
            sensitivity: None,
            payload: json!({"current":true}),
            causation_id: None,
            correlation_id: None,
        },
        "client_test",
        "producer_current_event",
    )
    .unwrap();

    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn segment_compression_never_holds_the_session_writer() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-segment-writer-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("checkpoint-segment-writer", crate::SurfaceOptions::default(), &root)
            .unwrap();
    let manifest = JournalProducerManifest {
        producer_id: "segment_writer_test".into(),
        namespace: "plugin.segment_writer_test".into(),
        manifest_version: 1,
        max_sensitivity: JournalSensitivity::Metadata,
        permissions: vec!["journal.append.plugin.segment_writer_test".into()],
        events: vec![JournalEventSchema {
            kind: "plugin.segment_writer_test.event".into(),
            schema_version: 1,
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Metadata,
            payload_schema: json!({"type":"object"}),
        }],
    };
    mux.put_journal_producer(&manifest, "client_test", "segment_writer_manifest").unwrap();
    let checkpoint =
        mux.create_journal_checkpoint("client_test", "segment_writer_checkpoint").unwrap();

    let (prepare_entered_tx, prepare_entered_rx) = std::sync::mpsc::sync_channel(1);
    let (release_prepare_tx, release_prepare_rx) = std::sync::mpsc::sync_channel(1);
    mux.set_journal_segment_prepare_hook_for_test(move || {
        prepare_entered_tx.send(()).unwrap();
        release_prepare_rx.recv().unwrap();
    });
    let sealing_mux = mux.clone();
    let through = checkpoint.checkpoint.source_sequence;
    let sealing = std::thread::spawn(move || {
        sealing_mux.seal_journal_segments(through, "client_test", "segment_writer_seal")
    });
    prepare_entered_rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap();

    let ingress = crate::JournalIngress {
        producer_id: manifest.producer_id,
        manifest_version: 1,
        kind: manifest.events[0].kind.clone(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: vec![],
        sensitivity: None,
        payload: json!({"message":"writer remains live"}),
        causation_id: None,
        correlation_id: None,
    };
    let appending_mux = mux.clone();
    let (append_tx, append_rx) = std::sync::mpsc::sync_channel(1);
    let appending = std::thread::spawn(move || {
        let result = appending_mux.append_journal_ingress(
            &ingress,
            "client_concurrent",
            "segment_writer_concurrent_append",
        );
        append_tx.send(result).unwrap();
    });
    let append_result = append_rx.recv_timeout(std::time::Duration::from_secs(2));
    release_prepare_tx.send(()).unwrap();
    append_result.expect("journal append blocked behind segment compression").unwrap();
    appending.join().unwrap();
    let sealed = sealing.join().unwrap().unwrap();
    assert_eq!(sealed.through_sequence, through);

    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn checkpoint_capture_resolves_public_terminal_ids() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-checkpoint-terminal-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent("checkpoint-terminal", crate::SurfaceOptions::default(), &root)
        .unwrap();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    mux.seed_running_terminal_for_test(
        "00000000000040008000000000000071",
        "10000000000040008000000000000071",
        &workspace.key,
    )
    .unwrap();

    let captured = capture(&mux).unwrap();
    // Terminal screens stay out of the journal (output_store.rs).
    assert!(captured.blobs.is_empty());
    let terminals = captured.state["session_snapshot"]["terminals"].as_array().unwrap();
    assert_eq!(terminals.len(), 1);
    assert!(terminals[0]["id"].as_str().unwrap().starts_with("term_"));
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
