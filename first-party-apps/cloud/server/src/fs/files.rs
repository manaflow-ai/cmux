//! `cloud.fs.*` on the machine's cmux daemon over the link
//! (super::link_files: the `fs-v1` gate and the daemon call). The op
//! shapes the Cloud page uses stay; each maps to one finder `fs.*` op.

use super::link_files;
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
        }
    }
}

fn too_large(what: &str, size: u64, bound: usize) -> CloudError {
    CloudError::new(FILE_TOO_LARGE, format!("{what} is {size} bytes; the limit is {bound} bytes"))
}

pub(crate) fn list<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    path: &GuestPath,
) -> Result<Vec<Entry>, CloudError> {
    let page = link_files::call(
        server,
        machine,
        "fs.list",
        json!({ "path": path.as_str(), "limit": MAX_LIST_ENTRIES }),
    )?;
    let entries = page["entries"].as_array().map(Vec::as_slice).unwrap_or_default();
    Ok(entries.iter().map(Entry::from_daemon).collect())
}

pub(crate) fn stat<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    path: &GuestPath,
) -> Result<Entry, CloudError> {
    let answer = link_files::call(server, machine, "fs.stat", json!({ "path": path.as_str() }))?;
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

/// Reads a whole file of at most [`MAX_READ_BYTES`]. A stat comes first, so
/// a large file is refused before its bytes cross the link; a truncated
/// answer (the file grew) is refused too.
pub(crate) fn read<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    path: &GuestPath,
) -> Result<Vec<u8>, CloudError> {
    let entry = stat(server, machine, path)?;
    if entry.kind == "directory" {
        return Err(CloudError::invalid(format!("{} is a directory", path.as_str())));
    }
    if let Some(size) = entry.size.filter(|s| *s > MAX_READ_BYTES as u64) {
        return Err(too_large(path.as_str(), size, MAX_READ_BYTES));
    }
    let params = json!({ "path": path.as_str(), "offset": 0, "max_bytes": MAX_READ_BYTES });
    let answer = link_files::call(server, machine, "fs.read", params)?;
    if answer["truncated"].as_bool() == Some(true) {
        let size = answer["size"].as_u64().unwrap_or_default();
        return Err(too_large(path.as_str(), size, MAX_READ_BYTES));
    }
    let bytes = read_bytes(&answer)?;
    if bytes.len() > MAX_READ_BYTES {
        return Err(too_large(path.as_str(), bytes.len() as u64, MAX_READ_BYTES));
    }
    Ok(bytes)
}

/// Writes a whole file (atomic on the daemon). With `base_revision` the
/// write replaces only that revision (`fs.revision_mismatch` otherwise).
pub(crate) fn write<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
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
    let answer = link_files::call(server, machine, "fs.write", params)?;
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

pub(crate) fn mkdir<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    path: &GuestPath,
) -> Result<(), CloudError> {
    let (parent, name) = parent_and_name(path)?;
    link_files::call(server, machine, "fs.mkdir", json!({ "path": parent, "name": name }))?;
    Ok(())
}

pub(crate) fn remove<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    path: &GuestPath,
) -> Result<(), CloudError> {
    let params = json!({ "paths": [path.as_str()], "permanent": true });
    link_files::call(server, machine, "fs.delete", params)?;
    Ok(())
}

/// The catalog ops `cloud.fs.list|stat|read|write|mkdir|remove`.
pub(crate) fn run<C: ControlPlane>(
    server: &mut Server<C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    let allowed: &[&str] = match name {
        "cloud.fs.write" => &["machine", "path", "dataBase64", "mode", "baseRevision"],
        _ => &["machine", "path"],
    };
    let map = args::object(raw, allowed)?;
    let machine = args::id(map, "machine")?.to_owned();
    let machine = machine.as_str();
    let path = guest_arg(map, "path")?;
    match name {
        "cloud.fs.list" => {
            Ok(json!({ "path": path.as_str(), "entries": list(server, machine, &path)? }))
        }
        "cloud.fs.stat" => Ok(json!(stat(server, machine, &path)?)),
        "cloud.fs.read" => {
            let bytes = read(server, machine, &path)?;
            Ok(json!({ "path": path.as_str(), "dataBase64": STANDARD.encode(&bytes),
                "size": bytes.len() }))
        }
        "cloud.fs.write" => {
            let (bytes, base) = write_args(map)?;
            let revision = write(server, machine, &path, &bytes, base.as_deref())?;
            Ok(json!({ "ok": true, "path": path.as_str(), "size": bytes.len(),
                "revision": revision }))
        }
        "cloud.fs.mkdir" => {
            mkdir(server, machine, &path)?;
            Ok(json!({ "ok": true, "path": path.as_str() }))
        }
        "cloud.fs.remove" => {
            remove(server, machine, &path)?;
            Ok(json!({ "ok": true, "path": path.as_str() }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
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
