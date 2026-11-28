//! `cloud.fs.*` on the machine's cmux daemon over the link
//! (super::link_files: the `fs-v1` gate and the daemon call). The op
//! shapes the Cloud page uses stay; each maps to one finder `fs.*` op.

use super::link_files::{self, Daemon};
use super::path::{GuestPath, guest_arg};
use super::{FILE_TOO_LARGE, MAX_READ_BYTES, MAX_WRITE_BYTES};
use crate::api::{CloudError, ControlPlane, args, codes};
use crate::ops::Server;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// The largest listing one `cloud.fs.list` returns (one daemon batch).
pub const MAX_LIST_ENTRIES: u64 = 1000;

/// One directory entry or stat answer (`cmux.fs.provider/1` `Entry`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// The entry name (list) or the full path (stat).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// `file`, `directory` or `symlink`.
    pub kind: String,
    #[serde(default)]
    pub size: Option<u64>,
    #[serde(default)]
    pub mode: Option<u32>,
    /// Epoch milliseconds.
    #[serde(default)]
    pub modified_at: Option<f64>,
    /// The daemon's revision (`s<size>-m<mtime>`), for a `baseRevision`
    /// write; stat only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
}

impl Entry {
    /// A daemon entry (finder.md 4.1: `{name, kind: file|dir|symlink|other,
    /// size, mtime}`) in this server's shape.
    fn from_daemon(value: &Value) -> Self {
        let kind = match value["kind"].as_str().unwrap_or("other") {
            "dir" | "directory" => "directory",
            "file" => "file",
            "symlink" => "symlink",
            _ => "other",
        };
        Self {
            name: value["name"].as_str().map(str::to_owned),
            path: None,
            kind: kind.into(),
            size: value["size"].as_u64(),
            mode: None,
            modified_at: value["mtime"].as_f64(),
            revision: value["revision"].as_str().map(str::to_owned),
        }
    }
}

fn too_large(what: &str, size: u64, bound: usize) -> CloudError {
    CloudError::new(FILE_TOO_LARGE, format!("{what} is {size} bytes; the limit is {bound} bytes"))
}

pub(crate) fn list(d: &Daemon, path: &GuestPath) -> Result<Vec<Entry>, CloudError> {
    let page = d.call(
        "fs.list",
        // The daemon hides dotfiles unless asked (decision D5c); the Cloud
        // explorer shows them.
        json!({ "path": path.as_str(), "limit": MAX_LIST_ENTRIES, "filter": { "hidden": true } }),
    )?;
    let entries = page["entries"].as_array().map(Vec::as_slice).unwrap_or_default();
    Ok(entries.iter().map(Entry::from_daemon).collect())
}

pub(crate) fn stat(d: &Daemon, path: &GuestPath) -> Result<Entry, CloudError> {
    let answer = d.call("fs.stat", json!({ "path": path.as_str() }))?;
    let mut entry = Entry::from_daemon(&answer);
    entry.path = Some(path.as_str().to_owned());
    Ok(entry)
}

/// Bytes of one daemon `fs.read` answer (`text` or `bytes_base64`).
pub(crate) fn read_bytes(answer: &Value) -> Result<Vec<u8>, CloudError> {
    if let Some(text) = answer["text"].as_str() {
        return Ok(text.as_bytes().to_vec());
    }
    let encoded = answer["bytes_base64"].as_str().unwrap_or_default();
    STANDARD
        .decode(encoded)
        .map_err(|e| CloudError::new(codes::BAD_RESPONSE, format!("fs.read: {e}")))
}

/// The daemon's cap on one `fs.read` answer (request file: <= 1 MiB).
pub const READ_CHUNK_BYTES: u64 = 1024 * 1024;

/// The least a daemon answer that says "more" must hold (or all that was
/// asked, if less): it bounds the number of range calls, so a daemon that
/// answers one byte at a time cannot keep a read or a pull going for long.
pub const MIN_RANGE_BYTES: u64 = 64 * 1024;

