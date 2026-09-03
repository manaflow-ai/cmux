use std::collections::HashMap;
use std::io::Write;

use anyhow::Context;
use base64::Engine;
use flate2::{Compression, GzBuilder};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::resource::TerminalPublicId;
use crate::workspace_registry::JournalContentBlob;
use crate::{JournalCheckpoint, JournalContentRef, JournalReplayPolicy, Mux, SessionJournalRecord};

pub(crate) const JOURNAL_REDUCER_VERSION: u32 = 1;
const MAX_CHECKPOINT_TERMINALS: usize = 4096;
const MAX_CHECKPOINT_UNCOMPRESSED_BYTES: u64 = 256 * 1024 * 1024;
const MAX_UNSUPPORTED_PREVIEW_RECORDS: usize = 1024;
const RESOURCE_COLLECTIONS: [&str; 10] = [
    "workspaces",
    "screens",
    "panes",
    "tabs",
    "terminals",
    "browsers",
    "notifications",
    "agents",
    "frontend_projections",
    "sidebar_views",
];

#[derive(Debug)]
pub(crate) struct CapturedCheckpoint {
    pub(crate) source_sequence: u64,
    pub(crate) state: Value,
    pub(crate) blobs: Vec<JournalContentBlob>,
}

pub(crate) fn capture(mux: &Mux) -> anyhow::Result<CapturedCheckpoint> {
    // Drain every output frame that reached ingress before the capture fence.
    // Per-terminal epochs below reject a parser snapshot taken while its
    // corresponding journal frame is still being enqueued.
    mux.flush_terminal_journal()?;
    // The snapshot and the journal head form one consistency cut, read under
    // a single registry + state lock hold. A journal record committed before
    // the cut is covered by the snapshot; the fence below only has to reject
    // writes that land after it, while terminal content is being captured.
    let (snapshot, head_before) =
        crate::resource_api::public_session_snapshot_with_journal_head(mux)
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
        .map(|terminal| {
            terminal["id"]
                .as_str()
                .context("session snapshot terminal id is not a string")
                .and_then(|terminal_id| TerminalPublicId::parse(terminal_id).map_err(Into::into))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    anyhow::ensure!(
        terminal_ids.len() <= MAX_CHECKPOINT_TERMINALS,
        "checkpoint contains more than {MAX_CHECKPOINT_TERMINALS} terminals"
    );

    let mut total_bytes = 0_u64;
    let mut blobs = Vec::new();
    for terminal_id in terminal_ids {
        let Some(surface) = mux.terminal_resource_surface(&terminal_id) else { continue };
        let blob = terminal_replay_blob(&surface, &terminal_id)?;
        total_bytes = total_bytes
            .checked_add(blob.reference.uncompressed_bytes)
            .context("checkpoint content byte count overflow")?;
        anyhow::ensure!(
            total_bytes <= MAX_CHECKPOINT_UNCOMPRESSED_BYTES,
            "checkpoint terminal content exceeds {MAX_CHECKPOINT_UNCOMPRESSED_BYTES} bytes"
        );
        blobs.push(blob);
    }

    mux.flush_terminal_journal()?;
    // Verify against one cut as well, so a write landing between two separate
    // head and cursor reads cannot fail a capture that was in fact stable.
    let (verify_snapshot, head_after) =
        crate::resource_api::public_session_snapshot_with_journal_head(mux)
            .map_err(|error| anyhow::anyhow!("verify public session snapshot: {error:?}"))?;
    let cursor_after = verify_snapshot["cursor"].clone();
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

/// Capture one terminal's bounded `cmux.vt-replay.v1` blob from its live
/// runtime surface. The terminal's journal ingress must be settled (flush
/// first) so the replay and the journaled output stream describe the same
/// byte prefix; a torn capture is rejected through the per-terminal epoch.
pub(crate) fn terminal_replay_blob(
    surface: &crate::Surface,
    terminal_id: &TerminalPublicId,
) -> anyhow::Result<JournalContentBlob> {
    let epoch_before = surface
        .terminal_journal_capture_epoch()
        .context("captured terminal is not a PTY surface")?;
    anyhow::ensure!(
        epoch_before & 1 == 0,
        "terminal journal ingress is unsettled during replay capture"
    );
    let (cols, rows, replay) = surface.try_with_terminal(|terminal| {
        terminal
            .vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
            .map(|replay| (terminal.cols(), terminal.rows(), replay))
    })??;
    let epoch_after = surface
        .terminal_journal_capture_epoch()
        .context("captured terminal is not a PTY surface")?;
    anyhow::ensure!(
        epoch_before == epoch_after && epoch_after & 1 == 0,
        "terminal changed during replay capture"
    );
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
    let digest = Sha256::digest(&uncompressed);
    let digest_hex = encode_hex(digest.as_slice());
    let compressed = gzip_deterministic(&uncompressed)?;
    JournalContentBlob::verified(
        JournalContentRef {
            content_id: format!("jcontent_{digest_hex}"),
            terminal_id: terminal_id.as_str().into(),
            format: "cmux.vt-replay.v1".into(),
            codec: "gzip".into(),
            sha256: digest_hex,
            uncompressed_bytes,
            cols,
            rows,
        },
        compressed,
    )
}

#[cfg(test)]
pub(crate) fn restore_preview(
    checkpoint: &JournalCheckpoint,
    records: &[SessionJournalRecord],
    head_sequence: u64,
) -> anyhow::Result<Value> {
    let mut reducer = RestoreReducer::new(checkpoint)?;
    for record in records {
        reducer.apply(record)?;
    }
    reducer.finish(head_sequence)
}

pub(crate) struct RestoreReducer {
    checkpoint_id: String,
    checkpoint_source_sequence: u64,
    content_refs: Vec<JournalContentRef>,
    state: Value,
    resources: HashMap<String, HashMap<String, Value>>,
    extensions: HashMap<String, HashMap<String, Value>>,
    applied: u64,
    ignored: u64,
    unsupported_count: u64,
    unsupported: Vec<Value>,
    terminal_streams: HashMap<(String, String), TerminalReplayState>,
    last_sequence: u64,
}

struct TerminalReplayState {
    terminal_id: String,
    generation: String,
    replay_hasher: Sha256,
    output_hasher: Sha256,
    output_bytes: u64,
    output_events: u64,
    resize_events: u64,
    first_stream_offset: Option<u64>,
    stream_offset_end: Option<u64>,
    last_geometry: Option<Value>,
}

impl RestoreReducer {
    pub(crate) fn new(checkpoint: &JournalCheckpoint) -> anyhow::Result<Self> {
        anyhow::ensure!(
            checkpoint.reducer_version == JOURNAL_REDUCER_VERSION,
            "unsupported checkpoint reducer version {}",
            checkpoint.reducer_version
        );
        let mut state = checkpoint.state.clone();
        let snapshot = state
            .get_mut("session_snapshot")
            .and_then(Value::as_object_mut)
            .context("checkpoint session_snapshot is not an object")?;
        let mut resources = HashMap::new();
        for collection in RESOURCE_COLLECTIONS {
            if let Some(values) = take_indexed_collection(snapshot, collection, "id")? {
                resources.insert(collection.into(), values);
            }
        }
        let mut extensions = HashMap::new();
        if let Some(extension_state) = state.get_mut("journal_extensions") {
            let extension_state = extension_state
                .as_object_mut()
                .context("checkpoint journal_extensions is not an object")?;
            for (collection, id_field) in [("producers", "producer_id"), ("hooks", "hook_id")] {
                if let Some(values) =
                    take_indexed_collection(extension_state, collection, id_field)?
                {
                    extensions.insert(collection.into(), values);
                }
            }
        }
        Ok(Self {
            checkpoint_id: checkpoint.checkpoint_id.clone(),
            checkpoint_source_sequence: checkpoint.source_sequence,
            content_refs: checkpoint.content_refs.clone(),
            state,
            resources,
            extensions,
            applied: 0,
            ignored: 0,
            unsupported_count: 0,
            unsupported: Vec::new(),
            terminal_streams: HashMap::new(),
            last_sequence: checkpoint.source_sequence,
        })
    }

    pub(crate) fn apply(&mut self, record: &SessionJournalRecord) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.last_sequence.checked_add(1) == Some(record.sequence),
            "journal records are not contiguous after checkpoint"
        );
        self.last_sequence = record.sequence;
        if record.replay != JournalReplayPolicy::Required {
            self.ignored = self.ignored.saturating_add(1);
            return Ok(());
        }
        if self.apply_required_record(record)? {
            self.applied = self.applied.saturating_add(1);
        } else {
            self.unsupported_count = self.unsupported_count.saturating_add(1);
            if self.unsupported.len() < MAX_UNSUPPORTED_PREVIEW_RECORDS {
                self.unsupported.push(json!({
                    "sequence":record.sequence.to_string(),
                    "event_id":record.event_id,
                    "kind":record.kind,
                }));
            }
        }
        Ok(())
    }

    pub(crate) fn finish(mut self, head_sequence: u64) -> anyhow::Result<Value> {
        anyhow::ensure!(
            head_sequence == self.last_sequence,
            "restore preview did not reduce through the journal head"
        );
        let snapshot = self
            .state
            .get_mut("session_snapshot")
            .and_then(Value::as_object_mut)
            .context("checkpoint session_snapshot is not an object")?;
        for (collection, values) in self.resources {
            snapshot.insert(collection, Value::Array(sorted_resource_values(values)));
        }
        if !self.extensions.is_empty() {
            let extensions = self
                .state
                .get_mut("journal_extensions")
                .and_then(Value::as_object_mut)
                .context("checkpoint journal_extensions is not an object")?;
            for (collection, values) in self.extensions {
                let mut values = values.into_values().collect::<Vec<_>>();
                values.sort_by(|left, right| {
                    extension_identity(left).cmp(&extension_identity(right))
                });
                extensions.insert(collection, Value::Array(values));
            }
        }
        if !self.terminal_streams.is_empty() {
            let mut terminal_streams = self
                .terminal_streams
                .into_values()
                .map(TerminalReplayState::finish)
                .collect::<Vec<_>>();
            terminal_streams.sort_by(|left, right| {
                left["terminal_id"]
                    .as_str()
                    .cmp(&right["terminal_id"].as_str())
                    .then_with(|| left["generation"].as_str().cmp(&right["generation"].as_str()))
            });
            let state = self.state.as_object_mut().context("checkpoint state is not an object")?;
            let replay = state.entry("journal_replay").or_insert_with(|| json!({}));
            let replay =
                replay.as_object_mut().context("checkpoint journal_replay is not an object")?;
            replay.insert("terminal_streams".into(), Value::Array(terminal_streams));
        }
        let digest =
            Sha256::digest(crate::workspace_registry::canonical_json(&self.state)?.as_bytes());
        Ok(json!({
            "checkpoint_id":self.checkpoint_id,
            "checkpoint_source_sequence":self.checkpoint_source_sequence.to_string(),
            "head_sequence":head_sequence.to_string(),
            "reducer_version":JOURNAL_REDUCER_VERSION,
            "fully_reducible":self.unsupported_count == 0,
            "applied_required_records":self.applied.to_string(),
            "ignored_non_required_records":self.ignored.to_string(),
            "unsupported_required_record_count":self.unsupported_count.to_string(),
            "unsupported_required_records_truncated":
                self.unsupported_count > self.unsupported.len() as u64,
            "unsupported_required_records":self.unsupported,
            "state_sha256":encode_hex(digest.as_slice()),
            "state":self.state,
            "content_refs":self.content_refs,
        }))
    }

    fn apply_required_record(&mut self, record: &SessionJournalRecord) -> anyhow::Result<bool> {
        if matches!(record.kind.as_str(), "journal.checkpoint.created" | "journal.segment.sealed") {
            return Ok(true);
        }
        if record.kind == "journal.producer.installed" {
            return self.upsert_manifest("producers", "producer_id", &record.payload);
        }
        if record.kind == "hook.manifest.installed" {
            return self.upsert_manifest("hooks", "hook_id", &record.payload);
        }
        if record.kind == "terminal.output" {
            self.apply_terminal_output(record)?;
            return Ok(true);
        }
        if record.kind == "terminal.resized" {
            self.apply_terminal_resize(record)?;
            return Ok(true);
        }
        let Some(changes) = record.payload.get("changes").and_then(Value::as_array) else {
            return Ok(false);
        };
        if !self.validate_resource_changes(changes)
            || !self.cursor_accepts(record.resource_revision, record.previous_resource_revision)?
        {
            return Ok(false);
        }
        for change in changes {
            self.apply_resource_change(change)?;
        }
        if let Some(revision) = record.resource_revision {
            let snapshot = self
                .state
                .get_mut("session_snapshot")
                .and_then(Value::as_object_mut)
                .context("checkpoint session_snapshot is not an object")?;
            match snapshot.get_mut("cursor") {
                Some(Value::Object(cursor)) => {
                    cursor.insert("revision".into(), Value::String(revision.to_string()));
                }
                Some(cursor @ Value::Null) => {
                    *cursor = json!({"revision":revision.to_string()});
                }
                None => {
                    snapshot.insert("cursor".into(), json!({"revision":revision.to_string()}));
                }
                Some(_) => anyhow::bail!("checkpoint cursor is not an object"),
            }
        }
        Ok(true)
    }

    fn terminal_stream_mut(
        &mut self,
        record: &SessionJournalRecord,
    ) -> anyhow::Result<&mut TerminalReplayState> {
        let terminal_id = required_terminal_subject(record)?;
        let authority = record
            .authority
            .as_ref()
            .context("terminal journal record omitted runtime authority")?;
        anyhow::ensure!(
            authority.role == "terminal.runtime",
            "terminal journal record has invalid runtime authority"
        );
        let key = (terminal_id.to_string(), authority.generation.clone());
        if !self.terminal_streams.contains_key(&key) {
            anyhow::ensure!(
                self.terminal_streams.len() < MAX_CHECKPOINT_TERMINALS,
                "terminal replay exceeds {MAX_CHECKPOINT_TERMINALS} streams"
            );
            self.terminal_streams.insert(
                key.clone(),
                TerminalReplayState {
                    terminal_id: key.0.clone(),
                    generation: key.1.clone(),
                    replay_hasher: Sha256::new(),
                    output_hasher: Sha256::new(),
                    output_bytes: 0,
                    output_events: 0,
                    resize_events: 0,
                    first_stream_offset: None,
                    stream_offset_end: None,
                    last_geometry: None,
                },
            );
        }
        self.terminal_streams.get_mut(&key).context("terminal replay stream was not inserted")
    }

    fn apply_terminal_output(&mut self, record: &SessionJournalRecord) -> anyhow::Result<()> {
        anyhow::ensure!(
            record.payload["format"].as_str() == Some("cmux.terminal-output.v1")
                && record.payload["encoding"].as_str() == Some("raw"),
            "terminal output replay metadata is invalid"
        );
        let bytes = record
            .terminal_output
            .as_deref()
            .context("terminal output replay content is absent")?;
        let byte_count = decimal_field(&record.payload, "byte_count")?;
        anyhow::ensure!(
            byte_count == u64::try_from(bytes.len())?,
            "terminal output replay byte_count is invalid"
        );
        let start = decimal_field(&record.payload, "stream_offset_start")?;
        let end = decimal_field(&record.payload, "stream_offset_end")?;
        anyhow::ensure!(
            end.checked_sub(start) == Some(byte_count),
            "terminal output replay offsets are invalid"
        );
        anyhow::ensure!(
            record.payload["sha256"].as_str()
                == Some(encode_hex(Sha256::digest(bytes).as_slice()).as_str()),
            "terminal output replay digest is invalid"
        );
        let stream = self.terminal_stream_mut(record)?;
        if let Some(previous_end) = stream.stream_offset_end {
            anyhow::ensure!(start == previous_end, "terminal output replay contains an offset gap");
        } else {
            stream.first_stream_offset = Some(start);
        }
        stream.stream_offset_end = Some(end);
        stream.output_bytes = stream
            .output_bytes
            .checked_add(byte_count)
            .context("terminal replay byte count exhausted")?;
        stream.output_events = stream.output_events.saturating_add(1);
        stream.output_hasher.update(bytes);
        stream.replay_hasher.update(b"output\0");
        stream.replay_hasher.update(byte_count.to_be_bytes());
        stream.replay_hasher.update(bytes);
        Ok(())
    }

    fn apply_terminal_resize(&mut self, record: &SessionJournalRecord) -> anyhow::Result<()> {
        anyhow::ensure!(
            record.payload["format"].as_str() == Some("cmux.terminal-geometry.v1"),
            "terminal resize replay metadata is invalid"
        );
        anyhow::ensure!(record.terminal_output.is_none(), "terminal resize contains output bytes");
        let cols = geometry_field(&record.payload, "cols")?;
        let rows = geometry_field(&record.payload, "rows")?;
        let cell_width = geometry_field(&record.payload, "cell_width")?;
        let cell_height = geometry_field(&record.payload, "cell_height")?;
        anyhow::ensure!(cols > 0 && rows > 0, "terminal resize grid must be non-zero");
        let geometry = json!({
            "cols":cols,
            "rows":rows,
            "cell_width":cell_width,
            "cell_height":cell_height,
        });
        let stream = self.terminal_stream_mut(record)?;
        stream.resize_events = stream.resize_events.saturating_add(1);
        stream.last_geometry = Some(geometry);
        stream.replay_hasher.update(b"resize\0");
        for value in [cols, rows, cell_width, cell_height] {
            stream.replay_hasher.update(value.to_be_bytes());
        }
        Ok(())
    }

    fn upsert_manifest(
        &mut self,
        collection: &str,
        id_field: &str,
        manifest: &Value,
    ) -> anyhow::Result<bool> {
        let Some(id) = manifest.get(id_field).and_then(Value::as_str) else {
            return Ok(false);
        };
        let Some(values) = self.extensions.get_mut(collection) else {
            return Ok(false);
        };
        values.insert(id.into(), manifest.clone());
        Ok(true)
    }

    fn cursor_accepts(
        &self,
        revision: Option<u64>,
        previous_revision: Option<u64>,
    ) -> anyhow::Result<bool> {
        let Some(revision) = revision else {
            return Ok(false);
        };
        let snapshot = self
            .state
            .get("session_snapshot")
            .and_then(Value::as_object)
            .context("checkpoint session_snapshot is not an object")?;
        let Some(cursor) = snapshot.get("cursor") else {
            return Ok(false);
        };
        if cursor.is_null() {
            return Ok(false);
        }
        let Some(cursor) = cursor.as_object() else {
            anyhow::bail!("checkpoint cursor is not an object")
        };
        let Some(cursor_revision) = cursor.get("revision") else { return Ok(false) };
        let cursor_revision = match cursor_revision {
            Value::String(value) => value
                .parse::<u64>()
                .context("checkpoint cursor revision is not an unsigned integer")?,
            Value::Number(value) => {
                value.as_u64().context("checkpoint cursor revision is not an unsigned integer")?
            }
            _ => anyhow::bail!("checkpoint cursor revision is not an unsigned integer"),
        };
        let expected_revision = cursor_revision.checked_add(1);
        Ok(match previous_revision {
            Some(previous) => previous == cursor_revision && expected_revision == Some(revision),
            None => false,
        })
    }

    fn validate_resource_changes(&self, changes: &[Value]) -> bool {
        changes.iter().all(|change| {
            let Some(kind) = change.get("kind").and_then(Value::as_str) else { return false };
            let Some(resource) = change.get("resource").and_then(Value::as_str) else {
                return false;
            };
            let Some(id) = change.get("id").and_then(Value::as_str) else { return false };
            if resource == "session" {
                return kind == "upsert" && change.get("value").is_some();
            }
            let Some(collection) = resource_collection(resource) else { return false };
            self.resources.contains_key(collection)
                && matches!(kind, "upsert" | "delete")
                && (kind == "delete" || change.get("value").is_some())
                && (kind == "delete" || change["value"]["id"].as_str() == Some(id))
        })
    }

    fn apply_resource_change(&mut self, change: &Value) -> anyhow::Result<()> {
        let kind = change["kind"].as_str().context("validated replay change omitted kind")?;
        let resource =
            change["resource"].as_str().context("validated replay change omitted resource")?;
        let id = change["id"].as_str().context("validated replay change omitted id")?;
        if resource == "session" {
            let snapshot = self.state["session_snapshot"]
                .as_object_mut()
                .context("checkpoint session_snapshot is not an object")?;
            snapshot.insert("session".into(), change["value"].clone());
            return Ok(());
        }
        let collection = resource_collection(resource).context("validated replay resource")?;
        let values =
            self.resources.get_mut(collection).context("validated replay collection is absent")?;
        match kind {
            "upsert" => {
                values.insert(id.into(), change["value"].clone());
            }
            "delete" => {
                values.remove(id);
            }
            _ => anyhow::bail!("validated replay change kind is unsupported"),
        }
        Ok(())
    }
}

impl TerminalReplayState {
    fn finish(self) -> Value {
        json!({
            "terminal_id":self.terminal_id,
            "generation":self.generation,
            "output_bytes":self.output_bytes.to_string(),
            "output_events":self.output_events.to_string(),
            "resize_events":self.resize_events.to_string(),
            "first_stream_offset":self.first_stream_offset.map(|value| value.to_string()),
            "stream_offset_end":self.stream_offset_end.map(|value| value.to_string()),
            "output_sha256":encode_hex(self.output_hasher.finalize().as_slice()),
            "replay_sha256":encode_hex(self.replay_hasher.finalize().as_slice()),
            "last_geometry":self.last_geometry,
        })
    }
}

fn required_terminal_subject(record: &SessionJournalRecord) -> anyhow::Result<&str> {
    let mut terminals = record
        .subjects
        .iter()
        .filter(|subject| subject.kind == "terminal")
        .map(|subject| subject.id.as_str());
    let terminal = terminals.next().context("terminal journal record omitted terminal subject")?;
    anyhow::ensure!(terminals.next().is_none(), "terminal journal record has multiple terminals");
    TerminalPublicId::parse(terminal.to_string()).context("terminal journal subject is invalid")?;
    Ok(terminal)
}

fn decimal_field(payload: &Value, field: &str) -> anyhow::Result<u64> {
    payload[field]
        .as_str()
        .with_context(|| format!("terminal journal payload omitted {field}"))?
        .parse()
        .with_context(|| format!("terminal journal payload has invalid {field}"))
}

fn geometry_field(payload: &Value, field: &str) -> anyhow::Result<u16> {
    payload[field]
        .as_u64()
        .and_then(|value| u16::try_from(value).ok())
        .with_context(|| format!("terminal journal payload has invalid {field}"))
}

fn take_indexed_collection(
    parent: &mut Map<String, Value>,
    collection: &str,
    id_field: &str,
) -> anyhow::Result<Option<HashMap<String, Value>>> {
    let Some(values) = parent.remove(collection) else { return Ok(None) };
    let Value::Array(values) = values else {
        anyhow::bail!("checkpoint collection {collection} is not an array");
    };
    let mut indexed = HashMap::with_capacity(values.len());
    for value in values {
        let id = value
            .get(id_field)
            .and_then(Value::as_str)
            .with_context(|| format!("checkpoint collection {collection} has an invalid id"))?;
        anyhow::ensure!(
            !indexed.contains_key(id),
            "checkpoint collection {collection} contains duplicate id {id:?}"
        );
        indexed.insert(id.into(), value);
    }
    Ok(Some(indexed))
}

fn sorted_resource_values(values: HashMap<String, Value>) -> Vec<Value> {
    let mut values = values.into_values().collect::<Vec<_>>();
    values.sort_by(|left, right| {
        left["index"]
            .as_u64()
            .unwrap_or(u64::MAX)
            .cmp(&right["index"].as_u64().unwrap_or(u64::MAX))
            .then_with(|| left["id"].as_str().cmp(&right["id"].as_str()))
    });
    values
}

fn extension_identity(value: &Value) -> Option<&str> {
    value["producer_id"].as_str().or_else(|| value["hook_id"].as_str())
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
        JournalAuthority, JournalClass, JournalEventSchema, JournalProducer,
        JournalProducerManifest, JournalSensitivity, JournalSubject,
    };
    use std::sync::Arc;

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
        assert!(restore_preview(&checkpoint, &[record.clone()], 5).is_err());
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
            let preview = restore_preview(&checkpoint(cursor), &[record.clone()], 4).unwrap();
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
            restore_preview(&terminal_replay_checkpoint(), &[output_record, resize_record], 5)
                .unwrap();
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
        let mux = Mux::open_persistent("checkpoint-race", crate::SurfaceOptions::default(), &root)
            .unwrap();

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

    #[test]
    fn replaying_an_old_producer_put_keeps_the_current_validator() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-producer-replay-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent(
            "producer-replay-validator",
            crate::SurfaceOptions::default(),
            &root,
        )
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

        let replay =
            mux.put_journal_producer(&original, "client_test", "producer_original").unwrap();
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
        let mux = Mux::open_persistent(
            "checkpoint-segment-writer",
            crate::SurfaceOptions::default(),
            &root,
        )
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

    #[cfg(unix)]
    #[test]
    fn checkpoint_rejects_terminal_state_ahead_of_journal_ingress() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-checkpoint-fence-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent("checkpoint-fence", crate::SurfaceOptions::default(), &root)
            .unwrap();
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let surface_id = mux
            .seed_running_terminal_for_test(
                "00000000000040008000000000000072",
                "10000000000040008000000000000072",
                &workspace.key,
            )
            .unwrap();
        let surface = mux.surface(surface_id).unwrap();
        {
            let mut pending_output = surface.begin_terminal_journal_update_for_test().unwrap();
            assert!(pending_output.activate(), "terminal journal update must be active");
            let error = match capture(&mux) {
                Ok(_) => panic!("checkpoint accepted unsettled terminal output"),
                Err(error) => error,
            };
            assert!(error.to_string().contains("terminal journal ingress is unsettled"));
        }

        drop(surface);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}
