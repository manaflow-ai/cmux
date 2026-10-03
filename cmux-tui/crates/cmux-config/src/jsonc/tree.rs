//! The structure the editor needs: member offsets of every object, scalars
//! and arrays as opaque spans (Swift `JSONC.parseRoot`).

use super::JsoncError;
use super::lex::{body_start, is_delimiter, skip_trivia, string_end};

pub(super) struct Member {
    pub key: String,
    pub key_start: usize,
    pub value_start: usize,
    pub value_end: usize,
    pub node: Node,
    /// Offset of the comma that follows the value, if any.
    pub comma_after: Option<usize>,
}

pub(super) struct ObjectNode {
    pub open: usize,
    pub members: Vec<Member>,
}

pub(super) enum Node {
    Object(ObjectNode),
    Scalar,
}

/// The root node, or `None` for an empty or comment-only document.
pub(super) fn parse_root(bytes: &[u8]) -> Result<Option<Node>, JsoncError> {
    let index = skip_trivia(bytes, body_start(bytes))?;
    if index >= bytes.len() {
        return Ok(None);
    }
    let (node, end) = parse_value(bytes, index)?;
    if skip_trivia(bytes, end)? != bytes.len() {
        return Err(JsoncError::Malformed { offset: end });
    }
    Ok(Some(node))
}

fn parse_value(bytes: &[u8], start: usize) -> Result<(Node, usize), JsoncError> {
    let Some(&first) = bytes.get(start) else {
        return Err(JsoncError::Malformed { offset: start });
    };
    match first {
        b'{' => parse_object(bytes, start),
        b'[' => parse_array(bytes, start),
        b'"' => Ok((Node::Scalar, string_end(bytes, start)?)),
        _ => {
            let mut end = start;
            while end < bytes.len() && !is_delimiter(bytes[end]) {
                end += 1;
            }
            if end == start {
                return Err(JsoncError::Malformed { offset: start });
            }
            Ok((Node::Scalar, end))
        }
    }
}

fn parse_array(bytes: &[u8], start: usize) -> Result<(Node, usize), JsoncError> {
    let mut index = skip_trivia(bytes, start + 1)?;
    if bytes.get(index) == Some(&b']') {
        return Ok((Node::Scalar, index + 1));
    }
    // Every pass consumes input of a finite in-memory buffer.
    loop {
        let (_, end) = parse_value(bytes, index)?;
        index = skip_trivia(bytes, end)?;
        match bytes.get(index) {
            Some(b',') => {
                index = skip_trivia(bytes, index + 1)?;
                if bytes.get(index) == Some(&b']') {
                    return Ok((Node::Scalar, index + 1));
                }
            }
            Some(b']') => return Ok((Node::Scalar, index + 1)),
            _ => return Err(JsoncError::Malformed { offset: index }),
        }
    }
}

fn parse_object(bytes: &[u8], open: usize) -> Result<(Node, usize), JsoncError> {
    let mut members = Vec::new();
    let mut index = skip_trivia(bytes, open + 1)?;
    // Every pass consumes input of a finite in-memory buffer.
    loop {
        match bytes.get(index) {
            None => return Err(JsoncError::Malformed { offset: index }),
            Some(b'}') => return Ok((Node::Object(ObjectNode { open, members }), index + 1)),
            Some(b'"') => {}
            Some(_) => return Err(JsoncError::Malformed { offset: index }),
        }
        let key_end = string_end(bytes, index)?;
        let key_text = String::from_utf8_lossy(&bytes[index..key_end]);
        let key = serde_json::from_str::<String>(&key_text).unwrap_or_default();
        let mut cursor = skip_trivia(bytes, key_end)?;
        if bytes.get(cursor) != Some(&b':') {
            return Err(JsoncError::Malformed { offset: cursor });
        }
        cursor = skip_trivia(bytes, cursor + 1)?;
        let (node, value_end) = parse_value(bytes, cursor)?;
        let mut member = Member {
            key,
            key_start: index,
            value_start: cursor,
            value_end,
            node,
            comma_after: None,
        };
        index = skip_trivia(bytes, value_end)?;
        match bytes.get(index) {
            None => return Err(JsoncError::Malformed { offset: index }),
            Some(b',') => {
                member.comma_after = Some(index);
                index = skip_trivia(bytes, index + 1)?;
            }
            Some(b'}') => {}
            Some(_) => return Err(JsoncError::Malformed { offset: index }),
        }
        members.push(member);
    }
}
