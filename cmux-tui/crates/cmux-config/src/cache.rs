//! The cold-start cache `<state dir>/settings/effective.json`: the app
//! applies it at launch before the daemon answers (no merge logic in Swift).
//! Secret policy values appear only as present.

use std::io;
use std::path::Path;

use serde_json::{Value, json};

use crate::fsio::write_atomic;
use crate::location::cache_path;
use crate::store::State;

/// Format version of the cache file.
pub const CACHE_VERSION: u64 = 1;

/// The cache document for `state`.
pub fn cache_document(state: &State) -> Value {
    let effective = state.effective();
    json!({
        "version": CACHE_VERSION,
        "revision": state.revision(),
        "schema_hash": state.schema().schema_hash,
        "effective": effective.root,
        "managed": crate::store::managed_json(&effective.managed_keys),
        "policy": effective.policy.to_json(true),
    })
}

/// Writes the cache atomically.
pub fn write_cache(state_dir: &Path, state: &State) -> io::Result<()> {
    let mut text = crate::render::pretty(&cache_document(state), "");
    text.push('\n');
    write_atomic(&cache_path(state_dir), text.as_bytes())
}

/// The cached revision and effective document, if a readable cache exists.
pub fn read_cache(state_dir: &Path) -> Option<(u64, Value)> {
    let text = std::fs::read_to_string(cache_path(state_dir)).ok()?;
    let document: Value = serde_json::from_str(&text).ok()?;
    let revision = document.get("revision")?.as_u64()?;
    let effective = crate::value::canonical(document.get("effective")?.clone());
    Some((revision, effective))
}
