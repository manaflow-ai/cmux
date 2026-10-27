//! `conversation.events`: one conversation's changes in commit order, plus
//! its live typing and draft items. The cursor is {generation: conversation
//! id, revision: conversation rev}; the owner raises rev by exactly one per
//! committed op, so a missed rev is detected and ends the stream with `gap`.
//! The stream runs as a drain on the sequenced pool (resource_pump.rs).

use crate::panic_free::JsonFields;
use std::sync::Arc;
use std::sync::mpsc::TryRecvError;

use serde_json::{Value, json};

use super::{EventsStart, owner_error};
use crate::conversation_store::ConversationEvent;
use crate::resource_router::ParsedResourceRequest;
use crate::server::attach_lifecycle::attach_pump::{PumpTimer, Step as Next};
use crate::server::resource_pump::{ResourceOut, ResourceSource, ResourceStart, StreamItem};
use crate::server::sequenced_pool::SequencePriority;
use crate::server::{
    MessageWriter, Mux, MuxEvent, ResourceError, ResourceOperation, register_resource_outbound,
    resource_stream_end, resource_stream_id,
};

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
            let generation = requested.field("generation").as_str().unwrap_or_default();
            let revision = requested.field("revision").as_str().and_then(|r| r.parse::<u64>().ok());
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
    let typing = mux.conversation_typing(&conversation);
    let initial = reset.map(|reason| {
        json!({
            "type": "snapshot",
            "reset_reason": reason,
            "conversation": summary,
            "messages": messages,
            "typing": typing,
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
            principal,
            events,
            initial,
            rev,
        },
    ))
}

fn invalid_cursor(requested: &Value, current: &Value, reason: &str) -> ResourceError {
    let requested = json!({
        "generation": requested.field("generation").as_str().unwrap_or_default(),
        "revision": requested.field("revision").as_str().unwrap_or("0"),
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

pub(super) fn start(mux: Arc<Mux>, client: u64, writer: MessageWriter, mut start: EventsStart) {
    let (stream_id, outbound) = (start.stream_id.clone(), start.outbound.clone());
    let initial = start
        .initial
        .take()
        .map(|item| StreamItem::at(cursor(&start.conversation, start.rev), item));
    let stream = ResourceStart {
        mux: mux.clone(),
        client,
        writer: writer.clone(),
        outbound: outbound.clone(),
        stream_id: stream_id.clone(),
        canceled: start.canceled.clone(),
        lifecycle: None,
        first_sequence: 1,
        initial: initial.into_iter().collect(),
    };
    // Its membership checks read the conversation store, which the request
    // workers (input, control) may not block on: the utility workers run it.
    let pump = stream.bind(
        SequencePriority::Utility,
        EventsSource { stream: start, end: None },
        |source, wake| {
            source.stream.events.on_ready(move || wake());
        },
    );
    if pump.start().is_err() {
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

/// A `conversation.events` stream after its snapshot: the conversation's
/// changes from the mux's events.
struct EventsSource {
    stream: EventsStart,
    /// The end the stream ends with; `None` after a close or a failed send.
    end: Option<Value>,
}

impl EventsSource {
    fn end_with(&mut self, reason: &str, recovery: &str) -> Next {
        let at = cursor(&self.stream.conversation, self.stream.rev);
        self.end = Some(resource_stream_end(
            &self.stream.stream_id,
            reason,
            Some(at),
            Some(recovery),
            None,
        ));
        Next::End
    }
}

impl ResourceSource for EventsSource {
    fn next(&mut self, out: &mut ResourceOut, _timer: &PumpTimer<'_>) -> Next {
        let event = match self.stream.events.try_recv() {
            Ok(MuxEvent::Conversation(event)) => event,
            Ok(_) => return Next::Sent,
            Err(TryRecvError::Empty) => return Next::Empty,
            // The mailbox closes only when it overflowed (or the mux is
            // gone): the stream missed changes.
            Err(TryRecvError::Disconnected) => return self.end_with("gap", RECOVERY),
        };
        if !still_member(&out.mux, out.client, &self.stream, &event) {
            return self
                .end_with("closed", "the connection no longer takes part in the conversation");
        }
        match step(&self.stream.conversation, &mut self.stream.rev, &event) {
            Step::Skip => Next::Sent,
            Step::Gap => self.end_with("gap", RECOVERY),
            Step::Item(item) => {
                let at = cursor(&self.stream.conversation, self.stream.rev);
                if out.send(StreamItem::at(at, item)) { Next::Sent } else { Next::End }
            }
        }
    }

    fn finish(&mut self, out: &ResourceOut, _timer: &PumpTimer<'_>) -> bool {
        if let Some(end) = self.end.take() {
            out.send_end(&end);
        }
        out.finish();
        true
    }
}

/// Whether the stream's principal still reads the conversation: the
/// connection keeps its principal (a replaced agent token ends a binding),
/// and a summary change still lists it.
fn still_member(mux: &Mux, client: u64, stream: &EventsStart, event: &ConversationEvent) -> bool {
    if mux.conversation_principal(client) != stream.principal {
        return false;
    }
    let ConversationEvent::Changed { conversation, change, .. } = event else { return true };
    if *conversation != stream.conversation
        || change.get("kind").and_then(Value::as_str) != Some("conversation")
    {
        return true;
    }
    change.pointer("/conversation/participants").and_then(Value::as_array).is_none_or(|all| {
        all.iter().any(|p| p.get("id").and_then(Value::as_str) == Some(stream.principal.as_str()))
    })
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
                    item.insert("message", change.field("message").clone());
                    Step::Item(item)
                }
                Some("read-cursor") => {
                    let mut item = base("read_cursor");
                    item.insert("participant", change.field("participant").clone());
                    item.insert("seq", change.field("seq").clone());
                    Step::Item(item)
                }
                Some("conversation") => {
                    let mut item = base("conversation");
                    item.insert("summary", change.field("conversation").clone());
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
