//! `cloud.fs.*` over the Cloud API file routes (`/api/vm/:id/fs/<op>`).
//!
//! Every byte goes through the host credential relay as base64 in JSON, so
//! reads and writes are bounded ([`MAX_READ_BYTES`], [`MAX_WRITE_BYTES`]).
//! The VM daemon path over the link (`workspace-rpc` file ops) is a later
//! improvement (cloud-app.md 3.5); it needs no change to these op shapes.

use super::path::{GuestPath, guest_arg};
use super::{FILE_TOO_LARGE, MAX_READ_BYTES, MAX_WRITE_BYTES};
use crate::api::{CloudError, ControlPlane, Ctx, args, codes, decode_answer};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

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

#[derive(Deserialize)]
struct Listing {
    entries: Vec<Entry>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contents {
    data_base64: String,
}

fn route(machine: &str, op: &str, path: &GuestPath) -> String {
    format!("/api/vm/{machine}/fs/{op}?path={}", path.query_value())
}

fn too_large(what: &str, size: u64, bound: usize) -> CloudError {
    CloudError::new(
        FILE_TOO_LARGE,
        format!("{what} is {size} bytes; the limit through the Cloud API is {bound} bytes"),
    )
}

pub(crate) fn list<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<Vec<Entry>, CloudError> {
    let at = route(machine, "dir", path);
    let listing: Listing = decode_answer(&at, ctx.call("GET", at.clone(), None)?)?;
    Ok(listing.entries)
}

pub(crate) fn stat<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<Entry, CloudError> {
    let at = route(machine, "stat", path);
    decode_answer(&at, ctx.call("GET", at.clone(), None)?)
}

/// Reads a whole file of at most [`MAX_READ_BYTES`]. A stat comes first, so
/// a large file is refused before its bytes cross the relay; the answer is
/// checked again (the file can grow between the two calls).
pub(crate) fn read<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<Vec<u8>, CloudError> {
    let entry = stat(ctx, machine, path)?;
    if entry.kind == "directory" {
        return Err(CloudError::invalid(format!("{} is a directory", path.as_str())));
    }
    if let Some(size) = entry.size.filter(|s| *s > MAX_READ_BYTES as u64) {
        return Err(too_large(path.as_str(), size, MAX_READ_BYTES));
    }
    let at = route(machine, "read", path);
    let contents: Contents = decode_answer(&at, ctx.call("GET", at.clone(), None)?)?;
    // Refuse an oversized answer before decoding it (4 base64 chars = 3 bytes).
    let estimate = contents.data_base64.len() / 4 * 3;
    if estimate > MAX_READ_BYTES + 2 {
        return Err(too_large(path.as_str(), estimate as u64, MAX_READ_BYTES));
    }
    let bytes = STANDARD
        .decode(contents.data_base64.as_bytes())
        .map_err(|e| CloudError::new(codes::BAD_RESPONSE, format!("{at}: {e}")))?;
    if bytes.len() > MAX_READ_BYTES {
        return Err(too_large(path.as_str(), bytes.len() as u64, MAX_READ_BYTES));
    }
    Ok(bytes)
}

/// Writes a whole file (the Cloud API writes it atomically). There is no
/// revision on the route, so a base revision cannot be checked.
pub(crate) fn write<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
    bytes: &[u8],
    mode: Option<u32>,
) -> Result<(), CloudError> {
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(too_large("the data", bytes.len() as u64, MAX_WRITE_BYTES));
    }
    let mut body = json!({ "path": path.as_str(), "dataBase64": STANDARD.encode(bytes) });
    if let Some(mode) = mode {
        body["mode"] = json!(mode);
    }
    ctx.call("POST", format!("/api/vm/{machine}/fs/write"), Some(body))?;
    Ok(())
}

pub(crate) fn mkdir<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<(), CloudError> {
    let body = json!({ "path": path.as_str() });
    ctx.call("POST", format!("/api/vm/{machine}/fs/mkdir"), Some(body))?;
    Ok(())
}

pub(crate) fn remove<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<(), CloudError> {
    ctx.call("DELETE", route(machine, "remove", path), None)?;
    Ok(())
}

/// The catalog ops `cloud.fs.list|stat|read|write|mkdir|remove`.
pub(crate) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    let allowed: &[&str] = match name {
        "cloud.fs.write" => &["machine", "path", "dataBase64", "mode", "baseRevision"],
        _ => &["machine", "path"],
    };
    let map = args::object(raw, allowed)?;
    let machine = args::id(map, "machine")?;
    let path = guest_arg(map, "path")?;
    match name {
        "cloud.fs.list" => {
            Ok(json!({ "path": path.as_str(), "entries": list(ctx, machine, &path)? }))
        }
        "cloud.fs.stat" => {
            let mut entry = stat(ctx, machine, &path)?;
            entry.path.get_or_insert_with(|| path.as_str().to_owned());
            Ok(json!(entry))
        }
        "cloud.fs.read" => {
            let bytes = read(ctx, machine, &path)?;
            Ok(json!({ "path": path.as_str(), "dataBase64": STANDARD.encode(&bytes),
                "size": bytes.len() }))
        }
        "cloud.fs.write" => {
            let (bytes, mode) = write_args(map)?;
            write(ctx, machine, &path, &bytes, mode)?;
            Ok(json!({ "ok": true, "path": path.as_str(), "size": bytes.len() }))
        }
        "cloud.fs.mkdir" => {
            mkdir(ctx, machine, &path)?;
            Ok(json!({ "ok": true, "path": path.as_str() }))
        }
        "cloud.fs.remove" => {
            remove(ctx, machine, &path)?;
            Ok(json!({ "ok": true, "path": path.as_str() }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

fn write_args(map: &Map<String, Value>) -> Result<(Vec<u8>, Option<u32>), CloudError> {
    if map.get("baseRevision").is_some_and(|v| !v.is_null()) {
        return Err(CloudError::new(
            codes::UNSUPPORTED,
            "The cmux Cloud API file route has no revision, so baseRevision cannot be checked",
        ));
    }
    let data = map
        .get("dataBase64")
        .and_then(Value::as_str)
        .ok_or_else(|| CloudError::invalid("dataBase64 is required"))?;
    if data.len() / 4 * 3 > MAX_WRITE_BYTES + 2 {
        return Err(too_large("the data", (data.len() / 4 * 3) as u64, MAX_WRITE_BYTES));
    }
    let bytes =
        STANDARD.decode(data).map_err(|_| CloudError::invalid("dataBase64 must be base64"))?;
    let mode = args::int(map, "mode", 0, 0o7777, 1)?.map(|m| m as u32);
    Ok((bytes, mode))
}
