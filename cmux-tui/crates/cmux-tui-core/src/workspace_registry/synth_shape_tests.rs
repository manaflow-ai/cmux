use super::*;

fn number(counts: &Value, key: &str) -> u64 {
    counts[key].as_u64().unwrap_or_else(|| panic!("{key} is not a number in {counts}"))
}

/// The History fold's cursor: every record of a rested agent is below it.
fn history_floor(counts: &Value) -> u64 {
    number(counts, "history_cursor")
}

/// A small registry of the shape: the counts say what the module doc says,
/// and an owner opens the file.
#[test]
fn a_small_registry_of_the_shape_has_its_counts_and_opens() {
    let root = std::env::temp_dir()
        .join(format!("cmux-synth-shape-{}", crate::workspace_registry::new_uuid_v4()));
    let options = ShapeOptions {
        session: "synth-shape".into(),
        records: Some(6_000),
        workspaces: 3,
        agent_terminals: 5,
        rested_agents: 3,
        live_rows: 100,
        seal_age_minutes: 120,
        young_segments: 1,
        ..ShapeOptions::default()
    };
    let report = generate_shape(&root, &options).unwrap();
    assert_eq!(counts(&report.registry_path).unwrap(), report.counts);
    let json = report.to_json();
    let head = number(&json, "journal_head");
    let records = number(&json, "records");
    assert!(head >= 6_000 && records >= 6_000, "{json}");
    assert_eq!(number(&json, "checkpoints"), 16, "{json}");
    assert_eq!(number(&json, "roster_cursor"), head, "{json}");
    // 5 agents that take the rounds and 3 with every record at the start.
    assert_eq!(number(&json, "roster_agents"), 8, "{json}");
    assert_eq!(number(&json, "roster_rested"), 3, "{json}");
    assert_eq!(number(&json, "history_rested"), 3, "{json}");
    assert_eq!(report.rested_agents, 3, "{json}");
    // 5 session starts, then 5 records of each rested agent, after what the
    // first owner wrote.
    assert!((15..history_floor(&json)).contains(&report.rested_through), "{json}");
    assert!(number(&json, "roster_state_bytes") > 0 && json["roster_base"].is_null(), "{json}");
    // The History fold is saved behind the head, by the daemon's own fold.
    let history_cursor = number(&json, "history_cursor");
    assert!((3_000..=4_800).contains(&history_cursor), "{json}");
    assert!(number(&json, "history_sessions") >= 5, "{json}");
    // 36% of the records have an ingress receipt; 12 subject rows a record.
    let receipts = number(&json, "receipts");
    assert!((records * 33..=records * 39).contains(&(receipts * 100)), "{json}");
    let subject_rows = number(&json, "subject_rows");
    assert!((records * 10..=records * 13).contains(&subject_rows), "{json}");
    assert!(number(&json, "workspaces") >= 3, "{json}");
    assert_eq!(number(&json, "auto_vacuum"), 0, "{json}");
    assert_eq!(number(&json, "pruned_ranges"), 0, "{json}");
    assert_eq!(number(&json, "retention_floor"), 0, "{json}");
    let live = number(&json, "live_rows");
    assert!((100..1_000).contains(&live), "{json}");
    let segments = number(&json, "segments");
    assert!(segments >= 5, "{json}");
    assert_eq!(report.segments_backdated, segments - 1, "{json}");
    // All segments but the newest are older than the hour.
    let connection = Connection::open(&report.registry_path).unwrap();
    let young: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM journal_segments WHERE sealed_at_ms > ?1",
            [unix_epoch_ms().unwrap() as i64 - 3_600_000],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(young, 1, "{json}");
    drop(connection);

    let mux = crate::Mux::open_persistent(options.session, crate::SurfaceOptions::default(), &root)
        .unwrap();
    assert!(mux.session_journal_head().unwrap() >= head);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(&root).ok();
}

