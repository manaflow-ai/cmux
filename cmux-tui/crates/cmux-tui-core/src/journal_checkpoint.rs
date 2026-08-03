use std::io::Write;

use anyhow::Context;
use base64::Engine;
use flate2::{Compression, GzBuilder};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::workspace_registry::JournalContentBlob;
use crate::{JournalCheckpoint, JournalContentRef, JournalReplayPolicy, Mux, SessionJournalRecord};

pub(crate) const JOURNAL_REDUCER_VERSION: u32 = 1;
const MAX_CHECKPOINT_TERMINALS: usize = 4096;
const MAX_CHECKPOINT_UNCOMPRESSED_BYTES: u64 = 256 * 1024 * 1024;

pub(crate) struct CapturedCheckpoint {
    pub(crate) source_sequence: u64,
    pub(crate) state: Value,
    pub(crate) blobs: Vec<JournalContentBlob>,
}

pub(crate) fn capture(mux: &Mux) -> anyhow::Result<CapturedCheckpoint> {
    let head_before = mux.session_journal_after(0, 1)?.head_sequence;
    let snapshot = crate::resource_api::public_session_snapshot(mux)
        .map_err(|error| anyhow::anyhow!("capture public session snapshot: {error:?}"))?;
    let producers = mux.journal_producer_manifests()?;
    let hooks = mux
        .journal_hook_states()?
        .into_iter()
        .filter(|hook| hook.enabled)
        .map(|hook| hook.manifest)
        .collect::<Vec<_>>();
    let terminal_ids = snapshot["terminals"]
        .as_array()
        .context("session snapshot terminals is not an array")?
        .iter()
        .filter_map(|terminal| terminal["id"].as_str().map(str::to_string))
        .collect::<Vec<_>>();
    anyhow::ensure!(
        terminal_ids.len() <= MAX_CHECKPOINT_TERMINALS,
        "checkpoint contains more than {MAX_CHECKPOINT_TERMINALS} terminals"
    );

    let mut total_bytes = 0_u64;
    let mut blobs = Vec::new();
    for terminal_id in terminal_ids {
        let Some(resolution) = mux.resolve_terminal(&terminal_id)? else { continue };
        let Some(surface_id) = resolution.surface else { continue };
        let Some(surface) = mux.surface(surface_id) else { continue };
        let (cols, rows, replay) = surface.try_with_terminal(|terminal| {
            terminal
                .vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
                .map(|replay| (terminal.cols(), terminal.rows(), replay))
        })??;
        let replay_value = json!({
            "format":"cmux.vt-replay.v1",
            "cols":cols,
            "rows":rows,
            "bytes_base64":base64::engine::general_purpose::STANDARD.encode(&replay.bytes),
            "kitty_image_aliases":replay.kitty_image_aliases.iter().map(|alias| json!({
                "image_id":alias.image_id,
                "image_number":alias.image_number,
            })).collect::<Vec<_>>(),
            "kitty_state":{
                "limits":{
                    "image_bytes":replay.kitty_state.limits.image_bytes.to_string(),
                    "inflight_bytes":replay.kitty_state.limits.inflight_bytes.to_string(),
                    "images":replay.kitty_state.limits.images.to_string(),
                    "placements":replay.kitty_state.limits.placements.to_string(),
                },
                "replay_cursor_offset":replay.kitty_state.replay_cursor_offset,
                "replay_next_image_ids":{
                    "primary":replay.kitty_state.replay_next_image_ids.primary,
                    "alternate":replay.kitty_state.replay_next_image_ids.alternate,
                },
                "next_image_ids":{
                    "primary":replay.kitty_state.next_image_ids.primary,
                    "alternate":replay.kitty_state.next_image_ids.alternate,
                },
            },
        });
        let uncompressed = serde_json::to_vec(&replay_value)?;
        let uncompressed_bytes = u64::try_from(uncompressed.len())?;
        total_bytes = total_bytes
            .checked_add(uncompressed_bytes)
            .context("checkpoint content byte count overflow")?;
        anyhow::ensure!(
            total_bytes <= MAX_CHECKPOINT_UNCOMPRESSED_BYTES,
            "checkpoint terminal content exceeds {MAX_CHECKPOINT_UNCOMPRESSED_BYTES} bytes"
        );
        let digest = Sha256::digest(&uncompressed);
        let digest_hex = encode_hex(digest.as_slice());
        let compressed = gzip_deterministic(&uncompressed)?;
        blobs.push(JournalContentBlob {
            reference: JournalContentRef {
                content_id: format!("jcontent_{digest_hex}"),
                terminal_id,
                format: "cmux.vt-replay.v1".into(),
                codec: "gzip".into(),
                sha256: digest_hex,
                uncompressed_bytes,
                cols,
                rows,
            },
            compressed,
        });
    }

    let head_after = mux.session_journal_after(0, 1)?.head_sequence;
    let cursor_after = crate::resource_api::public_session_snapshot(mux)
        .map_err(|error| anyhow::anyhow!("verify public session snapshot: {error:?}"))?["cursor"]
        .clone();
    anyhow::ensure!(
        head_before == head_after && snapshot["cursor"] == cursor_after,
        "session changed during checkpoint capture"
    );
    Ok(CapturedCheckpoint {
        source_sequence: head_after,
        state: json!({
            "session_snapshot":snapshot,
            "journal_extensions":{
                "producers":producers,
                "hooks":hooks,
            },
        }),
        blobs,
    })
}

