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
