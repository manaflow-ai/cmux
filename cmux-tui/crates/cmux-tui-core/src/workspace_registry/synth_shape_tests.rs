use super::*;

fn number(counts: &Value, key: &str) -> u64 {
    counts[key].as_u64().unwrap_or_else(|| panic!("{key} is not a number in {counts}"))
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
    assert!(number(&json, "roster_agents") > 0, "{json}");
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

    let mux = crate::Mux::open_persistent(
        options.session.clone(),
        crate::SurfaceOptions::default(),
        &root,
    )
    .unwrap();
    assert!(mux.session_journal_head().unwrap() >= head);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(&root).ok();
}
