//! The Mac app's reads of cmux-next.json, as JSON ops: the app hands Rust a
//! file's text (and what it needs beside it) and gets back the finished
//! value, so the parse, the validation and the defaults live here once, and
//! the app's CmuxNextSettings keeps only the AppKit apply side.
//! cmux-app-ffi links them as `cmux_settings_call` (include/cmux_settings.h,
//! Swift module `CCmuxSettingsFFI`).
//!
//! Every op takes one JSON object and answers one JSON object. An op name is
//! `area.verb`:
//! - `jsonc.parse` `{source}` answers `{value}` (an empty or comment-only
//!   text is `{}`) or `{problem}`: where and what, as a person reads it
//!   ([`jsonc::problem`]).
//! - `jsonc.strip` `{source}` answers `{text}` or `{problem}`.
//! - `jsonc.position` `{source, path}` answers `{line, column}` of the key at
//!   `path`, or `{}`.
//! - `build_scope.source` `{source, buildFile}` answers `{source}`: the shared settings file's
//!   text with this build's own cmux tools answer and Computer Use permissions over it
//!   ([`crate::build_scope`]; the build's file is made from `source` on its first read). Without
//!   `buildFile` (a build on its own settings file) `source` comes back as it is.
//! - The areas: [`theme`], [`effective`], [`looks`].

pub mod effective;
pub mod jsonc;
pub mod looks;
pub mod theme;

use serde_json::Value;

/// Why an op gave no reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpError {
    /// No op of that name.
    Unknown,
    /// The request is not the JSON the op takes.
    Invalid(String),
}

/// Runs the op `op` on `request`.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    match op {
        "jsonc.parse" => jsonc::parse(request),
        "jsonc.strip" => jsonc::strip(request),
        "jsonc.position" => jsonc::position_of(request),
        "build_scope.source" => build_scope_source(request),
        _ => theme::call(op, request)
            .or_else(|| effective::call(op, request))
            .or_else(|| looks::call(op, request))
            .unwrap_or(Err(OpError::Unknown)),
    }
}

fn build_scope_source(request: &Value) -> Result<Value, OpError> {
    let source = string(request, "source")?;
    let source = match request.get("buildFile").and_then(Value::as_str).filter(|p| !p.is_empty()) {
        Some(file) => {
            let file = std::path::Path::new(file);
            crate::build_scope::overlaid_source(
                source,
                &crate::build_scope::build_values(file, source),
            )
        }
        None => source.to_string(),
    };
    Ok(serde_json::json!({ "source": source }))
}

/// The string member `key` of `request`.
pub(crate) fn string<'a>(request: &'a Value, key: &str) -> Result<&'a str, OpError> {
    request
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| OpError::Invalid(format!("expected a string `{key}`")))
}
