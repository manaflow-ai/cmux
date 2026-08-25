//! Renderable content for terminals restored as exited placeholders.
//!
//! `spec/session-journal.md` ("Restoration") defines the inert restored model:
//! the newest compatible checkpoint plus every later required record.
//! Restart reconciliation preserves the journaled topology and commits dead
//! terminals as exited; this module computes the VT content those exited
//! placeholders can honestly render, from the terminal's checkpoint VT blob
//! plus the reducible `terminal.output` / `terminal.resized` tail. It spawns
//! nothing and never mutates the journal; materialization appends its own
//! post-replay outcome record.

use anyhow::Context;
use base64::Engine;
use ghostty_vt::{KittyGraphicsLimits, KittyImageAlias, KittyImageIdCursors, KittyReplayState};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::SessionJournalRecord;
use crate::workspace_registry::{encode_hex, JournalContentRef, WorkspaceRegistry};

/// Bound on tail bytes replayed into one restored placeholder. Matches the
/// bounded VT replay budget used everywhere else a terminal is rebuilt.
pub(crate) const RESTORE_TAIL_MAX_BYTES: u64 = crate::surface::VT_REPLAY_MAX_BYTES as u64;

const RESTORE_SCAN_PAGE: usize = 1024;
const MAX_RESTORE_TAIL_RESIZE_EVENTS: u64 = 10_000;

/// One replayable event of the post-checkpoint tail, in commit order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RestoredTailEvent {
    Output(Vec<u8>),
    Resize { cols: u16, rows: u16, cell_width: u32, cell_height: u32 },
}

/// The reducible content for one restored terminal: an optional checkpoint
/// VT replay base plus the contiguous journaled tail after it.
#[derive(Debug, Clone)]
pub(crate) struct RestoredTerminalContent {
    pub(crate) checkpoint_id: Option<String>,
    /// Checkpoint VT replay bytes; empty when the terminal had no blob in the
    /// newest checkpoint (tail-only restore).
    pub(crate) replay: Vec<u8>,
    pub(crate) kitty_image_aliases: Vec<KittyImageAlias>,
    pub(crate) kitty_state: KittyReplayState,
    /// Grid the replay bytes were captured at (or the durable launch grid for
    /// a tail-only restore).
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) tail: Vec<RestoredTailEvent>,
    pub(crate) tail_output_bytes: u64,
    pub(crate) tail_resize_events: u64,
    /// Why the tail stopped early, when it did. The content before the stop
    /// remains renderable; the projection never guesses at missing bytes.
    pub(crate) degraded: Option<String>,
}

impl RestoredTerminalContent {
    pub(crate) fn is_empty(&self) -> bool {
        self.replay.is_empty() && self.tail.is_empty()
    }

    pub(crate) fn source_label(&self) -> &'static str {
        match (self.checkpoint_id.is_some(), self.tail.is_empty()) {
            (true, true) => "checkpoint",
            (true, false) => "checkpoint+tail",
            (false, false) => "tail",
            (false, true) => "none",
        }
    }
}

