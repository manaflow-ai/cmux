//! The model and effort a harness CLI's own config chooses (cx-uq9xi; Leo 2026-10-14): Codex's
//! `$CODEX_HOME/config.toml` (`model` and `model_reasoning_effort`, the active
//! `[profiles.<profile>]` table's first) and Claude Code's `$CLAUDE_CONFIG_DIR/settings.json`
//! `model`. A new chat with nothing picked starts on them before the catalog default
//! (`hub::start_defaults`). A file that is missing or does not parse chooses nothing.

use std::collections::BTreeMap;
use std::path::PathBuf;

/// What a harness's own config chooses, each value as written there.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Choice {
    pub model: Option<String>,
    pub effort: Option<String>,
}

/// The choice of a `family` ("codex" or "claude"; any other chooses nothing). `envs`: the
/// profile's env, then its defaults' env, which can move the config folder.
pub fn read(family: &str, envs: &[&BTreeMap<String, String>]) -> Choice {
    let file = |key, default, name| {
        config_dir(key, default, envs).and_then(|d| std::fs::read_to_string(d.join(name)).ok())
    };
    match family {
        "codex" => file("CODEX_HOME", ".codex", "config.toml").map(|t| codex(&t)),
        "claude" => file("CLAUDE_CONFIG_DIR", ".claude", "settings.json").map(|t| claude(&t)),
        _ => None,
    }
    .unwrap_or_default()
}

/// `key` from the profile's envs, the daemon's environment or the imported login environment,
/// else `~/<default>`.
pub(crate) fn config_dir(
    key: &str,
    default: &str,
    envs: &[&BTreeMap<String, String>],
) -> Option<PathBuf> {
    envs.iter()
        .find_map(|env| env.get(key).filter(|v| !v.is_empty()).cloned())
        .or_else(|| std::env::var(key).ok().filter(|v| !v.is_empty()))
        .or_else(|| crate::login_env::var(key).filter(|v| !v.is_empty()))
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|home| home.join(default)))
}

fn text(value: Option<&toml::Value>) -> Option<String> {
    value.and_then(toml::Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
}

/// Codex's config.toml: the `[profiles.<profile>]` table its top-level `profile` names wins
/// over the top-level keys.
pub fn codex(config_toml: &str) -> Choice {
    let Ok(table) = config_toml.parse::<toml::Table>() else { return Choice::default() };
    let profile = table
        .get("profile")
        .and_then(toml::Value::as_str)
        .and_then(|name| table.get("profiles")?.get(name)?.as_table());
    let pick = |key: &str| text(profile.and_then(|p| p.get(key))).or_else(|| text(table.get(key)));
    Choice { model: pick("model"), effort: pick("model_reasoning_effort") }
}

/// Claude Code's settings.json `model`: an alias such as `sonnet`, or a model id. A variant
/// suffix (`sonnet[1m]`, the 1M-context variant) is dropped: the catalog lists the model bare.
pub fn claude(settings_json: &str) -> Choice {
    let model = serde_json::from_str::<serde_json::Value>(settings_json)
        .ok()
        .and_then(|v| v.get("model")?.as_str().map(without_variant).map(str::to_owned))
        .filter(|m| !m.is_empty());
    Choice { model, effort: None }
}

/// `sonnet[1m]` -> `sonnet`; a value that is only a bracket stays as it is.
fn without_variant(model: &str) -> &str {
    let model = model.trim();
    match model.strip_suffix(']').and_then(|m| m.rsplit_once('[')) {
        Some((bare, _)) if !bare.trim().is_empty() => bare.trim(),
        _ => model,
    }
}
