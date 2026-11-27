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
mod tests {
    use super::{ProviderAuth, codex_home, from_config, provider_auth};
    use std::collections::BTreeMap;

    fn auth(config: &str, env: &[(&str, &str)]) -> ProviderAuth {
        let env = env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        from_config(&config.parse().expect("test config"), &env)
    }

    fn configured(a: &ProviderAuth) -> bool {
        matches!(a, ProviderAuth::Configured(_))
    }

    #[test]
    fn default_and_openai_use_the_openai_sign_in() {
        assert_eq!(auth("", &[]), ProviderAuth::OpenAiLogin);
        assert_eq!(auth("model = \"gpt-5\"\n", &[]), ProviderAuth::OpenAiLogin);
        assert_eq!(auth("model_provider = \"openai\"\n", &[]), ProviderAuth::OpenAiLogin);
        // A same-named table cannot replace Codex's own provider.
        let shadow = "model_provider = \"openai\"\n[model_providers.openai]\nexperimental_bearer_token = \"t\"\n";
        assert_eq!(auth(shadow, &[]), ProviderAuth::OpenAiLogin);
    }

    /// The sr layout on the capture minis (hq#2569 #2): a custom provider with
    /// a bearer token. `codex login status` says "Not logged in" there.
    #[test]
    fn a_custom_provider_with_a_bearer_token_is_configured() {
        let config = "model_provider = \"subrouter\"\n[model_providers.subrouter]\nname = \"Subrouter\"\nbase_url = \"http://127.0.0.1:31415/v1\"\nexperimental_bearer_token = \"secret\"\nwire_api = \"responses\"\n";
        let a = auth(config, &[]);
        assert!(configured(&a), "{a:?}");
        let ProviderAuth::Configured(detail) = a else { unreachable!() };
        assert!(detail.contains("subrouter") && !detail.contains("secret"), "{detail}");
        // An empty token is no token.
        let empty = "model_provider = \"x\"\n[model_providers.x]\nexperimental_bearer_token = \" \"\nenv_key = \"X_KEY\"\n";
        assert!(matches!(auth(empty, &[]), ProviderAuth::Missing(_)));
    }

    #[test]
    fn an_env_key_counts_only_when_set() {
        let config = "model_provider = \"router\"\n[model_providers.router]\nbase_url = \"https://r.example/v1\"\nenv_key = \"ROUTER_KEY\"\n";
        assert!(configured(&auth(config, &[("ROUTER_KEY", "k")])));
        assert!(matches!(auth(config, &[]), ProviderAuth::Missing(_)));
        assert!(matches!(auth(config, &[("ROUTER_KEY", "  ")]), ProviderAuth::Missing(_)));
    }

    #[test]
    fn an_auth_command_or_no_credential_is_configured() {
        let command = "model_provider = \"c\"\n[model_providers.c]\nbase_url = \"https://c/v1\"\n[model_providers.c.auth]\ncommand = \"print-token\"\n";
        assert!(configured(&auth(command, &[])));
        let open = "model_provider = \"proxy\"\n[model_providers.proxy]\nbase_url = \"http://127.0.0.1:8080/v1\"\n";
        assert!(configured(&auth(open, &[])));
        for local in ["oss", "ollama", "lmstudio"] {
            assert!(configured(&auth(&format!("model_provider = \"{local}\"\n"), &[])), "{local}");
        }
    }

    #[test]
    fn requires_openai_auth_defers_to_the_sign_in() {
        let config = "model_provider = \"azure\"\n[model_providers.azure]\nbase_url = \"https://a/v1\"\nrequires_openai_auth = true\nexperimental_bearer_token = \"t\"\n";
        assert_eq!(auth(config, &[]), ProviderAuth::OpenAiLogin);
    }

    #[test]
    fn the_active_profile_picks_the_provider() {
        let config = "profile = \"sr\"\nmodel_provider = \"openai\"\n[profiles.sr]\nmodel_provider = \"subrouter\"\n[model_providers.subrouter]\nexperimental_bearer_token = \"t\"\n";
        assert!(configured(&auth(config, &[])));
        // A profile without its own provider keeps the top level's.
        let plain = "profile = \"fast\"\nmodel_provider = \"subrouter\"\n[profiles.fast]\nmodel = \"o3\"\n[model_providers.subrouter]\nexperimental_bearer_token = \"t\"\n";
        assert!(configured(&auth(plain, &[])));
        let back = "profile = \"plain\"\nmodel_provider = \"subrouter\"\n[profiles.plain]\nmodel_provider = \"openai\"\n";
        assert_eq!(auth(back, &[]), ProviderAuth::OpenAiLogin);
    }

    #[test]
    fn an_undefined_provider_is_missing() {
        assert!(matches!(auth("model_provider = \"nope\"\n", &[]), ProviderAuth::Missing(_)));
    }

    /// `CODEX_HOME` names the config read; a missing or broken config is
    /// the OpenAI sign-in's case.
    #[test]
    fn codex_home_selects_the_config() {
        let dir = std::env::temp_dir().join(format!("amx-codex-provider-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let env: BTreeMap<String, String> =
            BTreeMap::from([("CODEX_HOME".into(), dir.display().to_string())]);
        assert_eq!(codex_home(&env), Some(dir.clone()));
        assert_eq!(provider_auth(&env), ProviderAuth::OpenAiLogin);
        std::fs::write(dir.join("config.toml"), "not toml [").unwrap();
        assert_eq!(provider_auth(&env), ProviderAuth::OpenAiLogin);
        std::fs::write(
            dir.join("config.toml"),
            "model_provider = \"sr\"\n[model_providers.sr]\nexperimental_bearer_token = \"t\"\n",
        )
        .unwrap();
        assert!(matches!(provider_auth(&env), ProviderAuth::Configured(_)));
        let home: BTreeMap<String, String> = BTreeMap::from([("HOME".into(), "/u".into())]);
        assert_eq!(codex_home(&home), Some(std::path::PathBuf::from("/u/.codex")));
        let _ = std::fs::remove_dir_all(dir);
    }
}
