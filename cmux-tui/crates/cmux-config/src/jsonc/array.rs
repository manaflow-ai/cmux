//! Edits of a root array (keybindings.json): element spans, append, remove
//! and replace, with comments and formatting outside the edited element
//! preserved byte for byte.

use serde_json::Value;

use super::JsoncError;
use super::lex::{
    body_start, line_end_if_blank, line_indent, line_start_if_blank, same_line_trivia_end,
    skip_trivia, string_end,
};

/// One element of the root array: its value span and the comma after it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Element {
    pub start: usize,
    pub end: usize,
    pub comma_after: Option<usize>,
}

pub(super) struct RootArray {
    pub open: usize,
    pub close: usize,
    pub elements: Vec<Element>,
}

/// The root array, or `None` for an empty or comment-only document.
pub(super) fn root_array(bytes: &[u8]) -> Result<Option<RootArray>, JsoncError> {
    let open = skip_trivia(bytes, body_start(bytes))?;
    if open >= bytes.len() {
        return Ok(None);
    }
    if bytes[open] != b'[' {
        return Err(JsoncError::Malformed { offset: open });
    }
    let mut elements = Vec::new();
    let mut index = skip_trivia(bytes, open + 1)?;
    while bytes.get(index) != Some(&b']') {
        let end = value_end(bytes, index)?;
        let after = skip_trivia(bytes, end)?;
        let comma_after = (bytes.get(after) == Some(&b',')).then_some(after);
        elements.push(Element { start: index, end, comma_after });
        index = skip_trivia(bytes, comma_after.map_or(after, |comma| comma + 1))?;
        if comma_after.is_none() && bytes.get(index) != Some(&b']') {
            return Err(JsoncError::Malformed { offset: index });
        }
    }
    if skip_trivia(bytes, index + 1)? != bytes.len() {
        return Err(JsoncError::Malformed { offset: index + 1 });
    }
    Ok(Some(RootArray { open, close: index, elements }))
}

/// The end of the value that starts at `start`: nested brackets are
/// balanced, strings and comments skipped.
fn value_end(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    let mut depth = 0usize;
    let mut index = start;
    while index < bytes.len() {
        match bytes[index] {
            b'"' => index = string_end(bytes, index)?,
            b'{' | b'[' => {
                depth += 1;
                index += 1;
            }
            b'}' | b']' if depth == 0 => return Ok(index),
            b'}' | b']' => {
                depth -= 1;
                index += 1;
                if depth == 0 {
                    return Ok(index);
                }
            }
            b',' if depth == 0 => return Ok(index),
            b'/' if super::lex::is_comment_start(bytes, index) => {
                if depth == 0 {
                    return Ok(index);
                }
                index = super::lex::comment_end(bytes, index)?;
            }
            b' ' | b'\t' | b'\n' | b'\r' if depth == 0 => return Ok(index),
            _ => index += 1,
        }
    }
    if depth == 0 { Ok(index) } else { Err(JsoncError::Malformed { offset: index }) }
}

fn render(value: &Value, indent: &str) -> String {
    let text = serde_json::to_string_pretty(value).unwrap_or_else(|_| "null".into());
    text.replace('\n', &format!("\n{indent}"))
}

/// `source` with `value` appended to the root array (an empty document
/// becomes a one-element array).
pub(super) fn append(source: &str, value: &Value) -> Result<String, JsoncError> {
    let bytes = source.as_bytes();
    let Some(array) = root_array(bytes)? else {
        return Ok(format!("[\n  {}\n]\n", render(value, "  ")));
    };
    let Some(last) = array.elements.last() else {
        let indent = line_indent(bytes, array.open) + "  ";
        let closing = line_indent(bytes, array.close);
        let insert = format!("\n{indent}{}\n{closing}", render(value, &indent));
        return Ok(splice(source, array.open + 1, array.close, &insert));
    };
    let indent = line_indent(bytes, last.start);
    let tail = same_line_trivia_end(bytes, last.comma_after.map_or(last.end, |comma| comma + 1));
    let comma = if last.comma_after.is_some() { "" } else { "," };
    let insert = format!("{comma}\n{indent}{}", render(value, &indent));
    let at = if last.comma_after.is_some() { tail } else { last.end };
    Ok(splice(source, at, at, &insert))
}

/// `source` with element `index` of the root array removed.
pub(super) fn remove(source: &str, index: usize) -> Result<String, JsoncError> {
    let bytes = source.as_bytes();
    let array = root_array(bytes)?.ok_or(JsoncError::Malformed { offset: 0 })?;
    let element = *array.elements.get(index).ok_or(JsoncError::Malformed { offset: 0 })?;
    let (start, end) = match (element.comma_after, index.checked_sub(1)) {
        (Some(comma), _) => (element.start, comma + 1),
        // The last element without a comma takes the previous element's comma.
        (None, Some(previous)) => {
            (array.elements[previous].comma_after.unwrap_or(element.start), element.end)
        }
        (None, None) => (element.start, element.end),
    };
    let start = line_start_if_blank(bytes, start);
    let end = line_end_if_blank(bytes, same_line_trivia_end(bytes, end));
    Ok(splice(source, start, end, ""))
}

/// `source` with element `index` of the root array replaced by `value`.
pub(super) fn replace(source: &str, index: usize, value: &Value) -> Result<String, JsoncError> {
    let bytes = source.as_bytes();
    let array = root_array(bytes)?.ok_or(JsoncError::Malformed { offset: 0 })?;
    let element = array.elements.get(index).ok_or(JsoncError::Malformed { offset: 0 })?;
    let indent = line_indent(bytes, element.start);
    Ok(splice(source, element.start, element.end, &render(value, &indent)))
}

fn splice(source: &str, start: usize, end: usize, insert: &str) -> String {
    let mut out = String::with_capacity(source.len() + insert.len());
    out.push_str(&source[..start]);
    out.push_str(insert);
    out.push_str(&source[end..]);
    out
}
