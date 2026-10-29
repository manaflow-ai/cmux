use crate::panic_free::JsonFields;
use std::collections::HashMap;
use std::io::Write;

use anyhow::Context;
use base64::Engine;
use flate2::{Compression, GzBuilder};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::resource::TerminalPublicId;
use crate::workspace_registry::{JournalContentBlob, SessionJournalReader};
use crate::{JournalCheckpoint, JournalContentRef, JournalReplayPolicy, Mux, SessionJournalRecord};

pub(crate) const JOURNAL_REDUCER_VERSION: u32 = 1;
const MAX_CHECKPOINT_TERMINALS: usize = 4096;
const CHECKPOINT_REPLAY_RETRY_BUDGETS: [usize; 3] = [
    crate::surface::VT_REPLAY_MAX_BYTES,
    crate::surface::VT_REPLAY_MAX_BYTES * 2,
    crate::surface::VT_REPLAY_MAX_BYTES * 4,
];
const MAX_UNSUPPORTED_PREVIEW_RECORDS: usize = 1024;
pub(crate) const MAX_CHECKPOINT_CAPTURE_ATTEMPTS: usize = 4;
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
    for _ in 0..MAX_CHECKPOINT_CAPTURE_ATTEMPTS {
        if let Some(captured) = capture_attempt(mux)? {
            return Ok(captured);
        }
        #[cfg(test)]
        if let Some(hook) = tests::AFTER_RECOVERY_HOOK.with_borrow_mut(Option::take) {
            hook();
        }
    }
    anyhow::bail!("terminal replay recovery did not settle during checkpoint capture")
}

