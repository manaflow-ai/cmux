//! Codex's own-or-team rule at the spawn boundary (`codex_cloud_auth.rs`): with no sign-in, the
//! launch env itself carries the key the generated `cmux` provider reads, so a remote-origin chat
//! (no login env) reaches the team's model plane too.

use super::*;
use crate::store::{META_SCHEMA, SessionMeta};
use serde_json::json;

fn hub() -> Arc<Hub> {
    let config: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

#[tokio::test]
async fn a_codex_with_no_sign_in_gets_the_team_key_in_its_launch_env() {
    let root =
        std::env::temp_dir().join(format!("acpmux-spawn-codex-cloud-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/vm-kind"), "owner\n").unwrap();
    std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
    // `localhost` resolves on any test box.
    std::fs::write(
        root.join("etc/cmux/model-plane.env"),
        "export OPENAI_BASE_URL='https://localhost/v1'\n\
         export OPENAI_API_KEY='cmux-vm-edge-placeholder'\n\
         export CMUX_CODEROUTER_URL='https://localhost'\n",
    )
    .unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    // The config agent-config.sh generates: the `cmux` provider reads OPENAI_API_KEY.
    std::fs::write(
        home.join(".codex/config.toml"),
        "model_provider = \"cmux\"\n\n[model_providers.cmux]\nenv_key = \"OPENAI_API_KEY\"\n\
         requires_openai_auth = false\n",
    )
    .unwrap();
    let hub = hub();
    hub.set_vm_marker_root(root.clone());
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": "spawn-codex-cloud",
        "name": "spawn-codex-cloud",
        "harness": "codex",
        "cwd": home,
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap();
    let profile = |extra: &[(&str, &str)]| -> HarnessProfile {
        let mut env = std::collections::BTreeMap::from([
            ("HOME".to_owned(), home.to_string_lossy().into_owned()),
            ("CODEX_HOME".to_owned(), home.join(".codex").to_string_lossy().into_owned()),
        ]);
        env.extend(extra.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())));
        serde_json::from_value(
            json!({"argv": ["codex", "app-server"], "family": "codex", "env": env}),
        )
        .unwrap()
    };
    let none = std::collections::BTreeMap::new();
    let got = hub.spawn_profile_for(&meta, &profile(&[]), &none).await.unwrap();
    assert_eq!(
        got.env.get("OPENAI_API_KEY").map(String::as_str),
        Some(crate::codex_cloud_auth::PLACEHOLDER_KEY),
        "team mode's codex has no key for its provider"
    );
    assert_eq!(got.argv, ["codex", "app-server"], "team mode keeps the cmux provider");

    // The child a remote-origin launch builds: its env cleared, no login env, and still the key.
    let mut remote = got.clone();
    remote.env.insert(crate::agent::REMOTE_ENV_POLICY_KEY.to_owned(), "1".to_owned());
    let cmd = crate::agent::harness_command(&meta.harness, &remote, &home, None, None).unwrap();
    let child: std::collections::BTreeMap<String, String> =
        crate::agent::command_env(&cmd).into_iter().collect();
    assert_eq!(
        child.get("OPENAI_API_KEY").map(String::as_str),
        Some(crate::codex_cloud_auth::PLACEHOLDER_KEY)
    );

    // A key the profile sets stays.
    let own_key = profile(&[("OPENAI_API_KEY", "sk-profile")]);
    let got = hub.spawn_profile_for(&meta, &own_key, &none).await.unwrap();
    assert_eq!(got.env.get("OPENAI_API_KEY").map(String::as_str), Some("sk-profile"));

    // Its own sign-in: own mode, the built-in provider, and no placeholder.
    std::fs::write(home.join(".codex/auth.json"), r#"{"tokens":{"access_token":"t"}}"#).unwrap();
    let got = hub.spawn_profile_for(&meta, &profile(&[]), &none).await.unwrap();
    assert_eq!(got.env.get("OPENAI_API_KEY"), None);
    assert_eq!(got.argv, ["codex", "-c", "model_provider=\"openai\"", "app-server"]);
    let _ = std::fs::remove_dir_all(&root);
}