/// Compute the restorable content for one terminal from the newest
/// checkpoint and the journal tail. Returns `Ok(None)` when the journal
/// holds nothing renderable for this terminal (for example a session that
/// never journaled and never checkpointed).
pub(crate) fn restored_terminal_content(
    registry: &WorkspaceRegistry,
    terminal_public_id: &str,
    fallback_grid: (u16, u16),
) -> anyhow::Result<Option<RestoredTerminalContent>> {
    let checkpoint = registry.journal_checkpoint("latest")?;
    let (mut content, scan_from) = match checkpoint {
        Some(checkpoint) => {
            let reference = checkpoint
                .content_refs
                .iter()
                .find(|reference| reference.terminal_id == terminal_public_id);
            match reference {
                Some(reference) => {
                    let base = registry
                        .journal_content_blob_bytes(reference)?
                        .map(|uncompressed| decode_vt_replay_blob(reference, &uncompressed))
                        .transpose()?;
                    match base {
                        Some(base) => {
                            let mut base = base;
                            base.checkpoint_id = Some(checkpoint.checkpoint_id.clone());
                            (base, checkpoint.source_sequence)
                        }
                        // The referenced blob is absent or unreadable. The
                        // tail after the checkpoint is still contiguous and
                        // renderable on an empty grid only for output that
                        // starts a new generation; reducing it onto a missing
                        // base would misrepresent the screen, so restore
                        // nothing renderable and report the degradation.
                        None => {
                            return Ok(Some(RestoredTerminalContent {
                                checkpoint_id: Some(checkpoint.checkpoint_id.clone()),
                                replay: Vec::new(),
                                kitty_image_aliases: Vec::new(),
                                kitty_state: KittyReplayState::disabled(),
                                cols: fallback_grid.0.max(1),
                                rows: fallback_grid.1.max(1),
                                tail: Vec::new(),
                                tail_output_bytes: 0,
                                tail_resize_events: 0,
                                degraded: Some("checkpoint content blob is unavailable".into()),
                            }));
                        }
                    }
                }
                // The newest checkpoint does not cover this terminal (it was
                // created after the capture, or had no live surface then).
                // Its full journaled output history is the only base.
                None => (empty_content(fallback_grid), 0),
            }
        }
        None => (empty_content(fallback_grid), 0),
    };

    let mut fold = TerminalTailFold::new(terminal_public_id, RESTORE_TAIL_MAX_BYTES);
    let mut cursor = scan_from;
    loop {
        let page = registry.session_journal_after(cursor, RESTORE_SCAN_PAGE)?;
        if page.records.is_empty() {
            break;
        }
        for record in &page.records {
            cursor = cursor.max(record.sequence);
            if !fold.apply(record) {
                break;
            }
        }
        if fold.stopped() {
            break;
        }
    }
    let (tail, tail_output_bytes, tail_resize_events, degraded) = fold.finish();
    content.tail = tail;
    content.tail_output_bytes = tail_output_bytes;
    content.tail_resize_events = tail_resize_events;
    if content.degraded.is_none() {
        content.degraded = degraded;
    }

    if content.is_empty() && content.degraded.is_none() {
        return Ok(None);
    }
    Ok(Some(content))
}

fn empty_content(fallback_grid: (u16, u16)) -> RestoredTerminalContent {
    RestoredTerminalContent {
        checkpoint_id: None,
        replay: Vec::new(),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::disabled(),
        cols: fallback_grid.0.max(1),
        rows: fallback_grid.1.max(1),
        tail: Vec::new(),
        tail_output_bytes: 0,
        tail_resize_events: 0,
        degraded: None,
    }
}

/// Fold `terminal.output` / `terminal.resized` records for one terminal into
/// an ordered replayable tail, with the same validation the restore-preview
/// reducer applies: exact byte counts, digests, and per-generation offset
/// contiguity. A `terminal.output.gap`, a validation failure, or an exceeded
/// byte budget stops the tail at the last provably complete event instead of
/// guessing at missing bytes.
pub(crate) struct TerminalTailFold {
    terminal_id: String,
    budget: u64,
    events: Vec<RestoredTailEvent>,
    output_bytes: u64,
    resize_events: u64,
    /// `(generation, next_expected_offset)` for the stream currently being
    /// followed. Restarted hosts start a new generation; commit order is the
    /// authoritative order across generations.
    stream: Option<(String, u64)>,
    degraded: Option<String>,
}

impl TerminalTailFold {
    pub(crate) fn new(terminal_id: &str, budget: u64) -> Self {
        Self {
            terminal_id: terminal_id.to_string(),
            budget,
            events: Vec::new(),
            output_bytes: 0,
            resize_events: 0,
            stream: None,
            degraded: None,
        }
    }

    pub(crate) fn stopped(&self) -> bool {
        self.degraded.is_some()
    }

    /// Apply one journal record. Returns `false` once the fold has stopped.
    pub(crate) fn apply(&mut self, record: &SessionJournalRecord) -> bool {
        if self.stopped() {
            return false;
        }
        if !record
            .subjects
            .iter()
            .any(|subject| subject.kind == "terminal" && subject.id == self.terminal_id)
        {
            return true;
        }
        match record.kind.as_str() {
            "terminal.output" => match self.apply_output(record) {
                Ok(()) => true,
                Err(error) => {
                    self.degraded = Some(format!("terminal output tail stopped: {error:#}"));
                    false
                }
            },
            "terminal.resized" => match self.apply_resize(record) {
                Ok(()) => true,
                Err(error) => {
                    self.degraded = Some(format!("terminal resize tail stopped: {error:#}"));
                    false
                }
            },
            "terminal.output.gap" => {
                let reason = record.payload["reason"].as_str().unwrap_or("unknown");
                self.degraded = Some(format!("terminal output gap: {reason}"));
                false
            }
            _ => true,
        }
    }

