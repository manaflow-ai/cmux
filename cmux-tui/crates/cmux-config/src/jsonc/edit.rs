//! In-place set and remove (Swift `JSONC.setting` and `JSONC.removing`).

use std::ops::Range;

use serde_json::Value;

use super::JsoncError;
use super::lex::{line_end_if_blank, line_indent, line_start_if_blank, same_line_trivia_end};
use super::tree::{Node, ObjectNode, parse_root};
use crate::render::{pretty, quote};
use crate::value::nest;

struct Edit {
    range: Range<usize>,
    text: String,
}

pub(super) fn set(source: &str, path: &[String], value: &Value) -> Result<String, JsoncError> {
    if path.is_empty() {
        return Err(JsoncError::EmptyPath);
    }
    let bytes = source.as_bytes();
    let Some(root) = parse_root(bytes)? else {
        // Empty or comment-only file: write a fresh document after it.
        let document = pretty(&nest(value.clone(), path), "");
        let prefix = if source.chars().all(char::is_whitespace) {
            String::new()
        } else if source.ends_with('\n') {
            source.to_string()
        } else {
            format!("{source}\n")
        };
        return Ok(format!("{prefix}{document}\n"));
    };
    let Node::Object(object) = root else {
        return Err(JsoncError::RootIsNotObject);
    };
    let mut edits = Vec::new();
    set_in(value, path, &object, bytes, &mut edits);
    Ok(apply(edits, bytes))
}

pub(super) fn remove(source: &str, path: &[String]) -> Result<String, JsoncError> {
    let Some((last, parents)) = path.split_last() else {
        return Err(JsoncError::EmptyPath);
    };
    let bytes = source.as_bytes();
    let Some(root) = parse_root(bytes)? else {
        return Ok(source.to_string());
    };
    let Node::Object(mut object) = root else {
        return Err(JsoncError::RootIsNotObject);
    };
    for key in parents {
        let Some(position) = object.members.iter().position(|member| &member.key == key) else {
            return Ok(source.to_string());
        };
        let member = object.members.swap_remove(position);
        let Node::Object(child) = member.node else {
            return Ok(source.to_string());
        };
        object = child;
    }
    let Some(index) = object.members.iter().position(|member| &member.key == last) else {
        return Ok(source.to_string());
    };
    Ok(apply(removal_edits(index, &object, bytes), bytes))
}

fn set_in(
    value: &Value,
    path: &[String],
    object: &ObjectNode,
    bytes: &[u8],
    edits: &mut Vec<Edit>,
) {
    let (key, rest) = path.split_first().expect("non-empty path");
    if let Some(member) = object.members.iter().find(|member| &member.key == key) {
        let indent = line_indent(bytes, member.key_start);
        if rest.is_empty() {
            edits.push(Edit {
                range: member.value_start..member.value_end,
                text: pretty(value, &indent),
            });
        } else if let Node::Object(child) = &member.node {
            set_in(value, rest, child, bytes, edits);
        } else {
            let nested = nest(value.clone(), rest);
            edits.push(Edit {
                range: member.value_start..member.value_end,
                text: pretty(&nested, &indent),
            });
        }
        return;
    }
    let nested = if rest.is_empty() { value.clone() } else { nest(value.clone(), rest) };
    let brace_indent = line_indent(bytes, object.open);
    let member_indent = object
        .members
        .first()
        .map_or_else(|| format!("{brace_indent}  "), |first| line_indent(bytes, first.key_start));
    let member_text = format!("{}: {}", quote(key), pretty(&nested, &member_indent));
    let Some(last) = object.members.last() else {
        let at = object.open + 1;
        edits.push(Edit {
            range: at..at,
            text: format!("\n{member_indent}{member_text}\n{brace_indent}"),
        });
        return;
    };
    if let Some(comma) = last.comma_after {
        // Keep the file's trailing-comma style and any comment that follows
        // the comma on its line.
        let at = same_line_trivia_end(bytes, comma + 1);
        edits.push(Edit { range: at..at, text: format!("\n{member_indent}{member_text},") });
        return;
    }
    // Put the comma right after the value and the new member after any
    // same-line comment, so `"a": 1 // note` keeps its note on its line.
    let at = same_line_trivia_end(bytes, last.value_end);
    if at == last.value_end {
        edits.push(Edit { range: at..at, text: format!(",\n{member_indent}{member_text}") });
    } else {
        edits.push(Edit { range: last.value_end..last.value_end, text: ",".to_string() });
        edits.push(Edit { range: at..at, text: format!("\n{member_indent}{member_text}") });
    }
}

fn removal_edits(index: usize, object: &ObjectNode, bytes: &[u8]) -> Vec<Edit> {
    let member = &object.members[index];
    let start = line_start_if_blank(bytes, member.key_start);
    if let Some(comma) = member.comma_after {
        let end = line_end_if_blank(bytes, comma + 1);
        return vec![Edit { range: start..end, text: String::new() }];
    }
    let end = line_end_if_blank(bytes, member.value_end);
    let mut edits = vec![Edit { range: start..end, text: String::new() }];
    if index > 0
        && let Some(previous) = object.members[index - 1].comma_after
    {
        edits.push(Edit { range: previous..previous + 1, text: String::new() });
    }
    edits
}

fn apply(mut edits: Vec<Edit>, bytes: &[u8]) -> String {
    let mut result = bytes.to_vec();
    edits.sort_by_key(|edit| std::cmp::Reverse(edit.range.start));
    for edit in edits {
        result.splice(edit.range, edit.text.into_bytes());
    }
    String::from_utf8_lossy(&result).into_owned()
}
