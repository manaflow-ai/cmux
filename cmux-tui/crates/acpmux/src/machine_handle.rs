//! Persistent spoken handles for machines and VMs.
//!
//! A machine's provider id and configured host name remain its identity. A handle is display
//! metadata that people can say in a forum or send command and can be changed without moving
//! sessions. The registry is deliberately separate from peer configuration so a move or a peer
//! reconnect cannot rewrite the stable machine id.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

const HANDLE_POOL: &[&str] = &[
    "Mango", "Biscuit", "Tofu", "Ramen", "Waffle", "Nori", "Pico", "Miso", "Kiwi", "Taco", "Panda",
    "Olive", "Cocoa", "Mocha", "Peach", "Berry", "Sushi", "Pesto", "Gizmo", "Puff",
];

/// The owner-only file retained by a daemon. It lives beside the other acpmux state, so a
/// session compaction or VM image move carries its handles with the daemon's home.
pub const FILE_NAME: &str = "machine-handles.json";

/// One machine's spoken label and the subtitle shown beside it in the UI.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// Stable provider or host identity. This is never replaced by a handle.
    pub id: String,
    /// The configured host name, retained for routing and diagnostics.
    pub canonical: String,
    /// Short spoken handle, unique case-insensitively in this registry.
    pub handle: String,
    /// Optional harness or host subtitle, such as `ci-fleet`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
}

/// Durable machine-handle index. The map key is the stable machine id and is not user-facing.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(transparent)]
pub struct Registry {
    entries: BTreeMap<String, Entry>,
}

impl Registry {
    /// Read a registry. A missing file is the empty registry. A malformed file is an error so a
    /// caller never silently loses existing names.
    pub fn load(path: &Path) -> Result<Self> {
        match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .with_context(|| format!("parse machine handles {}", path.display())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => {
                Err(error).with_context(|| format!("read machine handles {}", path.display()))
            }
        }
    }