fn capture_attempt(mux: &Mux) -> anyhow::Result<Option<CapturedCheckpoint>> {
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
    let terminal_ids = JsonFields::field(&snapshot, "terminals")
        .as_array()
        .context("session snapshot terminals is not an array")?
        .iter()
        .map(|terminal| {
            JsonFields::field(terminal, "id")
                .as_str()
                .context("session snapshot terminal id is not a string")
                .and_then(|terminal_id| TerminalPublicId::parse(terminal_id).map_err(Into::into))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    anyhow::ensure!(
        terminal_ids.len() <= MAX_CHECKPOINT_TERMINALS,
        "checkpoint contains more than {MAX_CHECKPOINT_TERMINALS} terminals"
    );

    // Terminal screens stay out of the journal (output_store.rs): a
    // checkpoint names its terminals but keeps no replay blob. The output
    // store writes its snapshots now instead, so a respawn after a reboot
    // gets the screen of this checkpoint (none in memory mode).
    mux.output_store.write_now(mux);
    let blobs = Vec::new();

    // Verify against one cut as well, so a write landing between two separate
    // head and cursor reads cannot fail a capture that was in fact stable.
    let (verify_snapshot, head_after) =
        crate::resource_api::public_session_snapshot_with_journal_head(mux)
            .map_err(|error| anyhow::anyhow!("verify public session snapshot: {error:?}"))?;
    let cursor_after = verify_snapshot.field("cursor").clone();
    anyhow::ensure!(
        head_before == head_after && *snapshot.field("cursor") == cursor_after,
        "session changed during checkpoint capture"
    );
    Ok(Some(CapturedCheckpoint {
        source_sequence: head_after,
        state: json!({
            "session_snapshot":snapshot,
            "journal_extensions":{
                "producers":producers,
                "hooks":hooks,
            },
        }),
        blobs,
    }))
}

pub(crate) fn capture_error_is_retryable(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        let message = cause.to_string();
        [
            "session changed during checkpoint capture",
            "session journal changed during checkpoint capture",
            "terminal changed during replay capture",
            "terminal journal ingress is unsettled during replay capture",
        ]
        .iter()
        .any(|reason| message.contains(reason))
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
    terminal_replay_blob_with_recovery(surface, terminal_id).map(|(blob, _)| blob)
}

fn terminal_replay_blob_with_recovery(
    surface: &crate::Surface,
    terminal_id: &TerminalPublicId,
) -> anyhow::Result<(JournalContentBlob, bool)> {
    let epoch_before = surface
        .terminal_journal_capture_epoch()
        .context("captured terminal is not a PTY surface")?;
    anyhow::ensure!(
        epoch_before & 1 == 0,
        "terminal journal ingress is unsettled during replay capture"
    );
    let (cols, rows, replay, recovered) = {
        let mut last_error = None;
        let mut captured = None;
        let mut recovered = false;
        for budget in CHECKPOINT_REPLAY_RETRY_BUDGETS {
            let result = surface
                .try_with_terminal(|terminal| {
                    terminal
                        .vt_replay_bounded(budget)
                        .map(|replay| (terminal.cols(), terminal.rows(), replay))
                })
                .with_context(|| format!("terminal {terminal_id} replay capture"))?;
            match result {
                Ok(value) => {
                    captured = Some(value);
                    break;
                }
                Err(ghostty_vt::Error::OutOfSpace) => {
                    last_error = Some(anyhow::Error::new(ghostty_vt::Error::OutOfSpace));
                }
                Err(error) => {
                    return Err(anyhow::anyhow!(
                        "terminal {terminal_id} replay capture failed: {error}"
                    ));
                }
            }
        }
        if captured.is_none() {
            let result = surface
                .discard_unreplayable_replay_with(|terminal| {
                    terminal
                        .vt_replay_bounded(CHECKPOINT_REPLAY_RETRY_BUDGETS[0])
                        .map(|replay| (terminal.cols(), terminal.rows(), replay))
                })
                .with_context(|| format!("terminal {terminal_id} replay recovery"))?;
            if let Some(Ok(value)) = result {
                captured = Some(value);
                recovered = true;
            } else {
                return Err(anyhow::anyhow!(
                    "terminal {terminal_id} replay capture failed after retrying larger buffers: {}",
                    last_error
                        .map(|error| error.to_string())
                        .unwrap_or_else(|| "buffer too small".into())
                ));
            }
        }
        let (cols, rows, replay) = captured.context("replay recovery returned no capture")?;
        (cols, rows, replay, recovered)
    };
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
        "bytes_base64":base64::engine::general_purpose::STANDARD.encode(replay.self_contained_bytes()),
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
    let blob = JournalContentBlob::verified(
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
    )?;
    Ok((blob, recovered))
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

/// The restore preview of `checkpoint` through `through` (the journal head
/// when `None`), read on `reader`'s own read-only connection in one read
/// transaction: sealed segments, then active rows. It takes no registry
/// lock and never waits on the journal writer
/// (`session.journal.restore.preview`). The
/// journal is append-only, so a preview through an earlier head is the
/// preview of that cut whenever it is read.
pub(crate) fn restore_preview_on_reader(
    checkpoint: &JournalCheckpoint,
    reader: SessionJournalReader,
    through: Option<u64>,
) -> anyhow::Result<Value> {
    let mut reducer = RestoreReducer::new(checkpoint)?;
    let mut cursor = reader.restore_cursor(checkpoint.source_sequence)?;
    let head_sequence = 'pages: loop {
        let page = cursor.next_page(1024)?;
        let end = through.unwrap_or(page.head_sequence);
        anyhow::ensure!(
            end <= page.head_sequence,
            "cursor.invalid: journal sequence {end} is ahead of {}",
            page.head_sequence
        );
        for record in &page.records {
            if record.sequence > end {
                break 'pages end;
            }
            reducer.apply(record)?;
        }
        if page.records.is_empty() {
            break end;
        }
    };
    cursor.finish()?;
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
    /// `state_upsert`/`state_delete` changes of applied records: they
    /// change the snapshot's `extra.state` (`state::store`), which this
    /// reducer does not reduce, so `extra` stays the checkpoint's and the
    /// preview is not `fully_reducible` (spec/session-journal.md).
    state_changes_not_reduced: u64,
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
            state_changes_not_reduced: 0,
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
        if self.state_changes_not_reduced > 0 {
            let state = self.state.as_object_mut().context("checkpoint state is not an object")?;
            let replay = state.entry("journal_replay").or_insert_with(|| json!({}));
            let replay =
                replay.as_object_mut().context("checkpoint journal_replay is not an object")?;
            replay.insert(
                "state_changes_not_reduced".into(),
                Value::String(self.state_changes_not_reduced.to_string()),
            );
        }
        let digest =
            Sha256::digest(crate::workspace_registry::canonical_json(&self.state)?.as_bytes());
        Ok(json!({
            "checkpoint_id":self.checkpoint_id,
            "checkpoint_source_sequence":self.checkpoint_source_sequence.to_string(),
            "head_sequence":head_sequence.to_string(),
            "reducer_version":JOURNAL_REDUCER_VERSION,
            "fully_reducible":self.unsupported_count == 0 && self.state_changes_not_reduced == 0,
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
            if is_state_change(change) {
                self.state_changes_not_reduced = self.state_changes_not_reduced.saturating_add(1);
            } else {
                self.apply_resource_change(change)?;
            }
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
            // The session resource's revision is the cursor's
            // (`resource_api::session_snapshot`); no change restates it.
            if let Some(Value::Object(session)) = snapshot.get_mut("session")
                && session.contains_key("revision")
            {
                session.insert("revision".into(), Value::String(revision.to_string()));
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
            record.payload.field("format").as_str() == Some("cmux.terminal-output.v1")
                && record.payload.field("encoding").as_str() == Some("raw"),
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
            record.payload.field("sha256").as_str()
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
            record.payload.field("format").as_str() == Some("cmux.terminal-geometry.v1"),
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
            if is_state_change(change) {
                return kind == "state_delete" || change.get("value").is_some();
            }
            if resource == "session" {
                return kind == "upsert" && change.get("value").is_some();
            }
            let Some(collection) = resource_collection(resource) else { return false };
            self.resources.contains_key(collection)
                && matches!(kind, "upsert" | "delete")
                && (kind == "delete" || change.get("value").is_some())
                && (kind == "delete" || change.field("value").field("id").as_str() == Some(id))
        })
    }

    fn apply_resource_change(&mut self, change: &Value) -> anyhow::Result<()> {
        let text = |key| change.field(key).as_str();
        let kind = text("kind").context("validated replay change omitted kind")?;
        let resource = text("resource").context("validated replay change omitted resource")?;
        let id = text("id").context("validated replay change omitted id")?;
        if resource == "session" {
            let snapshot = self.state.get_mut("session_snapshot").and_then(Value::as_object_mut);
            let snapshot = snapshot.context("checkpoint session_snapshot is not an object")?;
            snapshot.insert("session".into(), change.field("value").clone());
            return Ok(());
        }
        let collection = resource_collection(resource).context("validated replay resource")?;
        let values =
            self.resources.get_mut(collection).context("validated replay collection is absent")?;
        match kind {
            "upsert" => {
                values.insert(id.into(), change.field("value").clone());
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

/// A state-family change (`state::store::state_upsert`/`state_delete`).
fn is_state_change(change: &Value) -> bool {
    matches!(change.field("kind").as_str(), Some("state_upsert" | "state_delete"))
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
    let mut encoded = String::with_capacity(bytes.len().saturating_mul(2));
    for nibble in bytes.iter().flat_map(|byte| [byte >> 4, byte & 0x0f]) {
        encoded.push(char::from_digit(u32::from(nibble), 16).unwrap_or('0'));
    }
    encoded
}

#[cfg(test)]
#[path = "journal_checkpoint_tests.rs"]
mod tests;
