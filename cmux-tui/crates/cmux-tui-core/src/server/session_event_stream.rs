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
use crate::resource::WireDecimal;
use crate::state::placement_shift::CAPABILITY as PLACEMENT_SHIFT_CAPABILITY;
use crate::state::placement_shift::PlacementShift;
use crate::stream_interrupt::StreamInterrupt;
use crate::supervised::{self, Fatal, ShutdownBehavior};
use cmux_threads::sync::Mutex;
use serde_json::Value;
use serde_json::json;
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
    let snapshot = resource_session_snapshot(mux, client, &request.selectors)?;
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
            Ok::<_, ResourceError>((generation, revision))
        })
        .transpose()?;

    let mut initial_items = Vec::new();
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
            opened_cursor = json!({
                "generation":snapshot_generation,
                "revision":snapshot_revision.to_string(),
            });
        }
        Some((generation, _)) if generation != snapshot_generation => {
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
            opened_cursor = json!({
                "generation":snapshot_generation,
                "revision":snapshot_revision.to_string(),
            });
        }
        Some((generation, revision)) => match mux.resource_events_after(revision) {
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
                opened_cursor = json!({
                    "generation":snapshot_generation,
                    "revision":snapshot_revision.to_string(),
                });
            }
            Ok(page) => {
                let mut deltas = Vec::with_capacity(page.batches.len());
                let mut failed = None;
                for batch in page.batches {
                    let cursor = json!({
                        "generation":page.generation,
                        "revision":batch.revision.to_string(),
                    });
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
                    opened_cursor = json!({
                        "generation":snapshot_generation,
                        "revision":snapshot_revision.to_string(),
                    });
                } else {
                    initial_items.extend(deltas);
                    last_revision = page.head_revision;
                    opened_cursor = json!({
                        "generation":page.generation,
                        "revision":page.head_revision.to_string(),
                    });
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
                opened_cursor = json!({
                    "generation":snapshot_generation,
                    "revision":snapshot_revision.to_string(),
                });
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
    // Its items share the reply FIFO (spec/transports.md "Reply and event order").
    let outbound = writer
        .start_control_stream(&overflow)
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
    let spawn = supervised::spawn_at(
        "mux-resource-session-events",
        crate::thread_qos::ThreadType::Interactive.qos(),
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            run_session_event_stream(&worker_mux, client, &worker_writer, start);
        },
    );
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
        let epoch = mux.wait_for_journal_event_until_interrupted(stream.epoch, &interrupt);
        if epoch == stream.epoch {
            continue;
        }
        stream.epoch = epoch;
        loop {
            let read = match &reader {
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
                    reader = None;
                    mux.resource_events_after(stream.last_revision)
                }
                read => read,
            };
            let page = match read {
                Ok(page) => page,
                Err(error) => {
                    let end = resource_stream_end(
                        &stream.stream_id,
                        "gap",
                        None,
                        Some("request a fresh session snapshot"),
                        None,
                    );
                    let _ = error;
                    let _ = writer.send_terminal(&end, &stream.outbound);
                    break 'stream;
                }
            };
            let head_revision = page.head_revision;
            if page.batches.is_empty() && stream.last_revision < head_revision {
                let end = resource_stream_end(
                    &stream.stream_id,
                    "gap",
                    None,
                    Some("request a fresh session snapshot"),
                    None,
                );
                let _ = writer.send_terminal(&end, &stream.outbound);
                break 'stream;
            }
            for batch in page.batches {
                let cursor = json!({
                    "generation":page.generation,
                    "revision":batch.revision.to_string(),
                });
                let revision = batch.revision;
                let item = match delta_item(mux, client, &page.generation, &cursor, batch) {
                    Ok(item) => item,
                    Err(error) => {
                        eprintln!(
                            "cmux-tui: session.events: placement restatement failed: {error:#}"
                        );
                        let end = resource_stream_end(
                            &stream.stream_id,
                            "gap",
                            None,
                            Some("request a fresh session snapshot"),
                            None,
                        );
                        let _ = writer.send_terminal(&end, &stream.outbound);
                        break 'stream;
                    }
                };
                let end = resource_stream_end(
                    &stream.stream_id,
                    "gap",
                    Some(cursor.clone()),
                    Some("request a fresh session snapshot"),
                    None,
                );
                let _ = writer.update_stream_overflow(&stream.outbound, &end);
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
                stream.last_revision = revision;
            }
            if stream.last_revision >= head_revision {
                break;
            }
        }
    }
    mux.control_clients.finish_resource_stream(client, &stream.stream_id, stream.outbound.id);
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
static PLACEMENTS: Mutex<PlacementCache> = Mutex::new(None);

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