pub(crate) fn restore_preview(
    checkpoint: &JournalCheckpoint,
    records: &[SessionJournalRecord],
    head_sequence: u64,
) -> anyhow::Result<Value> {
    anyhow::ensure!(
        checkpoint.reducer_version == JOURNAL_REDUCER_VERSION,
        "unsupported checkpoint reducer version {}",
        checkpoint.reducer_version
    );
    let mut state = checkpoint.state.clone();
    let mut applied = 0_u64;
    let mut ignored = 0_u64;
    let mut unsupported = Vec::new();
    let mut last_sequence = checkpoint.source_sequence;
    for record in records {
        anyhow::ensure!(
            record.sequence > last_sequence,
            "journal records are not strictly ordered after checkpoint"
        );
        last_sequence = record.sequence;
        if record.replay != JournalReplayPolicy::Required {
            ignored = ignored.saturating_add(1);
            continue;
        }
        if apply_required_record(&mut state, record)? {
            applied = applied.saturating_add(1);
        } else {
            unsupported.push(json!({
                "sequence":record.sequence.to_string(),
                "event_id":record.event_id,
                "kind":record.kind,
            }));
        }
    }
    let digest = Sha256::digest(crate::workspace_registry::canonical_json(&state)?.as_bytes());
    Ok(json!({
        "checkpoint_id":checkpoint.checkpoint_id,
        "checkpoint_source_sequence":checkpoint.source_sequence.to_string(),
        "head_sequence":head_sequence.to_string(),
        "reducer_version":JOURNAL_REDUCER_VERSION,
        "fully_reducible":unsupported.is_empty(),
        "applied_required_records":applied.to_string(),
        "ignored_non_required_records":ignored.to_string(),
        "unsupported_required_records":unsupported,
        "state_sha256":encode_hex(digest.as_slice()),
        "state":state,
        "content_refs":checkpoint.content_refs,
    }))
}

fn apply_required_record(state: &mut Value, record: &SessionJournalRecord) -> anyhow::Result<bool> {
    if matches!(record.kind.as_str(), "journal.checkpoint.created" | "journal.segment.sealed") {
        return Ok(true);
    }
    if record.kind == "journal.producer.installed" {
        return upsert_manifest(state, "producers", "producer_id", &record.payload);
    }
    if record.kind == "hook.manifest.installed" {
        return upsert_manifest(state, "hooks", "hook_id", &record.payload);
    }
    let Some(changes) = record.payload.get("changes").and_then(Value::as_array) else {
        return Ok(false);
    };
    let snapshot = state
        .get_mut("session_snapshot")
        .and_then(Value::as_object_mut)
        .context("checkpoint session_snapshot is not an object")?;
    for change in changes {
        if !apply_resource_change(snapshot, change)? {
            return Ok(false);
        }
    }
    if let Some(revision) = record.resource_revision {
        snapshot.entry("cursor").or_insert_with(|| json!({}))["revision"] =
            Value::String(revision.to_string());
    }
    Ok(true)
}

fn upsert_manifest(
    state: &mut Value,
    collection: &str,
    id_field: &str,
    manifest: &Value,
) -> anyhow::Result<bool> {
    let Some(id) = manifest.get(id_field).and_then(Value::as_str) else { return Ok(false) };
    let values = state
        .get_mut("journal_extensions")
        .and_then(Value::as_object_mut)
        .and_then(|extensions| extensions.get_mut(collection))
        .and_then(Value::as_array_mut)
        .context("checkpoint journal extension collection is absent")?;
    if let Some(existing) = values.iter_mut().find(|value| value[id_field].as_str() == Some(id)) {
        *existing = manifest.clone();
    } else {
        values.push(manifest.clone());
    }
    Ok(true)
}

