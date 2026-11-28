//! `cmux settings explain KEY`: why a setting has the value it has.
//!
//! One answer to "where does this come from": every layer that could set the key, in the order
//! [`crate::EffectiveSettings::merge`] applies them (highest first), which one won, and the last
//! write in the settings history that touched it. A database's EXPLAIN for the settings merge.
//! A key no schema row and no layer has answers with the nearest schema keys instead.

use serde_json::{Value, json};

use crate::history::HistoryEntry;
use crate::keypath::key_path;
use crate::managed::ManagedSource;
use crate::project::ProjectLayer;
use crate::store::{State, Target};
use crate::value::value_at;

/// How many near keys an unknown key lists.
const NEAR_KEYS: usize = 3;

impl State {
    /// `settings.get` with `explain`: `{key, value, winner, layers, last_change, changes, near}`.
    /// `layers` lists each layer, highest first, as `{layer, value, set, wins}` (plus `team`
    /// for a team layer and `folder` for the project layer). `project` adds the project layer
    /// of a folder, which sits under the managed layers and over the user's file. `history` is
    /// the settings history, oldest or newest first.
    pub fn explain(
        &self,
        target: &Target,
        history: &[HistoryEntry],
        project: Option<&ProjectLayer>,
    ) -> Value {
        let view = self.get(target);
        let key = view.key.clone();
        let path = view.path.clone();
        let aliased = |values| crate::schema::aliasing_replaced(values);
        let team = self.team.limited_to_catalog(self.schema);
        let row = self.schema.row_at(&path);
        let mut layers: Vec<(&str, Option<Value>, Value)> = vec![
            ("mdm_forced", aliased(&self.managed.forced).get(&key).cloned(), Value::Null),
            (
                "team_enforced",
                aliased(&team.enforced).get(&key).cloned(),
                json!({"team": team.team_name}),
            ),
        ];
        if let Some(layer) = project {
            let folder = layer.folder.to_string_lossy().into_owned();
            layers.push(("project", layer.value(&key).cloned(), json!({"folder": folder})));
        }
        layers.extend([
            ("user", value_at(&self.effective.file_root, &path).cloned(), Value::Null),
            ("mdm_recommended", aliased(&self.managed.recommended).get(&key).cloned(), Value::Null),
            (
                "team_default",
                aliased(&team.defaults).get(&key).cloned(),
                json!({"team": team.team_name}),
            ),
            ("build_default", self.schema.build_defaults().get(&key).cloned(), Value::Null),
            ("product_default", row.and_then(|row| row.default.clone()), Value::Null),
        ]);
        // A managed key wins whatever its layer map says (the lock is on a parent key, or a
        // retired key answers for this one): name the managed layer that holds it.
        let managed_winner = view.managed.as_ref().map(|(_, source)| match source {
            ManagedSource::Device => "mdm_forced",
            ManagedSource::Team(_) => "team_enforced",
        });
        let winner = managed_winner.or_else(|| {
            layers.iter().find(|(_, value, _)| value.is_some()).map(|(name, ..)| *name)
        });
        let value = match (winner, project) {
            (Some("project"), Some(layer)) => layer.value(&key).cloned(),
            _ => view.value.clone(),
        };
        let layers: Vec<Value> = layers
            .into_iter()
            .map(|(name, layer_value, extra)| {
                let mut entry = json!({
                    "layer": name,
                    "set": layer_value.is_some(),
                    "value": layer_value,
                    "wins": Some(name) == winner,
                });
                if let (Some(members), Value::Object(extra)) = (entry.as_object_mut(), extra) {
                    members.extend(extra);
                }
                entry
            })
            .collect();
        let touching: Vec<&HistoryEntry> =
            history.iter().filter(|entry| touches(entry, &path)).collect();
        let last_change =
            touching.iter().max_by_key(|entry| entry.revision).map(|entry| entry.summary_json());
        let known = row.is_some() || winner.is_some() || view.value.is_some();
        json!({
            "key": key,
            "value": value,
            "winner": winner,
            "managed": view.managed.as_ref().map(|(lock, source)| {
                let mut info = source.to_json(lock);
                if let Some(members) = info.as_object_mut() {
                    members.insert("key".into(), Value::String(lock.clone()));
                }
                info
            }),
            "layers": layers,
            "last_change": last_change,
            "changes": touching.len(),
            "known": known,
            "near": if known { Vec::new() } else { self.near_keys(&key) },
        })
    }

    /// The schema keys nearest `key` by edit distance, nearest first.
    fn near_keys(&self, key: &str) -> Vec<String> {
        let wanted = key.to_lowercase();
        let bound = (wanted.len() / 3).max(2);
        let mut near: Vec<(usize, &str)> = self
            .schema
            .rows
            .iter()
            .map(|row| (distance(&wanted, &row.key.to_lowercase()), row.key.as_str()))
            .filter(|(far, _)| *far <= bound)
            .collect();
        near.sort();
        near.into_iter().take(NEAR_KEYS).map(|(_, key)| key.to_string()).collect()
    }
}

/// The entry changed `path`, a key under it, or a key over it.
fn touches(entry: &HistoryEntry, path: &[String]) -> bool {
    entry.keys.iter().any(|changed| {
        let changed = key_path(changed);
        changed.starts_with(path) || path.starts_with(&changed)
    })
}

/// Levenshtein distance over chars.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut diagonal = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let above = row[j + 1];
            row[j + 1] = (above + 1).min(row[j] + 1).min(diagonal + usize::from(ca != *cb));
            diagonal = above;
        }
    }
    row[b.len()]
}

#[cfg(test)]
#[path = "explain_tests.rs"]
mod tests;
