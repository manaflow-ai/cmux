//! Daemon-owned `cmux settings` (and `cmux config`) verbs.
//!
//! These commands use the protocol-v2 settings owner directly. The app
//! control socket has a legacy settings parser too, but routing CRUD here is
//! what keeps CLI writes behind the daemon's schema, managed-key and policy
//! checks.

use serde_json::{Map, Value};

use super::{CommandPlan, Flags, ResourceOperation, Selectors, UsageError, request};

pub(super) fn parse(
    words: &[String],
    flags: &mut Flags,
    argv: Option<&[String]>,
) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    let (verb, args) = words.split_first().ok_or_else(|| {
        UsageError::new(
            "unknown or incomplete settings action; run `cmux settings --help` for its actions",
        )
    })?;
    let mut operands = args.to_vec();
    if let Some(argv) = argv {
        operands.extend_from_slice(argv);
    }
    match (verb.as_str(), operands.as_slice()) {
        ("get", [key]) => {
            request(ResourceOperation::SettingsGet, &selectors, flags, key_params(key))
        }
        ("set", [key, value]) => {
            let value =
                serde_json::from_str(value).unwrap_or_else(|_| Value::String(value.clone()));
            let mut params = key_params(key);
            params.insert("value".into(), value);
            request(ResourceOperation::SettingsSet, &selectors, flags, params)
        }
        ("reset" | "unset", [key]) => {
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
