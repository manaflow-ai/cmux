use std::fmt;

use crate::memory::{Memory, Store};
use crate::node::NodeId;
use crate::{MARKS, PLACEHOLDER};

/// The view as the agent reads it (section 5.1), with the cache cut points.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderedView {
    pub text: String,
    /// Byte offsets into `text` where a cached piece ends: the last line end
    /// before each of `MARKS` characters; marks past the end are skipped (section 8).
    pub marks: Vec<usize>,
}

fn flatten(text: &str) -> String {
    text.replace('\n', " ")
}

/// `<chat>`, one `id+n|text` line per part (newlines shown as spaces), `</chat>`.
pub fn render_view(memory: &Memory, store: &dyn Store) -> RenderedView {
    let mut text = String::from("<chat>\n");
    let mut chars = text.chars().count();
    let mut line_ends: Vec<(usize, usize)> = Vec::new(); // (chars, bytes) after each line
    for part in memory.view() {
        let body = store.node(*part).unwrap_or_else(|| PLACEHOLDER.to_string());
        let line = format!("{}|{}\n", part.name(), flatten(&body));
        chars += line.chars().count();
        text.push_str(&line);
        line_ends.push((chars, text.len()));
    }
    text.push_str("</chat>");
    let total = chars + "</chat>".len();
    let mut marks = Vec::new();
    for mark in MARKS {
        if mark >= total {
            continue;
        }
        if let Some(&(_, bytes)) = line_ends.iter().rev().find(|(c, _)| *c <= mark) {
            if marks.last() != Some(&bytes) {
                marks.push(bytes);
            }
        }
    }
    RenderedView { text, marks }
}

/// Why `zoom` refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ZoomError {
    pub id: u64,
    pub n: u64,
}

impl fmt::Display for ZoomError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "No line {}+{}.", self.id, self.n)
    }
}

/// `zoom(id, n)` (section 7.1): the two lines of n/2 under line `id+n`, or
/// message `id` whole (newlines kept) when `n` is 1.
pub fn zoom(memory: &Memory, store: &dyn Store, id: u64, n: u64) -> Result<String, ZoomError> {
    let err = ZoomError { id, n };
    let node = NodeId::from_name(id, n).ok_or(err.clone())?;
    if node.end() > memory.len() {
        return Err(err);
    }
    let Some((a, b)) = node.children() else {
        let (kind, text) = store.message(id);
        return Ok(format!("{id}+0|{}: {text}", kind.as_str()));
    };
    let line = |c: NodeId| {
        format!(
            "{}|{}",
            c.name(),
            flatten(&store.node(c).unwrap_or_else(|| PLACEHOLDER.to_string()))
        )
    };
    Ok(format!("{}\n{}", line(a), line(b)))
}
