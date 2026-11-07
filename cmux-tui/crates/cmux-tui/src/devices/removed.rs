//! The joined machines a person removed (`cmux device remove`), so every
//! list that shows joined machines leaves them out: `cmux machine list`,
//! `cmux device list`, and so the app, the phone and MCP, which read those.
//! The platform keeps a revoked machine listed (`revoked: true`); a revoke
//! that was not a Remove still shows as revoked.
//!
//! `removed-machines.json` in the host state directory (next to the device audit log,
//! `remote_host::config::dir`), owner-only:
//! `{"machines": [{"id": "m_1", "at": <unix seconds>}]}`. A file that cannot be read
//! hides nothing; the list then shows the machine as revoked, as before.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use anyhow::{Context as _, anyhow};
use serde_json::{Value, json};

pub(crate) const FILE: &str = "removed-machines.json";

/// The host state directory (`CMUX_HOST_DIR`, else the default), where the device audit log lives too.
pub(crate) fn dir() -> anyhow::Result<PathBuf> {
    crate::remote_host::config::dir()
}

/// The removed machine ids in `dir`; none when the file is missing or unreadable.
pub(crate) fn ids_in(dir: &Path) -> HashSet<String> {
    let Ok(bytes) = std::fs::read(dir.join(FILE)) else { return HashSet::new() };
    let Ok(doc) = serde_json::from_slice::<Value>(&bytes) else { return HashSet::new() };
    doc.get("machines")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.get("id").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// The removed machine ids in the default directory.
pub(crate) fn ids() -> HashSet<String> {
    dir().map(|dir| ids_in(&dir)).unwrap_or_default()
}

/// Records `id` as removed in `dir` (once), written whole through a temporary file.
pub(crate) fn add_in(dir: &Path, id: &str, at: u64) -> anyhow::Result<()> {
    let path = dir.join(FILE);
    let mut doc = std::fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .filter(|doc| doc.get("machines").is_some_and(Value::is_array))
        .unwrap_or_else(|| json!({"machines": []}));
    let Some(machines) = doc.get_mut("machines").and_then(Value::as_array_mut) else {
        return Err(anyhow!("{} has no machines list", path.display()));
    };
    if machines.iter().any(|entry| entry.get("id").and_then(Value::as_str) == Some(id)) {
        return Ok(());
    }
    machines.push(json!({"id": id, "at": at}));
    std::fs::create_dir_all(dir).with_context(|| format!("cannot create {}", dir.display()))?;
    let temp = dir.join(format!("{FILE}.tmp"));
    std::fs::write(&temp, serde_json::to_vec_pretty(&doc)?)
        .with_context(|| format!("cannot write {}", temp.display()))?;
    cmux_tui_core::platform::restrict_file(&temp)?;
    std::fs::rename(&temp, &path).with_context(|| format!("cannot write {}", path.display()))?;
    Ok(())
}

/// Records `id` as removed in the default directory.
pub(crate) fn add(id: &str) -> anyhow::Result<()> {
    let at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    add_in(&dir()?, id, at)
}

/// `rows` (joined machine list rows, each with an `id`) without the removed ones.
pub(crate) fn without(rows: Vec<Value>, removed: &HashSet<String>) -> Vec<Value> {
    if removed.is_empty() {
        return rows;
    }
    rows.into_iter()
        .filter(|row| row.get("id").and_then(Value::as_str).is_none_or(|id| !removed.contains(id)))
        .collect()
}
