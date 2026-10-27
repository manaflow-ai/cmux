//! Shared settings-list grammar for local key completion and daemon value reads.

use cmux_config::Schema;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::{CommandPlan, Flags, Selectors, UsageError, request};

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
