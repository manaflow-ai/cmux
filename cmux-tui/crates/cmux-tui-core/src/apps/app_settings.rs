//! An extension's own settings: the manifest's `settings` (a JSON Schema object whose
//! `properties` each name a type, a default and optionally an enum, bounds or a length limit).
//!
//! Settings > Extensions draws them from `apps.settings.list` and writes them with
//! `apps.settings.set`. The daemon is the one owner: it validates a change against the manifest,
//! stores it with the app's install record (`mirror::Record::settings`, so an uninstall drops it),
//! and a running host gets the new values at once (`ToHost::Settings`, the runtime's
//! `cmux.app.settings` signal) followed by a `settings.changed` event. A host that starts later
//! loads them in `Init`. No value is a secret: a manifest asks for credentials through scopes.

use std::collections::BTreeMap;

use cmux_app_host::ToHost;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::catalog::Package;
use super::mirror::{Origin, Record, SetOp};
use super::store::text;
use super::supervisor::{ApiError, Inner, Supervisor};

/// The stream a host hears after its settings change.
pub(super) const STREAM: &str = "settings.changed";
/// The most settings one change may carry, and the longest stored string.
const MAX_KEYS: usize = 64;
const MAX_STRING: usize = 4096;

/// Whether the manifest declares settings of its own.
pub(super) fn declares(package: &Package) -> bool {
    properties(package).is_some()
}

/// The manifest's settings properties, or None when it declares none.
fn properties(package: &Package) -> Option<&Map<String, Value>> {
    package
        .manifest
        .pointer("/settings/properties")
        .and_then(Value::as_object)
        .filter(|properties| !properties.is_empty())
}

/// The values an app runs with: its manifest defaults, with the stored values for keys the
/// manifest still declares over them.
pub(super) fn effective(package: &Package, record: Option<&Record>) -> Value {
    let mut values = match package.default_settings() {
        Value::Object(values) => values,
        _ => Map::new(),
    };
    if let (Some(properties), Some(record)) = (properties(package), record) {
        for (key, value) in &record.settings {
            if properties.contains_key(key) {
                values.insert(key.clone(), value.clone());
            }
        }
    }
    Value::Object(values)
}

/// Why `value` is not a valid value of the property `schema`, if it is not.
fn invalid(schema: &Value, value: &Value) -> Option<String> {
    if let Some(choices) = schema.get("enum").and_then(Value::as_array) {
        return (!choices.contains(value))
            .then(|| format!("must be one of {}", Value::from(choices.clone())));
    }
    let kind = schema.get("type").and_then(Value::as_str).unwrap_or_default();
    let fits = match kind {
        "boolean" => value.is_boolean(),
        "string" => value.is_string(),
        "integer" => value.is_i64() || value.is_u64(),
        "number" => value.is_number(),
        _ => false,
    };
    if !fits {
        return Some(format!("must be a {}", if kind.is_empty() { "declared type" } else { kind }));
    }
    if let Some(number) = value.as_f64() {
        if let Some(min) = schema.get("minimum").and_then(Value::as_f64).filter(|min| number < *min)
        {
            return Some(format!("must be at least {min}"));
        }
        if let Some(max) = schema.get("maximum").and_then(Value::as_f64).filter(|max| number > *max)
        {
            return Some(format!("must be at most {max}"));
        }
    }
    if let Some(string) = value.as_str() {
        let length = string.chars().count();
        let max =
            schema.get("maxLength").and_then(Value::as_u64).map_or(MAX_STRING, |m| m as usize);
        if length > max.min(MAX_STRING) {
            return Some(format!("must be at most {} characters", max.min(MAX_STRING)));
        }
        if let Some(min) =
            schema.get("minLength").and_then(Value::as_u64).filter(|min| (length as u64) < *min)
        {
            return Some(format!("must be at least {min} characters"));
        }
    }
    None
}

fn refuse(message: impl Into<String>) -> ApiError {
    ApiError::new("apps.settings.invalid", message)
}

/// Checks a change against the manifest: an object of declared keys, each a valid value or
/// `null` (back to the default).
fn validate(package: &Package, values: &Value) -> Result<BTreeMap<String, Value>, ApiError> {
    let properties = properties(package)
        .ok_or_else(|| refuse(format!("{} declares no settings", package.id)))?;
    let values = values.as_object().ok_or_else(|| refuse("values must be an object"))?;
    if values.is_empty() || values.len() > MAX_KEYS {
        return Err(refuse(format!("values must name 1 to {MAX_KEYS} settings")));
    }
    let mut out = BTreeMap::new();
    for (key, value) in values {
        let schema = properties
            .get(key)
            .ok_or_else(|| refuse(format!("{} has no setting {key}", package.id)))?;
        if !value.is_null()
            && let Some(why) = invalid(schema, value)
        {
            return Err(refuse(format!("{key} {why}")));
        }
        out.insert(key.clone(), value.clone());
    }
    Ok(out)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SetParams {
    app: String,
    values: Value,
    idempotency_key: String,
}

impl Supervisor {
    /// `apps.settings.list`: every installed app whose manifest declares settings, with the
    /// schema to draw and the values it runs with.
    pub(super) fn settings_list(&self) -> Value {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let apps: Vec<Value> = inner
            .catalog
            .packages
            .values()
            .filter_map(|package| {
                let record = inner.mirror.apps.get(&package.id).filter(|r| r.installed)?;
                properties(package)?;
                Some(json!({
                    "app": package.id,
                    "name": text(&package.manifest["name"]),
                    "enabled": record.enabled,
                    "schema": package.manifest["settings"],
                    "values": effective(package, Some(record)),
                }))
            })
            .collect();
        json!({ "apps": apps })
    }

    /// `apps.settings.set {app, values, idempotency_key}`: validates, stores and pushes the change.
    pub(super) fn settings_set(
        &self,
        client: u64,
        p: SetParams,
        origin: Origin,
    ) -> Result<Value, ApiError> {
        let settings = {
            let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let package = inner
                .catalog
                .packages
                .get(&p.app)
                .ok_or_else(|| refuse(format!("{} is not in the catalog", p.app)))?;
            validate(package, &p.values)?
        };
        let op = SetOp {
            key: p.idempotency_key,
            app: p.app.clone(),
            origin,
            settings: Some(settings),
            ..SetOp::default()
        };
        self.set(client, op)?;
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let values = inner
            .catalog
            .packages
            .get(&p.app)
            .map_or(Value::Null, |package| effective(package, inner.mirror.apps.get(&p.app)));
        Ok(json!({ "app": p.app, "values": values }))
    }

    /// After a stored change: every running host of `app` gets its new values, then
    /// `settings.changed` on its subscriptions. The app's own settings need no scope.
    pub(super) fn push_settings_locked(inner: &Inner, app: &str) {
        let Some(package) = inner.catalog.packages.get(app) else { return };
        let values = effective(package, inner.mirror.apps.get(app));
        for (key, host) in &inner.hosts {
            if key.app != app {
                continue;
            }
            let Some(process) = &host.process else { continue };
            process.send(&ToHost::Settings { values: values.clone() });
            for (sub, _) in host.subs.iter().filter(|(_, stream)| stream.as_str() == STREAM) {
                process.send(&ToHost::Event { sub: *sub, body: json!({}) });
            }
        }
    }
}
