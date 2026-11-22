use super::*;

#[test]
fn resource_record_is_typed_scoped_and_append_only() {
    let mut registry = WorkspaceRegistry::in_memory("journal").unwrap();
    let workspace_id = format!("ws_{}", "1".repeat(32));
    let pane_id = format!("pane_{}", "2".repeat(32));
    let result = serde_json::json!({"workspace_id":workspace_id});
    let changes = serde_json::json!([{
        "kind":"upsert",
        "resource":"pane",
        "id":pane_id,
        "value":{"workspace_id":workspace_id,"pane_id":pane_id}
    }]);
    let tx = registry.connection.transaction().unwrap();
    tx.execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", []).unwrap();
    append_resource_journal_record(
        &tx,
        1,
        0,
        "test-client",
        "focus-one",
        "pane.focus",
        None,
        &result,
        &changes,
    )
    .unwrap();
    tx.commit().unwrap();

    let page = registry.session_journal_after(0, 10).unwrap();
    assert_eq!(page.head_sequence, 1);
    assert_eq!(page.records.len(), 1);
    let record = &page.records[0];
    assert_eq!(record.kind, "pane.focus");
    assert_eq!(record.class, JournalClass::State);
    assert_eq!(record.replay, JournalReplayPolicy::Required);
    assert_eq!(record.correlation_id.as_deref(), Some("focus-one"));
    assert_eq!(record.resource_revision, Some(1));
    assert_eq!(record.previous_resource_revision, Some(0));
    assert!(
        record
            .subjects
            .iter()
            .any(|subject| { subject.kind == "workspace" && subject.id == workspace_id })
    );
    assert!(record.subjects.iter().any(|subject| subject.kind == "pane" && subject.id == pane_id));
    let indexed = registry
        .connection
        .query_row(
            "SELECT COUNT(*) FROM journal_subject_index
                 WHERE kind = 'pane' AND id = ?1 AND sequence = 1",
            [&pane_id],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(indexed, 1);

    let update = registry
        .connection
        .execute("UPDATE session_journal SET kind = 'pane.changed' WHERE sequence = 1", []);
    assert!(update.unwrap_err().to_string().contains("append-only"));
    let delete = registry.connection.execute("DELETE FROM session_journal", []);
    assert!(delete.unwrap_err().to_string().contains("append-only"));
    let delete_index = registry.connection.execute("DELETE FROM journal_subject_index", []);
    assert!(delete_index.unwrap_err().to_string().contains("append-only"));
}

#[test]
fn migration_marks_incomplete_history_and_preserves_retained_events() {
    let mut registry = WorkspaceRegistry::in_memory("migration").unwrap();
    let tx = registry.connection.transaction().unwrap();
    tx.execute_batch(
        "DROP TABLE session_journal;
             CREATE TABLE resource_events (
               revision INTEGER PRIMARY KEY NOT NULL,
               previous_revision INTEGER NOT NULL,
               origin TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               deltas_json TEXT NOT NULL
             );
             UPDATE meta SET value = '4' WHERE key = 'resource_revision';",
    )
    .unwrap();
    let result = serde_json::json!({"focused":true});
    tx.execute(
        "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES('test', 'focus-four', 'pane.focus', '{}', ?1, 4)",
        [canonical_json(&result).unwrap()],
    )
    .unwrap();
    tx.execute(
        "INSERT INTO resource_events(
               revision, previous_revision, origin, idempotency_key, deltas_json
             ) VALUES(4, 3, 'test', 'focus-four', '[]')",
        [],
    )
    .unwrap();
    migrate_resource_events_to_session_journal(&tx).unwrap();
    tx.commit().unwrap();

    let page = registry.session_journal_after(0, 10).unwrap();
    assert_eq!(page.records.len(), 2);
    assert_eq!(page.records[0].kind, "session.journal.migrated");
    assert_eq!(page.records[0].payload["history_complete"], false);
    assert_eq!(page.records[1].kind, "pane.focus");
    assert_eq!(page.records[1].resource_revision, Some(4));
    assert_eq!(registry.resource_events_after(3).unwrap().batches.len(), 1);
}

#[test]
fn migration_marks_projection_only_legacy_history_incomplete() {
    let mut registry = WorkspaceRegistry::in_memory("projection-only-migration").unwrap();
    let tx = registry.connection.transaction().unwrap();
    tx.execute_batch(
        "DROP TABLE session_journal;
             UPDATE meta SET value = '7' WHERE key = 'resource_revision';",
    )
    .unwrap();
    migrate_resource_events_to_session_journal(&tx).unwrap();
    tx.commit().unwrap();

    let page = registry.session_journal_after(0, 10).unwrap();
    assert_eq!(page.records.len(), 1);
    assert_eq!(page.records[0].kind, "session.journal.migrated");
    assert_eq!(page.records[0].payload["source"], "projection_only");
    assert_eq!(page.records[0].payload["resource_head_revision"], "7");
    assert_eq!(page.records[0].payload["history_complete"], false);
}

