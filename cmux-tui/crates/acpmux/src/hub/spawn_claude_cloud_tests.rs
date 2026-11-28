//! The Claude team-plane rule at the spawn boundary (`claude_cloud_auth.rs`), for a discovered
//! Claude profile, which has no family set.

use super::*;
use crate::store::{META_SCHEMA, SessionMeta};
use serde_json::json;

fn hub(home: &std::path::Path) -> Arc<Hub> {
    let config: crate::config::Config = serde_json::from_value(json!({
        "store": {"mode": "memory"},
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["claude"], "env": {"HOME": home}}}
    }))
    .unwrap();
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

#[tokio::test]
async fn automatic_gateway_fallback_keeps_signed_out_machine_login_choices() {
    let home = tempfile::tempdir().unwrap();
    let hub = hub(home.path());
    hub.set_vm_marker_root(home.path().to_owned());
    let profile = hub.config.read().await.profile("claude").unwrap().clone();
    for recovered in [false, true] {
        let mut meta: SessionMeta = serde_json::from_value(json!({
            "schema": META_SCHEMA,
            "id": if recovered { "recovered" } else { "explicit" },
            "name": "signed-out",
            "harness": "claude",
            "cwd": home.path(),
            "status": "idle",
            "createdAt": 1,
            "updatedAt": 1,
        }))
        .unwrap();
        if recovered {
            meta.claude_token_recovery = Some(crate::store::ClaudeTokenRecovery::MachineLogin);
            meta.claude_login_restart_pending = Some(false);
        } else {
            meta.session_env.insert("CMUX_CLAUDE_AUTH".into(), "own".into());
        }
        let session = hub.make_session(meta);

        assert!(!hub.use_gateway_now(&session).await, "recovered: {recovered}");
        let launch =
            hub.spawn_profile_for(&session.meta(), &profile, &Default::default()).await.unwrap();
        assert_eq!(launch.env["CMUX_CLAUDE_AUTH"], "own");
    }
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
    let hub = hub(&home);
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
    assert!(got.argv.iter().any(|a| a == "--settings"));
    // A launcher that picks Claude's provider itself keeps it, with no sign-in either: `claude-sr`
    // (`sr claude proxy`) and `claude-cr` (`cr <route>`, `config/discover.rs`) carry no bound
    // route, and team mode's --settings env would outrank the provider they export.
    for argv in [
        vec!["/usr/local/bin/sr", "claude", "proxy"],
        vec!["/usr/local/bin/cr", "fast"],
        vec!["/usr/local/bin/coderouter", "fast"],
    ] {
        let mut launcher = profile(&[]);
        launcher.argv = argv.iter().map(|s| (*s).to_owned()).collect();
        assert_eq!(crate::config::derive_family(&meta.harness, &launcher), "claude");
        let got = hub.spawn_profile_for(&meta, &launcher, &none).await.unwrap();
        assert_eq!(got.env.get("ANTHROPIC_BASE_URL"), None, "{argv:?} got the team plane");
        assert_eq!(got.env.get("ANTHROPIC_API_KEY"), None, "{argv:?} got the team key");
        assert!(!got.env.contains_key(crate::claude_cloud_auth::TEAM_MARKER), "{argv:?}");
        assert_eq!(got.argv, launcher.argv, "{argv:?} got a team --settings");

        let mut linked = meta.clone();
        linked.session_env.insert("CMUX_CLAUDE_AUTH".into(), "team".into());
        linked.session_env.insert(crate::claude_cloud_auth::REQUIRED_TEAM.into(), "1".into());
        launcher.env.insert("CMUX_CLAUDE_AUTH".into(), "own".into());
        launcher.env.insert("ANTHROPIC_BASE_URL".into(), "https://wrapper.test".into());
        let got = hub.spawn_profile_for(&linked, &launcher, &none).await.unwrap();
        assert_eq!(got.argv, launcher.argv);
        assert_eq!(got.env["CMUX_CLAUDE_AUTH"], "own");
        assert_eq!(got.env["ANTHROPIC_BASE_URL"], "https://wrapper.test");
        assert!(!got.env.contains_key(crate::claude_cloud_auth::REQUIRED_TEAM));
        assert!(!got.env.contains_key(crate::claude_cloud_auth::TEAM_MARKER));
    }
    // Claude itself by its full path still takes team mode.
    let mut by_path = profile(&[]);
    by_path.argv = vec!["/usr/local/bin/claude".to_owned()];
    let got = hub.spawn_profile_for(&meta, &by_path, &none).await.unwrap();
    assert_eq!(got.env.get("ANTHROPIC_BASE_URL").map(String::as_str), Some("https://localhost"));
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
    // A chat that selects a signed-in machine account pins its launch to it,
    // even while the machine's recorded preference still selects team.
    let choice = home.join(".config/cmux/agent-auth");
    std::fs::create_dir_all(&choice).unwrap();
    std::fs::write(choice.join("claude"), "team\n").unwrap();
    let mut account = meta.clone();
    let p = profile(&[]);
    let team = hub.spawn_profile_for(&account, &p, &none).await.unwrap();
    assert_eq!(team.env.get("ANTHROPIC_BASE_URL").map(String::as_str), Some("https://localhost"));
    account.session_env.insert("CMUX_CLAUDE_AUTH".into(), "own".into());
    account.stop_condition = Some("The task is done.".into());
    let own = hub.spawn_profile_for(&account, &p, &none).await.unwrap();
    assert_eq!(own.env.get("CMUX_CLAUDE_AUTH").map(String::as_str), Some("own"));
    assert!(!own.env.contains_key("ANTHROPIC_BASE_URL"));
    let settings = crate::claude_cloud_auth::flag_settings(&own.argv[1..], &home).unwrap().unwrap();
    assert_eq!(settings["hooks"]["Stop"][0]["hooks"][0]["prompt"], "The task is done.");
    assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "");
    assert_eq!(std::fs::read_to_string(choice.join("claude")).unwrap(), "team\n");
    let refused = hub.spawn_profile_for(&account, &flagged, &none).await.err().unwrap();
    assert_eq!(refused.data.unwrap()["reason"], "route.unavailable");

    // A gateway selection supersedes a machine login even when the machine preference is own.
    std::fs::write(choice.join("claude"), "own\n").unwrap();
    hub.config.write().await.harnesses.insert(meta.harness.clone(), p.clone());
    for recovered in [false, true] {
        let mut pinned = account.clone();
        if recovered {
            pinned.session_env.remove("CMUX_CLAUDE_AUTH");
            pinned.claude_token_recovery = Some(crate::store::ClaudeTokenRecovery::MachineLogin);
            pinned.claude_login_restart_pending = Some(false);
        }
        let session = hub.make_session(pinned);
        assert!(hub.select_claude_gateway(&session, false).await.unwrap());
        let gateway = hub.spawn_profile_for(&session.meta(), &p, &none).await.unwrap();
        assert_eq!(
            gateway.env.get("ANTHROPIC_BASE_URL").map(String::as_str),
            Some("https://localhost")
        );
        assert!(gateway.env.contains_key(crate::claude_cloud_auth::TEAM_MARKER));
        assert_eq!(std::fs::read_to_string(choice.join("claude")).unwrap(), "own\n");
    }

    // The explicit Cloud start replaces even a profile's personal launch key and endpoint.
    std::fs::write(choice.join("claude"), "own\n").unwrap();
    let mut requested = meta.clone();
    requested.session_env.insert("CMUX_CLAUDE_AUTH".into(), "team".into());
    requested.session_env.insert(crate::claude_cloud_auth::REQUIRED_TEAM.into(), "1".into());
    let mut personal = profile(&[
        ("ANTHROPIC_BASE_URL", "https://personal.test"),
        ("ANTHROPIC_API_KEY", "personal-key"),
        ("ANTHROPIC_AUTH_TOKEN", "personal-token"),
    ]);
    personal.argv.extend(["--".into(), "positional".into()]);
    let team = hub.spawn_profile_for(&requested, &personal, &none).await.unwrap();
    let child =
        crate::agent::harness_command(&requested.harness, &team, &home, None, None).unwrap();
    let env: std::collections::BTreeMap<String, String> =
        crate::agent::command_env(&child).into_iter().collect();
    assert_eq!(env["ANTHROPIC_BASE_URL"], "https://localhost");
    assert_eq!(env["ANTHROPIC_API_KEY"], crate::codex_cloud_auth::PLACEHOLDER_KEY);
    assert!(!env.contains_key("ANTHROPIC_AUTH_TOKEN"));
    assert!(!env.contains_key(crate::claude_cloud_auth::REQUIRED_TEAM));
    let args: Vec<_> =
        child.as_std().get_args().map(|a| a.to_string_lossy().into_owned()).collect();
    let settings = crate::claude_cloud_auth::flag_settings(&args, &home).unwrap().unwrap();
    assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "https://localhost");
    assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], crate::codex_cloud_auth::PLACEHOLDER_KEY);
    assert_eq!(settings["env"]["ANTHROPIC_AUTH_TOKEN"], "");

    // Native team starts preserve file-based permissions. A credential cleared by
    // the overlay never enters argv or durable spawn metadata.
    let mut file_profile = profile(&[]);
    file_profile.argv.push("--settings=permissions.json".into());
    for contents in [
        r#"{"permissions":{"allow":["Read"]}}"#,
        r#"{"permissions":{"allow":["Read"]},"env":{"ANTHROPIC_AUTH_TOKEN":"fixture-cleared-token"}}"#,
    ] {
        std::fs::write(home.join("permissions.json"), contents).unwrap();
        let team = hub.spawn_profile_for(&requested, &file_profile, &none).await.unwrap();
        let settings =
            crate::claude_cloud_auth::flag_settings(&team.argv[1..], &home).unwrap().unwrap();
        assert_eq!(settings["permissions"]["allow"], json!(["Read"]));
        assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "https://localhost");
        assert_eq!(settings["env"]["ANTHROPIC_AUTH_TOKEN"], "");
        assert!(team.argv.iter().all(|arg| !arg.contains("fixture-cleared-token")));
    }

    // A credential that would survive the overlay must never enter those launch settings.
    std::fs::write(
        home.join("personal.json"),
        r#"{"env":{"ANTHROPIC_BASE_URL":"https://personal.test","AWS_BEARER_TOKEN_BEDROCK":"fixture-file-secret"}}"#,
    ).unwrap();
    let mut file_profile = profile(&[]);
    file_profile.argv.extend(["--settings".into(), "personal.json".into()]);
    let own = hub.spawn_profile_for(&meta, &file_profile, &none).await.unwrap();
    assert_eq!(own.argv, file_profile.argv);
    let refused = hub.spawn_profile_for(&requested, &file_profile, &none).await.err().unwrap();
    let data = refused.data.unwrap();
    assert_eq!(data["reason"], "route.settings_secret");
    assert!(!data.to_string().contains("fixture-file-secret"));
    assert!(!refused.message.contains("fixture-file-secret"));

    std::fs::remove_file(root.join("etc/cmux/model-plane.env")).unwrap();
    let refused = hub.spawn_profile_for(&requested, &personal, &none).await.err().unwrap();
    assert_eq!(refused.data.unwrap()["reason"], "route.unavailable");
    assert_eq!(std::fs::read_to_string(choice.join("claude")).unwrap(), "own\n");
    let _ = std::fs::remove_dir_all(&root);
}