/// The shape with a sparse part: the journal head is far above the records
/// that the file holds, the first segment starts at sequence 1, each hole
/// is a pruned range, and an owner reads and opens the file.
#[test]
fn a_registry_with_a_sparse_part_has_holes_at_low_sequences_and_opens() {
    let root = std::env::temp_dir()
        .join(format!("cmux-synth-sparse-{}", crate::workspace_registry::new_uuid_v4()));
    let options = ShapeOptions {
        session: "synth-sparse".into(),
        records: Some(9_000),
        workspaces: 3,
        agent_terminals: 5,
        rested_agents: 3,
        live_rows: 100,
        seal_age_minutes: 120,
        young_segments: 1,
        sparse_head: 40_000,
        sparse_records: 3_000,
        ..ShapeOptions::default()
    };
    let report = generate_shape(&root, &options).unwrap();
    let json = report.to_json();
    let sparse = report.sparse.as_ref().expect("the report has the sparse part");
    assert_eq!(sparse.head, 40_000, "{json}");
    assert!((3_000..3_010).contains(&sparse.records), "{json}");
    assert_eq!(sparse.output_rows, 3_000, "{json}");
    assert!(sparse.empty_output_rows > 30_000, "{json}");
    // The cleanup kept the records that are not superseded session puts.
    assert!((2_000..3_500).contains(&sparse.kept), "{json}");
    // About one hole for each burst of 2 records.
    assert!(sparse.pruned_ranges >= 1_000, "{json}");
    assert!(sparse.bytes_after < sparse.bytes_before, "{json}");
    assert_eq!(sparse.stretched_to, 0, "{json}");
    // Tests build such a registry at one time in the same temporary folder:
    // the generator's log stays below the size at which a daemon cuts its own.
    assert!(
        report.log_peak_bytes <= crate::workspace_registry::wal_durability::WAL_SIZE_LIMIT_BYTES,
        "the generator's log reached {} bytes: {json}",
        report.log_peak_bytes
    );

    // The file holds the record target; the head is above it by the holes.
    let head = number(&json, "journal_head");
    let records = number(&json, "records");
    assert!((9_000..9_500).contains(&records), "{json}");
    assert!(head >= 40_000 + 9_000 - sparse.kept, "{json}");
    assert_eq!(number(&json, "pruned_ranges"), sparse.pruned_ranges, "{json}");
    assert_eq!(number(&json, "retention_floor"), 0, "{json}");
    assert_eq!(number(&json, "checkpoints"), 16, "{json}");
    assert_eq!(number(&json, "roster_cursor"), head, "{json}");
    assert_eq!(number(&json, "roster_agents"), 8, "{json}");
    assert_eq!(number(&json, "roster_rested"), 3, "{json}");
    assert_eq!(number(&json, "history_rested"), 3, "{json}");
    // The History fold crossed the sparse part and stopped behind the head.
    let history_cursor = number(&json, "history_cursor");
    assert!(history_cursor > 40_000 && history_cursor < head - 1_000, "{json}");

    let connection = Connection::open(&report.registry_path).unwrap();
    let (first_start, first_end, first_records): (i64, i64, i64) = connection
        .query_row(
            "SELECT start_sequence, end_sequence, record_count FROM journal_segments
             ORDER BY start_sequence LIMIT 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(first_start, 1, "{json}");
    assert!(first_end - first_start + 1 > first_records * 4, "the first segment has no holes");
    // No removed row is left, and the swapped file is not kept.
    let output: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM session_journal WHERE kind = 'terminal.output'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(output, 0, "{json}");
    drop(connection);
    let previous = crate::workspace_registry::output_cleanup::previous_path(&report.registry_path);
    assert!(!previous.exists(), "the generator left the file that the swap replaced");

    // An owner reads the journal from sequence 0 through the holes.
    let mux = crate::Mux::open_persistent(options.session, crate::SurfaceOptions::default(), &root)
        .unwrap();
    assert!(mux.session_journal_head().unwrap() >= head);
    let mut cursor = 0;
    let mut read = 0;
    loop {
        let page = mux.session_journal_after(cursor, 1_024).unwrap();
        let Some(last) = page.records.last() else { break };
        assert!(last.sequence > cursor, "the read does not move past {cursor}");
        cursor = last.sequence;
        read += page.records.len() as u64;
    }
    assert!(read >= records, "an owner read {read} of {records} records");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(&root).ok();
}

/// `advance_checkpoints` on a generated registry: 500 more records, 16
/// checkpoints above them, no young segment, and the agents and sessions it
/// had.
#[test]
fn advance_checkpoints_moves_the_restore_points_to_the_head() {
    let root = std::env::temp_dir()
        .join(format!("cmux-synth-advance-{}", crate::workspace_registry::new_uuid_v4()));
    let options = ShapeOptions {
        session: "synth-advance".into(),
        records: Some(3_000),
        workspaces: 3,
        agent_terminals: 5,
        rested_agents: 2,
        live_rows: 400,
        seal_age_minutes: 120,
        ..ShapeOptions::default()
    };
    let report = generate_shape(&root, &options).unwrap();
    let before = report.to_json();
    let head = number(&before, "journal_head");

    let advanced = advance_checkpoints(&root, &options, 16, 500).unwrap();
    assert_eq!(number(&advanced, "checkpoints"), 16, "{advanced}");
    assert!(number(&advanced, "appended_through") >= head + 500, "{advanced} after head {head}");
    assert!(
        number(&advanced, "first_checkpoint") > number(&advanced, "appended_through"),
        "{advanced}"
    );
    assert!(number(&advanced, "sealed_through") > number(&advanced, "last_checkpoint"));
    let after = counts(&report.registry_path).unwrap();
    assert!(number(&after, "journal_head") >= head + 500 + 17, "{after}");
    assert!(number(&after, "records") >= number(&before, "records") + 500 + 17, "{after}");
    assert!(number(&after, "checkpoints") >= 16, "{after}");
    assert_eq!(number(&after, "retention_floor"), 0, "{after}");
    for key in ["roster_agents", "roster_rested", "history_rested", "history_sessions"] {
        assert_eq!(after[key], before[key], "{key}: {after}");
    }
    // Sealed: the 400 live rows of the generator are in segments now.
    assert!(number(&after, "live_rows") < 400, "{after}");
    let connection = Connection::open(&report.registry_path).unwrap();
    let young: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM journal_segments WHERE sealed_at_ms > ?1",
            [unix_epoch_ms().unwrap() as i64 - 3_600_000],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(young, 0, "{after}");
    // The trigger is back: a segment row refuses an update.
    let refused = connection.execute("UPDATE journal_segments SET sealed_at_ms = 1", []);
    assert!(refused.is_err(), "a segment row took an update after the advance");
    drop(connection);

    // A second advance has idempotency keys of its own: it seals again.
    let again = advance_checkpoints(&root, &options, 2, 10).unwrap();
    assert!(number(&again, "sealed_through") > number(&advanced, "sealed_through"), "{again}");
    assert!(number(&again, "first_checkpoint") > number(&advanced, "last_checkpoint"), "{again}");

    let mux = crate::Mux::open_persistent(options.session, crate::SurfaceOptions::default(), &root)
        .unwrap();
    assert!(mux.session_journal_head().unwrap() >= number(&after, "journal_head"));
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(&root).ok();
}