#[test]
fn journal_cursor_and_page_limits_fail_closed() {
    let registry = WorkspaceRegistry::in_memory("limits").unwrap();
    assert_eq!(registry.session_journal_head().unwrap(), 0);
    assert!(registry.session_journal_after(1, 1).unwrap_err().to_string().contains("ahead"));
    assert!(registry.session_journal_after(0, 0).unwrap_err().to_string().contains("positive"));
    assert!(
        registry
            .session_journal_after(0, MAX_JOURNAL_PAGE_SIZE + 1)
            .unwrap_err()
            .to_string()
            .contains("exceeds")
    );
}

#[test]
fn persistent_reader_observes_commits_on_an_independent_connection() {
    let root = std::env::temp_dir().join(format!("cmux-journal-reader-{}", new_uuid_v4()));
    let mut registry = WorkspaceRegistry::open(&root, "reader").unwrap();
    let database_path = registry.session_journal_database_path().unwrap();
    let reader = SessionJournalReader::open(&database_path).unwrap();
    assert_eq!(reader.after(0, 1).unwrap().head_sequence, 0);

    let workspace_id = format!("ws_{}", "1".repeat(32));
    let result = serde_json::json!({"workspace_id":workspace_id});
    let tx = registry.connection.transaction().unwrap();
    tx.execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", []).unwrap();
    append_resource_journal_record(
        &tx,
        1,
        0,
        "reader-test",
        "reader-commit",
        "workspace.focus",
        None,
        &result,
        &serde_json::json!([]),
    )
    .unwrap();
    tx.commit().unwrap();

    assert_eq!(registry.session_journal_head().unwrap(), 1);
    let page = reader.after(0, 1).unwrap();
    assert_eq!(page.head_sequence, 1);
    assert_eq!(page.records[0].kind, "workspace.focus");
    let matching = reader
        .after_subjects(0, 1, &[JournalSubject { kind: "workspace".into(), id: workspace_id }])
        .unwrap();
    assert_eq!(matching.scanned_through, 1);
    assert_eq!(matching.records.len(), 1);
    let absent = reader
        .after_subjects(
            0,
            1,
            &[JournalSubject { kind: "agent_tree".into(), id: "agenttree_absent".into() }],
        )
        .unwrap();
    assert_eq!(absent.scanned_through, 1);
    assert!(absent.records.is_empty());
    drop(reader);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn archived_segment_metadata_is_verified_before_replay() {
    let mut registry = WorkspaceRegistry::in_memory("segment-integrity").unwrap();
    let result = serde_json::json!({"focused":true});
    let tx = registry.connection.transaction().unwrap();
    tx.execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", []).unwrap();
    append_resource_journal_record(
        &tx,
        1,
        0,
        "segment-test",
        "segment-record-1",
        "pane.focus",
        None,
        &result,
        &serde_json::json!([]),
    )
    .unwrap();
    tx.commit().unwrap();

    let records = registry.session_journal_after(0, 10).unwrap().records;
    let uncompressed = serde_json::to_vec(&records).unwrap();
    let digest = Sha256::digest(&uncompressed);
    let mut encoder =
        flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
    encoder.write_all(&uncompressed).unwrap();
    let compressed = encoder.finish().unwrap();
    registry
        .connection
        .execute(
            "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms
                 ) VALUES('segment_bad_metadata', 1, 1, 2, 'gzip-json-v1', ?1, ?2, ?3, 1)",
            params![compressed, i64::try_from(uncompressed.len()).unwrap(), digest.as_slice()],
        )
        .unwrap();
    registry
        .connection
        .execute_batch(
            "DROP TRIGGER session_journal_reject_delete;
                 DELETE FROM session_journal;
                 CREATE TRIGGER session_journal_reject_delete
                   BEFORE DELETE ON session_journal
                 BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;",
        )
        .unwrap();

    let error = registry.session_journal_after(0, 10).unwrap_err();
    assert!(error.to_string().contains("record count"), "{error:#}");
}

