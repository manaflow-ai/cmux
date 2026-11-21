//! A message as its lines of words (`crate::lines`).

use crate::{MessagePreview, Words, folded};

/// Each line's preview; consecutive `|` lines as one block (a pipe table, or
/// rows the preview keeps as words); a fenced block's lines as written.
pub(crate) fn lines(markdown: &str, words: &Words) -> Vec<String> {
    let mut out = Vec::new();
    let mut table = String::new();
    let mut fence: Option<char> = None;
    for raw in markdown.lines() {
        let line = raw.trim_start();
        let marker = ['`', '~'].into_iter().find(|c| line.starts_with(&c.to_string().repeat(3)));
        if let Some(c) = marker {
            if !table.is_empty() {
                push(&mut out, MessagePreview::new(&table).text(words));
                table.clear();
            }
            fence = match fence {
                None => Some(c),
                Some(open) if open == c => None,
                open => open,
            };
            continue;
        }
        if fence.is_some() {
            push(&mut out, folded(raw));
            continue;
        }
        if line.starts_with('|') {
            if !table.is_empty() {
                table.push('\n');
            }
            table.push_str(line);
            continue;
        }
        if !table.is_empty() {
            push(&mut out, MessagePreview::new(&table).text(words));
            table.clear();
        }
        push(&mut out, MessagePreview::new(raw).text(words));
    }
    if !table.is_empty() {
        push(&mut out, MessagePreview::new(&table).text(words));
    }
    out
}

/// Adds `line` to `out` unless it is empty.
fn push(out: &mut Vec<String>, line: String) {
    if !line.is_empty() {
        out.push(line);
    }
}
