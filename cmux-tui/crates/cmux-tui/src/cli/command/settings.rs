//! Daemon-owned `cmux settings` (and `cmux config`) verbs.
//!
//! These commands use the protocol-v2 settings owner directly. The app
//! control socket has a legacy settings parser too, but routing CRUD here is
//! what keeps CLI writes behind the daemon's schema, managed-key and policy
//! checks.

use cmux_config::Schema;
use serde_json::{Map, Value, json};

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

pub(in crate::cli) struct SettingsList {
    pub section: Option<String>,
    pub keys: bool,
}

impl SettingsList {
    pub(in crate::cli) fn parse(args: &[String]) -> Result<Self, UsageError> {
        let messages = &crate::localization::catalog().app_control;
        let mut options = Self { section: None, keys: false };
        let mut words = args.iter();
        while let Some(word) = words.next() {
            match word.as_str() {
                "--keys" => options.keys = true,
                "--section" if options.section.is_none() => {
                    options.section = Some(
                        words
                            .next()
                            .ok_or_else(|| UsageError::new(messages.settings_usage))?
                            .clone(),
                    );
                }
                _ => return Err(UsageError::new(messages.settings_usage)),
            }
        }
        let schema = Schema::embedded();
        if let Some(name) = &options.section
            && schema.rows_in(Some(name)).next().is_none()
        {
            let mut sections: Vec<&str> =
                schema.rows.iter().map(|row| row.section.as_str()).collect();
            sections.sort_unstable();
            sections.dedup();
            return Err(UsageError::new(
                messages
                    .settings_unknown_section
                    .replace("{section}", name)
                    .replace("{sections}", &sections.join(", ")),
            ));
        }
        Ok(options)
    }
}

pub(super) fn request_list(args: &[String]) -> Result<CommandPlan, UsageError> {
    let options = SettingsList::parse(args)?;
    // Key completion stays local in app/settings.rs. It must never silently
    // turn into a value read if reached through a different parser.
    if options.keys {
        return Err(UsageError::new(crate::localization::catalog().app_control.settings_usage));
    }
    let mut params = Map::new();
    if let Some(section) = options.section {
        params.insert("section".into(), Value::String(section));
    }
    request(ResourceOperation::SettingsList, &Selectors::default(), &mut Flags::default(), params)
}

/// Keep the existing human table concise; JSON retains all owner metadata.
pub(in crate::cli) fn human_rows(rows: &Value) -> Value {
    json!(rows.as_array().map(|rows| {
        rows.iter()
            .map(|row| {
                json!({
                    "key": row.get("key"), "value": row.get("value"), "default": row.get("default"),
                })
            })
            .collect::<Vec<_>>()
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_list_human_table_keeps_values_and_defaults() {
        let rows =
            json!([{"key":"sidebar.side", "value":"right", "default":"left", "customized":true}]);
        assert_eq!(
            human_rows(&rows),
            json!([{"key":"sidebar.side", "value":"right", "default":"left"}])
        );
    }
}
