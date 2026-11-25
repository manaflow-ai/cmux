//! Compact `agent_message_chunk` frames on an event stream (`chunk-deltas-v1`).
//!
//! A streamed answer is one `_acpmux/event` per chunk, and each carries the whole record: the
//! chat's id, `seq`, `at`, `dir`, `kind` and the agent's `session/update` message with its own
//! session id, `jsonrpc`, the `sessionUpdate` and the reply's `_meta.acpmux.segment`. A chunk of
//! about 6 B of text went out as about 435 B (the mobile bandwidth bench,
//! `tests/mobile_link_conditions.rs` `chat_bytes_per_minute`).
//!
//! A client that sends `initialize` with `_meta.acpmux.chunkDeltas: true` hears a chunk whose
//! record matches the last chunk event it got for that chat in every field but `seq`, `at` and
//! the text as `_acpmux/chunk {ref, seq, dt, text}`. That last chunk event is the full
//! `_acpmux/event`, with `chunkRef` added to its params. The client rebuilds the event from it:
//! the same params with this `seq`, `at` the previous frame's plus `dt`, and
//! `msg.params.update.content.text` this text. Any other change (a new reply segment, a
//! `messageId`, a subagent, a peer route) goes as a full event again, with a new `ref`.
//!
//! No frame waits: each chunk goes when it comes, as before (the added delay is 0). Every other
//! client, and every record but a text chunk, hears the full `_acpmux/event`, as before. The book
//! holds one entry per attached chat and forgets it when the chat is attached again or detached,
//! so the next chunk after either goes whole.

use super::*;
use crate::rpc::method;

/// The notification a compact chunk goes as.
pub(crate) const CHUNK: &str = method::MUX_CHUNK;

/// The last full chunk event sent for one chat, less what a compact frame carries.
struct Template {
    chunk_ref: u64,
    /// The event's params with `seq`, `at`, `chunkRef` and the text taken out.
    shape: Value,
    seq: u64,
    at: u64,
}

/// One connection's templates (`Conn::chunk_deltas`).
#[derive(Default)]
pub(super) struct ChunkDeltas {
    /// The client asked for compact chunks (`initialize` `_meta.acpmux.chunkDeltas`).
    enabled: AtomicBool,
    next_ref: AtomicU64,
    templates: StdMutex<HashMap<String, Template>>,
}

/// The text of an `agent_message_chunk` event's params, if it is one with text content.
fn chunk_text(params: &Value) -> Option<&str> {
    let update = params.pointer("/msg/params/update")?;
    if update.get("sessionUpdate").and_then(Value::as_str) != Some("agent_message_chunk") {
        return None;
    }
    let content = update.get("content")?;
    if content.get("type").and_then(Value::as_str) != Some("text") {
        return None;
    }
    content.get("text").and_then(Value::as_str)
}

/// `params` less what a compact frame carries.
fn shape_of(params: &Value) -> Value {
    let mut shape = params.clone();
    if let Some(obj) = shape.as_object_mut() {
        obj.remove("seq");
        obj.remove("at");
        obj.remove("chunkRef");
    }
    if let Some(content) = shape.pointer_mut("/msg/params/update/content")
        && let Some(obj) = content.as_object_mut()
    {
        obj.remove("text");
    }
    shape
}

impl ChunkDeltas {
    pub(super) fn set_enabled(&self, on: bool) {
        self.enabled.store(on, Ordering::SeqCst);
        if !on {
            self.templates.lock_or_recover().clear();
        }
    }

    pub(super) fn enabled(&self) -> bool {
        self.enabled.load(Ordering::SeqCst)
    }

    /// The chat was attached again or detached: its next chunk goes whole.
    pub(super) fn forget(&self, session_id: &str) {
        if self.enabled() {
            self.templates.lock_or_recover().remove(session_id);
        }
    }

    /// The frame for one `_acpmux/event`'s `params` of chat `session_id`: the event as it is, or,
    /// for a client that asked, a text chunk as `_acpmux/chunk` when the chat's template matches
    /// it, or the event with a new `chunkRef` (and the template it starts) when none does.
    pub(super) fn frame(&self, session_id: &str, mut params: Value) -> Message {
        if !self.enabled() {
            return Message::notification(method::MUX_EVENT, params);
        }
        let Some(text) = chunk_text(&params) else {
            return Message::notification(method::MUX_EVENT, params);
        };
        let seq = params.get("seq").and_then(Value::as_u64).unwrap_or(0);
        let at = params.get("at").and_then(Value::as_u64).unwrap_or(0);
        let shape = shape_of(&params);
        let mut templates = self.templates.lock_or_recover();
        if let Some(t) = templates.get_mut(session_id)
            && seq > t.seq
            && at >= t.at
            && t.shape == shape
        {
            let delta = json!({"ref": t.chunk_ref, "seq": seq, "dt": at.saturating_sub(t.at), "text": text});
            t.seq = seq;
            t.at = at;
            return Message::notification(CHUNK, delta);
        }
        let chunk_ref = self.next_ref.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        templates.insert(session_id.to_owned(), Template { chunk_ref, shape, seq, at });
        params.set("chunkRef", json!(chunk_ref));
        Message::notification(method::MUX_EVENT, params)
    }
}

#[cfg(test)]
#[path = "chunk_deltas_tests.rs"]
mod tests;
