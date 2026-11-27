//! Managed preferences: Swift `ManagedPreferencesManifest`, `ManagedStatusReport`,
//! the Chrome policy mapping, `DisabledFeatures` and the team device policy.
//! Swift keeps only the CFPreferences read and hands Rust the raw values.
//!
//! - `managed.manifest` `{}` answers `{files: [{name, text}]}`: the five published files of
//!   docs/mdm, byte for byte.
//! - `managed.policy_keys` `{}` answers `{keys: [{name, type, choices, help}]}`.
//! - `managed.status_body` `{context, managed, team, effective}` answers the status report
//!   without its timestamp; `managed.status_document` `{body, writtenAt}` adds it;
//!   `managed.status_path` `{bundleID, home, classic}` answers `{path}`.
//! - `managed.chrome_merge` `{chrome, cmuxBrowser}` answers the merged `{mandatory, recommended}`;
//!   `managed.chrome_values` `{document}` answers `{forced, recommended}`;
//!   `managed.chrome_native_domain` `{cmuxBrowser}` answers `{domain}` or `{}`.
//! - `managed.disabled_features` `{value}` answers `{features, problem}`.
//! - `managed.device_policy_layer` `{value}` answers the team layer or `{}`.
//! - `managed.enrollment_token_hash` `{token}` answers `{hash}`; `managed.enrollment_token`
//!   `{forced}` answers `{token}` or `{}`.

use serde_json::{Value, json};

use super::{OpError, string};
use crate::managed::{
    self, POLICY_KEYS, PolicyType, TeamPolicyLayer, chrome, features, manifest, status,
};
use crate::schema::Schema;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "managed.manifest" => Ok(manifest_files()),
        "managed.policy_keys" => Ok(policy_keys()),
        "managed.status_body" => Ok(status::body(request)),
        "managed.status_document" => status_document(request),
        "managed.status_path" => status_path(request),
        "managed.chrome_merge" => Ok(chrome_merge(request)),
        "managed.chrome_values" => Ok(chrome_values(request)),
        "managed.chrome_native_domain" => Ok(chrome_native_domain(request)),
        "managed.disabled_features" => Ok(disabled_features(request)),
        "managed.device_policy_layer" => Ok(device_policy_layer(request)),
        "managed.enrollment_token_hash" => {
            string(request, "token").map(|t| json!({ "hash": managed::enrollment_token_hash(t) }))
        }
        "managed.enrollment_token" => Ok(enrollment_token(request)),
        _ => return None,
    })
}

fn manifest_files() -> Value {
    let files: Vec<Value> = manifest::files(Schema::embedded())
        .into_iter()
        .map(|(name, text)| json!({ "name": name, "text": text }))
        .collect();
    json!({ "files": files })
}

fn policy_keys() -> Value {
    let keys: Vec<Value> = POLICY_KEYS
        .iter()
        .map(|key| {
            let (ty, choices): (&str, &[&str]) = match key.ty {
                PolicyType::String => ("string", &[]),
                PolicyType::Boolean => ("boolean", &[]),
                PolicyType::Choice(values) => ("choice", values),
                PolicyType::StringArray(values) => ("stringArray", values),
            };
            json!({ "name": key.name, "type": ty, "choices": choices, "help": key.help })
        })
        .collect();
    json!({ "keys": keys })
}

fn status_document(request: &Value) -> Result<Value, OpError> {
    let body = request.get("body").cloned().unwrap_or(Value::Null);
    Ok(status::document(&body, string(request, "writtenAt")?))
}

fn status_path(request: &Value) -> Result<Value, OpError> {
    let classic = request.get("classic").and_then(Value::as_bool).unwrap_or(false);
    Ok(
        json!({ "path": status::path(string(request, "bundleID")?, string(request, "home")?, classic) }),
    )
}

fn document(request: &Value, key: &str) -> chrome::Document {
    chrome::Document::from_json(request.get(key).unwrap_or(&Value::Null))
}

fn chrome_merge(request: &Value) -> Value {
    chrome::merged(&document(request, "chrome"), &document(request, "cmuxBrowser")).to_json()
}

fn chrome_values(request: &Value) -> Value {
    let (forced, recommended) = chrome::managed_values(&document(request, "document"));
    json!({ "forced": forced, "recommended": recommended })
}

fn chrome_native_domain(request: &Value) -> Value {
    match chrome::native_policy_domain(&document(request, "cmuxBrowser")) {
        Some(domain) => json!({ "domain": domain }),
        None => json!({}),
    }
}

fn disabled_features(request: &Value) -> Value {
    let (features, problem) = features::disabled_features(request.get("value"));
    json!({ "features": features, "problem": problem })
}

fn device_policy_layer(request: &Value) -> Value {
    let value = request.get("value").unwrap_or(&Value::Null);
    match TeamPolicyLayer::from_device_policy(value, Schema::embedded()) {
        Some(layer) => layer.to_device_policy(),
        None => json!({}),
    }
}

fn enrollment_token(request: &Value) -> Value {
    let token = request
        .get("forced")
        .and_then(|forced| forced.get("EnrollmentToken"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|t| !t.is_empty());
    match token {
        Some(token) => json!({ "token": token }),
        None => json!({}),
    }
}

#[cfg(test)]
#[path = "managed_tests.rs"]
mod tests;
