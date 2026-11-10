//! Session event streams: preparing the initial session event items,
//! starting the stream worker and running it until cancellation or
//! disconnect.

use super::MessageWriter;
use super::OutboundStream;
use super::ResourceWorkerPermit;
use super::register_resource_outbound;
use super::resource_session_snapshot;
use super::resource_stream_end;
use super::resource_stream_id;
use super::send_resource_stream_item;
use super::session_stream;
use crate::Mux;
use crate::panic_free::JsonFields;
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::StreamPublicId;
use crate::resource::TerminalPublicId;
use crate::resource::WireDecimal;
use crate::state::placement_shift::CAPABILITY as PLACEMENT_SHIFT_CAPABILITY;
use crate::state::placement_shift::PlacementShift;
use crate::stream_interrupt::StreamInterrupt;
use serde_json::Value;
use serde_json::json;
use std::collections::HashMap;
use std::hash::Hash;
use std::hash::Hasher;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;

pub(super) struct SessionEventStreamStart {
    pub(super) stream_id: StreamPublicId,
    pub(super) outbound: OutboundStream,
    pub(super) canceled: Arc<AtomicBool>,
    pub(super) _worker_permit: ResourceWorkerPermit,
    pub(super) initial_items: Vec<(Value, Value)>,
    pub(super) next_sequence: u64,
    pub(super) last_revision: u64,
    pub(super) epoch: u64,
    /// The registry generation of this stream's cursors.
    pub(super) generation: String,
    /// The live terminal sequence this stream's client has
    /// (`mux/terminal_live.rs`): each terminal whose live facts changed
    /// through it was sent, or is in the snapshot.
    pub(super) live_sequence: u64,
    /// The connection sent `session-live-cursor-v1`: each cursor says the
    /// client's live position.
    live_cursor: bool,
    /// What this stream sent of its terminals; at the start, what the
    /// replayed batches of a resume carry.
    sent: SentTerminals,
}

/// A stream cursor: the registry `generation` and `revision` and, for a
/// connection that sent `session-live-cursor-v1`, `live`: the live position
/// (`Mux::terminal_live_position`) of a client that got this cursor. A
/// live terminal fact moves no revision, so `generation` and `revision`
/// alone do not say which live facts the client has.
fn stream_cursor(generation: &str, revision: u64, live: Option<String>) -> Value {
    let mut cursor = json!({"generation":generation, "revision":revision.to_string()});
    if let (Some(live), Some(fields)) = (live, cursor.as_object_mut()) {
        fields.insert("live".into(), Value::String(live));
    }
    cursor
}

impl SessionEventStreamStart {
    /// The cursor of an item at `revision` for a client that has the live
    /// changes through the sequence `live`.
    fn cursor(&self, mux: &Mux, generation: &str, revision: u64, live: u64) -> Value {
        stream_cursor(
            generation,
            revision,
            self.live_cursor.then(|| mux.terminal_live_position(live)),
        )
    }
}

