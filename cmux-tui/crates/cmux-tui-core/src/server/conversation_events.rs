//! `conversation.events`: one conversation's changes in commit order, plus
//! its live typing and draft items. The cursor is {generation: conversation
//! id, revision: conversation rev}; the owner raises rev by exactly one per
//! committed op, so a missed rev is detected and ends the stream with `gap`.

use std::sync::Arc;
use std::sync::mpsc::RecvTimeoutError;

use serde_json::{Value, json};

use super::{EventsStart, owner_error};
use crate::conversation_store::ConversationEvent;
use crate::resource_router::ParsedResourceRequest;
use crate::server::{
    MessageWriter, Mux, MuxEvent, ResourceError, ResourceOperation, register_resource_outbound,
    resource_stream_end, resource_stream_id, send_resource_stream_item,
};
use crate::stream_interrupt::StreamInterrupt;

const OPERATION: ResourceOperation = ResourceOperation::ConversationEvents;
const RECOVERY: &str = "reopen conversation.events with the last cursor";

/// Validates the request, subscribes, reads the snapshot and registers the
/// stream. Subscribing before the read means no commit falls between them:
/// changes at or below the snapshot's rev are dropped by [`step`].
pub(super) fn prepare(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &ParsedResourceRequest,
) -> Result<(Value, EventsStart), ResourceError> {
    let principal = mux.conversation_principal(client);
    let fields = &Value::Object(request.fields.clone());
    let conversation = fields["conversation"].as_str().unwrap_or_default().to_owned();
    let tail = fields["tail"].as_u64().and_then(|t| u32::try_from(t).ok()).unwrap_or(50);
    let stream_id = resource_stream_id(request)?;
    let events = mux.subscribe();
    let (summary, messages) = mux
        .with_conversations(|store| {
            store.check_typing(&conversation, &principal)?;
            store.snapshot(&conversation, tail.max(1))
        })
        .map_err(|error| owner_error(OPERATION, &conversation, "", error))?;
    let rev = summary.rev;
    let current = cursor(&conversation, rev);
    let reset = match fields.get("cursor") {
        None => Some("initial"),
        Some(requested) => {
            let generation = requested["generation"].as_str().unwrap_or_default();
            let revision = requested["revision"].as_str().and_then(|r| r.parse::<u64>().ok());
            match revision {
                _ if generation != conversation => {
                    return Err(invalid_cursor(
                        requested,
                        &current,
                        "the cursor names another conversation",
                    ));
                }
                Some(revision) if revision > rev => {
                    return Err(invalid_cursor(
                        requested,
                        &current,
                        "the cursor is ahead of the conversation",
                    ));
                }
                Some(revision) if revision == rev => None,
                Some(_) => Some("cursor_expired"),
                None => {
                    return Err(invalid_cursor(
                        requested,
                        &current,
                        "the cursor revision is not a decimal",
                    ));
                }
            }
        }
    };
    let messages = if tail == 0 { Vec::new() } else { messages };
    let initial = reset.map(|reason| {
        json!({
            "type": "snapshot",
            "reset_reason": reason,
            "conversation": summary,
            "messages": messages,
        })
    });
    let overflow =
        resource_stream_end(&stream_id, "gap", Some(current.clone()), Some(RECOVERY), None);
    let outbound = writer
        .start_stream(&overflow)
        .map_err(|_| ResourceError::transport_closed("could not allocate an outbound stream"))?;
    let (canceled, worker_permit) =
        register_resource_outbound(mux, client, &stream_id, &outbound, OPERATION.wire_name())?;
    Ok((
        json!({"stream_id": stream_id, "cursor": current}),
        EventsStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            conversation,
            events,
            initial,
            rev,
        },
    ))
}

fn invalid_cursor(requested: &Value, current: &Value, reason: &str) -> ResourceError {
    let requested = json!({
        "generation": requested["generation"].as_str().unwrap_or_default(),
        "revision": requested["revision"].as_str().unwrap_or("0"),
    });
    ResourceError::new(
        "cursor.invalid",
        reason,
        json!({"requested": requested, "current": current, "reason": reason}),
        false,
    )
}

fn cursor(conversation: &str, rev: u64) -> Value {
    json!({"generation": conversation, "revision": rev.to_string()})
}