    fn apply_output(&mut self, record: &SessionJournalRecord) -> anyhow::Result<()> {
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
        let generation = record
            .authority
            .as_ref()
            .filter(|authority| authority.role == "terminal.runtime")
            .map(|authority| authority.generation.clone())
            .context("terminal output record omitted runtime authority")?;
        match &self.stream {
            Some((current, expected)) if *current == generation => {
                anyhow::ensure!(
                    start == *expected,
                    "terminal output replay contains an offset gap"
                );
            }
            // First record of this generation inside the scan window. A
            // checkpoint base covers everything before the window, so an
            // arbitrary first offset is the continuation point, exactly as
            // the restore-preview reducer accepts it.
            _ => {}
        }
        anyhow::ensure!(
            self.output_bytes.saturating_add(byte_count) <= self.budget,
            "terminal output tail exceeds the bounded replay budget"
        );
        self.stream = Some((generation, end));
        self.output_bytes += byte_count;
        self.events.push(RestoredTailEvent::Output(bytes.to_vec()));
        Ok(())
    }

    fn apply_resize(&mut self, record: &SessionJournalRecord) -> anyhow::Result<()> {
        anyhow::ensure!(
            record.payload["format"].as_str() == Some("cmux.terminal-geometry.v1"),
            "terminal resize replay metadata is invalid"
        );
        let cols = geometry_field(&record.payload, "cols")?;
        let rows = geometry_field(&record.payload, "rows")?;
        let cell_width = geometry_field(&record.payload, "cell_width")?;
        let cell_height = geometry_field(&record.payload, "cell_height")?;
        anyhow::ensure!(
            (1..=10_000).contains(&cols)
                && (1..=10_000).contains(&rows)
                && (1..=10_000).contains(&cell_width)
                && (1..=10_000).contains(&cell_height)
                && u64::from(cols).saturating_mul(u64::from(rows)) <= 4_000_000,
            "terminal resize geometry is invalid"
        );
        anyhow::ensure!(
            self.resize_events < MAX_RESTORE_TAIL_RESIZE_EVENTS,
            "terminal resize tail exceeds the bounded replay budget"
        );
        self.resize_events += 1;
        self.events.push(RestoredTailEvent::Resize {
            cols: u16::try_from(cols).context("terminal resize cols overflow")?,
            rows: u16::try_from(rows).context("terminal resize rows overflow")?,
            cell_width,
            cell_height,
        });
        Ok(())
    }

    pub(crate) fn finish(self) -> (Vec<RestoredTailEvent>, u64, u64, Option<String>) {
        (self.events, self.output_bytes, self.resize_events, self.degraded)
    }
}

