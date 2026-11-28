//! The cmux settings that choose models (Settings > Agents), read from the
//! settings file at each use (`user_settings`), so a change applies to the
//! next new chat or the next generated text:
//!
//! - `agents.defaults.<family>.model` and `agents.defaults.<family>.effort`
//!   (`claude`, `codex`): the model and reasoning effort a new chat of that
//!   family starts on when its request names none (`hub/start_defaults.rs`).
//!   They come before config.json `defaults` (which every pick in a chat
//!   writes, so a setting below it would stop applying after the first pick),
//!   and after everything that pins a chat today: the request's own
//!   `--model`/`--effort` or the app's pick, a preset, a folder profile, a
//!   profile's own `model`/`effort`. A model or effort the harness refuses is
//!   skipped as every start value is. Unset (empty model, `auto` effort):
//!   today's chain.
//! - `agents.titles.model`: the Claude model that writes chat titles, task
//!   names, rolling summaries and diff hunk summaries, every `_acpmux/complete`
//!   that names no model and runs on Claude Code (`hub/complete.rs`). A model
//!   acpmux config names (`titles.model`, `summaries.model`) still wins.
//!   Unset: the harness's small model (`haiku` on Claude Code), as today.

use serde_json::Value;

/// The families with model and effort rows in Settings.
pub const FAMILIES: [&str; 2] = ["claude", "codex"];

/// `agents.titles.model`.
pub const TEXT_MODEL_SETTING: &str = "agents.titles.model";

/// The effort value that leaves the start effort to today's chain.
const AUTO_EFFORT: &str = "auto";

/// `agents.defaults.<family>.model`.
pub fn model_key(family: &str) -> String {
    format!("agents.defaults.{family}.model")
}

/// `agents.defaults.<family>.effort`.
pub fn effort_key(family: &str) -> String {
    format!("agents.defaults.{family}.effort")
}

/// A new chat's model and effort from the settings, for one family.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ChatDefaults {
    pub model: Option<String>,
    pub effort: Option<String>,
}

/// A string setting as a value to use: trimmed, non-empty, not `skip`, not
/// `default` (the harness's own) and of a length a pick may save.
fn chosen(doc: &Value, key: &str, skip: &str) -> Option<String> {
    let value = crate::user_settings::value(doc, key)?;
    let text = value.as_str()?.trim();
    (!text.is_empty() && text != skip && text != "default" && text.len() <= 256)
        .then(|| text.to_owned())
}

/// The settings document now, or None (no file, or one that does not parse:
/// these settings widen nothing, so they then take today's chain).
fn document() -> Option<Value> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        crate::user_settings::Settings::Missing | crate::user_settings::Settings::Unreadable(_) => {
            None
        }
    }
}

impl ChatDefaults {
    /// `family`'s rows in `doc`. A family with no rows has none.
    pub fn from_doc(doc: &Value, family: &str) -> Self {
        if !FAMILIES.contains(&family) {
            return Self::default();
        }
        Self {
            model: chosen(doc, &model_key(family), ""),
            effort: chosen(doc, &effort_key(family), AUTO_EFFORT),
        }
    }

    /// `family`'s rows in the settings file now (blocking file IO).
    pub fn current(family: &str) -> Self {
        document().map(|doc| Self::from_doc(&doc, family)).unwrap_or_default()
    }
}

/// Every family's rows now (blocking file IO): what the settings watch
/// compares, so a change redraws the New Tab's start model and effort.
pub fn chat_defaults_snapshot() -> Vec<ChatDefaults> {
    let doc = document();
    FAMILIES
        .iter()
        .map(|family| doc.as_ref().map(|d| ChatDefaults::from_doc(d, family)).unwrap_or_default())
        .collect()
}

/// `agents.titles.model` in `doc`, when set.
pub fn text_model_from_doc(doc: &Value) -> Option<String> {
    chosen(doc, TEXT_MODEL_SETTING, "")
}

/// `agents.titles.model` in the settings file now (blocking file IO).
pub fn text_model() -> Option<String> {
    document().as_ref().and_then(text_model_from_doc)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn chat_defaults_read_nested_and_flat_keys() {
        let nested = json!({"agents": {"defaults": {
            "claude": {"model": "claude-sonnet-5-5", "effort": "high"},
            "codex": {"model": " gpt-6.2-sol ", "effort": "xhigh"}
        }}});
        assert_eq!(
            ChatDefaults::from_doc(&nested, "claude"),
            ChatDefaults { model: Some("claude-sonnet-5-5".into()), effort: Some("high".into()) }
        );
        assert_eq!(
            ChatDefaults::from_doc(&nested, "codex"),
            ChatDefaults { model: Some("gpt-6.2-sol".into()), effort: Some("xhigh".into()) }
        );
        let flat = json!({"agents.defaults.codex.effort": "low"});
        assert_eq!(
            ChatDefaults::from_doc(&flat, "codex"),
            ChatDefaults { model: None, effort: Some("low".into()) }
        );
    }

    #[test]
    fn unset_values_keep_todays_chain() {
        let doc = json!({"agents": {"defaults": {
            "claude": {"model": "", "effort": "auto"},
            "codex": {"model": "default", "effort": 3}
        }}});
        assert_eq!(ChatDefaults::from_doc(&doc, "claude"), ChatDefaults::default());
        assert_eq!(ChatDefaults::from_doc(&doc, "codex"), ChatDefaults::default());
        assert_eq!(ChatDefaults::from_doc(&json!({}), "claude"), ChatDefaults::default());
    }

    #[test]
    fn only_the_listed_families_have_rows() {
        let doc = json!({"agents": {"defaults": {"gemini": {"model": "gemini-3.1-pro-preview"}}}});
        assert_eq!(ChatDefaults::from_doc(&doc, "gemini"), ChatDefaults::default());
    }

    #[test]
    fn text_model_reads_the_titles_row() {
        assert_eq!(
            text_model_from_doc(&json!({"agents": {"titles": {"model": "sonnet"}}})),
            Some("sonnet".into())
        );
        assert_eq!(
            text_model_from_doc(&json!({"agents.titles.model": "opus"})),
            Some("opus".into())
        );
        assert_eq!(text_model_from_doc(&json!({"agents": {"titles": {"model": " "}}})), None);
        assert_eq!(text_model_from_doc(&json!({})), None);
    }
}
