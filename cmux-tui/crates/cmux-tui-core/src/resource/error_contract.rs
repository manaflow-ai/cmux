//! Checks a `ResourceError` against its contract in the embedded operation
//! catalog (`errors.<code>`: retryable flag and the details shape).

use std::sync::OnceLock;

use serde_json::Value;

fn error_catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!("../../../../spec/resource-operations-v2.json"))
            .expect("checked-in resource operation catalog")
    })
}

pub(super) fn catalog_error_contract_matches(code: &str, details: &Value, retryable: bool) -> bool {
    let Some(error) = error_catalog()["errors"].get(code) else { return false };
    error["retryable"].as_bool() == Some(retryable)
        && catalog_value_matches(details, &error["details"])
}

fn catalog_value_matches(value: &Value, descriptor: &Value) -> bool {
    match descriptor["kind"].as_str() {
        Some("primitive") => match descriptor["name"].as_str() {
            Some("json") => true,
            Some("string") => {
                let Some(value) = value.as_str() else { return false };
                descriptor["min_length"]
                    .as_u64()
                    .is_none_or(|minimum| value.len() >= minimum as usize)
                    && descriptor["max_length"]
                        .as_u64()
                        .is_none_or(|maximum| value.len() <= maximum as usize)
            }
            Some("decimal") => value.as_str().is_some_and(|value| {
                value == "0"
                    || (!value.starts_with('0')
                        && value.len() <= 20
                        && value.bytes().all(|byte| byte.is_ascii_digit())
                        && value.parse::<u64>().is_ok())
            }),
            Some("boolean") => value.is_boolean(),
            Some("uint32") => value.as_u64().is_some_and(|value| u32::try_from(value).is_ok()),
            Some("uint64") => value.is_u64(),
            _ => false,
        },
        Some("resource_id") => {
            let Some(value) = value.as_str() else { return false };
            let Some(resource) = descriptor["resource"].as_str() else { return false };
            resource_id_has_kind(value, resource)
        }
        Some("enum") => {
            descriptor["values"].as_array().is_some_and(|values| values.contains(value))
        }
        Some("array") => {
            let Some(values) = value.as_array() else { return false };
            descriptor["min_items"].as_u64().is_none_or(|minimum| values.len() >= minimum as usize)
                && descriptor["max_items"]
                    .as_u64()
                    .is_none_or(|maximum| values.len() <= maximum as usize)
                && values.iter().all(|value| catalog_value_matches(value, &descriptor["items"]))
        }
        Some("map") => value.as_object().is_some_and(|values| {
            values.values().all(|value| catalog_value_matches(value, &descriptor["values"]))
        }),
        Some("object") => {
            let Some(value) = value.as_object() else { return false };
            let Some(fields) = descriptor["fields"].as_object() else { return false };
            if descriptor["extra"] == Value::Bool(false)
                && value.keys().any(|name| !fields.contains_key(name))
            {
                return false;
            }
            fields.iter().all(|(name, field)| match value.get(name) {
                Some(value) => catalog_value_matches(value, &field["type"]),
                None => field["required"] != Value::Bool(true),
            })
        }
        Some("ref") => descriptor["name"]
            .as_str()
            .and_then(|name| error_catalog()["types"].get(name))
            .is_some_and(|descriptor| catalog_value_matches(value, descriptor)),
        _ => false,
    }
}

fn resource_id_has_kind(value: &str, kind: &str) -> bool {
    let prefix = match kind {
        "machine" => "machine_",
        "session" => "session_",
        "client" => "client_",
        "workspace" => "ws_",
        "screen" => "screen_",
        "pane" => "pane_",
        "split" => "split_",
        "tab" => "tab_",
        "terminal" => "term_",
        "browser" => "browser_",
        "notification" => "notification_",
        "agent" => "agent_",
        "frontend_projection" => "projection_",
        "pairing_request" => "pairing_",
        "sidebar_view" => "sidebar_view_",
        "stream" => "stream_",
        _ => return false,
    };
    value.strip_prefix(prefix).is_some_and(is_lower_hex_128)
}

fn is_lower_hex_128(value: &str) -> bool {
    value.len() == 32
        && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
