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

    // A sign-in in the launch's own --settings keeps own.
    let mut flagged = profile(&[]);
    flagged
        .argv
        .extend(["--settings".to_owned(), r#"{"env":{"ANTHROPIC_AUTH_TOKEN":"t"}}"#.to_owned()]);
    let got = hub.spawn_profile_for(&meta, &flagged, &none).await.unwrap();
    assert_eq!(got.env.get("ANTHROPIC_BASE_URL"), None);
    assert_eq!(got.argv, flagged.argv);

    // Team mode pinned over a personal token and a provider switch in the profile, a token in the
    // user's and the project's settings files and one in the launch's own --settings: the child
    // the launch builds gets the pair and none of them, from the profile, the inherited env or,
    // once Claude loads its settings, any settings file.
    std::fs::write(
        home.join(".claude/settings.json"),
        r#"{"env":{"ANTHROPIC_AUTH_TOKEN":"personal-user","ANTHROPIC_BASE_URL":"https://own.test"}}"#,
    )
    .unwrap();
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::write(
        home.join(".claude/settings.local.json"),
        r#"{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"personal-local"}}"#,
    )
    .unwrap();
    let mut pinned = profile(&[
        ("CMUX_CLAUDE_AUTH", "team"),
        ("ANTHROPIC_AUTH_TOKEN", "personal-token"),
        ("CLAUDE_CODE_USE_BEDROCK", "1"),
        ("ANTHROPIC_CUSTOM_HEADERS", "x-cmux-workspace-id: ws-1\nx-personal: 1"),
    ]);
    pinned.argv.extend([
        "--settings".to_owned(),
        r#"{"model":"opus","env":{"ANTHROPIC_CUSTOM_HEADERS":"x-personal: 1"}}"#.to_owned(),
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
    let headers = crate::claude_cloud_auth::HEADERS;
    for key in crate::claude_cloud_auth::TEAM_CLEARS.iter().filter(|k| **k != headers) {
        assert!(!child.contains_key(*key), "{key} reached the child");
        assert!(removed.iter().any(|k| k == key), "{key} not removed from the inherited env");
    }
    // The usage attribution header stays; the personal one does not.
    assert_eq!(child[headers], "x-cmux-workspace-id: ws-1");
    assert!(!child.contains_key(crate::claude_cloud_auth::TEAM_MARKER));
    // The env Claude runs on, as Claude Code 2.1.322 layers it: its process env, then the user's,
    // the project's and the local settings `env`, then the last --settings (a later one replaces
    // an earlier one whole).
    let args: Vec<String> =
        cmd.as_std().get_args().map(|a| a.to_string_lossy().into_owned()).collect();
    assert_eq!(args.iter().filter(|a| *a == "--settings").count(), 1);
    let flag = crate::claude_cloud_auth::flag_settings(&args, &home).unwrap().unwrap();
    assert_eq!(flag["model"], "opus");
    let settings_env = |path: std::path::PathBuf| -> Vec<(String, String)> {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
        v.get("env")
            .and_then(|e| e.as_object())
            .map(|e| {
                e.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_owned())).collect()
            })
            .unwrap_or_default()
    };
    let mut claude = child.clone();
    claude.extend(settings_env(home.join(".claude/settings.json")));
    claude.extend(settings_env(home.join(".claude/settings.local.json")));
    claude.extend(
        flag["env"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_owned())),
    );
    assert_eq!(claude["ANTHROPIC_BASE_URL"], "https://localhost");
    assert_eq!(claude["ANTHROPIC_API_KEY"], crate::codex_cloud_auth::PLACEHOLDER_KEY);
    for key in crate::claude_cloud_auth::TEAM_CLEARS.iter().filter(|k| **k != headers) {
        assert_eq!(claude.get(*key).map(String::as_str).unwrap_or(""), "", "{key} reaches Claude");
    }
    assert_eq!(claude[headers], "x-cmux-workspace-id: ws-1");
    let _ = std::fs::remove_dir_all(&root);
}
