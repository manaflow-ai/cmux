//! The readers `browser_import.read` names (its `reader` field). Each takes the request's other
//! fields and answers `{"ok": <result>}` or, when the reader throws, `{"error": {"kind", "message"}}`.
//!
//! Files are named by `path`; a reader of a file's bytes also takes `base64` instead (bytes the
//! app already holds: an archive entry, Safari's `Bookmarks.plist`). A `limit` defaults to
//! [`crate::exported::DEFAULT_HISTORY_LIMIT`].
//!
//! A path under a folder macOS protects ([`PROTECTED`]: Safari's, the app containers') is refused:
//! the app stages a private copy of what it reads there, so the daemon never opens such a folder.
//!
//! | reader | fields | result |
//! | --- | --- | --- |
//! | `chromium.bookmarks` | path or base64 | bookmarks |
//! | `chromium.history` | path, limit | history entries |
//! | `chromium.session_file` | profile | path or null |
//! | `chromium.latest_session_file` | sessions | path or null |
//! | `chromium.session` | path or base64 | tabs |
//! | `chromium.search_engine` | profile | engine or null |
//! | `chromium.extensions` | profile | extensions |
//! | `arc.bookmarks` | path or base64, profileDirectory | bookmarks |
//! | `firefox.bookmarks` | path | bookmarks |
//! | `firefox.history` | path, limit | history entries |
//! | `firefox.session_file` | profile | path or null |
//! | `firefox.session` | path or base64 | tabs |
//! | `firefox.search_engine` | profile | engine or null |
//! | `safari.bookmarks` | path or base64 | bookmarks |
//! | `safari.history` | path, limit | history entries |
//! | `safari.search_engine` | services (NSPreferredWebServices) | engine or null |
//! | `exported_history.looks_like` | head | bool |
//! | `exported_history.parse` | path or base64, limit | {format, entries} or null |
//! | `search_engine.setting` | engine, builtIn ({id: template}) | {engine, search?, suggest?} |

use crate::model::{self, Bookmark, Extension, HistoryEntry, ReadError, SearchEngine, Tab};
use crate::{arc, chromium, exported, firefox, safari, search};
use base64::Engine as _;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};

#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    /// Not one of the ops above.
    Unknown,
    /// A field the op needs is missing or of the wrong type.
    Invalid,
    /// A path under a folder macOS protects ([`PROTECTED`]), not absolute, or with a `..`.
    Refused,
}

/// The folders under the home that macOS keeps from a process without Full Disk Access or the
/// container's own app: Safari's (and Safari Technology Preview's), and every app's sandbox and
/// group container.
pub const PROTECTED: [&str; 4] = [
    "Library/Safari",
    "Library/SafariTechnologyPreview",
    "Library/Containers",
    "Library/Group Containers",
];

/// `path` is under one of `home`'s [`PROTECTED`] folders: as written, or with its links resolved
/// (a link elsewhere into Safari's folder is refused too). The written path is checked first, so
/// a protected one is refused before anything under it is looked at. Case is ignored, as on the
/// Mac's default volume.
pub fn protected(path: &Path, home: &Path) -> bool {
    let lower = |path: &Path| PathBuf::from(path.to_string_lossy().to_lowercase());
    let under = |path: &Path, home: &Path| {
        let path = lower(path);
        PROTECTED.iter().any(|folder| path.starts_with(lower(&home.join(folder))))
    };
    if under(path, home) {
        return true;
    }
    let home = std::fs::canonicalize(home).unwrap_or_else(|_| home.to_path_buf());
    under(path, &home) || std::fs::canonicalize(path).is_ok_and(|path| under(&path, &home))
}

fn field<'a>(request: &'a Value, key: &str) -> Result<&'a str, OpError> {
    request.get(key).and_then(Value::as_str).ok_or(OpError::Invalid)
}

/// The absolute path in `key`, refused under a [`PROTECTED`] folder of `home`.
fn path(request: &Value, key: &str, home: Option<&Path>) -> Result<PathBuf, OpError> {
    let path = PathBuf::from(field(request, key)?);
    let climbs = path.components().any(|part| part == std::path::Component::ParentDir);
    if !path.is_absolute() || climbs || home.is_some_and(|home| protected(&path, home)) {
        return Err(OpError::Refused);
    }
    Ok(path)
}

fn limit(request: &Value) -> Result<i64, OpError> {
    match request.get("limit") {
        None | Some(Value::Null) => Ok(exported::DEFAULT_HISTORY_LIMIT),
        Some(value) => value.as_i64().ok_or(OpError::Invalid),
    }
}

/// The bytes a request names: `base64`, else the file at `path`.
fn bytes(request: &Value, home: Option<&Path>) -> Result<Result<Vec<u8>, ReadError>, OpError> {
    if let Some(encoded) = request.get("base64") {
        let encoded = encoded.as_str().ok_or(OpError::Invalid)?;
        return base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map(Ok)
            .map_err(|_| OpError::Invalid);
    }
    let file = path(request, "path", home)?;
    Ok(std::fs::read(file).map_err(|e| ReadError::Read(e.to_string())))
}

