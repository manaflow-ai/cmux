//! The per-host model-name hot patch: `$ACPMUX_HOME/model-aliases.json`.
//!
//! Leo, 2026-11-22 (ask-7f78a3917c): "you guys need to be able to hot patch these and reroute and
//! auto-reroute to proper names". [`crate::model_catalog::canonical_model`] folds spellings
//! against the catalog; this file covers a name no fold reaches (`fable-latest`, a model newer
//! than this host's catalog) without a release, a catalog publish or a daemon restart. It is read
//! again whenever its modification time changes.
//!
//! ```json
//! { "claude": { "fable-latest": "claude-fable-5-2" }, "codex": { "astra": "gpt-6.2-astra" } }
//! ```
//!
//! Keys are a catalog harness id or family; names match case-insensitively; a `[1m]` suffix on
//! the name is kept. A file that does not parse is warned about once per change and ignored.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::SystemTime;

/// The file, in `$ACPMUX_HOME`.
pub const FILE: &str = "model-aliases.json";

/// harness id or family -> lowercase name -> id.
pub type Patches = BTreeMap<String, BTreeMap<String, String>>;

struct Cached {
    path: PathBuf,
    modified: Option<SystemTime>,
    patches: Patches,
}

static CACHE: Mutex<Option<Cached>> = Mutex::new(None);

/// The id the hot patch sends `name` (already trimmed, without `[1m]`) to on the harness `keys`
/// (its id and families), if any.
pub fn lookup<'a>(keys: impl IntoIterator<Item = &'a str>, name: &str) -> Option<String> {
    let path = crate::config::home().join(FILE);
    let modified = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
    let mut slot = CACHE.lock().unwrap_or_else(PoisonError::into_inner);
    let stale = slot.as_ref().is_none_or(|c| c.path != path || c.modified != modified);
    if stale {
        let patches = modified.map(|_| read(&path)).unwrap_or_default();
        *slot = Some(Cached { path, modified, patches });
    }
    let patches = &slot.as_ref()?.patches;
    find(patches, keys, name)
}

fn find<'a>(
    patches: &Patches,
    keys: impl IntoIterator<Item = &'a str>,
    name: &str,
) -> Option<String> {
    if patches.is_empty() {
        return None;
    }
    let name = name.to_lowercase();
    keys.into_iter().find_map(|k| patches.get(k)?.get(&name).cloned())
}

/// The file's patches, names lowercased, blanks dropped; `{}` when it does not parse.
pub fn read(path: &Path) -> Patches {
    let parsed = std::fs::read(path)
        .map_err(|e| e.to_string())
        .and_then(|b| serde_json::from_slice::<Patches>(&b).map_err(|e| e.to_string()));
    match parsed {
        Ok(patches) => patches
            .into_iter()
            .map(|(harness, names)| {
                let names = names
                    .into_iter()
                    .filter(|(k, v)| !k.trim().is_empty() && !v.trim().is_empty())
                    .map(|(k, v)| (k.trim().to_lowercase(), v.trim().to_owned()))
                    .collect();
                (harness.trim().to_owned(), names)
            })
            .collect(),
        Err(e) => {
            tracing::warn!(
                "{} is not used: {e} (it takes {{\"claude\": {{\"wrong-name\": \"model-id\"}}}})",
                path.display()
            );
            Patches::new()
        }
    }
}

#[cfg(test)]
#[path = "model_hot_patch_tests.rs"]
mod tests;
