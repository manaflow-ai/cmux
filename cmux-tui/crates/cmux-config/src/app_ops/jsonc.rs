//! `jsonc.parse` and `jsonc.strip`: the app's read of a JSONC text (Swift
//! `JSONC.parse`, `JSONC.strip` and `JSONC.problem`), on [`crate::jsonc`].

use serde_json::{Value, json};

use super::{OpError, string};
use crate::jsonc::{self, JsoncError};

/// `{source}` to `{value}` or `{problem}`.
pub fn parse(request: &Value) -> Result<Value, OpError> {
    let source = string(request, "source")?;
    Ok(match jsonc::parse(source) {
        Ok(value) => json!({ "value": value }),
        Err(error) => json!({ "problem": problem(&error, source) }),
    })
}

/// `{source}` to `{text}` (strict JSON) or `{problem}`.
pub fn strip(request: &Value) -> Result<Value, OpError> {
    let source = string(request, "source")?;
    Ok(match jsonc::strip(source) {
        Ok(text) => json!({ "text": text }),
        Err(error) => json!({ "problem": problem(&error, source) }),
    })
}

/// `{source, path}` to `{line, column}` (from 1; a column counts UTF-16
/// code units, as the code editor does) of the key of the member at `path`,
/// or `{}` when the text does not parse or has no such member.
pub fn position_of(request: &Value) -> Result<Value, OpError> {
    let source = string(request, "source")?;
    let path: Vec<String> = request
        .get("path")
        .and_then(Value::as_array)
        .and_then(|keys| keys.iter().map(|key| key.as_str().map(str::to_owned)).collect())
        .ok_or_else(|| OpError::Invalid("expected a string array `path`".to_owned()))?;
    if path.is_empty() {
        return Ok(json!({}));
    }
    let Some(offset) = jsonc::member_start(source, &path) else { return Ok(json!({})) };
    let Some(before) = source.get(..offset) else { return Ok(json!({})) };
    let line = before.matches('\n').count().saturating_add(1);
    let column = before.rsplit('\n').next().unwrap_or("").encode_utf16().count().saturating_add(1);
    Ok(json!({ "line": line, "column": column }))
}

/// A read failure as a person reads it: what and where in the file, such as
/// "the text is not valid JSON at line 5, column 3". Never the error's dump.
pub fn problem(error: &JsoncError, source: &str) -> String {
    match error {
        JsoncError::UnterminatedComment => "a /* comment is never closed".to_owned(),
        JsoncError::UnterminatedString => "a string is never closed".to_owned(),
        JsoncError::Malformed { offset } => {
            format!("the text is not valid JSON at {}", position(*offset, source))
        }
        JsoncError::Json(_) => match strict_error_position(source) {
            Some((line, column)) => {
                format!("the text is not valid JSON at line {line}, column {column}")
            }
            None => "the text is not valid JSON".to_owned(),
        },
        JsoncError::RootIsNotObject => "root is not an object".to_owned(),
        JsoncError::EmptyPath => "empty key path".to_owned(),
    }
}

/// "line L, column C" (both from 1) of UTF-8 byte `offset` in `source`;
/// a column counts characters.
pub fn position(offset: usize, source: &str) -> String {
    let (mut line, mut column): (usize, usize) = (1, 1);
    for byte in source.as_bytes().iter().take(offset) {
        if *byte == b'\n' {
            line = line.saturating_add(1);
            column = 1;
        } else if byte & 0xC0 != 0x80 {
            column = column.saturating_add(1);
        }
    }
    format!("line {line}, column {column}")
}

/// Where strict JSON parsing of the stripped text failed. Stripping keeps
/// every line break, so the line is the file's.
fn strict_error_position(source: &str) -> Option<(usize, usize)> {
    let strict = jsonc::strip(source).ok()?;
    let error = serde_json::from_str::<Value>(&strict).err()?;
    (error.line() > 0).then(|| (error.line(), error.column().max(1)))
}

#[cfg(test)]
#[path = "jsonc_tests.rs"]
mod tests;
