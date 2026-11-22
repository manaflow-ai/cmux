//! Model-name auto-reroute: a misspelled model id (`fable-5.2`, `claude-fable-5.2`,
//! `Claude-Opus-5.5`) starts on the model it plainly names instead of failing every turn.
//!
//! Leo, 2026-11-22 (ask-7f78a3917c), after 16 lanes started on `claude/fable-5.2` and never
//! completed a turn: "you guys need to be able to hot patch these and reroute and auto-reroute
//! to proper names. there's not much confusion possible here, so this is totally a candidate for
//! that kind of thing. you guys need to be catching these yourselves".
//!
//! A name is rerouted only to exactly one id, in this order:
//! 1. `$ACPMUX_HOME/model-aliases.json` (`{"wrong-name": "right-id"}`): a per-host hot patch,
//!    read again whenever the file changes; no restart, no release.
//! 2. The model catalog's `aliases` (`crate::catalog`): a fleet-wide hot patch, published from
//!    the catalog admin and fetched by every daemon within the hour (`catalog.refresh`: now).
//! 3. Spelling: case, `.`/`_`/space for `-`, a missing `claude-` prefix, a stray `claude/` or
//!    `anthropic/` head. The result must be a catalog id or alias; anything else is left as
//!    typed, so a new model the catalog does not know yet is never rewritten.
//!
//! A `[1m]` suffix is kept. Every reroute is logged (`tracing::info`) with both names.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::SystemTime;

/// The per-host alias file, in `$ACPMUX_HOME`.
pub const OVERRIDE_FILE: &str = "model-aliases.json";

/// What the catalog in use says each harness family's models are called.
#[derive(Debug, Default, Clone)]
pub struct Table {
    /// family (`claude`, `codex`, ...) -> lowercase name (id or alias) -> id.
    families: BTreeMap<String, BTreeMap<String, String>>,
}

impl Table {
    /// The table for `catalog`: every harness entry's model ids and aliases, under each family
    /// it lists and its own id.
    pub fn from_catalog(catalog: &crate::catalog::Catalog) -> Self {
        let mut families: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
        for harness in &catalog.harnesses {
            let mut keys: Vec<&str> = harness.families.iter().map(String::as_str).collect();
            keys.push(&harness.id);
            for key in keys {
                let names = families.entry(key.to_owned()).or_default();
                for model in &harness.models {
                    names.entry(model.id.to_lowercase()).or_insert_with(|| model.id.clone());
                    for alias in model.aliases.iter().flatten() {
                        names.entry(alias.to_lowercase()).or_insert_with(|| model.id.clone());
                    }
                }
            }
        }
        Self { families }
    }

    fn names(&self, family: &str) -> Option<&BTreeMap<String, String>> {
        self.families.get(family)
    }
}

static TABLE: RwLock<Option<Arc<Table>>> = RwLock::new(None);

/// Installs the table for the catalog now in use (`crate::catalog` calls it on every change).
pub fn install(catalog: &crate::catalog::Catalog) {
    let table = Arc::new(Table::from_catalog(catalog));
    *TABLE.write().unwrap_or_else(PoisonError::into_inner) = Some(table);
}

fn table() -> Arc<Table> {
    if let Some(t) = TABLE.read().unwrap_or_else(PoisonError::into_inner).clone() {
        return t;
    }
    // Before the daemon attached its catalog (a CLI-side spawn plan, a test): the bundled one.
    let bundled = crate::catalog::CatalogService::new().current();
    install(&bundled);
    TABLE.read().unwrap_or_else(PoisonError::into_inner).clone().unwrap_or_default()
}

/// The override file's aliases, cached by path and modification time.
struct Overrides {
    path: PathBuf,
    modified: Option<SystemTime>,
    map: BTreeMap<String, String>,
}

static OVERRIDES: Mutex<Option<Overrides>> = Mutex::new(None);

