//! The status file MDM tooling reads (Swift `ManagedStatusReport`): which keys
//! a profile forces or recommends, what applied from where, conflicts with
//! the team policy, and the policy keys with the enrollment token redacted.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::DOMAIN;

pub const SCHEMA_VERSION: i64 = 1;
/// Keys whose values the report never includes.
const SECRET_KEYS: [&str; 1] = ["EnrollmentToken"];
/// The chat keys (Swift `ChatSettings.keys`): a conflict on them is not reported.
const CHAT_KEYS: [&str; 5] = [
    "agents.chats.enabled",
    "agents.chats.discovery",
    "agents.chats.sessionRecap",
    "agents.chats.terminalChatWritable",
    "agents.chats.roots",
];

/// Whether `key` names a cmux.json setting (a lowercase first letter).
fn is_setting_key(key: &str) -> bool {
    key.chars().next().is_some_and(char::is_lowercase)
}

fn object(request: &Value, key: &str) -> BTreeMap<String, Value> {
    request
        .get(key)
        .and_then(Value::as_object)
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
        .unwrap_or_default()
}

/// The value at the dotted `key` of `root`.
fn value_at<'a>(root: &'a Value, key: &str) -> Option<&'a Value> {
    key.split('.').try_fold(root, |value, part| value.get(part))
}

/// Decision E2: the MDM value wins and the conflict is reported.
pub fn conflicts(
    forced: &BTreeMap<String, Value>,
    team_enforced: &BTreeMap<String, Value>,
) -> Vec<Value> {
    team_enforced
        .iter()
        .filter(|(key, _)| !CHAT_KEYS.contains(&key.as_str()))
        .filter_map(|(key, team)| {
            let device = forced.get(key)?;
            (device != team).then(
                || json!({ "key": key, "mdm_value": device, "team_value": team, "winner": "mdm" }),
            )
        })
        .collect()
}

/// The report without its timestamp. `request`: `{context: {appVersion, bundleID},
/// managed: {forced, recommended}, team: {teamID, teamName, version, enforced},
/// effective: {root, managedKeys: {key: "device" | {team}}}}`.
pub fn body(request: &Value) -> Value {
    let context = request.get("context").cloned().unwrap_or(Value::Null);
    let text = |key: &str| context.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let managed = request.get("managed").cloned().unwrap_or(Value::Null);
    let forced = object(&managed, "forced");
    let recommended = object(&managed, "recommended");
    let team = request.get("team").cloned().unwrap_or(Value::Null);
    let team_id = team.get("teamID").and_then(Value::as_str).unwrap_or_default();
    let effective = request.get("effective").cloned().unwrap_or(Value::Null);
    let root = effective.get("root").cloned().unwrap_or(Value::Null);
    let applied: Vec<Value> = object(&effective, "managedKeys")
        .iter()
        .map(|(key, layer)| {
            let source = if layer.is_string() { "mdm" } else { "team" };
            json!({
                "key": key,
                "source": source,
                "value": value_at(&root, key).cloned().unwrap_or(Value::Null),
            })
        })
        .collect();
    let mut policy = Map::new();
    for (key, value) in &forced {
        if !is_setting_key(key) {
            let shown =
                if SECRET_KEYS.contains(&key.as_str()) { json!("<set>") } else { value.clone() };
            policy.insert(key.clone(), shown);
        }
    }
    let token_present =
        forced.get("EnrollmentToken").and_then(Value::as_str).is_some_and(|t| !t.trim().is_empty());
    let managing = if team_id.is_empty() {
        Value::Null
    } else {
        json!({
            "id": team_id,
            "name": team.get("teamName").cloned().unwrap_or(json!("")),
            "policy_version": team.get("version").cloned().unwrap_or(json!(0)),
        })
    };
    json!({
        "schema_version": SCHEMA_VERSION,
        "app": { "version": text("appVersion"), "bundle_id": text("bundleID") },
        "domain": DOMAIN,
        "profile_present": !forced.is_empty() || !recommended.is_empty(),
        "keys_forced": forced.keys().collect::<Vec<_>>(),
        "keys_recommended": recommended.keys().collect::<Vec<_>>(),
        "applied": applied,
        "conflicts": conflicts(&forced, &object(&team, "enforced")),
        "policy": policy,
        "enrollment_token_present": token_present,
        "managing_team": managing,
    })
}

/// The file document: the body plus when it was written (`written_at`, ISO 8601).
pub fn document(body: &Value, written_at: &str) -> Value {
    let mut body = body.clone();
    if let Some(members) = body.as_object_mut() {
        members.insert("written_at".into(), json!(written_at));
    }
    body
}

/// Where the app writes the file under `home`: `classic` is the older `cmux`
/// folder, else NEXT's own `cmux-next`.
pub fn path(bundle_id: &str, home: &str, classic: bool) -> String {
    let folder = if classic { "cmux" } else { "cmux-next" };
    let file = if bundle_id == "com.cmuxterm.app" {
        "managed-status.json".to_string()
    } else {
        format!("managed-status.{bundle_id}.json")
    };
    format!("{}/Library/Application Support/{folder}/{file}", home.trim_end_matches('/'))
}

#[cfg(test)]
#[path = "status_tests.rs"]
mod tests;
