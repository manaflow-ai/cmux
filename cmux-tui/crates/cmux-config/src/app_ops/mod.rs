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
//! - The areas, each answering its own `area.*` ops: every `pub mod` below
//!   but [`jsonc`], each listed once in `AREAS`. Both lists are kept in
//!   name order, one per line, so branches that each add an area insert at
//!   different places and merge cleanly; no area answers another's op, so
//!   the order is only for merging.

pub mod backdrop_switch;
pub mod chrome_theme;
pub mod controller;
pub mod custom;
pub mod effective;
pub mod fields;
pub mod home_table;
pub mod import;
pub mod jsonc;
pub mod keymap;
pub mod link_rules;
pub mod looks;
pub mod managed;
pub mod notifications;
pub mod schema;
pub mod section_reads;
pub mod settings_window;
pub mod shortcut;
pub mod site_engines;
pub mod snapshot;
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

/// Each area's `call`, in name order, one per line: it answers `None` for an
/// op that is not its own.
type AreaCall = fn(&str, &Value) -> Option<Result<Value, OpError>>;
const AREAS: &[AreaCall] = &[
    backdrop_switch::call,
    chrome_theme::call,
    controller::call,
    custom::call,
    effective::call,
    fields::call,
    home_table::call,
    import::call,
    keymap::call,
    link_rules::call,
    looks::call,
    managed::call,
    notifications::call,
    schema::call,
    section_reads::call,
    settings_window::call,
    shortcut::call,
    site_engines::call,
    snapshot::call,
    theme::call,
];

/// Runs the op `op` on `request`.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    match op {
        "jsonc.parse" => jsonc::parse(request),
        "jsonc.strip" => jsonc::strip(request),
        "jsonc.position" => jsonc::position_of(request),
        _ => AREAS.iter().find_map(|call| call(op, request)).unwrap_or(Err(OpError::Unknown)),
    }
}

/// The string member `key` of `request`.
pub(crate) fn string<'a>(request: &'a Value, key: &str) -> Result<&'a str, OpError> {
    request
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| OpError::Invalid(format!("expected a string `{key}`")))
}
