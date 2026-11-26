//! A peer link's queued text chunks merged into one line (`ACPMUX_PEER_MERGE_CHUNKS`, off by
//! default).
//!
//! A streamed answer is one `session/update` (or `_acpmux/event`) per `agent_message_chunk`, a
//! few hundred bytes each. While a peer link is behind (a lossy relay, a blip), the chunks of one
//! answer pile up in its outbound queue (`outbound.rs`) one line each: on relay `lossy-3` under
//! duress about 180 KB in 530 lines, every one too small for the link's compression
//! (`frame_compress.rs` [`crate::frame_compress::MIN_BYTES`]), so the backlog crosses the link
//! as its text.
//!
//! With the setting on, a chunk queued right behind a still-queued chunk of the same chat and
//! the same record in every field but its `seq`, `at` and text (the same reply segment, so never
//! across turns or messages) is appended to it: the merged line has the newer one's `seq` and
//! `at` and the two texts in order, up to [`MERGE_CAP`] of text. A peer reads it as the one
//! newest record; its cursor moves past the merged seqs, as it does past any it was not sent
//! (`peer_dual.rs`). A line the pump already took is never changed, and nothing else is merged:
//! a line between two chunks keeps them apart.

use crate::rpc::{Message, method};
use serde_json::Value;

/// The most text one merged line carries: past the link's compression floor, so a merged
/// backlog crosses compressed, and small enough that rebuilding it on each merge stays cheap.
pub(super) const MERGE_CAP: usize = 32 << 10;

/// `ACPMUX_PEER_MERGE_CHUNKS=1`: a peer link's queue merges its queued text chunks.
pub(super) fn enabled_from(get: &dyn Fn(&str) -> Option<String>) -> bool {
    get("ACPMUX_PEER_MERGE_CHUNKS").is_some_and(|v| v.trim() == "1")
}

/// One queued text chunk, as the queue keeps it beside its line to merge into it.
pub(super) struct Chunk {
    method: &'static str,
    /// The record less its `seq`, `at` and text: only chunks with equal shapes merge.
    shape: String,
    /// The newest merged record's params (its `seq` and `at`), text as it came.
    params: Value,
    text: String,
}

impl Chunk {
    /// `line` as a chunk, if it is a text `agent_message_chunk` notification of
    /// [`MERGE_CAP`] or less.
    pub(super) fn of(line: &str) -> Option<Box<Chunk>> {
        if line.len() > MERGE_CAP {
            return None;
        }
        let v: Value = serde_json::from_str(line).ok()?;
        if v.get("id").is_some() {
            return None;
        }
        let method = match v.get("method")?.as_str()? {
            method::SESSION_UPDATE => method::SESSION_UPDATE,
            method::MUX_EVENT => method::MUX_EVENT,
            _ => return None,
        };
        let params = v.get("params")?;
        // A compact chunk's template (`chunk_deltas.rs`) must stay as it was sent.
        if params.get("chunkRef").is_some() {
            return None;
        }
        let update = params.pointer(Self::update_at(method))?;
        if update.get("sessionUpdate")?.as_str()? != "agent_message_chunk" {
            return None;
        }
        let content = update.get("content")?;
        if content.get("type")?.as_str()? != "text" {
            return None;
        }
        let text = content.get("text")?.as_str()?.to_owned();
        let mut shape = params.clone();
        if let Some(content) = shape
            .pointer_mut(&format!("{}/content", Self::update_at(method)))
            .and_then(Value::as_object_mut)
        {
            content.remove("text");
        }
        let stamp = if method == method::MUX_EVENT {
            shape.as_object_mut()
        } else {
            shape.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut)
        };
        if let Some(stamp) = stamp {
            stamp.remove("seq");
            stamp.remove("at");
        }
        Some(Box::new(Chunk { method, shape: shape.to_string(), params: params.clone(), text }))
    }

    fn update_at(method: &str) -> &'static str {
        if method == method::MUX_EVENT { "/msg/params/update" } else { "/update" }
    }

    /// `newer` appended to this chunk, and the merged line: None when the shapes differ or the
    /// text would pass [`MERGE_CAP`], and this chunk is unchanged.
    pub(super) fn merged(&mut self, newer: &Chunk) -> Option<String> {
        if self.shape != newer.shape || self.text.len() + newer.text.len() > MERGE_CAP {
            return None;
        }
        let mut text = String::with_capacity(self.text.len() + newer.text.len());
        text.push_str(&self.text);
        text.push_str(&newer.text);
        let mut params = newer.params.clone();
        let at = format!("{}/content/text", Self::update_at(self.method));
        *params.pointer_mut(&at)? = Value::String(text.clone());
        let line = Message::notification(self.method, params).to_line();
        self.text = text;
        self.params = newer.params.clone();
        Some(line)
    }
}

#[cfg(test)]
#[path = "chunk_merge_tests.rs"]
mod tests;
