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
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::StreamPublicId;
use crate::resource::WireDecimal;
use crate::stream_interrupt::StreamInterrupt;
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
    let snapshot_cursor = snapshot["cursor"].clone();
    let snapshot_generation = snapshot_cursor["generation"]
        .as_str()
        .expect("public snapshot cursor generation")
        .to_string();
    let snapshot_revision = snapshot_cursor["revision"]
        .as_str()
        .and_then(|revision| revision.parse::<u64>().ok())
        .expect("public snapshot cursor revision");
    let requested_cursor = request
        .fields
        .get("cursor")
        .map(|cursor| {
            let generation = cursor["generation"]
                .as_str()
                .ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("cursor"),
                        "cursor generation is missing",
                    )
                })?
                .to_string();
            let revision = serde_json::from_value::<WireDecimal>(cursor["revision"].clone())
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
                for batch in page.batches {
                    let cursor = json!({
                        "generation":page.generation,
                        "revision":batch.revision.to_string(),
                    });
                    initial_items.push((
                        cursor.clone(),
                        json!({
                            "kind":"delta",
                            "cursor":cursor,
                            "previous_revision":batch.previous_revision.to_string(),
                            "revision":batch.revision.to_string(),
                            "changes":batch.changes,
                        }),
                    ));
                }
                last_revision = page.head_revision;
                opened_cursor = json!({
                    "generation":page.generation,
                    "revision":page.head_revision.to_string(),
                });
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
            let page = match mux.resource_events_after(stream.last_revision) {
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
                        json!({
                            "kind":"delta",
                            "cursor":cursor,
                            "previous_revision":batch.previous_revision.to_string(),
                            "revision":batch.revision.to_string(),
                            "changes":batch.changes,
                        }),
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
                stream.last_revision = batch.revision;
            }
            if stream.last_revision >= head_revision {
                break;
            }
        }
    }
    mux.control_clients.finish_resource_stream(client, &stream.stream_id, stream.outbound.id);
}
