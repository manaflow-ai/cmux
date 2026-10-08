//! P8 landing 2c (plans/cmux-next/identity.md section 3): a resource journal
//! record carries its actor, also after it is sealed into a segment. Sealed
//! segments keep actors in `journal_segments.actors_json`, never in the record
//! JSON, so an older daemon still decodes them.

use std::io::Write;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-journal-actor-{label}-{}", new_uuid_v4()))
}

fn create(mux: &Arc<crate::Mux>, key: &str) {
    let request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": key,
        "operation": "workspace.create",
        "params": {"machine": "current", "session": "current", "initial_content": "empty"},
        "idempotency_key": key,
    });
    crate::resource_router::handle_resource_message(mux, &request.to_string()).unwrap();
}

fn actor_of(mux: &crate::Mux, key: &str) -> Option<String> {
    let records = mux.session_journal_after(0, 1024).unwrap().records;
    let record = records
        .iter()
        .find(|record| record.correlation_id.as_deref() == Some(key))
        .unwrap_or_else(|| panic!("no journal record for {key}"));
    let registry = mux.workspace_registry.lock().unwrap();
    journal_actor(&registry.connection, record.sequence).unwrap()
}

#[test]
fn a_record_keeps_its_actor_through_seal_and_reopen() {
    let root = temp_root("seal");
    {
        let mux = crate::Mux::open_persistent("journal-actor", crate::SurfaceOptions::default(), &root)
            .unwrap();
        create(&mux, "journal-actor-1");
        assert_eq!(actor_of(&mux, "journal-actor-1").as_deref(), Some("user:user_local"));
        let checkpoint = mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();
        let through = checkpoint.checkpoint.source_sequence;
        let seal = mux.seal_journal_segments(through, "client_test", "segment_1").unwrap();
        assert!(!seal.segments.is_empty());
        assert_eq!(actor_of(&mux, "journal-actor-1").as_deref(), Some("user:user_local"));
        mux.shutdown();
    }
    let mux =
        crate::Mux::open_persistent("journal-actor", crate::SurfaceOptions::default(), &root).unwrap();
    assert_eq!(actor_of(&mux, "journal-actor-1").as_deref(), Some("user:user_local"));
    mux.shutdown();
    let _ = fs::remove_dir_all(root);
}

/// One hot record, archived by hand as segment `segment_id` with `records`
/// as its JSON and `actors_json` beside it; the hot row is then removed.
fn archive_by_hand(registry: &WorkspaceRegistry, records: &Value, actors_json: Option<&str>) {
    let uncompressed = serde_json::to_vec(records).unwrap();
    let digest = Sha256::digest(&uncompressed);
    let mut encoder =
        flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
    encoder.write_all(&uncompressed).unwrap();
    let compressed = encoder.finish().unwrap();
    let length = i64::try_from(uncompressed.len()).unwrap();
    match actors_json {
        None => registry.connection.execute(
            "INSERT INTO journal_segments(
               segment_id, start_sequence, end_sequence, record_count, codec, content,
               uncompressed_bytes, sha256, sealed_at_ms
             ) VALUES('segment_by_hand', 1, 1, 1, 'gzip-json-v1', ?1, ?2, ?3, 1)",
            params![compressed, length, digest.as_slice()],
        ),
        Some(actors) => registry.connection.execute(
            "INSERT INTO journal_segments(
               segment_id, start_sequence, end_sequence, record_count, codec, content,
               uncompressed_bytes, sha256, sealed_at_ms, actors_json
             ) VALUES('segment_by_hand', 1, 1, 1, 'gzip-json-v1', ?1, ?2, ?3, 1, ?4)",
            params![compressed, length, digest.as_slice(), actors],
        ),
    }
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
}

/// A registry with one resource record (sequence 1) and its JSON.
fn one_record(label: &str) -> (WorkspaceRegistry, Value) {
    let mut registry = WorkspaceRegistry::in_memory(label).unwrap();
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
        &json!({"focused": true}),
        &json!([]),
    )
    .unwrap();
    tx.commit().unwrap();
    let records = registry.session_journal_after(0, 10).unwrap().records;
    let json = serde_json::to_value(&records).unwrap();
    (registry, json)
}

#[test]
fn a_segment_without_actors_reads_as_legacy() {
    let (registry, records) = one_record("segment-no-actors");
    archive_by_hand(&registry, &records, None);
    let records = registry.session_journal_after(0, 10).unwrap().records;
    assert_eq!(records.len(), 1);
    assert_eq!(journal_actor(&registry.connection, records[0].sequence).unwrap(), None);
}

#[test]
fn actors_for_sequences_outside_the_segment_are_ignored() {
    let (registry, records) = one_record("segment-foreign-actors");
    archive_by_hand(&registry, &records, Some(r#"{"1":"user:user_local","99":"peer:remote"}"#));
    let records = registry.session_journal_after(0, 10).unwrap().records;
    assert_eq!(records.len(), 1);
    let actor = journal_actor(&registry.connection, records[0].sequence).unwrap();
    assert_eq!(actor.as_deref(), Some("user:user_local"));
}

#[test]
fn a_segment_record_with_an_unknown_field_still_decodes() {
    let (registry, mut records) = one_record("segment-unknown-field");
    records[0]["field_from_a_newer_daemon"] = json!({"any": "value"});
    archive_by_hand(&registry, &records, None);
    let records = registry.session_journal_after(0, 10).unwrap().records;
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].kind, "pane.focus");
}
