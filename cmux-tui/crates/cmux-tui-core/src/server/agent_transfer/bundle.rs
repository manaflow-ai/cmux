//! The bundle a move hands out: which paths a page may name, and the
//! scrubbed copies of its `manifest.json` and `session.json` the source
//! serves in place of acpmux's own.

use crate::panic_free::JsonFields;
use std::collections::HashMap;
use std::path::{Component, Path};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};

use super::{BundleFiles, CALL_TIMEOUT, Failure, MAX_PAGE_BYTES, MAX_PATH_BYTES, Refusal};

const MANIFEST: &str = "manifest.json";
const SESSION: &str = "session.json";
/// `session.json` keys (acpmux `SessionMeta`, camelCase and old aliases)
/// that carry the source machine's launch settings.
const SESSION_LAUNCH_KEYS: &[&str] = &[
    "sessionEnv",
    "session_env",
    "harnessArgv",
    "harness_argv",
    "agent_argv",
    "harnessRoots",
    "harness_roots",
    "preset",
    "tags",
];

/// A bundle file path: relative plain components only.
pub(super) fn is_bundle_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= MAX_PATH_BYTES
        && Path::new(path).components().all(|c| matches!(c, Component::Normal(_)))
}

/// The bytes padded base64 `data` decodes to (acpmux checks the alphabet).
pub(super) fn page_data_len(data: &str) -> Option<usize> {
    if !data.len().is_multiple_of(4) {
        return None;
    }
    let padding = data.bytes().rev().take(2).filter(|b| *b == b'=').count();
    Some(data.len() / 4 * 3 - padding)
}

/// Every path the begin `manifest` lists, with scrubbed copies of the
/// bundle's `manifest.json` (no absolute `source` paths of native files) and
/// `session.json` (no launch settings: [`SESSION_LAUNCH_KEYS`]; its `cwd`
/// stays, as the target's import needs a folder and its finish replaces
/// it). Names compare case-insensitively (a case-insensitive disk serves
/// `Session.json` for `session.json`), and the manifest lists the scrubbed
/// sizes. The import uses neither removed part.
pub(super) fn scrub_bundle(
    call: &impl Fn(&str, Value, Duration) -> Result<Value, Failure>,
    transfer_id: &str,
    manifest: &mut Value,
) -> Result<BundleFiles, Failure> {
    let entries =
        manifest.get_mut("files").and_then(Value::as_array_mut).ok_or(Refusal::Refused)?;
    let mut files = HashMap::new();
    for entry in entries.iter_mut() {
        let path = entry.field("path").as_str().filter(|path| is_bundle_path(path));
        let path = path.ok_or(Refusal::Refused)?.to_owned();
        let scrubbed = if path.eq_ignore_ascii_case(MANIFEST) || path.eq_ignore_ascii_case(SESSION)
        {
            let bytes = scrubbed_file(call, transfer_id, &path, entry.field("size").as_u64())?;
            entry.insert("size", json!(bytes.len()));
            Some(Arc::new(bytes))
        } else {
            None
        };
        files.insert(path, scrubbed);
    }
    Ok(files)
}

/// One bundle JSON file read whole from acpmux and scrubbed.
fn scrubbed_file(
    call: &impl Fn(&str, Value, Duration) -> Result<Value, Failure>,
    transfer_id: &str,
    path: &str,
    size: Option<u64>,
) -> Result<Vec<u8>, Failure> {
    let size = size.filter(|size| *size <= MAX_PAGE_BYTES as u64).ok_or(Refusal::Refused)?;
    let params =
        json!({"transferId": transfer_id, "path": path, "offset": 0, "limit": size.max(1)});
    let page = call("_acpmux/transfer_read", params, CALL_TIMEOUT)?;
    let bytes = page
        .field("data")
        .as_str()
        .and_then(|data| BASE64.decode(data).ok())
        .filter(|bytes| bytes.len() as u64 == size)
        .ok_or(Refusal::Refused)?;
    let mut value: Value = serde_json::from_slice(&bytes).map_err(|_| Refusal::Refused)?;
    if path.eq_ignore_ascii_case(MANIFEST) {
        if let Some(native) = value.get_mut("native").and_then(Value::as_array_mut) {
            for file in native.iter_mut().filter_map(Value::as_object_mut) {
                file.remove("source");
            }
        }
    } else if let Some(meta) = value.as_object_mut() {
        for key in SESSION_LAUNCH_KEYS {
            meta.remove(*key);
        }
    } else {
        return Err(Refusal::Refused.into());
    }
    Ok(serde_json::to_vec_pretty(&value).map_err(|_| Refusal::Refused)?)
}

/// A `transfer_read` page of `bytes`, as acpmux answers one.
pub(super) fn page_of(bytes: &[u8], offset: u64, limit: u64) -> Value {
    let len = bytes.len() as u64;
    let start = offset.min(len);
    let end = start.saturating_add(limit).min(len);
    let range =
        usize::try_from(start).unwrap_or(usize::MAX)..usize::try_from(end).unwrap_or(usize::MAX);
    let data = BASE64.encode(bytes.get(range).unwrap_or_default());
    json!({"data": data, "next": end, "eof": end == len})
}
