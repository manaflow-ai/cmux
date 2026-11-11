use super::*;

#[test]
fn resource_record_is_typed_scoped_and_append_only() {
    let registry = WorkspaceRegistry::in_memory("journal").unwrap();
    let workspace_id = format!("ws_{}", "1".repeat(32));
    let pane_id = format!("pane_{}", "2".repeat(32));
    let result = serde_json::json!({"workspace_id":workspace_id});
    let changes = serde_json::json!([{
        "kind":"upsert",
        "resource":"pane",
        "id":pane_id,
        "value":{"workspace_id":workspace_id,"pane_id":pane_id}
    }]);
    let db = registry.connection.get();
    let tx = db.unchecked_transaction().unwrap();
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
        .get()
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
        .get()
        .execute("UPDATE session_journal SET kind = 'pane.changed' WHERE sequence = 1", []);
    assert!(update.unwrap_err().to_string().contains("append-only"));
    let delete = registry.connection.get().execute("DELETE FROM session_journal", []);
    assert!(delete.unwrap_err().to_string().contains("append-only"));
    let delete_index = registry.connection.get().execute("DELETE FROM journal_subject_index", []);
    assert!(delete_index.unwrap_err().to_string().contains("append-only"));
}

#[test]
fn migration_marks_incomplete_history_and_preserves_retained_events() {
    let registry = WorkspaceRegistry::in_memory("migration").unwrap();
    let db = registry.connection.get();
    let tx = db.unchecked_transaction().unwrap();
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
    let registry = WorkspaceRegistry::in_memory("projection-only-migration").unwrap();
    let db = registry.connection.get();
    let tx = db.unchecked_transaction().unwrap();
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
    let registry = WorkspaceRegistry::open(&root, "reader").unwrap();
    let database_path = registry.session_journal_database_path().unwrap();
    let reader = SessionJournalReader::open(&database_path).unwrap();
    assert_eq!(reader.after(0, 1).unwrap().head_sequence, 0);

    let workspace_id = format!("ws_{}", "1".repeat(32));
    let result = serde_json::json!({"workspace_id":workspace_id});
    let db = registry.connection.get();
    let tx = db.unchecked_transaction().unwrap();
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
    drop(db);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// Registry connections keep their statements compiled
/// (`REGISTRY_STATEMENT_CACHE_CAPACITY`). A reused statement must read the
/// latest commit, never the snapshot of its previous run: a long-lived
/// reader (the fanout's, the roster's) and the writer each run the same
/// statements again after every commit here.
#[test]
fn reused_statements_read_every_later_commit() {
    let root = std::env::temp_dir().join(format!("cmux-journal-cached-{}", new_uuid_v4()));
    let registry = WorkspaceRegistry::open(&root, "cached").unwrap();
    let database_path = registry.session_journal_database_path().unwrap();
    let reader = SessionJournalReader::open(&database_path).unwrap();
    let workspace_id = format!("ws_{}", "2".repeat(32));
    let result = serde_json::json!({"workspace_id":workspace_id});
    for revision in 1..=6_u64 {
        let db = registry.connection.get();
        let tx = db.unchecked_transaction().unwrap();
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )
        .unwrap();
        append_resource_journal_record(
            &tx,
            revision,
            revision - 1,
            "cached-test",
            &format!("cached-commit-{revision}"),
            if revision % 2 == 0 { "workspace.focus" } else { "workspace.rename" },
            None,
            &result,
            &serde_json::json!([]),
        )
        .unwrap();
        tx.commit().unwrap();
        drop(db);

        assert_eq!(registry.session_journal_head().unwrap(), revision);
        assert_eq!(reader.head().unwrap(), revision);
        let page = reader.after(revision - 1, 10).unwrap();
        assert_eq!(page.head_sequence, revision);
        assert_eq!(
            page.records.iter().map(|record| record.sequence).collect::<Vec<_>>(),
            [revision]
        );
        let (focused, reached) =
            reader.kinds_after(0, revision, |kind| kind == "workspace.focus", 100).unwrap();
        assert_eq!(reached, revision);
        assert_eq!(
            focused.iter().map(|record| record.sequence).collect::<Vec<_>>(),
            (1..=revision).filter(|sequence| sequence % 2 == 0).collect::<Vec<_>>(),
            "the kind read after commit {revision}"
        );
    }
    drop(reader);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn archived_segment_metadata_is_verified_before_replay() {
    let registry = WorkspaceRegistry::in_memory("segment-integrity").unwrap();
    let result = serde_json::json!({"focused":true});
    let db = registry.connection.get();
    let tx = db.unchecked_transaction().unwrap();
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
        .get()
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
        .get()
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
        let registry = WorkspaceRegistry::in_memory("segment-trailing").unwrap();
        let result = serde_json::json!({"focused":true});
        let db = registry.connection.get();
        let tx = db.unchecked_transaction().unwrap();
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
            .get()
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
            .get()
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
    let registry = WorkspaceRegistry::open(&root, "cursor").unwrap();
    let workspace_id = format!("ws_{}", "1".repeat(32));
    for sequence in 1..=4 {
        let db = registry.connection.get();
        let tx = db.unchecked_transaction().unwrap();
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
        .get()
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
        .get()
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

/// A registry whose whole journal is `segments` sealed segments of
/// `JOURNAL_SEGMENT_RECORD_LIMIT` records, the shape of a nightly registry
/// that ran for weeks: two of every three records are terminal output of
/// `output_bytes` each, the rest an agent kind the roster folds (of a test
/// producer, so its fold changes nothing), so a roster replay inflates every
/// segment. Returns the registry and the non-output sequences.
pub(crate) fn output_heavy_sealed_registry(
    segments: u64,
    output_bytes: usize,
) -> (WorkspaceRegistry, Vec<u64>) {
    let per_segment = u64::try_from(journal_extensions::JOURNAL_SEGMENT_RECORD_LIMIT).unwrap();
    sealed_registry_of(segments, per_segment, output_bytes)
}

/// [`output_heavy_sealed_registry`] with `per_segment` records a segment:
/// a few makes the sparse segments output cleanup leaves behind.
pub(crate) fn sealed_registry_of(
    segments: u64,
    per_segment: u64,
    output_bytes: usize,
) -> (WorkspaceRegistry, Vec<u64>) {
    let registry = WorkspaceRegistry::in_memory("journal-output-heavy").unwrap();
    let expected = fill_sealed_registry(&registry, segments, per_segment, output_bytes);
    (registry, expected)
}

/// Replaces `registry`'s journal with [`sealed_registry_of`]'s segments;
/// returns the non-output sequences.
pub(crate) fn fill_sealed_registry(
    registry: &WorkspaceRegistry,
    segments: u64,
    per_segment: u64,
    output_bytes: usize,
) -> Vec<u64> {
    use std::io::Write as _;
    registry
        .connection
        .get()
        .execute_batch(
            "DROP TRIGGER session_journal_reject_delete;
             DELETE FROM session_journal;
             CREATE TRIGGER session_journal_reject_delete
               BEFORE DELETE ON session_journal
             BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;",
        )
        .unwrap();
    let mut state = 0x2545_f491_u64;
    let mut expected = Vec::new();
    for segment in 0..segments {
        let start = segment * per_segment + 1;
        let end = start + per_segment - 1;
        let mut records = Vec::new();
        let mut kinds = BTreeSet::new();
        for sequence in start..=end {
            let output = sequence % 3 != 0;
            let kind = if output { "terminal.output" } else { "agent.test.noop" };
            let payload = if output {
                // Printable pseudo-random bytes, so gzip works about as hard
                // as it does on real terminal output.
                let bytes = (0..output_bytes)
                    .map(|_| {
                        state ^= state << 13;
                        state ^= state >> 7;
                        state ^= state << 17;
                        b' ' + u8::try_from(state % 95).unwrap()
                    })
                    .collect::<Vec<_>>();
                let offset = (sequence - 1) * u64::try_from(output_bytes).unwrap();
                serde_json::json!({
                    "format": "cmux.terminal-output.v1",
                    "encoding": "base64",
                    "data": base64::engine::general_purpose::STANDARD.encode(&bytes),
                    "byte_count": bytes.len().to_string(),
                    "stream_offset_start": offset.to_string(),
                    "stream_offset_end": (offset + u64::try_from(bytes.len()).unwrap()).to_string(),
                    "sha256": encode_bytes_hex(Sha256::digest(&bytes).as_slice()),
                })
            } else {
                expected.push(sequence);
                serde_json::json!({"workspace_id": format!("ws_{sequence:032x}")})
            };
            kinds.insert(kind);
            records.push(SessionJournalRecord {
                sequence,
                event_id: format!("event_{sequence}"),
                schema_version: 1,
                kind: kind.into(),
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Advisory,
                occurred_at_ms: sequence,
                committed_at_ms: sequence,
                producer: JournalProducer { kind: "test".into(), id: "test".into() },
                authority: None,
                causation_id: None,
                correlation_id: None,
                causation_depth: 0,
                subjects: Vec::new(),
                sensitivity: JournalSensitivity::Metadata,
                payload,
                resource_revision: None,
                previous_resource_revision: None,
                terminal_output: None,
            });
        }
        let uncompressed = serde_json::to_vec(&records).unwrap();
        let digest = Sha256::digest(&uncompressed);
        let mut encoder =
            flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
        encoder.write_all(&uncompressed).unwrap();
        let compressed = encoder.finish().unwrap();
        let segment_id = format!("segment_{start}_{end}");
        let db = registry.connection.get();
        db.execute(
            "INSERT INTO journal_segments(
               segment_id, start_sequence, end_sequence, record_count, codec, content,
               uncompressed_bytes, sha256, sealed_at_ms
             ) VALUES(?1, ?2, ?3, ?4, 'gzip-json-v1', ?5, ?6, ?7, 1)",
            params![
                segment_id,
                i64::try_from(start).unwrap(),
                i64::try_from(end).unwrap(),
                i64::try_from(per_segment).unwrap(),
                compressed,
                i64::try_from(uncompressed.len()).unwrap(),
                digest.as_slice()
            ],
        )
        .unwrap();
        for kind in kinds {
            db.execute(
                "INSERT INTO journal_segment_kinds(segment_id, kind) VALUES(?1, ?2)",
                params![segment_id, kind],
            )
            .unwrap();
        }
    }
    expected
}

/// A kind backfill an older build stopped partway (marker `0`) resumes after
/// the last segment it finished: segments at or before that progress are not
/// decoded again, a partly mapped one gets its missing kinds, and the run
/// ends with the marker at `1` and no progress row.
#[test]
fn a_stopped_kind_backfill_resumes_after_its_last_finished_segment() {
    let (registry, _) = output_heavy_sealed_registry(4, 64);
    let db = registry.connection.get();
    db.execute_batch(
        "DELETE FROM journal_segment_kinds
         WHERE segment_id IN ('segment_2049_3072', 'segment_3073_4096');
         INSERT INTO journal_segment_kinds VALUES('segment_2049_3072', 'agent.test.noop');
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill', '0')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill_through', '1025')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         DROP TRIGGER IF EXISTS journal_segments_reject_update;
         UPDATE journal_segments SET content = x'00112233'
         WHERE segment_id IN ('segment_1_1024', 'segment_1025_2048');",
    )
    .unwrap();
    // The two finished segments no longer decode: a backfill that decoded
    // them again would fail here.
    backfill_legacy_journal_segment_kinds(&db).unwrap();
    for segment_id in ["segment_2049_3072", "segment_3073_4096"] {
        let kinds = db
            .prepare("SELECT kind FROM journal_segment_kinds WHERE segment_id = ?1 ORDER BY kind")
            .unwrap()
            .query_map([segment_id], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(kinds, ["agent.test.noop", "terminal.output"], "{segment_id}");
    }
    let marker: String = db
        .query_row(
            "SELECT value FROM meta WHERE key = 'journal_segment_kinds_backfill'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(marker, "1");
    let progress: Option<String> = db
        .query_row(
            "SELECT value FROM meta WHERE key = 'journal_segment_kinds_backfill_through'",
            [],
            |row| row.get(0),
        )
        .optional()
        .unwrap();
    assert_eq!(progress, None);
}

/// #39096 review F2: this build's backfill (marker `2`) stopped, an older
/// build ran next (a downgrade), kept the marker and stopped partway through
/// a segment, mapping only some of its kinds. Back on this build, the
/// partly mapped segment is decoded again and gets its missing kinds; the
/// segments this build finished before the downgrade, and one sealed with its
/// map after the backfill began, are not decoded again.
#[test]
fn a_kind_backfill_after_a_downgrade_maps_the_segment_an_older_build_left_partly_mapped() {
    let (registry, _) = output_heavy_sealed_registry(5, 64);
    let db = registry.connection.get();
    db.execute_batch(
        "DELETE FROM journal_segment_kinds
         WHERE segment_id IN ('segment_2049_3072', 'segment_3073_4096');
         INSERT INTO journal_segment_kinds VALUES('segment_2049_3072', 'agent.test.noop');
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill', '2')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill_through', '1025')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill_end', '3073')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         DROP TRIGGER IF EXISTS journal_segments_reject_update;
         UPDATE journal_segments SET content = x'00112233'
         WHERE segment_id IN ('segment_1_1024', 'segment_1025_2048', 'segment_4097_5120');",
    )
    .unwrap();
    // The finished segments and the one sealed later no longer decode: a
    // backfill that decoded them again would fail here.
    backfill_legacy_journal_segment_kinds(&db).unwrap();
    for segment_id in ["segment_2049_3072", "segment_3073_4096"] {
        let kinds = db
            .prepare("SELECT kind FROM journal_segment_kinds WHERE segment_id = ?1 ORDER BY kind")
            .unwrap()
            .query_map([segment_id], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(kinds, ["agent.test.noop", "terminal.output"], "{segment_id}");
    }
    let marker: String = db
        .query_row(
            "SELECT value FROM meta WHERE key = 'journal_segment_kinds_backfill'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(marker, "1");
    let left: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM meta WHERE key IN (
               'journal_segment_kinds_backfill_through', 'journal_segment_kinds_backfill_end'
             )",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(left, 0);
}

/// #39096 router review F2: this build's backfill (marker `2`) stopped, an
/// older build ran next and stopped partway through a segment, and an older
/// build's next start mapped only the unmapped segments and set the marker
/// to `1`. The progress rows this build left show its run never finished, so
/// back on this build the `1` is not trusted: the segment left partly mapped
/// is decoded again, the finished ones and one sealed later are not.
#[test]
fn a_kind_backfill_an_older_build_marked_done_over_a_partly_mapped_segment_is_redone() {
    let (registry, _) = output_heavy_sealed_registry(5, 64);
    let db = registry.connection.get();
    db.execute_batch(
        "DELETE FROM journal_segment_kinds WHERE segment_id = 'segment_2049_3072';
         INSERT INTO journal_segment_kinds VALUES('segment_2049_3072', 'agent.test.noop');
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill', '1')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill_through', '1025')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill_end', '3073')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         DROP TRIGGER IF EXISTS journal_segments_reject_update;
         UPDATE journal_segments SET content = x'00112233'
         WHERE segment_id IN ('segment_1_1024', 'segment_1025_2048', 'segment_4097_5120');",
    )
    .unwrap();
    backfill_legacy_journal_segment_kinds(&db).unwrap();
    let kinds = db
        .prepare("SELECT kind FROM journal_segment_kinds WHERE segment_id = ?1 ORDER BY kind")
        .unwrap()
        .query_map(["segment_2049_3072"], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(kinds, ["agent.test.noop", "terminal.output"]);
    let left: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM meta WHERE key IN (
               'journal_segment_kinds_backfill_through', 'journal_segment_kinds_backfill_end'
             )",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(left, 0);
    // A finished backfill is trusted again: nothing is decoded.
    backfill_legacy_journal_segment_kinds(&db).unwrap();
}

/// #39096 review (start budget): the first kind-scoped read of a registry whose
/// legacy kind backfill has not finished ran the whole backfill before it
/// returned, decoding every unmapped segment: on a large registry, minutes
/// inside the start's 1 s roster budget. One call now decodes for a bounded
/// slice; the read takes the full-decode path for segments still unmapped,
/// returns the same records, and the backfill finishes across later reads.
#[test]
fn a_kind_read_runs_a_bounded_slice_of_an_unfinished_kind_backfill() {
    let segments = 8;
    let (registry, expected) = output_heavy_sealed_registry(segments, 64);
    let head = registry.session_journal_head().unwrap();
    let db = registry.connection.get();
    db.execute_batch(
        "DELETE FROM journal_segment_kinds;
         DELETE FROM meta WHERE key LIKE 'journal_segment_kinds_backfill%';",
    )
    .unwrap();
    drop(db);
    let mapped = |registry: &WorkspaceRegistry| -> i64 {
        registry
            .connection
            .get()
            .query_row("SELECT COUNT(DISTINCT segment_id) FROM journal_segment_kinds", [], |row| {
                row.get(0)
            })
            .unwrap()
    };
    let kinds: kind_read::JournalKinds = |kind| kind == "agent.test.noop";
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(Some(std::time::Duration::ZERO)));
    let started = std::time::Instant::now();
    let (first, mut cursor) = registry.session_journal_kinds_after(0, head, kinds, 512).unwrap();
    let first_call = started.elapsed();
    assert_eq!(mapped(&registry), 1, "one call maps one segment with a zero slice");
    let mut seen = first.iter().map(|record| record.sequence).collect::<Vec<_>>();
    let mut calls = 1;
    while cursor < head {
        let (records, reached) =
            registry.session_journal_kinds_after(cursor, head, kinds, 512).unwrap();
        assert!(reached > cursor, "each page makes progress");
        seen.extend(records.iter().map(|record| record.sequence));
        cursor = reached;
        calls += 1;
    }
    let total = started.elapsed();
    eprintln!(
        "bounded kind backfill: {segments} unmapped segments; first read {} ms, \
         all {calls} reads {} ms",
        first_call.as_millis(),
        total.as_millis()
    );
    assert_eq!(seen, expected, "the full-decode path returns the same records");
    // A read can pass a segment the backfill has not mapped yet (it decodes
    // that one whole); each later call maps one more.
    for _ in 0..segments {
        registry.session_journal_kinds_after(0, head, kinds, 1).unwrap();
    }
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(None));
    assert_eq!(mapped(&registry), i64::try_from(segments).unwrap(), "the backfill finished");
}

/// router-review on #39096 at 498cf0f: while the kind backfill was
/// unfinished, a kind read met an unmapped segment and fell back to the
/// legacy read of up to `limit` records of every kind, terminal output
/// included. Over sparse segments (output cleanup leaves a few records in
/// each) that decoded up to `limit` whole segments in one call, and a kind
/// read over mapped segments decoded every segment holding a match until it
/// had `limit` records, all before the replay's next deadline check.
/// A read now decodes the segments of one slice (one batch at least, one
/// unmapped segment at most) and returns the cursor it reached; later reads
/// return the rest.
#[test]
fn a_kind_read_over_many_sparse_sealed_segments_decodes_one_slice() {
    let (segments, per_segment) = (64_u64, 12_u64);
    let (registry, expected) = sealed_registry_of(segments, per_segment, 64);
    let head = registry.session_journal_head().unwrap();
    registry
        .connection
        .get()
        .execute_batch(
            "DELETE FROM journal_segment_kinds;
             DELETE FROM meta WHERE key LIKE 'journal_segment_kinds_backfill%';",
        )
        .unwrap();
    let kinds: kind_read::JournalKinds = |kind| kind == "agent.test.noop";
    let read_all = |registry: &WorkspaceRegistry, first_bound: u64| {
        let (first, mut cursor) =
            registry.session_journal_kinds_after(0, head, kinds, 512).unwrap();
        assert!(
            cursor <= first_bound,
            "the first read decodes one slice: it reached {cursor}, past {first_bound}"
        );
        let mut seen = first.iter().map(|record| record.sequence).collect::<Vec<_>>();
        while cursor < head {
            let (records, reached) =
                registry.session_journal_kinds_after(cursor, head, kinds, 512).unwrap();
            assert!(reached > cursor, "each read makes progress");
            seen.extend(records.iter().map(|record| record.sequence));
            cursor = reached;
        }
        assert_eq!(seen, expected, "the reads return every record of the kinds, once");
    };
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(Some(std::time::Duration::ZERO)));
    kind_read::SEGMENT_DECODE_WORKERS.with(|workers| workers.set(Some(2)));
    // Unmapped: each call's backfill maps one segment, and the read decodes
    // at most that one and the first unmapped segment after it.
    read_all(&registry, 2 * per_segment);
    // A full slice maps the rest (64 small segments).
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(None));
    registry.session_journal_kinds_after(0, head, kinds, 1).unwrap();
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(Some(std::time::Duration::ZERO)));
    let unmapped: i64 = registry
        .connection
        .get()
        .query_row(
            "SELECT COUNT(*) FROM journal_segments WHERE segment_id NOT IN
               (SELECT segment_id FROM journal_segment_kinds)",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(unmapped, 0, "the backfill finished");
    // Mapped: one batch of two segments.
    read_all(&registry, 2 * per_segment);
    kind_read::SEGMENT_DECODE_WORKERS.with(|workers| workers.set(None));
    BACKFILL_SLICE_FOR_TEST.with(|slice| slice.set(None));
}