fn answer(result: Result<Value, ReadError>) -> Value {
    match result {
        Ok(value) => json!({ "ok": value }),
        Err(error) => json!({ "error": error.to_json() }),
    }
}

fn bookmarks(result: Result<Vec<Bookmark>, ReadError>) -> Value {
    answer(result.map(|items| model::list(&items, Bookmark::to_json)))
}

fn history(result: Result<Vec<HistoryEntry>, ReadError>) -> Value {
    answer(result.map(|items| model::list(&items, HistoryEntry::to_json)))
}

fn tabs(items: &[Tab]) -> Value {
    json!({ "ok": model::list(items, Tab::to_json) })
}

fn engine(found: Option<SearchEngine>) -> Value {
    json!({ "ok": found.as_ref().map_or(Value::Null, SearchEngine::to_json) })
}

fn file(found: Option<PathBuf>) -> Value {
    json!({ "ok": found.map(|p| p.to_string_lossy().into_owned()) })
}

/// Runs `op` on `request` (a JSON object). `home` is the reading process's home, whose
/// [`PROTECTED`] folders are refused; `None` refuses none.
pub fn call(op: &str, request: &Value, home: Option<&Path>) -> Result<Value, OpError> {
    let reply = match op {
        "chromium.bookmarks" => {
            bookmarks(bytes(request, home)?.and_then(|d| chromium::bookmarks(&d)))
        }
        "chromium.history" => {
            history(chromium::history(&path(request, "path", home)?, limit(request)?))
        }
        "chromium.session_file" => file(chromium::session_file(&path(request, "profile", home)?)),
        "chromium.latest_session_file" => {
            file(chromium::latest_session_file(&path(request, "sessions", home)?))
        }
        "chromium.session" => match bytes(request, home)? {
            Ok(data) => tabs(&chromium::session(&data)),
            Err(error) => answer(Err(error)),
        },
        "chromium.search_engine" => {
            engine(chromium::search_engine(&path(request, "profile", home)?))
        }
        "chromium.extensions" => {
            let items = chromium::extensions(&path(request, "profile", home)?);
            json!({ "ok": model::list(&items, Extension::to_json) })
        }
        "arc.bookmarks" => {
            let profile = field(request, "profileDirectory")?;
            bookmarks(bytes(request, home)?.and_then(|d| arc::bookmarks(&d, profile)))
        }
        "firefox.bookmarks" => bookmarks(firefox::bookmarks(&path(request, "path", home)?)),
        "firefox.history" => {
            history(firefox::history(&path(request, "path", home)?, limit(request)?))
        }
        "firefox.session_file" => file(firefox::session_file(&path(request, "profile", home)?)),
        "firefox.session" => match bytes(request, home)? {
            Ok(data) => tabs(&firefox::session(&data)),
            Err(error) => answer(Err(error)),
        },
        "firefox.search_engine" => engine(firefox::search_engine(&path(request, "profile", home)?)),
        "safari.bookmarks" => bookmarks(bytes(request, home)?.and_then(|d| safari::bookmarks(&d))),
        "safari.history" => {
            history(safari::history(&path(request, "path", home)?, limit(request)?))
        }
        "safari.search_engine" => engine(safari::search_engine(request.get("services"))),
        "exported_history.looks_like" => {
            json!({ "ok": exported::looks_like_history(field(request, "head")?) })
        }
        "exported_history.parse" => {
            let limit = limit(request)?;
            match bytes(request, home)? {
                Ok(data) => json!({ "ok": exported::parse(&data, limit).map(|h| json!({
                    "format": h.format.name(),
                    "entries": model::list(&h.entries, HistoryEntry::to_json),
                })) }),
                Err(error) => answer(Err(error)),
            }
        }
        "search_engine.setting" => {
            let engine =
                request.get("engine").and_then(SearchEngine::from_json).ok_or(OpError::Invalid)?;
            let built_in =
                request.get("builtIn").and_then(Value::as_object).ok_or(OpError::Invalid)?;
            let pairs = built_in.iter().filter_map(|(id, t)| Some((id.as_str(), t.as_str()?)));
            let setting = search::setting(&engine, pairs);
            let mut out = Map::new();
            out.insert("engine".into(), json!(setting.engine));
            if let Some(search) = setting.search {
                out.insert("search".into(), json!(search));
            }
            if let Some(suggest) = setting.suggest {
                out.insert("suggest".into(), json!(suggest));
            }
            json!({ "ok": Value::Object(out) })
        }
        _ => return Err(OpError::Unknown),
    };
    Ok(reply)
}

/// The reader names: `browser_import.read`'s `reader` values.
pub const OPS: [&str; 19] = [
    "chromium.bookmarks",
    "chromium.history",
    "chromium.session_file",
    "chromium.latest_session_file",
    "chromium.session",
    "chromium.search_engine",
    "chromium.extensions",
    "arc.bookmarks",
    "firefox.bookmarks",
    "firefox.history",
    "firefox.session_file",
    "firefox.session",
    "firefox.search_engine",
    "safari.bookmarks",
    "safari.history",
    "safari.search_engine",
    "exported_history.looks_like",
    "exported_history.parse",
    "search_engine.setting",
];
