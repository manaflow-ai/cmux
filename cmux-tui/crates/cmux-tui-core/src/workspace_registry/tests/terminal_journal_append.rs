//! Terminal output journal appends (moved out of workspace_registry/tests.rs).

use super::*;

#[test]
fn terminal_journal_persists_exact_output_and_geometry_in_order() {
    let mut registry = WorkspaceRegistry::in_memory("journal-terminal-content").unwrap();
    commit_terminal_topology(&mut registry, "journal-terminal-content-seed");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let journal_terminal_id = Arc::new(terminal_id.clone());
    let output = b"prompt> \x1b[31merror\x1b[0m\r\n\0binary";

    let events = [
        crate::journal_ingress::JournalIngressEvent::TerminalOutput {
            terminal_id: journal_terminal_id.clone(),
            generation: "incarnation-one".into(),
            occurred_at_ms: 42,
            bytes: output.to_vec(),
        },
        crate::journal_ingress::JournalIngressEvent::TerminalResize {
            terminal_id: journal_terminal_id.clone(),
            generation: "incarnation-one".into(),
            occurred_at_ms: 43,
            cols: 120,
            rows: 40,
            cell_width: 9,
            cell_height: 18,
        },
        crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
            terminal_id: journal_terminal_id,
            generation: "incarnation-one".into(),
            occurred_at_ms: 44,
            reason: "detach_fence_failed",
        },
    ];
    let appended =
        registry.append_journal_ingress_events(&events.iter().collect::<Vec<_>>()).unwrap();
    assert_eq!(appended.len(), 3);

    let records = registry
        .session_journal_after(0, 32)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| {
            matches!(
                record.kind.as_str(),
                "terminal.output" | "terminal.resized" | "terminal.output.gap"
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(records.len(), 3);
    let output_record = &records[0];
    assert_eq!(output_record.kind, "terminal.output");
    assert_eq!(output_record.replay, JournalReplayPolicy::Required);
    assert_eq!(output_record.sensitivity, JournalSensitivity::Sensitive);
    assert_eq!(output_record.terminal_output.as_deref(), Some(output.as_slice()));
    assert!(output_record.payload.get("data").is_none());
    assert_eq!(output_record.payload["byte_count"], output.len().to_string());
    assert_eq!(output_record.payload["stream_offset_start"], "0");
    assert_eq!(output_record.payload["stream_offset_end"], output.len().to_string());
    assert_eq!(output_record.payload["encoding"], "raw");
    assert_eq!(output_record.payload["sha256"].as_str().unwrap().len(), 64);
    assert_eq!(output_record.authority.as_ref().unwrap().generation, "incarnation-one");

    let resize_record = &records[1];
    assert_eq!(resize_record.kind, "terminal.resized");
    assert!(resize_record.terminal_output.is_none());
    assert_eq!(resize_record.payload["cols"], 120);
    assert_eq!(resize_record.payload["rows"], 40);
    assert_eq!(resize_record.payload["cell_width"], 9);
    assert_eq!(resize_record.payload["cell_height"], 18);

    let gap_record = &records[2];
    assert_eq!(gap_record.kind, "terminal.output.gap");
    assert_eq!(gap_record.replay, JournalReplayPolicy::Required);
    assert!(gap_record.terminal_output.is_none());
    assert_eq!(gap_record.payload["format"], "cmux.terminal-output-gap.v1");
    assert_eq!(gap_record.payload["reason"], "detach_fence_failed");

    let pane = pane_id(1);
    let screen = screen_id(1);
    let workspace_id = workspace(1, "one", "One").public_id;
    for record in &records {
        for (kind, id) in [
            ("terminal", terminal_id.as_str()),
            ("tab", tab_id(1).as_str()),
            ("pane", pane.as_str()),
            ("screen", screen.as_str()),
            ("workspace", workspace_id.as_str()),
        ] {
            assert!(
                record.subjects.iter().any(|subject| subject.kind == kind && subject.id == id),
                "missing {kind}:{id} from {} subjects: {:#?}",
                record.kind,
                record.subjects
            );
        }
    }
}

#[test]
#[ignore = "manual release-mode journal writer throughput probe"]
fn terminal_journal_writer_throughput_probe() {
    const BATCH_SIZE: usize = 1_024;
    const BATCHES: usize = 16;
    const CHUNK_BYTES: usize = 4 * 1_024;

    let mut registry = WorkspaceRegistry::in_memory("journal-terminal-throughput").unwrap();
    commit_terminal_topology(&mut registry, "journal-terminal-throughput-seed");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let journal_terminal_id = Arc::new(terminal_id.clone());
    let mut chunk = vec![b'x'; CHUNK_BYTES];
    chunk[CHUNK_BYTES - 17..].copy_from_slice(b"terminal-output\r\n");
    let started = std::time::Instant::now();
    for batch in 0..BATCHES {
        let events = (0..BATCH_SIZE)
            .map(|index| crate::journal_ingress::JournalIngressEvent::TerminalOutput {
                terminal_id: journal_terminal_id.clone(),
                generation: "throughput-generation".into(),
                occurred_at_ms: u64::try_from(batch * BATCH_SIZE + index).unwrap(),
                bytes: chunk.clone(),
            })
            .collect::<Vec<_>>();
        let references = events.iter().collect::<Vec<_>>();
        assert_eq!(registry.append_journal_ingress_events(&references).unwrap().len(), BATCH_SIZE);
    }
    let elapsed = started.elapsed();
    let event_count = BATCH_SIZE * BATCHES;
    let byte_count = event_count * CHUNK_BYTES;
    let events_per_second = event_count as f64 / elapsed.as_secs_f64();
    let mebibytes_per_second = byte_count as f64 / (1024.0 * 1024.0) / elapsed.as_secs_f64();
    eprintln!(
        "terminal journal writer: {event_count} records / {} MiB in {elapsed:?}, \
         {events_per_second:.0} records/s, {mebibytes_per_second:.1} MiB/s",
        byte_count / (1024 * 1024)
    );
    assert!(events_per_second >= 5_000.0, "journal writer regressed: {events_per_second:.0}/s");
    assert!(
        mebibytes_per_second >= 20.0,
        "journal writer regressed: {mebibytes_per_second:.1} MiB/s"
    );
    let stored_offset = registry
        .connection
        .get()
        .query_row(
            "SELECT next_offset FROM journal_terminal_streams
             WHERE terminal_id = ?1 AND generation = ?2",
            params![terminal_id.as_str(), "throughput-generation"],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(usize::try_from(stored_offset).unwrap(), byte_count);
}

#[test]
fn terminal_output_survives_immutable_segment_round_trip() {
    let root = temp_root("journal-terminal-segment");
    let mut registry = WorkspaceRegistry::open(&root, "journal-terminal-segment").unwrap();
    commit_terminal_topology(&mut registry, "journal-terminal-segment-seed");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let output = b"segment output \x1b[32mready\x1b[0m\r\n\0";
    let events = [crate::journal_ingress::JournalIngressEvent::TerminalOutput {
        terminal_id: Arc::new(terminal_id),
        generation: "segment-incarnation".into(),
        occurred_at_ms: 42,
        bytes: output.to_vec(),
    }];
    registry.append_journal_ingress_events(&events.iter().collect::<Vec<_>>()).unwrap();
    let through = registry.session_journal_after(0, 32).unwrap().head_sequence;
    registry
        .create_journal_checkpoint(
            through,
            1,
            &json!({
                "session_snapshot":{"cursor":{"revision":"1"}},
                "journal_extensions":{"producers":[],"hooks":[]},
            }),
            &[],
            "client_test",
            "terminal_segment_checkpoint",
        )
        .unwrap();

    let plan = match registry
        .begin_journal_segment_seal(through, "client_test", "terminal_segment_seal")
        .unwrap()
    {
        JournalSegmentSealStart::Prepare(plan) => plan,
        JournalSegmentSealStart::Replay(_) => panic!("first segment seal unexpectedly replayed"),
    };
    let reader = SessionJournalReader::open(
        &registry.session_journal_database_path().expect("persistent registry has a path"),
    )
    .unwrap();
    let prepared = plan.prepare(&reader).unwrap();
    let commit = registry
        .commit_journal_segment_seal(prepared, "client_test", "terminal_segment_seal")
        .unwrap()
        .expect("segment boundary remained stable");
    assert_eq!(commit.through_sequence, through);

    let record = registry
        .session_journal_after(0, 32)
        .unwrap()
        .records
        .into_iter()
        .find(|record| record.kind == "terminal.output")
        .unwrap();
    assert_eq!(record.terminal_output.as_deref(), Some(output.as_slice()));
    assert_eq!(record.payload["encoding"], "raw");
    assert!(record.payload.get("data").is_none());

    drop(reader);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