pub(super) fn prepare_session_event_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, SessionEventStreamStart), ResourceError> {
    mux.resolve_resource_path(crate::ResourceTarget::Session, &request.selectors)?;
    let stream_id = resource_stream_id(request)?;
    let epoch = mux.resource_event_epoch();
    // Before the snapshot: a live change after it reaches this stream.
    let mut live_sequence = mux.terminal_live_sequence();
    let live_cursor =
        mux.control_clients.supports_capability(client, super::SESSION_LIVE_CURSOR_CAPABILITY);
    let position = |sequence: u64| live_cursor.then(|| mux.terminal_live_position(sequence));
    let mut snapshot = resource_session_snapshot(mux, client, &request.selectors)?;
    if let (Some(live), Some(cursor)) =
        (position(live_sequence), snapshot.get_mut("cursor").and_then(Value::as_object_mut))
    {
        cursor.insert("live".into(), Value::String(live));
    }
    let snapshot_cursor = snapshot.field("cursor").clone();
    let cursor_missing = || {
        ResourceError::operation_failed(
            request.envelope.operation.wire_name(),
            "the session snapshot has no valid cursor",
            json!({}),
        )
    };
    let snapshot_generation =
        snapshot_cursor.field("generation").as_str().ok_or_else(cursor_missing)?.to_string();
    let snapshot_revision = snapshot_cursor
        .field("revision")
        .as_str()
        .and_then(|revision| revision.parse::<u64>().ok())
        .ok_or_else(cursor_missing)?;
    let requested_cursor = request
        .fields
        .get("cursor")
        .map(|cursor| {
            let generation = cursor
                .field("generation")
                .as_str()
                .ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("cursor"),
                        "cursor generation is missing",
                    )
                })?
                .to_string();
            let revision = serde_json::from_value::<WireDecimal>(cursor.field("revision").clone())
                .map(WireDecimal::get)
                .map_err(|_| {
                    ResourceError::validation_invalid(Some("cursor"), "cursor revision is invalid")
                })?;
            // The live position, when the cursor has one this process gave.
            // Without one the stream sends every terminal with a live
            // change: a cursor of two fields does not say which the client
            // has, and a position of another daemon process says nothing
            // about this one's.
            let live = cursor
                .field("live")
                .as_str()
                .and_then(|text| mux.terminal_live_sequence_of(text))
                .unwrap_or(0);
            Ok::<_, ResourceError>((generation, revision, live))
        })
        .transpose()?;

    let mut initial_items = Vec::new();
    let mut sent = SentTerminals::default();
    let last_revision;
    let opened_cursor;
    match requested_cursor {
        None => {
            initial_items.push((
                snapshot_cursor.clone(),
                json!({
                    "kind":"snapshot",
                    "cursor":snapshot_cursor,
                    "reset_reason":"initial",
                    "snapshot":snapshot,
                }),
            ));
            last_revision = snapshot_revision;
            opened_cursor =
                stream_cursor(&snapshot_generation, snapshot_revision, position(live_sequence));
        }
        Some((generation, _, _)) if generation != snapshot_generation => {
            initial_items.push((
                snapshot_cursor.clone(),
                json!({
                    "kind":"snapshot",
                    "cursor":snapshot_cursor,
                    "reset_reason":"generation_changed",
                    "snapshot":snapshot,
                }),
            ));
            last_revision = snapshot_revision;
            opened_cursor =
                stream_cursor(&snapshot_generation, snapshot_revision, position(live_sequence));
        }
        Some((generation, revision, resumed_live)) => match mux.resource_events_after(revision) {
            Ok(page)
                if page.batches.last().map_or(revision, |batch| batch.revision)
                    < page.head_revision =>
            {
                initial_items.push((
                    snapshot_cursor.clone(),
                    json!({
                        "kind":"snapshot",
                        "cursor":snapshot_cursor,
                        "reset_reason":"cursor_expired",
                        "snapshot":snapshot,
                    }),
                ));
                last_revision = snapshot_revision;
                opened_cursor =
                    stream_cursor(&snapshot_generation, snapshot_revision, position(live_sequence));
            }
            Ok(page) => {
                let mut deltas = Vec::with_capacity(page.batches.len());
                let mut replayed = SentTerminals::default();
                let mut failed = None;
                for batch in page.batches {
                    let cursor =
                        stream_cursor(&page.generation, batch.revision, position(resumed_live));
                    note_committed_terminals(&batch.changes, &mut replayed, true);
                    match delta_item(mux, client, &page.generation, &cursor, batch) {
                        Ok(item) => deltas.push((cursor, item)),
                        Err(error) => {
                            failed = Some(error);
                            break;
                        }
                    }
                }
                if let Some(error) = failed {
                    // The placements could not be read: resume from the
                    // snapshot instead, as for an expired cursor.
                    eprintln!("cmux-tui: session.events: placement restatement failed: {error:#}");
                    initial_items.push((
                        snapshot_cursor.clone(),
                        json!({
                            "kind":"snapshot",
                            "cursor":snapshot_cursor,
                            "reset_reason":"cursor_expired",
                            "snapshot":snapshot,
                        }),
                    ));
                    last_revision = snapshot_revision;
                    opened_cursor = stream_cursor(
                        &snapshot_generation,
                        snapshot_revision,
                        position(live_sequence),
                    );
                } else {
                    initial_items.extend(deltas);
                    // No snapshot: the stream sends the current record of
                    // each terminal whose live facts changed after the
                    // cursor's live position (of each terminal with a live
                    // change, when the cursor has none). A replayed batch
                    // carries the live facts of its commit, which can be
                    // older than a live item the client has: the stream
                    // checks each terminal such a batch upserts again.
                    live_sequence = resumed_live;
                    sent = replayed;
                    last_revision = page.head_revision;
                    opened_cursor =
                        stream_cursor(&page.generation, page.head_revision, position(resumed_live));
                }
            }
            Err(error) if error.to_string().starts_with("cursor.gap:") => {
                initial_items.push((
                    snapshot_cursor.clone(),
                    json!({
                        "kind":"snapshot",
                        "cursor":snapshot_cursor,
                        "reset_reason":"cursor_expired",
                        "snapshot":snapshot,
                    }),
                ));
                last_revision = snapshot_revision;
                opened_cursor =
                    stream_cursor(&snapshot_generation, snapshot_revision, position(live_sequence));
            }
            Err(error) if error.to_string().starts_with("cursor.invalid:") => {
                return Err(ResourceError::new(
                    "cursor.invalid",
                    "cursor revision is ahead of the session",
                    json!({
                        "requested":{
                            "generation":generation,
                            "revision":revision.to_string(),
                        },
                        "current":snapshot_cursor,
                        "reason":"cursor revision is ahead of the session",
                    }),
                    false,
                ));
            }
            Err(error) => {
                return Err(ResourceError::operation_failed(
                    "session.events",
                    "could not read session event journal",
                    json!({"error":error.to_string()}),
                ));
            }
        },
    }
    let overflow = resource_stream_end(
        &stream_id,
        "gap",
        Some(opened_cursor.clone()),
        Some("request a fresh session snapshot"),
        None,
    );
    let outbound = writer
        .start_stream(&overflow)
        .map_err(|_| ResourceError::transport_closed("could not allocate an outbound stream"))?;
    let (canceled, worker_permit) =
        register_resource_outbound(mux, client, &stream_id, &outbound, "session.events")?;
    Ok((
        json!({"stream_id":stream_id,"cursor":opened_cursor}),
        SessionEventStreamStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            initial_items,
            next_sequence: 0,
            last_revision,
            epoch,
            generation: snapshot_generation,
            live_sequence,
            live_cursor,
            sent,
        },
    ))
}

