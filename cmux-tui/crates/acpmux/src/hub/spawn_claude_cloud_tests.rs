//! The Claude team-plane rule at the spawn boundary (`claude_cloud_auth.rs`), for a discovered
//! Claude profile, which has no family set.

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
async fn a_discovered_claude_with_no_sign_in_gets_the_team_plane() {
    let root =
        std::env::temp_dir().join(format!("acpmux-spawn-claude-cloud-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("etc/cmux")).unwrap();
    std::fs::write(root.join("etc/cmux/vm-kind"), "owner\n").unwrap();
    std::fs::write(root.join("etc/cmux/agent-auth.sh"), "# image\n").unwrap();
    // `localhost` resolves on any test box.
    std::fs::write(
        root.join("etc/cmux/model-plane.env"),
        "export CMUX_CODEROUTER_URL='https://localhost'\n\
         export ANTHROPIC_BASE_URL='https://localhost'\n",
    )
    .unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    let hub = hub();
    hub.set_vm_marker_root(root.clone());
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": "spawn-claude-cloud",
        "name": "spawn-claude-cloud",
        "harness": "claude-path",
        "cwd": home,
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap();
    let env = |extra: &[(&str, &str)]| {
        let mut env = std::collections::BTreeMap::from([
            ("HOME".to_owned(), home.to_string_lossy().into_owned()),
            ("CLAUDE_CONFIG_DIR".to_owned(), home.join(".claude").to_string_lossy().into_owned()),
        ]);
        env.extend(extra.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())));
        env
    };
    let profile = |extra: &[(&str, &str)]| -> HarnessProfile {
        serde_json::from_value(
            json!({"kind": "claude-stdio", "argv": ["claude"], "env": env(extra)}),
        )
        .unwrap()
    };
    let none = std::collections::BTreeMap::new();
    let p = profile(&[]);
    assert_eq!(p.family, None);
    let got = hub.spawn_profile_for(&meta, &p, &none).await.unwrap();
    assert_eq!(got.env.get("ANTHROPIC_BASE_URL").map(String::as_str), Some("https://localhost"));
    assert_eq!(
        got.env.get("ANTHROPIC_API_KEY").map(String::as_str),
        Some(crate::codex_cloud_auth::PLACEHOLDER_KEY)
    );
    // A token of its own keeps own.
    let got = hub
        .spawn_profile_for(&meta, &profile(&[("CLAUDE_CODE_OAUTH_TOKEN", "t")]), &none)
        .await
        .unwrap();
    assert_eq!(got.env.get("ANTHROPIC_BASE_URL"), None);
    // A Claude home the profile names by a reference the launch cannot resolve: the check cannot
    // see its sign-in, so the launch keeps own rather than override it.
    let unresolved = profile(&[("CLAUDE_CONFIG_DIR", "${env:ACPMUX_TEST_NO_SUCH_CLAUDE_HOME}")]);
    let got = hub.spawn_profile_for(&meta, &unresolved, &none).await.unwrap();
    assert_eq!(got.env.get("ANTHROPIC_BASE_URL"), None);
    assert_eq!(got.env.get("ANTHROPIC_API_KEY"), None);

    // Team mode pinned over a personal token and a provider switch: the child the launch builds
    // gets the pair and neither, from the profile or the inherited env.
    let pinned = profile(&[
        ("CMUX_CLAUDE_AUTH", "team"),
        ("ANTHROPIC_AUTH_TOKEN", "personal-token"),
        ("CLAUDE_CODE_USE_BEDROCK", "1"),
    ]);
    let got = hub.spawn_profile_for(&meta, &pinned, &none).await.unwrap();
    let cmd = crate::agent::harness_command(&meta.harness, &got, &home, None, None).unwrap();
    let child: std::collections::BTreeMap<String, String> =
        crate::agent::command_env(&cmd).into_iter().collect();
    assert_eq!(child.get("ANTHROPIC_BASE_URL").map(String::as_str), Some("https://localhost"));
    assert_eq!(
        child.get("ANTHROPIC_API_KEY").map(String::as_str),
        Some(crate::codex_cloud_auth::PLACEHOLDER_KEY)
    );
    assert!(!child.contains_key(crate::routes::UNSET_KEY));
    // Removed outright, so a value the daemon, login shell, vault or `machine.env` gives never
    // reaches the child either.
    let removed: Vec<String> = cmd
        .as_std()
        .get_envs()
        .filter(|(_, v)| v.is_none())
        .map(|(k, _)| k.to_string_lossy().into_owned())
        .collect();
    for key in crate::claude_cloud_auth::TEAM_CLEARS {
        assert!(!child.contains_key(key), "{key} reached the child");
        assert!(removed.iter().any(|k| k == key), "{key} not removed from the inherited env");
    }
    let _ = std::fs::remove_dir_all(&root);
}