fn override_for(name: &str) -> Option<String> {
    let path = crate::config::home().join(OVERRIDE_FILE);
    let modified = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
    let mut slot = OVERRIDES.lock().unwrap_or_else(PoisonError::into_inner);
    let stale = match slot.as_ref() {
        Some(o) => o.path != path || o.modified != modified,
        None => true,
    };
    if stale {
        let map = modified.map(|_| read_overrides(&path)).unwrap_or_default();
        *slot = Some(Overrides { path, modified, map });
    }
    slot.as_ref().and_then(|o| o.map.get(&name.to_lowercase()).cloned())
}

/// `{"wrong": "right"}`, keys lowercased. A file that does not read is warned about and ignored.
fn read_overrides(path: &std::path::Path) -> BTreeMap<String, String> {
    let parsed = std::fs::read(path).map_err(|e| e.to_string()).and_then(|b| {
        serde_json::from_slice::<BTreeMap<String, String>>(&b).map_err(|e| e.to_string())
    });
    match parsed {
        Ok(map) => map
            .into_iter()
            .filter(|(k, v)| !k.trim().is_empty() && !v.trim().is_empty())
            .map(|(k, v)| (k.trim().to_lowercase(), v.trim().to_owned()))
            .collect(),
        Err(e) => {
            tracing::warn!(
                "{} is not used: {e} (it takes {{\"wrong-name\": \"model-id\"}})",
                path.display()
            );
            BTreeMap::new()
        }
    }
}

/// The spellings `name` may be a typo of, most literal first.
fn spellings(name: &str, family: &str) -> Vec<String> {
    let mut base = name.trim().to_lowercase();
    for head in [format!("{family}/"), "anthropic/".to_owned()] {
        if let Some(rest) = base.strip_prefix(&head) {
            base = rest.to_owned();
        }
    }
    let dashed: String =
        base.chars().map(|c| if matches!(c, '.' | '_' | ' ') { '-' } else { c }).collect();
    let mut out = vec![base.clone(), dashed.clone()];
    let prefix = format!("{family}-");
    if !dashed.starts_with(&prefix) {
        out.push(format!("{prefix}{dashed}"));
    }
    out.dedup();
    out
}

/// The id `name` should run as on a harness of `family`, when it is not already one: `None`
/// leaves the name as typed. `[1m]` is kept.
pub fn reroute(family: &str, name: &str) -> Option<String> {
    reroute_with(&table(), family, name, override_for)
}

fn reroute_with(
    table: &Table,
    family: &str,
    name: &str,
    overrides: impl Fn(&str) -> Option<String>,
) -> Option<String> {
    let trimmed = name.trim();
    let (base, suffix) = match trimmed.strip_suffix("[1m]") {
        Some(b) => (b, "[1m]"),
        None => (trimmed, ""),
    };
    if base.is_empty() || base == "default" {
        return None;
    }
    let names = table.names(family);
    // Never touched: an id the catalog knows, exactly as written, and a short alias with no
    // version in it (`opus`, `fable`), which is the harness's own and follows its releases.
    // An alias with a version (`fable-5.2`) is a reroute the catalog publishes.
    if let Some(id) = names.and_then(|n| n.get(base)) {
        if id == base || !base.chars().any(|c| c.is_ascii_digit()) {
            return None;
        }
    }
    let to = overrides(base).or_else(|| {
        let names = names?;
        spellings(base, family).iter().find_map(|s| names.get(s).cloned())
    })?;
    let to = format!("{to}{suffix}");
    (to != trimmed).then_some(to)
}

/// `name` as the harness should get it, logging a reroute.
pub fn resolve(family: &str, name: &str) -> String {
    match reroute(family, name) {
        Some(to) => {
            tracing::info!(from = name, to = %to, family, "model name rerouted");
            to
        }
        None => name.to_owned(),
    }
}

#[cfg(test)]
#[path = "model_reroute_tests.rs"]
mod tests;