pub(super) fn start_session_event_stream(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: SessionEventStreamStart,
) {
    let stream_id = start.stream_id.clone();
    let outbound = start.outbound.clone();
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn = std::thread::Builder::new()
        .name("mux-resource-session-events".into())
        .spawn(move || run_session_event_stream(&worker_mux, client, &worker_writer, start));
    if spawn.is_err() {
        let _ = mux.control_clients.take_resource_stream(client, &stream_id);
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a new session event stream"),
            Some((
                ResourceOperation::SessionEvents,
                ResourceError::operation_failed(
                    "session.events",
                    "could not start the session event stream",
                    json!({}),
                ),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
    }
}

pub(super) fn run_session_event_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    mut stream: SessionEventStreamStart,
) {
    for (cursor, item) in stream.initial_items.drain(..) {
        if stream.canceled.load(Ordering::Acquire)
            || !send_resource_stream_item(
                writer,
                &stream.outbound,
                &stream.stream_id,
                stream.next_sequence,
                &cursor,
                item,
            )
        {
            mux.control_clients.finish_resource_stream(
                client,
                &stream.stream_id,
                stream.outbound.id,
            );
            return;
        }
        stream.next_sequence = stream.next_sequence.saturating_add(1);
    }

    // Every journal commit (terminal output too) wakes every stream. Reading
    // pages on the stream's own read-only connection keeps those reads off
    // the registry lock, which every request and the journal writer need.
    let mut reader = match mux.resource_event_reader() {
        Ok(reader) => reader,
        Err(error) => {
            eprintln!("cmux-tui: session.events: open resource event reader: {error:#}");
            None
        }
    };
    let interrupt = StreamInterrupt::new();
    writer.register_interrupt(&interrupt);
    stream.outbound.register_interrupt(&interrupt);
    mux.wake_journal_waiters_on(&interrupt);
    'stream: loop {
        if session_stream::stopped(&stream.canceled, writer, &stream.outbound) {
            break;
        }
        // The terminals a committed batch gave a new value: that commit
        // read its live facts before it committed, and a live item with
        // newer ones can have gone out before the batch did. Before the
        // wait: a resume has the terminals of its replayed batches here.
        while let Some(terminal) = stream.sent.committed.pop() {
            match send_live_terminal(mux, client, writer, &mut stream, &mut reader, &terminal, None)
            {
                Sent::Current => {}
                Sent::Ended => break 'stream,
                Sent::Closed => return,
            }
        }
        let (epoch, live) = mux.wait_for_session_event_until_interrupted(
            stream.epoch,
            stream.live_sequence,
            &interrupt,
        );
        if epoch != stream.epoch {
            stream.epoch = epoch;
            match send_committed(mux, client, writer, &mut stream, &mut reader) {
                Sent::Current => {}
                Sent::Ended => break 'stream,
                Sent::Closed => return,
            }
        }
        if live == stream.live_sequence {
            continue;
        }
        // Only the terminals whose live facts changed, never all terminals,
        // oldest change first: the cursor of each item says the live
        // position of its change, so a client that leaves in the middle
        // resumes after the last one it got.
        let (live, terminals) = mux.terminal_live_changes_after(stream.live_sequence);
        for (sequence, terminal) in terminals {
            match send_live_terminal(
                mux,
                client,
                writer,
                &mut stream,
                &mut reader,
                &terminal,
                Some(sequence),
            ) {
                Sent::Current => stream.live_sequence = sequence,
                Sent::Ended => break 'stream,
                Sent::Closed => return,
            }
        }
        stream.live_sequence = live;
    }
    mux.control_clients.finish_resource_stream(client, &stream.stream_id, stream.outbound.id);
}

