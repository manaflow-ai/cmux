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
        let layer = TeamPolicyLayer {
            team_name: text("team_name"),
            defaults: map("defaults"),
            enforced: map("enforced"),
            team_id: text("team"),
            version: version.map_or(0, |x| x as i64),
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
        })
    }
}

#[cfg(test)]
mod owner_op_tests {
    use super::*;
    use serde_json::json;

    fn args(op: &str) -> serde_json::Map<String, Value> {
        json!({"route": "read", "body": {"op": op, "params": {}}}).as_object().unwrap().clone()
    }

    fn managed() -> Value {
        json!({"status": 200, "reply": {"ok": true, "value": {
            "managed": true, "team": "t-1", "team_name": "Acme", "version": 3,
            "defaults": {}, "enforced": {"browser.searchEngine": "duckduckgo"}}}})
    }

    #[test]
    fn a_managed_read_is_the_layer() {
        let layer = TeamPolicyLayer::from_owner_op(
            &args("team.device.policy"),
            &managed(),
            Schema::embedded(),
        )
        .unwrap();
        assert_eq!(layer.team_id, "t-1");
        assert_eq!(layer.version, 3);
        assert_eq!(layer.enforced.get("browser.searchEngine"), Some(&json!("duckduckgo")));
    }

    #[test]
    fn an_unmanaged_read_clears_the_layer() {
        let answer = json!({"status": 200, "reply": {"ok": true, "value": {"managed": false}}});
        let layer = TeamPolicyLayer::from_owner_op(
            &args("team.device.policy"),
            &answer,
            Schema::embedded(),
        );
        assert_eq!(layer, Some(TeamPolicyLayer::default()));
    }

    #[test]
    fn the_body_as_json_text_counts() {
        let args =
            json!({"route": "read", "body_json": r#"{"op":"team.device.policy","params":{}}"#});
        let layer = TeamPolicyLayer::from_owner_op(
            args.as_object().unwrap(),
            &managed(),
            Schema::embedded(),
        );
        assert_eq!(layer.map(|l| l.team_id), Some("t-1".into()));
    }

    #[test]
    fn other_calls_and_refusals_change_nothing() {
        let schema = Schema::embedded();
        assert_eq!(TeamPolicyLayer::from_owner_op(&args("feed.list"), &managed(), schema), None);
        let mut ops = args("team.device.policy");
        ops.insert("route".into(), json!("ops"));
        assert_eq!(TeamPolicyLayer::from_owner_op(&ops, &managed(), schema), None);
        for answer in [
            json!({"status": 401, "reply": null}),
            json!({"status": 200, "reply": {"error": {"code": "forbidden", "message": "no"}}}),
            json!({"status": 200, "reply": {"ok": false, "value": {"managed": false}}}),
            json!({"status": 200, "reply": {"ok": true}}),
        ] {
            let read = TeamPolicyLayer::from_owner_op(&args("team.device.policy"), &answer, schema);
            assert_eq!(read, None, "{answer}");
        }
    }
}