    /// Persist owner-only state atomically through the same config writer as the rest of acpmux.
    pub fn save(&self, path: &Path) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(self).context("encode machine handles")?;
        if let Some(parent) = path.parent() {
            crate::home_fs::create_dir_all(parent, 0o700).with_context(|| {
                format!("create machine handles directory {}", parent.display())
            })?;
        }
        crate::config::write_atomic(path, &bytes)
            .with_context(|| format!("write machine handles {}", path.display()))
    }

    /// Apply one read-modify-write transaction under an exclusive lock. CLI processes can run at
    /// the same time, so atomic replacement alone is insufficient to preserve both renames.
    pub fn update<T>(path: &Path, change: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        let lock_path = path.with_extension("lock");
        if let Some(parent) = lock_path.parent() {
            crate::home_fs::create_dir_all(parent, 0o700)?;
        }
        let file = open_lock_file(&lock_path)?;
        let _lock = cmux_file_lock::FileLock::take(file, cmux_file_lock::Kind::Exclusive)?;
        let mut registry = Self::load(path)?;
        let result = change(&mut registry)?;
        registry.save(path)?;
        Ok(result)
    }

    /// The normal state path in a daemon's acpmux home.
    pub fn default_path() -> PathBuf {
        crate::config::home().join(FILE_NAME)
    }

    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.entries.values()
    }

    pub fn get(&self, id: &str) -> Option<&Entry> {
        self.entries.get(id)
    }

    /// Resolve a handle or stable id. Canonical host names are accepted as a compatibility key,
    /// while a duplicate handle is refused instead of guessed.
    pub fn resolve(&self, key: &str) -> Result<Option<&Entry>> {
        if let Some(entry) = self.entries.get(key) {
            return Ok(Some(entry));
        }
        // Existing canonical names take precedence over display handles so adding a handle can
        // never retarget a route that already used that host name.
        let canonical: Vec<&Entry> =
            self.entries.values().filter(|entry| entry.canonical == key).collect();
        if let [entry] = canonical.as_slice() {
            return Ok(Some(entry));
        }
        if canonical.len() > 1 {
            bail!("machine name {key:?} is ambiguous")
        }
        let handles: Vec<&Entry> =
            self.entries.values().filter(|entry| entry.handle.eq_ignore_ascii_case(key)).collect();
        match handles.as_slice() {
            [] => Ok(None),
            [entry] => Ok(Some(entry)),
            _ => bail!("machine handle {key:?} is ambiguous"),
        }
    }

    /// Insert or update a machine while preserving its existing handle on reconnect.
    pub fn upsert(
        &mut self,
        id: impl Into<String>,
        canonical: impl Into<String>,
        handle: impl Into<String>,
        subtitle: Option<String>,
    ) -> Result<&Entry> {
        let id = id.into();
        let canonical = canonical.into();
        let handle = handle.into();
        validate_handle(&handle)?;
        if self
            .entries
            .values()
            .any(|entry| entry.id != id && entry.handle.eq_ignore_ascii_case(&handle))
        {
            bail!("machine handle {handle:?} is already in use")
        }
        let entry = Entry { id: id.clone(), canonical, handle, subtitle };
        self.entries.insert(id.clone(), entry);
        self.entries
            .get(&id)
            .ok_or_else(|| anyhow::anyhow!("machine handle disappeared after insert"))
    }

    /// Rename an existing machine and preserve its stable id and canonical route name.
    pub fn rename(&mut self, id_or_handle: &str, handle: impl Into<String>) -> Result<&Entry> {
        let handle = handle.into();
        validate_handle(&handle)?;
        let id = self
            .resolve(id_or_handle)?
            .map(|entry| entry.id.clone())
            .ok_or_else(|| anyhow::anyhow!("no machine named {id_or_handle:?}"))?;
        if self
            .entries
            .values()
            .any(|entry| entry.id != id && entry.handle.eq_ignore_ascii_case(&handle))
        {
            bail!("machine handle {handle:?} is already in use")
        }
        self.entries
            .get_mut(&id)
            .ok_or_else(|| anyhow::anyhow!("machine handle disappeared during rename"))?
            .handle = handle;
        self.entries
            .get(&id)
            .ok_or_else(|| anyhow::anyhow!("machine handle disappeared after rename"))
    }

    /// Rename a known machine, or register a canonical machine name on first use. This keeps the
    /// CLI useful before a provider has supplied a separate machine id. Once a row supplies one,
    /// callers should use that id so a host rename does not create another entry.
    pub fn rename_or_register(
        &mut self,
        id_or_canonical: &str,
        handle: impl Into<String>,
    ) -> Result<&Entry> {
        if self.resolve(id_or_canonical)?.is_some() {
            return self.rename(id_or_canonical, handle);
        }
        self.upsert(id_or_canonical, id_or_canonical, handle, None)
    }

    /// Add handle and display fields to a machine-list response. Unknown rows remain routable by
    /// their canonical name and are left untouched until a person assigns a handle.
    pub fn annotate_rows(&self, rows: &mut serde_json::Value) {
        let Some(items) = rows.get_mut("peers").and_then(serde_json::Value::as_array_mut) else {
            return;
        };
        for row in items {
            let key = row
                .get("machineId")
                .or_else(|| row.get("id"))
                .or_else(|| row.get("name"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            let canonical = row.get("name").and_then(serde_json::Value::as_str).unwrap_or(key);
            let entry =
                self.resolve(key).ok().flatten().or_else(|| self.resolve(canonical).ok().flatten());
            if let Some(entry) = entry {
                row["handle"] = serde_json::json!(entry.handle);
                row["displayName"] = serde_json::json!(display(entry));
                row["machineId"] = serde_json::json!(entry.id);
            }
        }
    }

    /// Ensure every machine row has a stable, deterministic spoken handle, then annotate it for
    /// display. Provider `machineId`/`daemonId` values are used when present. Existing canonical
    /// host names, including `cmux-runner-pool-*`, remain routing metadata.
    pub fn ensure_rows(&mut self, rows: &mut serde_json::Value) -> Result<()> {
        let Some(items) = rows.get("peers").and_then(serde_json::Value::as_array).cloned() else {
            return Ok(());
        };
        for row in items {
            let id = row
                .get("machineId")
                .or_else(|| row.get("daemonId"))
                .or_else(|| row.get("id"))
                .or_else(|| row.get("name"))
                .and_then(serde_json::Value::as_str)
                .filter(|id| !id.is_empty())
                .unwrap_or("machine");
            let canonical = row.get("name").and_then(serde_json::Value::as_str).unwrap_or(id);
            let existing =
                self.get(id).map(|entry| (entry.id.clone(), entry.handle.clone())).or_else(|| {
                    self.resolve(canonical)
                        .ok()
                        .flatten()
                        .map(|entry| (entry.id.clone(), entry.handle.clone()))
                });
            let (entry_id, handle) = existing.unwrap_or_else(|| {
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                id.hash(&mut hasher);
                let start = (hasher.finish() as usize) % HANDLE_POOL.len();
                for offset in 0..HANDLE_POOL.len() {
                    let candidate = HANDLE_POOL[(start + offset) % HANDLE_POOL.len()];
                    if !self
                        .entries
                        .values()
                        .any(|entry| entry.handle.eq_ignore_ascii_case(candidate))
                    {
                        return (id.to_owned(), candidate.to_owned());
                    }
                }
                (id.to_owned(), format!("VM-{}", hasher.finish() % 10_000))
            });
            self.upsert(
                entry_id,
                canonical,
                handle,
                row.get("harness").and_then(serde_json::Value::as_str).map(str::to_owned),
            )?;
        }
        self.annotate_rows(rows);
        Ok(())
    }
}

fn open_lock_file(path: &Path) -> Result<std::fs::File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        return Ok(OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?);
    }
    #[cfg(not(unix))]
    Ok(OpenOptions::new().create(true).read(true).write(true).open(path)?)
}