/// What a send step left of the stream.
enum Sent {
    /// The stream is open and has everything the step had to send.
    Current,
    /// The step sent the stream's end; the caller finishes the stream.
    Ended,
    /// The client is gone and the stream is finished.
    Closed,
}

type EventReader = Option<(crate::workspace_registry::SessionJournalReader, String)>;

/// What this stream sent of its terminals.
#[derive(Default)]
struct SentTerminals {
    /// The value last sent for a terminal (its hash): a live item equal to
    /// it is not sent again.
    hashes: HashMap<TerminalPublicId, u64>,
    /// The terminals a committed batch gave a new value since the last
    /// live step.
    committed: Vec<TerminalPublicId>,
}

/// A hash of `value` that does not depend on the order of object keys.
fn value_hash(value: &Value) -> u64 {
    fn feed(value: &Value, hasher: &mut std::collections::hash_map::DefaultHasher) {
        match value {
            Value::Object(object) => {
                let mut fields = object.iter().collect::<Vec<_>>();
                fields.sort_by(|left, right| left.0.cmp(right.0));
                fields.len().hash(hasher);
                for (key, field) in fields {
                    key.hash(hasher);
                    feed(field, hasher);
                }
            }
            Value::Array(items) => {
                items.len().hash(hasher);
                for item in items {
                    feed(item, hasher);
                }
            }
            scalar => scalar.to_string().hash(hasher),
        }
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    feed(value, &mut hasher);
    hasher.finish()
}

/// Remember, for each terminal a committed batch changes, the value the
/// client now has. `replayed`: the batch is one a resume replays, so each
/// terminal it upserts is checked again (its live facts are the commit's,
/// not the newest).
fn note_committed_terminals(changes: &Value, sent: &mut SentTerminals, replayed: bool) {
    for change in changes.as_array().map(Vec::as_slice).unwrap_or_default() {
        if change.field("resource").as_str() != Some("terminal") {
            continue;
        }
        let Some(id) = change.field("id").as_str().and_then(|id| TerminalPublicId::parse(id).ok())
        else {
            continue;
        };
        if change.field("kind").as_str() == Some("upsert") {
            let hash = value_hash(change.field("value"));
            // A value that replaces another one this stream sent can be
            // older than a live item already sent: check it again.
            let again = match sent.hashes.insert(id.clone(), hash) {
                Some(previous) => previous != hash,
                None => replayed,
            };
            if again {
                sent.committed.push(id);
            }
        } else {
            sent.hashes.remove(&id);
        }
    }
}

/// Send every committed batch after the stream's revision.
fn send_committed(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    stream: &mut SessionEventStreamStart,
    reader: &mut EventReader,
) -> Sent {
    fn gap(stream: &SessionEventStreamStart, cursor: Option<Value>) -> Value {
        resource_stream_end(
            &stream.stream_id,
            "gap",
            cursor,
            Some("request a fresh session snapshot"),
            None,
        )
    }
    loop {
        let read = match &*reader {
            Some((reader, generation)) => {
                reader.resource_events_after(generation, stream.last_revision)
            }
            None => mux.resource_events_after(stream.last_revision),
        };
        // A reader error (a busy or replaced file) falls back to the
        // registry, which decides between a page and a gap.
        let read = match read {
            Err(error) if reader.is_some() => {
                eprintln!("cmux-tui: session.events: resource event reader: {error:#}");
                *reader = None;
                mux.resource_events_after(stream.last_revision)
            }
            read => read,
        };
        let Ok(page) = read else {
            let _ = writer.send_terminal(&gap(stream, None), &stream.outbound);
            return Sent::Ended;
        };
        let head_revision = page.head_revision;
        if page.batches.is_empty() && stream.last_revision < head_revision {
            let _ = writer.send_terminal(&gap(stream, None), &stream.outbound);
            return Sent::Ended;
        }
        for batch in page.batches {
            let cursor = stream.cursor(mux, &page.generation, batch.revision, stream.live_sequence);
            let revision = batch.revision;
            note_committed_terminals(&batch.changes, &mut stream.sent, false);
            let item = match delta_item(mux, client, &page.generation, &cursor, batch) {
                Ok(item) => item,
                Err(error) => {
                    eprintln!("cmux-tui: session.events: placement restatement failed: {error:#}");
                    let _ = writer.send_terminal(&gap(stream, None), &stream.outbound);
                    return Sent::Ended;
                }
            };
            let _ =
                writer.update_stream_overflow(&stream.outbound, &gap(stream, Some(cursor.clone())));
            if stream.canceled.load(Ordering::Acquire)
                || !send_resource_stream_item(
                    writer,
                    &stream.outbound,
                    &stream.stream_id,
                    stream.next_sequence,
                    &cursor,
                    item,
                )
            {
                mux.control_clients.finish_resource_stream(
                    client,
                    &stream.stream_id,
                    stream.outbound.id,
                );
                return Sent::Closed;
            }
            stream.next_sequence = stream.next_sequence.saturating_add(1);
            stream.last_revision = revision;
        }
        if stream.last_revision >= head_revision {
            return Sent::Current;
        }
    }
}

/// Send `terminal`'s record with its live facts (an OSC 9;4 progress, the
/// last output time, a program status report that keeps its state) as a
/// `delta` item that moves no revision: `previous_revision`, `revision` and
/// the cursor are the stream's revision. Nothing was committed for it.
///
/// Order with the committed deltas: the durable part of the record is read
/// at one revision. When that is after the stream's, the committed batches
/// go first, so the item never shows a record older than a committed delta
/// the client has. The live facts come from the terminal's memory now, as
/// they do in every committed terminal upsert, so a later commit carries
/// them too.
///
/// `mark`: the live sequence of the change this item is for; the item's
/// cursor says that position. `None` for a check after a committed batch:
/// the cursor keeps the stream's position.
fn send_live_terminal(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    stream: &mut SessionEventStreamStart,
    reader: &mut EventReader,
    terminal: &TerminalPublicId,
    mark: Option<u64>,
) -> Sent {
    let value = loop {
        let read = mux.live_terminal_upsert(reader.as_ref().map(|(journal, _)| journal), terminal);
        let (revision, value) = match read {
            Ok(Some(read)) => read,
            // Closed or not running: its delete or its exit is a commit.
            Ok(None) => return Sent::Current,
            Err(error) if reader.is_some() => {
                eprintln!("cmux-tui: session.events: live terminal reader: {error:#}");
                *reader = None;
                continue;
            }
            Err(error) => {
                eprintln!("cmux-tui: session.events: live terminal read: {error:#}");
                return Sent::Current;
            }
        };
        if revision <= stream.last_revision {
            break value;
        }
        // Each pass sends at least one committed batch or ends the stream.
        match send_committed(mux, client, writer, stream, reader) {
            Sent::Current => {}
            ended => return ended,
        }
    };
    let hash = value_hash(&value);
    if stream.sent.hashes.insert(terminal.clone(), hash) == Some(hash) {
        return Sent::Current;
    }
    let cursor = stream.cursor(
        mux,
        &stream.generation,
        stream.last_revision,
        mark.unwrap_or(stream.live_sequence),
    );
    let revision = stream.last_revision.to_string();
    let item = json!({
        "kind":"delta",
        "cursor":cursor,
        "previous_revision":revision,
        "revision":revision,
        "changes":[{
            "kind":"upsert", "sequence":0, "resource":"terminal", "id":terminal, "value":value,
        }],
    });
    if stream.canceled.load(Ordering::Acquire)
        || !send_resource_stream_item(
            writer,
            &stream.outbound,
            &stream.stream_id,
            stream.next_sequence,
            &cursor,
            item,
        )
    {
        mux.control_clients.finish_resource_stream(client, &stream.stream_id, stream.outbound.id);
        return Sent::Closed;
    }
    stream.next_sequence = stream.next_sequence.saturating_add(1);
    Sent::Current
}

/// One journal batch as the `session.events` delta item `client` reads. A
/// batch with a placement shift (`crate::state::placement_shift`) restates
/// the shifted placements, from the current state, for a connection that
/// did not echo `placement-shift-v1`; a connection that did gets the batch
/// as stored.
fn delta_item(
    mux: &Mux,
    client: u64,
    generation: &str,
    cursor: &Value,
    batch: crate::workspace_registry::ResourceEventBatch,
) -> anyhow::Result<Value> {
    let mut changes = batch.changes;
    if let Some(shift) = batch.placement_shift.as_ref().and_then(PlacementShift::from_value)
        && !mux.control_clients.supports_capability(client, PLACEMENT_SHIFT_CAPABILITY)
        && let Some(array) = changes.as_array_mut()
    {
        let all = current_placements(mux, generation)?;
        for mut change in crate::state::placement_shift::restatement(&all, shift) {
            change.insert("sequence", json!(array.len()));
            array.push(change);
        }
    }
    Ok(json!({
        "kind":"delta",
        "cursor":cursor,
        "previous_revision":batch.previous_revision.to_string(),
        "revision":batch.revision.to_string(),
        "changes":changes,
    }))
}

/// The current placements, shared by every connection and every batch
/// while the state they depend on is unchanged (keyed by the registry's
/// generation, its resource and personal revisions and its write count). A
/// read at or after a batch's commit is valid for that batch
/// (`crate::state::placement_shift`), so a stream that resumes across many
/// shifted batches reads them once.
type PlacementCache = Option<((String, (u64, u64, u64)), Arc<Vec<Value>>)>;
static PLACEMENTS: std::sync::Mutex<PlacementCache> = std::sync::Mutex::new(None);

fn current_placements(mux: &Mux, generation: &str) -> anyhow::Result<Arc<Vec<Value>>> {
    let mut cache = PLACEMENTS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    mux.read_registry_state(|connection| {
        let key = (generation.to_string(), crate::state::placement_shift::state_key(connection)?);
        if let Some((cached, all)) = cache.as_ref()
            && *cached == key
        {
            return Ok(all.clone());
        }
        let all = Arc::new(crate::state::placement_shift::all_changes(connection)?);
        *cache = Some((key, all.clone()));
        Ok(all)
    })
}

#[cfg(test)]
#[path = "session_event_live_tests.rs"]
mod live_tests;

#[cfg(test)]
#[path = "session_event_resume_tests.rs"]
mod resume_tests;
