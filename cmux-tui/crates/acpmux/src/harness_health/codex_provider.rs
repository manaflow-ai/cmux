//! Which model provider Codex uses, read from its `config.toml` the way Codex
//! picks it (hq#2569 #2): the selected `profile`'s `model_provider`, else the
//! top-level `model_provider`, else `openai`. Only the `openai` provider (or a
//! custom one with `requires_openai_auth = true`) signs in with `codex login`;
//! every other provider carries its own credential (a bearer token in the
//! config, an `env_key`, an auth command) or needs none (a local server). For
//! those, `codex login status` says "Not logged in" while Codex works, so the
//! health check must not report the agent signed out.
//!
//! Reads names and presence only: no credential value is returned or logged,
//! and nothing is written.

use std::collections::BTreeMap;
use std::path::PathBuf;

/// What decides whether Codex can authenticate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ProviderAuth {
    /// The OpenAI sign-in (`codex login status` answers for it).
    OpenAiLogin,
    /// A provider that does not use the OpenAI sign-in and has what it needs.
    Configured(String),
    /// A provider that does not use the OpenAI sign-in and lacks what it
    /// names (an unset `env_key`, an undefined provider): not a sign-in
    /// `codex login` would fix, so the sign-in stays unknown.
    Missing(String),
}

/// Providers Codex defines itself that run on this machine and need no key.
const LOCAL_BUILTINS: [&str; 3] = ["oss", "ollama", "lmstudio"];

/// The Codex home in `env`: `CODEX_HOME`, else `$HOME/.codex`.
pub(crate) fn codex_home(env: &BTreeMap<String, String>) -> Option<PathBuf> {
    if let Some(home) = env.get("CODEX_HOME").filter(|h| !h.is_empty()) {
        return Some(PathBuf::from(home));
    }
    let user =
        env.get("HOME").filter(|h| !h.is_empty()).map(PathBuf::from).or_else(dirs::home_dir)?;
    Some(user.join(".codex"))
}

/// The Codex home's `config.toml`, parsed. None when it is missing or does
/// not parse (Codex then refuses to start, or uses its defaults).
pub(crate) fn config(env: &BTreeMap<String, String>) -> Option<toml::Table> {
    let text = std::fs::read_to_string(codex_home(env)?.join("config.toml")).ok()?;
    text.parse::<toml::Table>().ok()
}

/// How Codex with `env` authenticates, from its config.
pub(crate) fn provider_auth(env: &BTreeMap<String, String>) -> ProviderAuth {
    match config(env) {
        Some(config) => from_config(&config, env),
        None => ProviderAuth::OpenAiLogin,
    }
}

fn non_empty(value: Option<&toml::Value>) -> bool {
    value.and_then(toml::Value::as_str).is_some_and(|s| !s.trim().is_empty())
}

/// The selected provider's id: the active profile's, else the top level's.
fn selected(config: &toml::Table) -> String {
    let profile = config
        .get("profile")
        .and_then(toml::Value::as_str)
        .and_then(|name| config.get("profiles")?.get(name)?.get("model_provider")?.as_str());
    profile
        .or_else(|| config.get("model_provider").and_then(toml::Value::as_str))
        .unwrap_or("openai")
        .to_owned()
}

pub(crate) fn from_config(config: &toml::Table, env: &BTreeMap<String, String>) -> ProviderAuth {
    let id = selected(config);
    // Codex's own providers win over a same-named table in the config.
    if id == "openai" {
        return ProviderAuth::OpenAiLogin;
    }
    if LOCAL_BUILTINS.contains(&id.as_str()) {
        return ProviderAuth::Configured(format!(
            "Codex uses the local `{id}` provider, which needs no sign-in"
        ));
    }
    let Some(provider) = config.get("model_providers").and_then(|p| p.get(&id)) else {
        return ProviderAuth::Missing(format!(
            "Codex's model provider `{id}` is not defined in config.toml"
        ));
    };
    if provider.get("requires_openai_auth").and_then(toml::Value::as_bool) == Some(true) {
        return ProviderAuth::OpenAiLogin;
    }
    if non_empty(provider.get("experimental_bearer_token")) {
        return ProviderAuth::Configured(format!(
            "Codex uses the `{id}` provider, whose token is in config.toml"
        ));
    }
    if provider.get("auth").and_then(|a| a.get("command")).is_some() {
        return ProviderAuth::Configured(format!(
            "Codex uses the `{id}` provider, whose auth command supplies its token"
        ));
    }
    if let Some(key) =
        provider.get("env_key").and_then(toml::Value::as_str).filter(|k| !k.is_empty())
    {
        return if env.get(key).is_some_and(|v| !v.trim().is_empty()) {
            ProviderAuth::Configured(format!("Codex uses the `{id}` provider, with ${key} set"))
        } else {
            ProviderAuth::Missing(format!(
                "Codex uses the `{id}` provider, which reads ${key}, and it is not set"
            ))
        };
    }
    ProviderAuth::Configured(format!(
        "Codex uses the `{id}` provider, which needs no Codex sign-in"
    ))
}

#[cfg(test)]
mod tests;
