use super::*;

fn append_probe(registry: &mut WorkspaceRegistry, index: usize) -> u64 {
    let producer = JournalProducer { kind: "test".into(), id: "salvage".into() };
    let subjects = [JournalSubject { kind: "session".into(), id: "salvage".into() }];
    let event_id = format!("event_salvage_probe_{index}");
    let db = registry.connection.get();
    let tx = db.unchecked_transaction().unwrap();
    let sequence = append_journal_record(
        &tx,
        &JournalAppend {
            event_id: &event_id,
            schema_version: 1,
            kind: "test.salvage.probe",
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            occurred_at_ms: 1,
            producer: &producer,
            authority: None,
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: &subjects,
            sensitivity: JournalSensitivity::Metadata,
            payload: &serde_json::json!({ "index": index }),
            content: None,
            resource_revision: None,
            previous_resource_revision: None,
            actor: None,
        },
    )
    .unwrap();
    tx.commit().unwrap();
    sequence
}

/// Read everything after `sequence` the way a startup fold does.
fn salvage_all(
    registry: &WorkspaceRegistry,
    mut sequence: u64,
    limit: usize,
) -> (Vec<u64>, Vec<SkippedJournalRange>) {
    let mut records = Vec::new();
    let mut skipped = Vec::new();
    loop {
        match registry.session_journal_after_salvaging(sequence, limit).unwrap() {
            SalvagedJournalPage::Page(page) => {
                if page.records.is_empty() {
                    return (records, skipped);
                }
                for record in page.records {
                    sequence = record.sequence;
                    records.push(record.sequence);
                }
            }
            SalvagedJournalPage::Skipped(skip) => {
                sequence = skip.end_sequence;
                skipped.push(skip);
            }
        }
    }
}

#[test]
fn an_undecodable_active_row_is_skipped_alone_and_every_other_row_is_kept() {
    let root = std::env::temp_dir().join(format!("cmux-journal-salvage-row-{}", new_uuid_v4()));
    let mut registry = WorkspaceRegistry::open(&root, "journal-salvage-row").unwrap();
    let start = registry.session_journal_head().unwrap();
    let sequences = (0..6).map(|index| append_probe(&mut registry, index)).collect::<Vec<_>>();
    let bad = sequences[2];
    registry
        .connection
        .get()
        .execute_batch(
            "PRAGMA ignore_check_constraints=ON;
                 DROP TRIGGER IF EXISTS session_journal_reject_update;",
        )
        .unwrap();
    registry
        .connection
        .get()
        .execute(
            "UPDATE session_journal SET class = 'unknown' WHERE sequence = ?1",
            params![i64::try_from(bad).unwrap()],
        )
        .unwrap();

    assert!(registry.session_journal_after(start, 512).is_err());
    for limit in [1, 2, 512] {
        let (records, skipped) = salvage_all(&registry, start, limit);
        let expected =
            sequences.iter().copied().filter(|sequence| *sequence != bad).collect::<Vec<_>>();
        assert_eq!(records, expected, "page limit {limit}");
        assert_eq!(skipped.len(), 1, "page limit {limit}");
        assert_eq!((skipped[0].start_sequence, skipped[0].end_sequence), (bad, bad));
        assert_eq!(skipped[0].segment_id, None);
        assert_eq!(skipped[0].reason, UNDECODABLE_ROW);
    }
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
