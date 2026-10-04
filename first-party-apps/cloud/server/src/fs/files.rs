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
        todo!("C5 red: not built yet")
    }

pub(crate) fn stat<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<Entry, CloudError> {
        todo!("C5 red: not built yet")
    }

/// Reads a whole file of at most [`MAX_READ_BYTES`]. A stat comes first, so
/// a large file is refused before its bytes cross the relay; the answer is
/// checked again (the file can grow between the two calls).
pub(crate) fn read<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<Vec<u8>, CloudError> {
        todo!("C5 red: not built yet")
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
        todo!("C5 red: not built yet")
    }

pub(crate) fn mkdir<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<(), CloudError> {
        todo!("C5 red: not built yet")
    }

pub(crate) fn remove<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    machine: &str,
    path: &GuestPath,
) -> Result<(), CloudError> {
        todo!("C5 red: not built yet")
    }

/// The catalog ops `cloud.fs.list|stat|read|write|mkdir|remove`.
pub(crate) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
        todo!("C5 red: not built yet")
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