/// Validates a short spoken handle. Whitespace is allowed between words, while slash and control
/// characters are refused because handles may appear as the host part of `HANDLE/session`.
pub fn validate_handle(handle: &str) -> Result<()> {
    let trimmed = handle.trim();
    if trimmed.is_empty() || trimmed.len() > 32 {
        bail!("machine handle must be between 1 and 32 characters")
    }
    if trimmed.chars().any(|c| c.is_control() || c == '/') {
        bail!("machine handle cannot contain control characters or `/`")
    }
    if !trimmed.chars().any(|c| c.is_alphanumeric()) {
        bail!("machine handle must contain a letter or number")
    }
    Ok(())
}

/// Render the product subtitle without changing the route identity.
pub fn display(entry: &Entry) -> String {
    match entry.subtitle.as_deref().filter(|s| !s.is_empty()) {
        Some(subtitle) => format!("{} · {subtitle}", entry.handle),
        None => entry.handle.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_resolve_both_ways_and_rename_keeps_identity() {
        let mut registry = Registry::default();
        registry.upsert("vm-123", "cmux-runner-pool-1", "Mango", Some("ci-fleet".into())).unwrap();
        assert_eq!(registry.resolve("Mango").unwrap().unwrap().id, "vm-123");
        assert_eq!(registry.resolve("vm-123").unwrap().unwrap().canonical, "cmux-runner-pool-1");
        registry.rename("Mango", "Tofu").unwrap();
        assert!(registry.resolve("Mango").unwrap().is_none());
        assert_eq!(registry.resolve("Tofu").unwrap().unwrap().id, "vm-123");
        assert_eq!(display(registry.get("vm-123").unwrap()), "Tofu · ci-fleet");
    }

    #[test]
    fn duplicate_handles_are_refused_case_insensitively() {
        let mut registry = Registry::default();
        registry.upsert("one", "host-one", "Biscuit", None).unwrap();
        assert!(registry.upsert("two", "host-two", "bIsCuIt", None).is_err());
    }

    #[test]
    fn runner_pool_canonical_name_is_retained() {
        let mut registry = Registry::default();
        registry.upsert("pool-1", "cmux-runner-pool-1", "Ramen", None).unwrap();
        assert_eq!(registry.resolve("cmux-runner-pool-1").unwrap().unwrap().handle, "Ramen");
    }

    #[test]
    fn canonical_names_win_over_a_handle_with_the_same_spelling() {
        let mut registry = Registry::default();
        registry.upsert("host-id", "host-name", "Mango", None).unwrap();
        registry.upsert("mango-id", "other-host", "other", None).unwrap();
        assert_eq!(registry.resolve("host-name").unwrap().unwrap().id, "host-id");
        registry.rename("other-host", "host-name").unwrap();
        assert_eq!(registry.resolve("host-name").unwrap().unwrap().id, "host-id");
    }

    #[test]
    fn handles_refuse_route_breaking_values() {
        assert!(validate_handle("bad/name").is_err());
        assert!(validate_handle("---").is_err());
        assert!(validate_handle("  ").is_err());
        assert!(validate_handle("Biscuit 2").is_ok());
    }

    #[test]
    fn every_inventory_row_gets_a_handle_from_its_stable_id() {
        let mut registry = Registry::default();
        let mut rows = serde_json::json!({
            "peers": [
                {"machineId": "vm-1", "name": "cmux-runner-pool-1"},
                {"machineId": "vm-2", "name": "gcp-codex-lane-2"}
            ]
        });
        registry.ensure_rows(&mut rows).unwrap();
        assert!(rows["peers"].as_array().unwrap().iter().all(|row| row["handle"].is_string()));
        assert_eq!(registry.get("vm-1").unwrap().canonical, "cmux-runner-pool-1");
    }
}
