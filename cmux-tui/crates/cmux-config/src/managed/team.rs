//! Device-scoped values from the policy of the device's managing team
//! (Swift `TeamPolicyLayer`, decision E3). Keys are cmux.json dotted keys.
//! The app forwards it from the backend until the sync actor exists.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::schema::Schema;
use crate::value::canonical;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct TeamPolicyLayer {
    pub team_name: String,
    pub defaults: BTreeMap<String, Value>,
    pub enforced: BTreeMap<String, Value>,
    /// The managing team's id and the policy version these values come from.
    pub team_id: String,
    pub version: i64,
    /// The team's device-scoped RFD 0211 policy keys as the backend sent
    /// them (`agents.harnesses`, `sandbox.local`, `projection.syncBack`, ...),
    /// unfiltered: enforcement paths outside the settings catalog (sync-back)
    /// read them from the saved layer.
    pub features: BTreeMap<String, Value>,
}

/// A policy key's value: the backend sends `{value, mode}`; a bare value is
/// accepted too.
pub fn feature_value(features: &BTreeMap<String, Value>, key: &str) -> Option<Value> {
    let raw = features.get(key)?;
    Some(raw.get("value").cloned().unwrap_or_else(|| raw.clone()))
}

fn joined_list(value: &Value, strip_star: bool) -> Option<String> {
    let items: Vec<String> = value
        .as_array()?
        .iter()
        .filter_map(Value::as_str)
        .map(|item| {
            let item = item.trim();
            if strip_star { item.trim_end_matches('*') } else { item }.to_string()
        })
        .filter(|item| !item.is_empty())
        .collect();
    (!items.is_empty()).then(|| items.join(", "))
}

/// The settings the team's RFD 0211 keys force on this install. Only keys
/// the team set reach here, so nothing changes for a team that set none.
/// `agents.*` fill the lockdown lists (cmux#64460) without turning
/// `sessions.lockdown` on, which would also turn Cloud and computer use off;
/// `sandbox.local` maps to the Seatbelt toggle (cmux#56119).
fn settings_from_features(
    features: &BTreeMap<String, Value>,
    defaults: &mut BTreeMap<String, Value>,
    enforced: &mut BTreeMap<String, Value>,
) {
    match feature_value(features, "sandbox.local").as_ref().and_then(Value::as_str) {
        Some("required") => {
            enforced.insert("sessions.sandbox".into(), Value::Bool(true));
        }
        Some("on") => {
            defaults.insert("sessions.sandbox".into(), Value::Bool(true));
        }
        _ => {}
    }
    if let Some(list) =
        feature_value(features, "agents.harnesses").and_then(|v| joined_list(&v, false))
    {
        enforced.insert("sessions.lockdownHarnesses".into(), Value::String(list));
    }
    if let Some(list) = feature_value(features, "agents.models").and_then(|v| joined_list(&v, true))
    {
        enforced.insert("sessions.lockdownModels".into(), Value::String(list));
    }
}

impl TeamPolicyLayer {
    /// Only keys the settings catalog lists (never a whole object, shortcuts
    /// or custom actions).
    pub fn limited_to_catalog(&self, schema: &Schema) -> TeamPolicyLayer {
        let keep = |values: &BTreeMap<String, Value>| {
            values
                .iter()
                .filter(|(key, _)| {
                    schema.row(key).is_some()
                        || crate::schema::replaced_old_keys().any(|old| &old == *key)
                })
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        };
        TeamPolicyLayer {
            defaults: keep(&self.defaults),
            enforced: keep(&self.enforced),
            ..self.clone()
        }
    }

    /// The layer for the backend read `team.device.policy`; `None` when that
    /// team does not manage this install (the caller then clears the layer).
    pub fn from_device_policy(value: &Value, schema: &Schema) -> Option<TeamPolicyLayer> {
        if value.get("managed").and_then(Value::as_bool) != Some(true) {
            return None;
        }
        let map = |name: &str| -> BTreeMap<String, Value> {
            value
                .get(name)
                .and_then(Value::as_object)
                .map(|members| {
                    members.iter().map(|(k, v)| (k.clone(), canonical(v.clone()))).collect()
                })
                .unwrap_or_default()
        };
        let text =
            |name: &str| value.get(name).and_then(Value::as_str).unwrap_or_default().to_string();
        let version = value
            .get("version")
            .and_then(Value::as_f64)
            .filter(|x| crate::value::is_exact_integer(*x));
        let features = map("features");
        let mut defaults = map("defaults");
        let mut enforced = map("enforced");
        settings_from_features(&features, &mut defaults, &mut enforced);
        let layer = TeamPolicyLayer {
            team_name: text("team_name"),
            defaults,
            enforced,
            team_id: text("team"),
            version: version.map_or(0, |x| x as i64),
            features,
        };
        Some(layer.limited_to_catalog(schema))
    }

    /// The layer a Cloud API `owner.op` call carried: `args` its arguments, `answer` its
    /// `{status, reply}`. `Some` only for a 2xx `POST /v1/read` of `team.device.policy` that
    /// answered a value; an unmanaged answer is `Some(default)`, which clears the layer.
    pub fn from_owner_op(
        args: &serde_json::Map<String, Value>,
        answer: &Value,
        schema: &Schema,
    ) -> Option<TeamPolicyLayer> {
        if args.get("route").and_then(Value::as_str) != Some("read") {
            return None;
        }
        let body = match (args.get("body"), args.get("body_json").and_then(Value::as_str)) {
            (Some(body), None) => body.clone(),
            (None, Some(text)) => serde_json::from_str(text).ok()?,
            _ => return None,
        };
        if body.get("op").and_then(Value::as_str) != Some("team.device.policy") {
            return None;
        }
        let status = answer.get("status").and_then(Value::as_u64)?;
        if !(200..300).contains(&status) {
            return None;
        }
        let reply = answer.get("reply")?;
        if reply.get("ok").and_then(Value::as_bool) == Some(false) || reply.get("error").is_some() {
            return None;
        }
        let value = reply.get("value").filter(|value| value.is_object())?;
        Some(Self::from_device_policy(value, schema).unwrap_or_default())
    }

    /// The inverse of `from_device_policy`: the document the owner saves so
    /// the layer survives a daemon restart.
    pub fn to_device_policy(&self) -> Value {
        serde_json::json!({
            "managed": true,
            "team": self.team_id,
            "team_name": self.team_name,
            "version": self.version,
            "defaults": self.defaults,
            "enforced": self.enforced,
            "features": self.features,
        })
    }
}

#[cfg(test)]
#[path = "team_tests.rs"]
mod tests;
