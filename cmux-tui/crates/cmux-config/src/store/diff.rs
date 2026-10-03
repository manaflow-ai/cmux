//! The dotted keys an op changed: leaves whose effective or file value differs.

use std::collections::BTreeSet;

use serde_json::Value;

use crate::effective::EffectiveSettings;
use crate::keypath::dotted;

/// Sorted dotted keys whose value differs in the effective document or the
/// user's file. An empty object that appears or disappears counts as a key.
pub(super) fn changed_keys(before: &EffectiveSettings, after: &EffectiveSettings) -> Vec<String> {
    let mut keys = BTreeSet::new();
    let mut path = Vec::new();
    walk(Some(&before.root), Some(&after.root), &mut path, &mut keys);
    walk(Some(&before.file_root), Some(&after.file_root), &mut path, &mut keys);
    for key in before.managed_keys.keys().chain(after.managed_keys.keys()) {
        if before.managed_keys.get(key) != after.managed_keys.get(key) {
            keys.insert(key.clone());
        }
    }
    keys.into_iter().collect()
}

fn walk(a: Option<&Value>, b: Option<&Value>, path: &mut Vec<String>, out: &mut BTreeSet<String>) {
    match (a, b) {
        (Some(Value::Object(left)), Some(Value::Object(right))) => {
            let names: BTreeSet<&String> = left.keys().chain(right.keys()).collect();
            for name in names {
                path.push(name.clone());
                walk(left.get(name), right.get(name), path, out);
                path.pop();
            }
        }
        (Some(Value::Object(members)), None) | (None, Some(Value::Object(members))) => {
            if members.is_empty() {
                push(path, out);
            }
            for name in members.keys() {
                path.push(name.clone());
                let item = members.get(name);
                if a.is_some() {
                    walk(item, None, path, out);
                } else {
                    walk(None, item, path, out);
                }
                path.pop();
            }
        }
        (left, right) => {
            if left != right {
                push(path, out);
            }
        }
    }
}

fn push(path: &[String], out: &mut BTreeSet<String>) {
    if !path.is_empty() {
        out.insert(dotted(path));
    }
}
