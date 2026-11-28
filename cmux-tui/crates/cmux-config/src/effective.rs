//! The effective settings document and what manages it (Swift
//! `EffectiveSettings.merge`).

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use crate::diagnostics::{Diagnostic, DiagnosticKind};
use crate::keypath::key_path;
use crate::managed::{ManagedPreferences, ManagedSource, Policy, TeamPolicyLayer, is_setting_key};
use crate::schema::Schema;
use crate::value::{char_count, value_at, with_value};

#[derive(Debug, Clone, PartialEq)]
pub struct EffectiveSettings {
    /// What every module reads.
    pub root: Value,
    /// The user's own file, for "is this customized" and writes.
    pub file_root: Value,
    /// Dotted key -> manager, for keys a forced layer sets.
    pub managed_keys: BTreeMap<String, ManagedSource>,
    /// Managed policy keys that are not settings, from forced values only.
    pub policy: Policy,
    pub diagnostics: Vec<Diagnostic>,
}

impl EffectiveSettings {
    /// Merges, highest first: MDM forced, team enforced, the user's file,
    /// MDM recommended, team default, product default (an absent key).
    pub fn merge(
        file: &Value,
        managed: &ManagedPreferences,
        team: &TeamPolicyLayer,
        schema: &Schema,
    ) -> EffectiveSettings {
        let mut root = if file.is_object() { file.clone() } else { Value::Object(Map::new()) };
        // The team layer may only set catalog settings; MDM keys are limited by the reader.
        let team = team.limited_to_catalog(schema);
        let mut managed_keys = BTreeMap::new();
        let mut diagnostics = Vec::new();

        // Below the file: fill only absent keys; MDM recommended outranks team default.
        for (key, value) in sorted_setting_entries(&managed.recommended) {
            if value_at(&root, &key_path(key)).is_none() {
                root = with_value(&root, value.clone(), &key_path(key));
            }
        }
        for (key, value) in sorted_setting_entries(&team.defaults) {
            if value_at(&root, &key_path(key)).is_none() {
                root = with_value(&root, value.clone(), &key_path(key));
            }
        }
        // Above the file: team enforced, then MDM forced overwrites.
        for (key, value) in sorted_setting_entries(&team.enforced) {
            root = with_value(&root, value.clone(), &key_path(key));
            managed_keys.insert(key.clone(), ManagedSource::Team(team.team_name.clone()));
        }
        for (key, value) in sorted_setting_entries(&managed.forced) {
            root = with_value(&root, value.clone(), &key_path(key));
            managed_keys.insert(key.clone(), ManagedSource::Device);
        }
        for (key, team_value) in &team.enforced {
            if managed.forced.get(key).is_some_and(|device| device != team_value) {
                diagnostics.push(Diagnostic::new(
                    DiagnosticKind::ManagedConflict,
                    key,
                    "the team policy value is ignored: the MDM profile manages this key",
                ));
            }
        }
        for key in managed_keys.keys() {
            let path = key_path(key);
            if let Some(mine) = value_at(file, &path)
                && Some(mine) != value_at(&root, &path)
            {
                diagnostics.push(Diagnostic::new(
                    DiagnosticKind::ManagedOverride,
                    key,
                    "managed by your organization; the value in cmux.json is ignored",
                ));
            }
        }
        let raw_policy = managed
            .forced
            .iter()
            .filter(|(key, _)| !is_setting_key(key))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        let policy = Policy::from_raw(raw_policy, &mut diagnostics);
        EffectiveSettings { root, file_root: file.clone(), managed_keys, policy, diagnostics }
    }
}

/// Deterministic order, settings keys only (a shorter key first, so a nested
/// key set later wins over an object set at its parent).
fn sorted_setting_entries(values: &BTreeMap<String, Value>) -> Vec<(&String, &Value)> {
    let mut entries: Vec<(&String, &Value)> =
        values.iter().filter(|(key, _)| is_setting_key(key)).collect();
    entries.sort_by(|a, b| (char_count(a.0), a.0).cmp(&(char_count(b.0), b.0)));
    entries
}