/// router-review on #39096 at b9e8947 (F1): the roster's background replay
/// reads through the read-only reader, where the kind backfill cannot run.
/// After a downgrade (this build's run recorded its progress, then an older
/// build mapped the rest one kind at a time and stopped), a segment past
/// that progress can have a kind map without its agent kind. The read
/// trusted the map, skipped the segment, and the replay saved its cursor
/// past those records for good. A map the backfill has not proven whole is
/// not trusted: the segment is decoded, one per page.
#[test]
fn a_read_only_kind_read_decodes_a_segment_whose_map_is_not_proven_whole() {
    let root = std::env::temp_dir().join(format!("cmux-kind-untrusted-{}", new_uuid_v4()));
    let registry = WorkspaceRegistry::open(&root, "untrusted").unwrap();
    let per_segment = 12_u64;
    let expected = fill_sealed_registry(&registry, 4, per_segment, 64);
    let head = registry.session_journal_head().unwrap();
    // This build's run finished the first segment; an older build then
    // mapped the second without its agent kind and stopped.
    registry
        .connection
        .get()
        .execute_batch(&format!(
            "DELETE FROM journal_segment_kinds
               WHERE segment_id = 'segment_13_24' AND kind = 'agent.test.noop';
             DELETE FROM meta WHERE key LIKE 'journal_segment_kinds_backfill%';
             INSERT INTO meta(key, value) VALUES
               ('journal_segment_kinds_backfill', '2'),
               ('journal_segment_kinds_backfill_through', '1'),
               ('journal_segment_kinds_backfill_end', '{}');",
            3 * per_segment + 1
        ))
        .unwrap();
    let reader =
        SessionJournalReader::open(&registry.session_journal_database_path().unwrap()).unwrap();
    let kinds: kind_read::JournalKinds = |kind| kind == "agent.test.noop";
    let mut cursor = 0;
    let mut seen = Vec::new();
    while cursor < head {
        let (records, reached) = reader.kinds_after(cursor, head, kinds, 512).unwrap();
        assert!(reached > cursor, "each read makes progress");
        seen.extend(records.iter().map(|record| record.sequence));
        cursor = reached;
    }
    drop(reader);
    drop(registry);
    let _ = fs::remove_dir_all(&root);
    assert_eq!(seen, expected, "the read-only read returns the partly mapped segment's records");
}

