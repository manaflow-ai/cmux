//! The readers `browser_import.read` names (its `reader` field). Each takes the request's other
//! fields and answers `{"ok": <result>}` or, when the reader throws, `{"error": {"kind", "message"}}`.
//!
//! Files are named by `path`; a reader of a file's bytes also takes `base64` instead (bytes the
//! app already holds: an archive entry, Safari's `Bookmarks.plist`). A `limit` defaults to
//! [`crate::exported::DEFAULT_HISTORY_LIMIT`].
//!
//! A path under a folder macOS protects ([`PROTECTED`]: Safari's, the app containers') is refused,
//! so the daemon never opens such a folder. The app reads what a reader needs there itself and
//! sends the bytes, in chunks, into an upload held in the daemon's memory ([`crate::upload`]): no
//! copy is ever written to disk, where any process of the same user could read it. A request
//! with `upload` reads that upload's files: its `path`, `profile` and `sessions` are names in it
//! (`.` is its top folder), and a file a reader answers is named the same way.
//!
//! | op | fields | result |
//! | --- | --- | --- |
//! | `upload.append` | upload (an id the app chose), name, base64 | null, or a `tooLarge` error |
//! | `upload.drop` | upload | null |
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
use crate::place::{Files, Place};
use crate::upload::{self, Uploads};
use crate::{arc, chromium, exported, firefox, safari, search};
use base64::Engine as _;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::time::Instant;

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

/// Where a request's names point: absolute paths on disk, refused under a [`PROTECTED`] folder
/// of `home`; or, with `files`, names in an upload.
#[derive(Clone, Copy)]
struct Source<'a> {
    home: Option<&'a Path>,
    files: Option<&'a Files>,
}

impl<'a> Source<'a> {
    /// The place `key` names.
    fn place(self, request: &Value, key: &str) -> Result<Place<'a>, OpError> {
        let name = field(request, key)?;
        if let Some(files) = self.files {
            let key = Files::key(name).ok_or(OpError::Refused)?;
            return Ok(Place::Memory { files, key });
        }
        let path = PathBuf::from(name);
        let climbs = path.components().any(|part| part == std::path::Component::ParentDir);
        if !path.is_absolute() || climbs || self.home.is_some_and(|home| protected(&path, home)) {
            return Err(OpError::Refused);
        }
        Ok(Place::Disk(path))
    }
}

fn limit(request: &Value) -> Result<i64, OpError> {
    match request.get("limit") {
        None | Some(Value::Null) => Ok(exported::DEFAULT_HISTORY_LIMIT),
        Some(value) => value.as_i64().ok_or(OpError::Invalid),
    }
}

fn decode(request: &Value) -> Result<Vec<u8>, OpError> {
    let encoded = field(request, "base64")?;
    base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|_| OpError::Invalid)
}

/// The bytes a request names: `base64`, else the file at `path`.
fn bytes(request: &Value, source: Source<'_>) -> Result<Result<Vec<u8>, ReadError>, OpError> {
    if request.get("base64").is_some() {
        return decode(request).map(Ok);
    }
    Ok(source.place(request, "path")?.read())
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

/// Runs `op` on `request` (a JSON object) with the daemon's uploads ([`upload::SHARED`]).
/// `home` is the reading process's home, whose [`PROTECTED`] folders are refused; `None`
/// refuses none.
pub fn call(op: &str, request: &Value, home: Option<&Path>) -> Result<Value, OpError> {
    call_with(op, request, home, &upload::SHARED, Instant::now())
}

/// [`call`] with `uploads` at `now`.
pub fn call_with(
    op: &str,
    request: &Value,
    home: Option<&Path>,
    uploads: &Uploads,
    now: Instant,
) -> Result<Value, OpError> {
    uploads.prune(now);
    let id = match request.get("upload") {
        None => None,
        Some(id) => Some(id.as_str().filter(|id| upload::valid_id(id)).ok_or(OpError::Invalid)?),
    };
    match op {
        "upload.append" => {
            let id = id.ok_or(OpError::Invalid)?;
            let key = Files::key(field(request, "name")?)
                .filter(|key| !key.is_empty())
                .ok_or(OpError::Refused)?;
            let reply = uploads.append(id, key, &decode(request)?, now).map(|()| Value::Null);
            return Ok(answer(reply));
        }
        "upload.drop" => {
            uploads.drop_upload(id.ok_or(OpError::Invalid)?);
            return Ok(json!({ "ok": null }));
        }
        _ if !OPS.contains(&op) => return Err(OpError::Unknown),
        _ => {}
    }
    let Some(id) = id else { return read(op, request, Source { home, files: None }) };
    match uploads.files(id, now) {
        Ok(files) => read(op, request, Source { home, files: Some(&files) }),
        Err(error) => Ok(answer(Err(error))),
    }
}

fn read(op: &str, request: &Value, source: Source<'_>) -> Result<Value, OpError> {
    let path = |key: &str| source.place(request, key);
    let reply = match op {
        "chromium.bookmarks" => {
            bookmarks(bytes(request, source)?.and_then(|d| chromium::bookmarks(&d)))
        }
        "chromium.history" => history(chromium::history(path("path")?, limit(request)?)),
        "chromium.session_file" => file(chromium::session_file(path("profile")?)),
        "chromium.latest_session_file" => file(chromium::latest_session_file(path("sessions")?)),
        "chromium.session" => match bytes(request, source)? {
            Ok(data) => tabs(&chromium::session(&data)),
            Err(error) => answer(Err(error)),
        },
        "chromium.search_engine" => engine(chromium::search_engine(path("profile")?)),
        "chromium.extensions" => {
            let items = chromium::extensions(path("profile")?);
            json!({ "ok": model::list(&items, Extension::to_json) })
        }
        "arc.bookmarks" => {
            let profile = field(request, "profileDirectory")?;
            bookmarks(bytes(request, source)?.and_then(|d| arc::bookmarks(&d, profile)))
        }
        "firefox.bookmarks" => bookmarks(firefox::bookmarks(path("path")?)),
        "firefox.history" => history(firefox::history(path("path")?, limit(request)?)),
        "firefox.session_file" => file(firefox::session_file(path("profile")?)),
        "firefox.session" => match bytes(request, source)? {
            Ok(data) => tabs(&firefox::session(&data)),
            Err(error) => answer(Err(error)),
        },
        "firefox.search_engine" => engine(firefox::search_engine(path("profile")?)),
        "safari.bookmarks" => {
            bookmarks(bytes(request, source)?.and_then(|d| safari::bookmarks(&d)))
        }
        "safari.history" => history(safari::history(path("path")?, limit(request)?)),
        "safari.search_engine" => engine(safari::search_engine(request.get("services"))),
        "exported_history.looks_like" => {
            json!({ "ok": exported::looks_like_history(field(request, "head")?) })
        }
        "exported_history.parse" => {
            let limit = limit(request)?;
            match bytes(request, source)? {
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

/// The upload ops: `browser_import.read`'s other `reader` values.
pub const UPLOAD_OPS: [&str; 2] = ["upload.append", "upload.drop"];

/// The reader names: `browser_import.read`'s `reader` values besides [`UPLOAD_OPS`].
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