/// Whether one range answer is acceptable: never longer than asked, and an
/// answer that says "more" holds at least [`MIN_RANGE_BYTES`] (or `want`).
pub(crate) fn range_ok(len: u64, want: u64, more: bool) -> bool {
    len <= want && (!more || len >= want.min(MIN_RANGE_BYTES))
}

/// Reads at most `limit` bytes from `offset` in [`READ_CHUNK_BYTES`]
/// ranges. Returns the bytes and whether the file has more after them. An
/// answer longer than asked, or empty while it says there is more, is a
/// protocol break (never a loop).
pub(crate) fn read_range(
    d: &Daemon,
    path: &GuestPath,
    offset: u64,
    limit: u64,
) -> Result<(Vec<u8>, bool), CloudError> {
    let mut bytes = Vec::new();
    loop {
        let got = bytes.len() as u64;
        let want = READ_CHUNK_BYTES.min(limit - got);
        let params = json!({ "path": path.as_str(), "offset": offset + got, "max_bytes": want });
        let answer = d.call("fs.read", params)?;
        let chunk = read_bytes(&answer)?;
        let more = answer["truncated"].as_bool() == Some(true);
        if !range_ok(chunk.len() as u64, want, more) {
            return Err(CloudError::new(
                codes::BAD_RESPONSE,
                "the machine's daemon answered fs.read with a bad range",
            ));
        }
        bytes.extend_from_slice(&chunk);
        if !more || bytes.len() as u64 == limit {
            return Ok((bytes, more));
        }
    }
}

/// Reads a whole file of at most [`MAX_READ_BYTES`]. A stat comes first, so
/// a large file is refused before its bytes cross the link; a file that
/// grew past the bound meanwhile is refused too.
pub(crate) fn read(d: &Daemon, path: &GuestPath) -> Result<Vec<u8>, CloudError> {
    let entry = stat(d, path)?;
    if entry.kind == "directory" {
        return Err(CloudError::invalid(format!("{} is a directory", path.as_str())));
    }
    if let Some(size) = entry.size.filter(|s| *s > MAX_READ_BYTES as u64) {
        return Err(too_large(path.as_str(), size, MAX_READ_BYTES));
    }
    let (bytes, more) = read_range(d, path, 0, MAX_READ_BYTES as u64)?;
    if more {
        return Err(too_large(path.as_str(), MAX_READ_BYTES as u64 + 1, MAX_READ_BYTES));
    }
    Ok(bytes)
}

/// Writes a whole file (atomic on the daemon). With `base_revision` the
/// write replaces only that revision (`fs.revision_mismatch` otherwise).
pub(crate) fn write(
    d: &Daemon,
    path: &GuestPath,
    bytes: &[u8],
    base_revision: Option<&str>,
) -> Result<Option<String>, CloudError> {
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(too_large("the data", bytes.len() as u64, MAX_WRITE_BYTES));
    }
    let mut params = json!({ "path": path.as_str(), "bytes_base64": STANDARD.encode(bytes) });
    match base_revision {
        Some(expected) => {
            params["mode"] = json!("replace");
            params["expected"] = json!(expected);
        }
        None => params["mode"] = json!("overwrite"),
    }
    let answer = d.write(params, bytes.len() as u64)?;
    Ok(answer["entry"]["revision"].as_str().map(str::to_owned))
}

/// `path` as the daemon's `{path: parent, name}`.
fn parent_and_name(path: &GuestPath) -> Result<(String, String), CloudError> {
    let text = path.as_str().trim_end_matches('/');
    match text.rsplit_once('/') {
        Some((parent, name)) if !name.is_empty() => {
            Ok((if parent.is_empty() { "/".into() } else { parent.to_owned() }, name.to_owned()))
        }
        _ => Err(CloudError::invalid(format!("{} has no name to create", path.as_str()))),
    }
}