/// The same on a synthetic registry of a long-lived owner's shape
/// (`synth_registry`: `personal.session.put` churn, agent events, sealed
/// segments) whose kind map is gone, as an older build's segments have none:
/// the first kind read the roster replay makes, and all of them to the head.
/// Writes both times to `.build/kind-backfill-slice.json` for the PR.
#[test]
fn a_synth_registrys_first_kind_read_is_bounded_while_its_backfill_is_unfinished() {
    use crate::synth_registry::{SynthOptions, generate};
    let root = std::env::temp_dir().join(format!("cmux-kind-backfill-slice-{}", new_uuid_v4()));
    let options = SynthOptions {
        session: "slice".into(),
        session_puts: 60_000,
        agent_events: 2_500,
        payload_bytes: 2 * 1024,
        seal: true,
        ..SynthOptions::default()
    };
    let report = generate(&root, &options).unwrap();
    let registry = WorkspaceRegistry::open(&root, &options.session).unwrap();
    let db = registry.connection.get();
    db.execute_batch(
        "DELETE FROM journal_segment_kinds;
         DELETE FROM meta WHERE key LIKE 'journal_segment_kinds_backfill%';",
    )
    .unwrap();
    drop(db);
    let head = registry.session_journal_head().unwrap();
    let kinds = crate::journal_reducers::AgentRoster::folds_kind;
    let started = std::time::Instant::now();
    let (_, mut cursor) = registry.session_journal_kinds_after(0, head, kinds, 512).unwrap();
    let first = started.elapsed();
    let mut reads = 1;
    while cursor < head {
        let (_, reached) = registry.session_journal_kinds_after(cursor, head, kinds, 512).unwrap();
        assert!(reached > cursor, "each read makes progress");
        cursor = reached;
        reads += 1;
    }
    let total = started.elapsed();
    let numbers = serde_json::json!({
        "segments": report.segments,
        "journal_head": head,
        "registry_bytes": report.registry_bytes,
        "first_read_ms": first.as_millis().to_string(),
        "all_reads_ms": total.as_millis().to_string(),
        "reads": reads,
    });
    eprintln!("kind backfill slice: {numbers}");
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build");
    let _ = fs::create_dir_all(&out);
    let _ = fs::write(out.join("kind-backfill-slice.json"), numbers.to_string());
    drop(registry);
    let _ = fs::remove_dir_all(&root);
    assert!(report.segments > 8, "{numbers}");
    // The slice and one segment past it, with room for a slow host; the
    // whole backfill is several times that.
    assert!(first < std::time::Duration::from_millis(600), "{numbers}");
    assert!(first * 3 < total, "the first read is a slice of the backfill: {numbers}");
}