pub(super) fn start(mux: Arc<Mux>, client: u64, writer: MessageWriter, start: EventsStart) {
    let stream_id = start.stream_id.clone();
    let outbound = start.outbound.clone();
    let (worker_mux, worker_writer) = (mux.clone(), writer.clone());
    let spawned = std::thread::Builder::new()
        .name("mux-resource-conversation-events".into())
        .spawn(move || run(&worker_mux, client, &worker_writer, start));
    if spawned.is_err() {
        let _ = mux.control_clients.take_resource_stream(client, &stream_id);
        let error = ResourceError::operation_failed(
            OPERATION.wire_name(),
            "could not start the conversation event stream",
            json!({}),
        );
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some(RECOVERY),
            Some((OPERATION, error)),
        );
        let _ = writer.send_terminal(&end, &outbound);
    }
}

pub(super) fn run(mux: &Arc<Mux>, client: u64, writer: &MessageWriter, mut stream: EventsStart) {
    let mut sequence = 1_u64;
    if let Some(item) = stream.initial.take() {
        let at = cursor(&stream.conversation, stream.rev);
        if stream.cancelled()
            || !send_resource_stream_item(
                writer,
                &stream.outbound,
                &stream.stream_id,
                sequence,
                &at,
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
        sequence += 1;
    }
    let interrupt = StreamInterrupt::new();
    writer.register_interrupt(&interrupt);
    stream.outbound.register_interrupt(&interrupt);
    stream.events.wake_on(&interrupt);
    loop {
        if stream.stopped(writer) {
            break;
        }
        let event = match stream.events.recv_until_interrupted(&interrupt) {
            Ok(MuxEvent::Conversation(event)) => event,
            Ok(_) | Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => {
                // The mailbox closes only when it overflowed (or the mux is
                // gone): the stream missed changes.
                end_with_gap(writer, &stream);
                break;
            }
        };
        match step(&stream.conversation, &mut stream.rev, &event) {
            Step::Skip => {}
            Step::Gap => {
                end_with_gap(writer, &stream);
                break;
            }
            Step::Item(item) => {
                let at = cursor(&stream.conversation, stream.rev);
                if !send_resource_stream_item(
                    writer,
                    &stream.outbound,
                    &stream.stream_id,
                    sequence,
                    &at,
                    item,
                ) {
                    break;
                }
                sequence += 1;
            }
        }
    }
    mux.control_clients.finish_resource_stream(client, &stream.stream_id, stream.outbound.id);
}

fn end_with_gap(writer: &MessageWriter, stream: &EventsStart) {
    let at = cursor(&stream.conversation, stream.rev);
    let end = resource_stream_end(&stream.stream_id, "gap", Some(at), Some(RECOVERY), None);
    let _ = writer.send_terminal(&end, &stream.outbound);
}

#[derive(Debug, PartialEq)]
pub(super) enum Step {
    Skip,
    Item(Value),
    Gap,
}

/// The stream item of `event` for `conversation` whose last delivered rev is
/// `rev`. A committed change at or below `rev` was in the snapshot; one
/// above `rev + 1` means a commit was missed.
pub(super) fn step(conversation: &str, rev: &mut u64, event: &ConversationEvent) -> Step {
    match event {
        ConversationEvent::Changed { conversation: of, rev: at, change, .. }
            if of == conversation =>
        {
            if *at <= *rev {
                return Step::Skip;
            }
            if *at != *rev + 1 {
                return Step::Gap;
            }
            *rev = *at;
            let base = |kind: &str| json!({"type": kind, "conversation": conversation, "rev": at});
            match change.get("kind").and_then(Value::as_str) {
                Some(kind @ ("message" | "message-updated")) => {
                    let mut item =
                        base(if kind == "message" { "message" } else { "message_updated" });
                    item["message"] = change["message"].clone();
                    Step::Item(item)
                }
                Some("read-cursor") => {
                    let mut item = base("read_cursor");
                    item["participant"] = change["participant"].clone();
                    item["seq"] = change["seq"].clone();
                    Step::Item(item)
                }
                Some("conversation") => {
                    let mut item = base("conversation");
                    item["summary"] = change["conversation"].clone();
                    Step::Item(item)
                }
                _ => Step::Skip,
            }
        }
        ConversationEvent::Typing { conversation: of, participant, on } if of == conversation => {
            Step::Item(
                json!({"type": "typing", "conversation": of, "participant": participant, "on": on}),
            )
        }
        ConversationEvent::Draft { conversation: of, item, .. } if of == conversation => {
            Step::Item(item.clone())
        }
        _ => Step::Skip,
    }
}