#[test]
fn archived_segment_rejects_trailing_compressed_data() {
    let mut trailing_encoder =
        flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
    trailing_encoder.write_all(b"ignored").unwrap();
    let trailing_member = trailing_encoder.finish().unwrap();
    let variants = [("gzip member", trailing_member), ("non-gzip bytes", b"trailing".to_vec())];

    for (label, suffix) in variants {
        let mut registry = WorkspaceRegistry::in_memory("segment-trailing").unwrap();
        let result = serde_json::json!({"focused":true});
        let tx = registry.connection.transaction().unwrap();
        tx.execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", []).unwrap();
        append_resource_journal_record(
            &tx,
            1,
            0,
            "segment-test",
            "segment-record-1",
            "pane.focus",
            None,
            &result,
            &serde_json::json!([]),
        )
        .unwrap();
        tx.commit().unwrap();

        let records = registry.session_journal_after(0, 10).unwrap().records;
        let uncompressed = serde_json::to_vec(&records).unwrap();
        let digest = Sha256::digest(&uncompressed);
        let mut encoder =
            flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
        encoder.write_all(&uncompressed).unwrap();
        let mut compressed = encoder.finish().unwrap();
        compressed.extend_from_slice(&suffix);
        registry
            .connection
            .execute(
                "INSERT INTO journal_segments(
                       segment_id, start_sequence, end_sequence, record_count, codec, content,
                       uncompressed_bytes, sha256, sealed_at_ms
                     ) VALUES(?1, 1, 1, 1, 'gzip-json-v1', ?2, ?3, ?4, 1)",
                params![
                    format!("segment_bad_trailing_{label}"),
                    compressed,
                    i64::try_from(uncompressed.len()).unwrap(),
                    digest.as_slice()
                ],
            )
            .unwrap();
        registry
            .connection
            .execute_batch(
                "DROP TRIGGER session_journal_reject_delete;
                     DELETE FROM session_journal;
                     CREATE TRIGGER session_journal_reject_delete
                       BEFORE DELETE ON session_journal
                     BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;",
            )
            .unwrap();

        let error = registry.session_journal_after(0, 10).unwrap_err();
        assert!(error.to_string().contains("trailing compressed data"), "{label}: {error:#}");
    }
}

#[test]
fn restore_cursor_decodes_a_multi_page_segment_once() {
    let root = std::env::temp_dir().join(format!("cmux-journal-cursor-{}", new_uuid_v4()));
    let mut registry = WorkspaceRegistry::open(&root, "cursor").unwrap();
    let workspace_id = format!("ws_{}", "1".repeat(32));
    for sequence in 1..=4 {
        let tx = registry.connection.transaction().unwrap();
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [sequence.to_string()],
        )
        .unwrap();
        append_resource_journal_record(
            &tx,
            sequence,
            sequence - 1,
            "cursor-test",
            &format!("cursor-event-{sequence}"),
            "workspace.focus",
            None,
            &serde_json::json!({"workspace_id":workspace_id}),
            &serde_json::json!([]),
        )
        .unwrap();
        tx.commit().unwrap();
    }

    let records = registry.session_journal_after(0, 10).unwrap().records;
    let uncompressed = serde_json::to_vec(&records).unwrap();
    let digest = Sha256::digest(&uncompressed);
    let mut encoder =
        flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
    encoder.write_all(&uncompressed).unwrap();
    let compressed = encoder.finish().unwrap();
    registry
        .connection
        .execute(
            "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms
                 ) VALUES('cursor-segment', 1, 4, 4, 'gzip-json-v1', ?1, ?2, ?3, 1)",
            params![compressed, i64::try_from(uncompressed.len()).unwrap(), digest.as_slice()],
        )
        .unwrap();
    registry
        .connection
        .execute_batch(
            "DROP TRIGGER session_journal_reject_delete;
                 DELETE FROM session_journal;
                 CREATE TRIGGER session_journal_reject_delete
                   BEFORE DELETE ON session_journal
                 BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;",
        )
        .unwrap();

    let reader =
        SessionJournalReader::open(&registry.session_journal_database_path().unwrap()).unwrap();
    let mut cursor = reader.restore_cursor(0).unwrap();
    assert!(!cursor.segments_exhausted);
    assert_eq!(cursor.segment_content_load_count, 0);
    let mut replayed = Vec::new();
    loop {
        let page = cursor.next_page(1).unwrap();
        if page.records.is_empty() {
            assert_eq!(page.head_sequence, 4);
            break;
        }
        replayed.extend(page.records.into_iter().map(|record| record.sequence));
    }
    assert_eq!(cursor.segment_decode_count, 1);
    assert_eq!(cursor.segment_content_load_count, 1);
    cursor.finish().unwrap();
    assert_eq!(replayed, [1, 2, 3, 4]);

    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
