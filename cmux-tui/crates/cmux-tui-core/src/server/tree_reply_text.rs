//! The text of a `list-workspaces` tree, written once for all the readers of one build.
//!
//! A `list-workspaces` reply is `{"data":<tree>,"id":<id>,"ok":true}`, with
//! `lines_written_before_read` added to the tree for a connection that counts its lines. serde_json
//! writes the keys of an object in order, so the tree's text is two runs of entries: the keys
//! before `lines_written_before_read` and the keys after it. Each reply writes its own envelope,
//! its own `id` and its own line count around these runs. So the readers of one build serialize
//! its tree one time, and each reply has the bytes that the command path writes for its
//! `Response` (tests/list_workspaces_shared_text.rs). The text is the tree as its connection reads
//! the tab kinds: that projection is made on the tree before the text is written
//! (tree_reply_flight.rs), so the readers of one build share one text for each projection.
//!
//! Lifetime: the flight keeps the text only while a reader of its build waits for it
//! (tree_reply_flight.rs), and each reader drops its reference when its reply is written, so the
//! text is freed when the last reader of that build ends. There is one text for each projection
//! of a build, whatever the number of readers.

use super::render_service::json_error_to_io;
use serde_json::Value;
use std::cmp::Ordering;
use std::io::Write;
use std::sync::Arc;

const LINES_WRITTEN_KEY: &str = "lines_written_before_read";

/// The envelope and the line count of a reply: `{"data":{`, `,"lines_written_before_read":`, a
/// `u64`, `}`, `,"id":` and `,"ok":true}`.
const ENVELOPE_BYTES: usize = 96;

pub(crate) struct TreeText {
    /// The tree's entries whose keys sort before `lines_written_before_read`, `,` between them.
    before: Vec<u8>,
    /// The text of the tree's own `lines_written_before_read`, if it has one.
    own_lines: Option<Vec<u8>>,
    /// The entries whose keys sort after it.
    after: Vec<u8>,
}

impl TreeText {
    /// The text of `tree`, an object.
    pub(crate) fn of(tree: &Value) -> std::io::Result<Self> {
        let Value::Object(entries) = tree else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "a list-workspaces tree is an object",
            ));
        };
        let mut text = Self { before: Vec::new(), own_lines: None, after: Vec::new() };
        for (key, value) in entries {
            let run = match key.as_str().cmp(LINES_WRITTEN_KEY) {
                Ordering::Less => &mut text.before,
                Ordering::Greater => &mut text.after,
                Ordering::Equal => {
                    text.own_lines = Some(serde_json::to_vec(value).map_err(json_error_to_io)?);
                    continue;
                }
            };
            if !run.is_empty() {
                run.push(b',');
            }
            serde_json::to_writer(&mut *run, key).map_err(json_error_to_io)?;
            run.push(b':');
            serde_json::to_writer(&mut *run, value).map_err(json_error_to_io)?;
        }
        Ok(text)
    }

    /// The bytes of a reply written from this text with a short `id`.
    pub(crate) fn reply_bytes(&self) -> usize {
        self.before.len()
            + self.own_lines.as_ref().map_or(0, Vec::len)
            + self.after.len()
            + ENVELOPE_BYTES
    }

    /// The text serde_json writes of `{"data": <tree, with lines_written_before_read: lines when
    /// given>, "id": <id when given>, "ok": true}`.
    pub(crate) fn write_reply(
        &self,
        out: &mut impl Write,
        id: Option<&Value>,
        lines: Option<u64>,
    ) -> std::io::Result<()> {
        let lines = match (lines, &self.own_lines) {
            (Some(lines), _) => Some(format!("\"{LINES_WRITTEN_KEY}\":{lines}").into_bytes()),
            (None, Some(own)) => {
                Some([format!("\"{LINES_WRITTEN_KEY}\":").as_bytes(), own].concat())
            }
            (None, None) => None,
        };
        out.write_all(b"{\"data\":{")?;
        let entries = [Some(self.before.as_slice()), lines.as_deref(), Some(self.after.as_slice())];
        for (index, run) in entries.into_iter().flatten().filter(|run| !run.is_empty()).enumerate()
        {
            if index > 0 {
                out.write_all(b",")?;
            }
            out.write_all(run)?;
        }
        out.write_all(b"}")?;
        if let Some(id) = id {
            out.write_all(b",\"id\":")?;
            serde_json::to_writer(&mut *out, id).map_err(json_error_to_io)?;
        }
        out.write_all(b",\"ok\":true}")
    }
}

/// A `list-workspaces` reply's data: its build's shared tree text, and the lines its connection
/// had written when it was read (`cmd_workspaces::list_workspaces`).
///
/// `text` is the tree as the connection read the tab kinds when the tree was read
/// (`TabProjection`), so the reply is not parsed to change them. A capability that the connection
/// declares between that read and the send is in force from its next reply.
pub(crate) struct TreeReply {
    pub(crate) text: Arc<TreeText>,
    pub(crate) lines_written_before_read: Option<u64>,
}

#[cfg(test)]
#[path = "tree_reply_text_tests.rs"]
mod tests;
