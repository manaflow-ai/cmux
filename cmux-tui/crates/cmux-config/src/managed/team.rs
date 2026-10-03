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
}

impl TeamPolicyLayer {
    /// Only keys the settings catalog lists (never a whole object, shortcuts
    /// or custom actions).
    pub fn limited_to_catalog(&self, schema: &Schema) -> TeamPolicyLayer {
        let keep = |values: &BTreeMap<String, Value>| {
            values
                .iter()
                .filter(|(key, _)| schema.row(key).is_some())
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
        let layer = TeamPolicyLayer {
            team_name: text("team_name"),
            defaults: map("defaults"),
            enforced: map("enforced"),
            team_id: text("team"),
            version: version.map_or(0, |x| x as i64),
        };
        Some(layer.limited_to_catalog(schema))
    }
}