pub(crate) fn mkdir(d: &Daemon, path: &GuestPath) -> Result<(), CloudError> {
    let (parent, name) = parent_and_name(path)?;
    d.call("fs.mkdir", json!({ "path": parent, "name": name }))?;
    Ok(())
}

pub(crate) fn remove(d: &Daemon, path: &GuestPath) -> Result<(), CloudError> {
    let params = json!({ "paths": [path.as_str()], "permanent": true });
    d.call("fs.delete", params)?;
    Ok(())
}

/// The catalog ops `cloud.fs.list|stat|read|write|mkdir|remove`. Arguments
/// and the `fs-v1` gate are checked on the loop; the daemon work runs as
/// one file job (super::jobs: on a worker in the serve loop, inline for
/// direct callers).
pub(crate) fn run<C: ControlPlane>(
    server: &mut Server<C>,
    name: &str,
    raw: &Value,
    key: Option<&str>,
) -> Result<Value, CloudError> {
    let allowed: &[&str] = match name {
        "cloud.fs.write" => &["machine", "path", "dataBase64", "mode", "baseRevision"],
        _ => &["machine", "path"],
    };
    let map = args::object(raw, allowed)?;
    let machine = args::id(map, "machine")?.to_owned();
    let path = guest_arg(map, "path")?;
    let write_data = match name {
        "cloud.fs.write" => Some(write_args(map)?),
        "cloud.fs.list" | "cloud.fs.stat" | "cloud.fs.read" | "cloud.fs.mkdir"
        | "cloud.fs.remove" => None,
        _ => return Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    };
    let daemon = link_files::daemon(server, &machine)?;
    let name = name.to_owned();
    let work: super::jobs::Work = Box::new(move |d: &Daemon| match name.as_str() {
        "cloud.fs.list" => Ok(json!({ "path": path.as_str(), "entries": list(d, &path)? })),
        "cloud.fs.stat" => Ok(json!(stat(d, &path)?)),
        "cloud.fs.read" => {
            let bytes = read(d, &path)?;
            Ok(json!({ "path": path.as_str(), "dataBase64": STANDARD.encode(&bytes),
                "size": bytes.len() }))
        }
        "cloud.fs.write" => {
            let (bytes, base) = write_data.unwrap_or_default();
            let revision = write(d, &path, &bytes, base.as_deref())?;
            Ok(json!({ "ok": true, "path": path.as_str(), "size": bytes.len(),
                "revision": revision }))
        }
        "cloud.fs.mkdir" => {
            mkdir(d, &path)?;
            Ok(json!({ "ok": true, "path": path.as_str() }))
        }
        _ => {
            remove(d, &path)?;
            Ok(json!({ "ok": true, "path": path.as_str() }))
        }
    });
    super::jobs::submit(server, daemon, key, work)
}

fn write_args(map: &Map<String, Value>) -> Result<(Vec<u8>, Option<String>), CloudError> {
    if map.get("mode").is_some_and(|v| !v.is_null()) {
        return Err(CloudError::new(
            codes::UNSUPPORTED,
            "The machine's daemon write keeps the file's mode; it cannot set one",
        ));
    }
    let base = match map.get("baseRevision") {
        None | Some(Value::Null) => None,
        Some(Value::String(revision)) if !revision.is_empty() && revision.len() <= 128 => {
            Some(revision.clone())
        }
        Some(_) => return Err(CloudError::invalid("baseRevision must be a revision string")),
    };
    let data = map
        .get("dataBase64")
        .and_then(Value::as_str)
        .ok_or_else(|| CloudError::invalid("dataBase64 is required"))?;
    if data.len() / 4 * 3 > MAX_WRITE_BYTES + 2 {
        return Err(too_large("the data", (data.len() / 4 * 3) as u64, MAX_WRITE_BYTES));
    }
    let bytes =
        STANDARD.decode(data).map_err(|_| CloudError::invalid("dataBase64 must be base64"))?;
    Ok((bytes, base))
}