fn apply_resource_change(
    snapshot: &mut Map<String, Value>,
    change: &Value,
) -> anyhow::Result<bool> {
    let Some(kind) = change.get("kind").and_then(Value::as_str) else { return Ok(false) };
    let Some(resource) = change.get("resource").and_then(Value::as_str) else { return Ok(false) };
    let Some(id) = change.get("id").and_then(Value::as_str) else { return Ok(false) };
    if resource == "session" && kind == "upsert" {
        let Some(value) = change.get("value") else { return Ok(false) };
        snapshot.insert("session".into(), value.clone());
        return Ok(true);
    }
    let Some(collection) = resource_collection(resource) else { return Ok(false) };
    let Some(values) = snapshot.get_mut(collection).and_then(Value::as_array_mut) else {
        return Ok(false);
    };
    match kind {
        "upsert" => {
            let Some(value) = change.get("value") else { return Ok(false) };
            if let Some(existing) =
                values.iter_mut().find(|candidate| candidate["id"].as_str() == Some(id))
            {
                *existing = value.clone();
            } else {
                values.push(value.clone());
            }
            values.sort_by(|left, right| {
                left["index"]
                    .as_u64()
                    .unwrap_or(u64::MAX)
                    .cmp(&right["index"].as_u64().unwrap_or(u64::MAX))
                    .then_with(|| left["id"].as_str().cmp(&right["id"].as_str()))
            });
            Ok(true)
        }
        "delete" => {
            values.retain(|candidate| candidate["id"].as_str() != Some(id));
            Ok(true)
        }
        _ => Ok(false),
    }
}

fn resource_collection(resource: &str) -> Option<&'static str> {
    match resource {
        "workspace" => Some("workspaces"),
        "screen" => Some("screens"),
        "pane" => Some("panes"),
        "tab" => Some("tabs"),
        "terminal" => Some("terminals"),
        "browser" => Some("browsers"),
        "notification" => Some("notifications"),
        "agent" => Some("agents"),
        "frontend_projection" => Some("frontend_projections"),
        "sidebar_view" => Some("sidebar_views"),
        _ => None,
    }
}

fn gzip_deterministic(bytes: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut encoder = GzBuilder::new().mtime(0).write(Vec::new(), Compression::fast());
    encoder.write_all(bytes)?;
    Ok(encoder.finish()?)
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        JournalClass, JournalEventSchema, JournalProducer, JournalProducerManifest,
        JournalSensitivity, JournalSubject,
    };

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
        };
        let preview = restore_preview(&checkpoint, &[record], 4).unwrap();
        assert_eq!(preview["fully_reducible"], true);
        assert_eq!(preview["state"]["session_snapshot"]["workspaces"][0]["id"], "workspace_new");
        assert_eq!(preview["state"]["session_snapshot"]["cursor"]["revision"], "2");
    }

    #[test]
    fn checkpoint_aligned_segments_remain_transparently_replayable() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-segment-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux =
            Mux::open_persistent("checkpoint-segment", crate::SurfaceOptions::default(), &root)
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
        let checkpoint = mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();
        let before = mux.session_journal_after(0, 1024).unwrap().records;
        let seal = mux
            .seal_journal_segments(
                checkpoint.checkpoint.source_sequence,
                "client_test",
                "segment_1",
            )
            .unwrap();
        assert_eq!(seal.through_sequence, checkpoint.checkpoint.source_sequence);
        assert!(!seal.segments.is_empty());
        let after = mux.session_journal_after(0, 1024).unwrap().records;
        assert_eq!(&after[..before.len()], before.as_slice());
        assert_eq!(after.last().unwrap().kind, "journal.segment.sealed");
        let preview = mux.journal_restore_preview("latest").unwrap();
        assert_eq!(preview["fully_reducible"], true);

        let replayed = mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();
        assert!(replayed.journal.replayed);
        assert_eq!(replayed.checkpoint.checkpoint_id, checkpoint.checkpoint.checkpoint_id);
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
        let mux =
            Mux::open_persistent("checkpoint-terminal", crate::SurfaceOptions::default(), &root)
                .unwrap();
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        mux.seed_running_terminal_for_test(
            "00000000000040008000000000000071",
            "10000000000040008000000000000071",
            &workspace.key,
        )
        .unwrap();

        let captured = capture(&mux).unwrap();
        assert_eq!(captured.blobs.len(), 1);
        assert!(captured.blobs[0].reference.terminal_id.starts_with("term_"));
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}
