//! Reads: `settings.snapshot`, `settings.list` and `settings.get`.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::{State, Target};
use crate::diagnostics::Diagnostic;
use crate::domains::Domains;
use crate::guard::managed_key_for_path;
use crate::keypath::dotted;
use crate::managed::{ManagedSource, Policy};
use crate::schema::{Row, effective_value};
use crate::value::value_at;

/// Everything a client needs to project the settings.
#[derive(Debug, Clone, PartialEq)]
pub struct Snapshot {
    pub revision: u64,
    pub schema_hash: String,
    pub effective: Value,
    pub file: Value,
    pub managed: BTreeMap<String, ManagedSource>,
    pub policy: Policy,
    pub diagnostics: Vec<Diagnostic>,
    /// The value domains the hosting app published (theme names, font
    /// families, sound names); `null` for a domain never published.
    pub domains: Domains,
}

impl Snapshot {
    /// `{revision, schema_hash, effective, file, managed, policy, diagnostics, domains}`.
    pub fn to_json(&self) -> Value {
        json!({
            "revision": self.revision,
            "schema_hash": self.schema_hash,
            "effective": self.effective,
            "file": self.file,
            "managed": managed_json(&self.managed),
            "policy": self.policy.to_json(false),
            "diagnostics": self.diagnostics,
            "domains": serde_json::to_value(&self.domains).unwrap_or(Value::Null),
        })
    }
}

pub fn managed_json(managed: &BTreeMap<String, ManagedSource>) -> Value {
    Value::Object(managed.iter().map(|(key, source)| (key.clone(), source.to_json(key))).collect())
}

/// One schema row with its current state.
#[derive(Debug, Clone, PartialEq)]
pub struct RowView<'a> {
    pub row: &'a Row,
    /// What applies: the stored value when valid, else the default.
    pub value: Option<Value>,
    pub default: Option<Value>,
    /// The user's file sets a value other than the default.
    pub customized: bool,
    pub managed: Option<ManagedSource>,
}

impl RowView<'_> {
    /// The exported row (without conformance samples) plus `value`,
    /// `default`, `customized` and `managed {source, team, reason}`.
    pub fn to_json(&self) -> Value {
        let mut members: Map<String, Value> = self.row.raw.as_object().cloned().unwrap_or_default();
        members.remove("accepts");
        members.remove("refuses");
        members.insert("value".into(), self.value.clone().unwrap_or(Value::Null));
        members.insert("default".into(), self.default.clone().unwrap_or(Value::Null));
        members.insert("customized".into(), Value::Bool(self.customized));
        let managed =
            self.managed.as_ref().map_or(Value::Null, |source| source.to_json(&self.row.key));
        members.insert("managed".into(), managed);
        Value::Object(members)
    }
}

/// `settings.get`: the value at a key or path.
#[derive(Debug, Clone, PartialEq)]
pub struct GetView<'a> {
    pub key: String,
    pub path: Vec<String>,
    /// The effective value (`None` when absent).
    pub value: Option<Value>,
    /// The value in the user's file.
    pub file_value: Option<Value>,
    pub row: Option<RowView<'a>>,
    /// The managed key that covers this path, if any.
    pub managed: Option<(String, ManagedSource)>,
}

impl GetView<'_> {
    pub fn to_json(&self) -> Value {
        json!({
            "key": self.key,
            "path": self.path,
            "value": self.value,
            "file_value": self.file_value,
            "row": self.row.as_ref().map(RowView::to_json),
            "managed": self.managed.as_ref().map(|(key, source)| {
                let mut info = source.to_json(key);
                info["key"] = Value::String(key.clone());
                info
            }),
        })
    }
}

impl State {
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            revision: self.revision,
            schema_hash: self.schema.schema_hash.clone(),
            effective: self.effective.root.clone(),
            file: self.effective.file_root.clone(),
            managed: self.effective.managed_keys.clone(),
            policy: self.effective.policy.clone(),
            diagnostics: self.effective.diagnostics.clone(),
            domains: self.domains.clone(),
        }
    }

    /// Rows of `section` (every row for `None`), in schema order.
    pub fn list(&self, section: Option<&str>) -> Vec<RowView<'static>> {
        let schema: &'static crate::schema::Schema = self.schema;
        schema
            .rows
            .iter()
            .filter(|row| section.is_none_or(|id| row.section == id))
            .map(|row| self.row_view(row))
            .collect()
    }

    pub fn get(&self, target: &Target) -> GetView<'static> {
        let path = target.path();
        let row = self.schema.row_at(&path).map(|row| self.row_view(row));
        let managed = managed_key_for_path(&self.effective.managed_keys, &path)
            .map(|(key, source)| (key.to_string(), source.clone()));
        GetView {
            key: dotted(&path),
            value: value_at(&self.effective.root, &path).cloned(),
            file_value: value_at(&self.effective.file_root, &path).cloned(),
            path,
            row,
            managed,
        }
    }

    fn row_view(&self, row: &'static Row) -> RowView<'static> {
        let customized = value_at(&self.effective.file_root, &row.path)
            .is_some_and(|stored| Some(stored) != row.default.as_ref());
        RowView {
            row,
            value: effective_value(row, &self.effective.root, &self.domains),
            default: row.default.clone(),
            customized,
            managed: self.effective.managed_keys.get(&row.key).cloned(),
        }
    }
}
