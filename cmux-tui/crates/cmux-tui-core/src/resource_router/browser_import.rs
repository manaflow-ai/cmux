//! `browser_import.read` (read, `browser-import-v1`): one reader of another browser's files for
//! the app's browser import, run by the `cmux-browser-import` crate. `reader` names it
//! (`cmux_browser_import::ops::OPS`: `chromium.bookmarks`, `firefox.history`,
//! `search_engine.setting`, ...); the other fields are its request, and the result is its reply,
//! `{ok}` or `{error: {kind, message}}` when the source file does not read.
//!
//! Only the verified app connection sends it (`request_origin::USER_ONLY_OPERATIONS`): it opens a
//! file by path. A path under a folder macOS protects in the daemon's home (Safari's, an app
//! container's: `cmux_browser_import::ops::PROTECTED`) is refused, so the daemon never opens one;
//! the app reads what a reader needs there and sends the bytes into an upload held in the
//! daemon's memory only (`upload.append`, `upload.drop`: `cmux_browser_import::upload`), which a
//! read names. Nothing else is kept between calls; every database on disk is read from a private
//! copy, and one in an upload is opened in memory.

use std::path::PathBuf;
use std::sync::Arc;

use cmux_browser_import::ops::{self, OpError};
use serde_json::Value;

use super::{ParsedResourceRequest, ensure_session_route};
use crate::Mux;
use crate::resource::ResourceError;

/// Advertised in identify: the daemon answers `browser_import.read`.
pub(crate) const CAPABILITY: &str = "browser-import-v1";
/// Only the verified app sends it (`request_origin::USER_ONLY_OPERATIONS`).
pub(crate) const OPERATION: &str = "browser_import.read";

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    read(request.fields, home().as_deref())
}

/// The daemon's own home, whose protected folders are refused.
fn home() -> Option<PathBuf> {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).filter(|value| !value.is_empty()).map(PathBuf::from)
}

/// The reply to one request's fields, with `home`'s protected folders refused.
pub(crate) fn read(
    mut fields: serde_json::Map<String, Value>,
    home: Option<&std::path::Path>,
) -> Result<Value, ResourceError> {
    let reader = match fields.remove("reader") {
        Some(Value::String(reader)) => reader,
        _ => return Err(ResourceError::validation_invalid(Some("reader"), "reader is required")),
    };
    ops::call(&reader, &Value::Object(fields), home).map_err(|error| match error {
        OpError::Unknown => ResourceError::validation_invalid(
            Some("reader"),
            format!("{reader} is not a browser import reader"),
        ),
        OpError::Invalid => ResourceError::validation_invalid(
            None,
            format!("{reader}: a field it needs is missing or of the wrong type"),
        ),
        OpError::Refused => ResourceError::validation_invalid(
            None,
            format!(
                "{reader}: the path is not absolute, climbs with .., or is under a folder macOS \
                 protects (the app sends what it reads there into an upload)"
            ),
        ),
    })
}

#[cfg(test)]
mod tests;