/// Decode one `cmux.vt-replay.v1` checkpoint blob back into replay parts.
/// Inverse of the capture encoding in `journal_checkpoint::capture`.
pub(crate) fn decode_vt_replay_blob(
    reference: &JournalContentRef,
    uncompressed: &[u8],
) -> anyhow::Result<RestoredTerminalContent> {
    let value: Value =
        serde_json::from_slice(uncompressed).context("checkpoint replay blob is not JSON")?;
    anyhow::ensure!(
        value["format"].as_str() == Some("cmux.vt-replay.v1"),
        "checkpoint replay blob format is unsupported"
    );
    let cols = u16::try_from(value["cols"].as_u64().context("replay blob omitted cols")?)
        .context("replay blob cols overflow")?;
    let rows = u16::try_from(value["rows"].as_u64().context("replay blob omitted rows")?)
        .context("replay blob rows overflow")?;
    anyhow::ensure!(cols > 0 && rows > 0, "replay blob grid must be non-zero");
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value["bytes_base64"].as_str().context("replay blob omitted bytes")?)
        .context("replay blob bytes are not base64")?;
    let kitty_image_aliases = value["kitty_image_aliases"]
        .as_array()
        .context("replay blob omitted kitty image aliases")?
        .iter()
        .map(|alias| {
            Ok(KittyImageAlias {
                image_id: u32::try_from(
                    alias["image_id"].as_u64().context("kitty alias omitted image_id")?,
                )?,
                image_number: u32::try_from(
                    alias["image_number"].as_u64().context("kitty alias omitted image_number")?,
                )?,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let kitty = &value["kitty_state"];
    let limits = &kitty["limits"];
    let kitty_state = KittyReplayState {
        limits: KittyGraphicsLimits {
            image_bytes: decimal_field(limits, "image_bytes")?,
            inflight_bytes: decimal_field(limits, "inflight_bytes")?,
            images: decimal_field(limits, "images")?,
            placements: decimal_field(limits, "placements")?,
        },
        replay_cursor_offset: u32::try_from(
            kitty["replay_cursor_offset"]
                .as_u64()
                .context("replay blob omitted kitty replay cursor")?,
        )
        .context("kitty replay cursor overflow")?,
        replay_next_image_ids: kitty_cursors(&kitty["replay_next_image_ids"])?,
        next_image_ids: kitty_cursors(&kitty["next_image_ids"])?,
    };
    anyhow::ensure!(
        reference.cols == cols && reference.rows == rows,
        "checkpoint replay blob grid does not match its reference"
    );
    Ok(RestoredTerminalContent {
        checkpoint_id: None,
        replay: bytes,
        kitty_image_aliases,
        kitty_state,
        cols,
        rows,
        tail: Vec::new(),
        tail_output_bytes: 0,
        tail_resize_events: 0,
        degraded: None,
    })
}

fn kitty_cursors(value: &Value) -> anyhow::Result<KittyImageIdCursors> {
    Ok(KittyImageIdCursors {
        primary: u32::try_from(
            value["primary"].as_u64().context("kitty cursors omitted primary")?,
        )?,
        alternate: u32::try_from(
            value["alternate"].as_u64().context("kitty cursors omitted alternate")?,
        )?,
    })
}

/// Decimal string or integer field, matching the journal's decimal-string
/// serialization for JavaScript-safe transport.
fn decimal_field(payload: &Value, field: &str) -> anyhow::Result<u64> {
    let value = payload.get(field).with_context(|| format!("journal payload omitted {field}"))?;
    if let Some(value) = value.as_u64() {
        return Ok(value);
    }
    value
        .as_str()
        .with_context(|| format!("journal payload {field} is not a decimal"))?
        .parse::<u64>()
        .with_context(|| format!("journal payload {field} is not a decimal"))
}

fn geometry_field(payload: &Value, field: &str) -> anyhow::Result<u32> {
    u32::try_from(
        payload
            .get(field)
            .and_then(Value::as_u64)
            .with_context(|| format!("terminal geometry omitted {field}"))?,
    )
    .with_context(|| format!("terminal geometry {field} overflow"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace_registry::{
        JournalAuthority, JournalClass, JournalProducer, JournalReplayPolicy, JournalSensitivity,
        JournalSubject,
    };
    use serde_json::json;

    const TERMINAL: &str = "term_0000000000000000000000000000dead";

    fn output_record(
        sequence: u64,
        generation: &str,
        start: u64,
        bytes: &[u8],
    ) -> SessionJournalRecord {
        let end = start + bytes.len() as u64;
        SessionJournalRecord {
            sequence,
            event_id: format!("event_terminal_{sequence}"),
            schema_version: 1,
            kind: "terminal.output".into(),
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Required,
            occurred_at_ms: sequence,
            committed_at_ms: sequence,
            producer: JournalProducer { kind: "terminal_runtime".into(), id: TERMINAL.into() },
            authority: Some(JournalAuthority {
                principal_id: "cmux.terminal-runtime".into(),
                lease_id: format!("terminal:{TERMINAL}"),
                generation: generation.into(),
                role: "terminal.runtime".into(),
            }),
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: vec![JournalSubject { kind: "terminal".into(), id: TERMINAL.into() }],
            sensitivity: JournalSensitivity::Sensitive,
            payload: json!({
                "format": "cmux.terminal-output.v1",
                "encoding": "raw",
                "byte_count": bytes.len().to_string(),
                "sha256": encode_hex(Sha256::digest(bytes).as_slice()),
                "stream_offset_start": start.to_string(),
                "stream_offset_end": end.to_string(),
            }),
            resource_revision: None,
            previous_resource_revision: None,
            terminal_output: Some(bytes.to_vec().into()),
        }
    }

    fn resize_record(
        sequence: u64,
        generation: &str,
        cols: u32,
        rows: u32,
    ) -> SessionJournalRecord {
        let mut record = output_record(sequence, generation, 0, b"");
        record.kind = "terminal.resized".into();
        record.class = JournalClass::State;
        record.terminal_output = None;
        record.payload = json!({
            "format": "cmux.terminal-geometry.v1",
            "cols": cols,
            "rows": rows,
            "cell_width": 8,
            "cell_height": 16,
        });
        record
    }

    fn gap_record(sequence: u64, generation: &str, reason: &str) -> SessionJournalRecord {
        let mut record = output_record(sequence, generation, 0, b"");
        record.kind = "terminal.output.gap".into();
        record.class = JournalClass::State;
        record.terminal_output = None;
        record.payload = json!({
            "format": "cmux.terminal-output-gap.v1",
            "reason": reason,
        });
        record
    }

    #[test]
    fn fold_applies_contiguous_output_and_resize_in_commit_order() {
        let mut fold = TerminalTailFold::new(TERMINAL, 1024);
        assert!(fold.apply(&output_record(10, "gen-1", 0, b"hello ")));
        assert!(fold.apply(&resize_record(11, "gen-1", 132, 43)));
        assert!(fold.apply(&output_record(12, "gen-1", 6, b"world")));
        let (events, output_bytes, resize_events, degraded) = fold.finish();
        assert_eq!(degraded, None);
        assert_eq!(output_bytes, 11);
        assert_eq!(resize_events, 1);
        assert_eq!(
            events,
            vec![
                RestoredTailEvent::Output(b"hello ".to_vec()),
                RestoredTailEvent::Resize { cols: 132, rows: 43, cell_width: 8, cell_height: 16 },
                RestoredTailEvent::Output(b"world".to_vec()),
            ]
        );
    }

    #[test]
    fn fold_ignores_other_terminals_and_other_kinds() {
        let mut fold = TerminalTailFold::new(TERMINAL, 1024);
        let mut foreign = output_record(10, "gen-1", 0, b"foreign");
        foreign.subjects =
            vec![JournalSubject { kind: "terminal".into(), id: "term_other".into() }];
        assert!(fold.apply(&foreign));
        let mut unrelated = output_record(11, "gen-1", 0, b"");
        unrelated.kind = "workspace.create".into();
        unrelated.payload = json!({});
        assert!(fold.apply(&unrelated));
        assert!(fold.apply(&output_record(12, "gen-1", 0, b"mine")));
        let (events, output_bytes, _, degraded) = fold.finish();
        assert_eq!(degraded, None);
        assert_eq!(output_bytes, 4);
        assert_eq!(events, vec![RestoredTailEvent::Output(b"mine".to_vec())]);
    }

    #[test]
    fn fold_stops_at_gap_record_and_keeps_the_provable_prefix() {
        let mut fold = TerminalTailFold::new(TERMINAL, 1024);
        assert!(fold.apply(&output_record(10, "gen-1", 0, b"before")));
        assert!(!fold.apply(&gap_record(11, "gen-1", "detach_fence_failed")));
        assert!(!fold.apply(&output_record(12, "gen-1", 6, b"after")));
        assert!(fold.stopped());
        let (events, output_bytes, _, degraded) = fold.finish();
        assert_eq!(events, vec![RestoredTailEvent::Output(b"before".to_vec())]);
        assert_eq!(output_bytes, 6);
        assert_eq!(degraded.as_deref(), Some("terminal output gap: detach_fence_failed"));
    }

    #[test]
    fn fold_stops_at_a_same_generation_offset_discontinuity() {
        let mut fold = TerminalTailFold::new(TERMINAL, 1024);
        assert!(fold.apply(&output_record(10, "gen-1", 0, b"abc")));
        assert!(!fold.apply(&output_record(11, "gen-1", 9, b"skip")));
        let (events, _, _, degraded) = fold.finish();
        assert_eq!(events, vec![RestoredTailEvent::Output(b"abc".to_vec())]);
        assert!(
            degraded.as_deref().is_some_and(|reason| reason.contains("offset gap")),
            "{degraded:?}"
        );
    }

    #[test]
    fn fold_follows_a_new_generation_from_any_offset_in_commit_order() {
        let mut fold = TerminalTailFold::new(TERMINAL, 1024);
        assert!(fold.apply(&output_record(10, "gen-1", 100, b"old")));
        assert!(fold.apply(&output_record(11, "gen-2", 0, b"new")));
        let (events, output_bytes, _, degraded) = fold.finish();
        assert_eq!(degraded, None);
        assert_eq!(output_bytes, 6);
        assert_eq!(
            events,
            vec![
                RestoredTailEvent::Output(b"old".to_vec()),
                RestoredTailEvent::Output(b"new".to_vec()),
            ]
        );
    }

    #[test]
    fn fold_stops_when_the_tail_exceeds_the_replay_budget() {
        let mut fold = TerminalTailFold::new(TERMINAL, 4);
        assert!(fold.apply(&output_record(10, "gen-1", 0, b"okay")));
        assert!(!fold.apply(&output_record(11, "gen-1", 4, b"x")));
        let (events, output_bytes, _, degraded) = fold.finish();
        assert_eq!(events.len(), 1);
        assert_eq!(output_bytes, 4);
        assert!(
            degraded.as_deref().is_some_and(|reason| reason.contains("budget")),
            "{degraded:?}"
        );
    }

    #[test]
    fn fold_rejects_a_corrupt_output_digest() {
        let mut fold = TerminalTailFold::new(TERMINAL, 1024);
        let mut record = output_record(10, "gen-1", 0, b"payload");
        record.payload["sha256"] = json!(encode_hex(Sha256::digest(b"other").as_slice()));
        assert!(!fold.apply(&record));
        let (events, _, _, degraded) = fold.finish();
        assert!(events.is_empty());
        assert!(degraded.as_deref().is_some_and(|reason| reason.contains("digest")));
    }

    #[test]
    fn decode_vt_replay_blob_round_trips_the_capture_encoding() {
        let bytes = b"\x1b[2J\x1b[Hrestored".to_vec();
        let encoded = json!({
            "format": "cmux.vt-replay.v1",
            "cols": 120,
            "rows": 32,
            "bytes_base64": base64::engine::general_purpose::STANDARD.encode(&bytes),
            "kitty_image_aliases": [{"image_id": 7, "image_number": 9}],
            "kitty_state": {
                "limits": {
                    "image_bytes": "1048576",
                    "inflight_bytes": "65536",
                    "images": "64",
                    "placements": "128",
                },
                "replay_cursor_offset": 0,
                "replay_next_image_ids": {"primary": 1, "alternate": 2},
                "next_image_ids": {"primary": 3, "alternate": 4},
            },
        });
        let serialized = serde_json::to_vec(&encoded).unwrap();
        let reference = JournalContentRef {
            content_id: format!("jcontent_{}", encode_hex(Sha256::digest(&serialized).as_slice())),
            terminal_id: TERMINAL.into(),
            format: "cmux.vt-replay.v1".into(),
            codec: "gzip".into(),
            sha256: encode_hex(Sha256::digest(&serialized).as_slice()),
            uncompressed_bytes: serialized.len() as u64,
            cols: 120,
            rows: 32,
        };
        let content = decode_vt_replay_blob(&reference, &serialized).unwrap();
        assert_eq!(content.replay, bytes);
        assert_eq!((content.cols, content.rows), (120, 32));
        assert_eq!(content.kitty_image_aliases.len(), 1);
        assert_eq!(content.kitty_image_aliases[0].image_id, 7);
        assert_eq!(content.kitty_state.limits.image_bytes, 1_048_576);
        assert_eq!(content.kitty_state.next_image_ids.primary, 3);
        // The decoder returns a checkpoint-less base; the caller stamps the
        // checkpoint id and tail.
        assert_eq!(content.source_label(), "none");
        assert!(!content.is_empty());
    }

    #[test]
    fn decode_vt_replay_blob_rejects_a_grid_mismatch() {
        let encoded = json!({
            "format": "cmux.vt-replay.v1",
            "cols": 80,
            "rows": 24,
            "bytes_base64": "",
            "kitty_image_aliases": [],
            "kitty_state": {
                "limits": {
                    "image_bytes": "0",
                    "inflight_bytes": "0",
                    "images": "0",
                    "placements": "0",
                },
                "replay_cursor_offset": 0,
                "replay_next_image_ids": {"primary": 1, "alternate": 1},
                "next_image_ids": {"primary": 1, "alternate": 1},
            },
        });
        let serialized = serde_json::to_vec(&encoded).unwrap();
        let reference = JournalContentRef {
            content_id: "jcontent_x".into(),
            terminal_id: TERMINAL.into(),
            format: "cmux.vt-replay.v1".into(),
            codec: "gzip".into(),
            sha256: "x".into(),
            uncompressed_bytes: serialized.len() as u64,
            cols: 100,
            rows: 30,
        };
        assert!(decode_vt_replay_blob(&reference, &serialized).is_err());
    }
}
