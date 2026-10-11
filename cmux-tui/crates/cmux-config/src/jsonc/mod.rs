//! JSON with comments, the cmux.json authoring format: `//` and `/* */`
//! comments and trailing commas are allowed. Reads strip them; writes edit
//! the source text in place so comments, key order and formatting the user
//! wrote survive (port of Swift `JSONC`).

mod edit;
mod lex;
mod tree;

use std::fmt;

use serde_json::Value;

use crate::value::canonical;

/// Why a JSONC text could not be read or edited.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JsoncError {
    UnterminatedComment,
    UnterminatedString,
    Malformed {
        offset: usize,
    },
    /// Strict JSON parsing failed after stripping.
    Json(String),
    /// The document's root is not an object, so a key path cannot be set.
    RootIsNotObject,
    /// An edit needs at least one path component.
    EmptyPath,
}

impl fmt::Display for JsoncError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JsoncError::UnterminatedComment => f.write_str("unterminated comment"),
            JsoncError::UnterminatedString => f.write_str("unterminated string"),
            JsoncError::Malformed { offset } => write!(f, "malformed JSON at byte {offset}"),
            JsoncError::Json(message) => f.write_str(message),
            JsoncError::RootIsNotObject => f.write_str("root is not an object"),
            JsoncError::EmptyPath => f.write_str("empty key path"),
        }
    }
}

impl std::error::Error for JsoncError {}

/// Strict JSON text for `source`: comments removed (their newlines kept, so
/// error positions stay meaningful), trailing commas dropped, a leading BOM
/// dropped. String contents are untouched.
pub fn strip(source: &str) -> Result<String, JsoncError> {
    let bytes = source.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = lex::body_start(bytes);
    while index < bytes.len() {
        let byte = bytes[index];
        if byte == b'"' {
            let end = lex::string_end(bytes, index)?;
            output.extend_from_slice(&bytes[index..end]);
            index = end;
        } else if lex::is_comment_start(bytes, index) {
            let end = lex::comment_end(bytes, index)?;
            output.extend(bytes[index..end].iter().filter(|b| **b == b'\n'));
            index = end;
        } else if byte == b',' {
            let next = lex::skip_trivia(bytes, index + 1)?;
            if !matches!(bytes.get(next), Some(b'}' | b']')) {
                output.push(byte);
            }
            index += 1;
        } else {
            output.push(byte);
            index += 1;
        }
    }
    Ok(String::from_utf8_lossy(&output).into_owned())
}

/// Parses JSONC text. An empty or comment-only document is an empty object.
/// Numbers come back in canonical form (`value::canonical`).
pub fn parse(source: &str) -> Result<Value, JsoncError> {
    let strict = strip(source)?;
    if strict.trim().is_empty() {
        return Ok(Value::Object(serde_json::Map::new()));
    }
    serde_json::from_str::<Value>(&strict)
        .map(canonical)
        .map_err(|error| JsoncError::Json(error.to_string()))
}

/// `source` with the value at `path` set to `value`, creating intermediate
/// objects as needed. Everything outside the edited value is preserved byte
/// for byte.
pub fn set(source: &str, path: &[String], value: &Value) -> Result<String, JsoncError> {
    edit::set(source, path, value)
}

/// `source` with the member at `path` removed. Unchanged when absent.
pub fn remove(source: &str, path: &[String]) -> Result<String, JsoncError> {
    edit::remove(source, path)
}
