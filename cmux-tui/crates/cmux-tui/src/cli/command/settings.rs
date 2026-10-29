//! Daemon-owned `cmux settings` (and `cmux config`) verbs.
//!
//! These commands use the protocol-v2 settings owner directly. The app
//! control socket has a legacy settings parser too, but routing CRUD here is
//! what keeps CLI writes behind the daemon's schema, managed-key and policy
//! checks.

use serde_json::{Map, Value};

use super::{CommandPlan, Flags, ResourceOperation, Selectors, UsageError, request};

pub(super) fn parse(words: &[String], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    match words {
        [verb, key] if verb == "get" => {
            request(ResourceOperation::SettingsGet, &selectors, flags, key_params(key))
        }
        [verb, key, value] if verb == "set" => {
            let value =
                serde_json::from_str(value).unwrap_or_else(|_| Value::String(value.clone()));
            let mut params = key_params(key);
            params.insert("value".into(), value);
            request(ResourceOperation::SettingsSet, &selectors, flags, params)
        }
        [verb, key] if verb == "reset" || verb == "unset" => {
            request(ResourceOperation::SettingsReset, &selectors, flags, key_params(key))
        }
        _ => Err(UsageError::new(
            "unknown or incomplete settings action; run `cmux settings --help` for its actions",
        )),
    }
}

fn key_params(key: &str) -> Map<String, Value> {
    Map::from_iter([(String::from("key"), Value::String(key.to_owned()))])
}
