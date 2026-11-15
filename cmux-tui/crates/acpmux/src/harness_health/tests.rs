use super::{
    Auth, Channel, HarnessHealth, HealthService, Subject, auth_failure, codex_login_in_file,
    codex_project_config,
};
use serde_json::json;
use std::collections::BTreeMap;

/// Hermes keeps its provider and model in ~/.hermes: `hermes model` picks
/// them (an API key or a provider sign-in), which is the sign-in a Chief on
/// Hermes needs.
#[test]
fn hermes_signs_in_with_hermes_model() {
    assert_eq!(super::builtin_login("hermes"), Some("hermes model"));
}

#[test]
fn muse_signs_in_with_the_official_cli() {
    assert_eq!(super::builtin_login("muse"), Some("muse login"));
}

#[test]
fn expired_login_probe_is_not_just_signed_out() {
    assert_eq!(auth_failure("OAuth token has expired"), Auth::Expired);
    assert_eq!(auth_failure("Not logged in"), Auth::SignedOut);
    assert_eq!(auth_failure("check failed"), Auth::SignedOut);
    assert_eq!(auth_failure("HTTP 503"), Auth::Unknown);
    assert_eq!(auth_failure("HTTP 502: authentication_failed"), Auth::Unknown);
    assert_eq!(auth_failure("Not logged in? HTTP 503: authentication_failed"), Auth::Unknown);
    assert_eq!(auth_failure("token expired? connection refused"), Auth::Unknown);
    assert_eq!(auth_failure("Your refresh token has expired; run codex login"), Auth::Expired);
    assert_eq!(auth_failure("the MCP session expired"), Auth::SignedOut);
    assert_eq!(auth_failure("Provided authentication token is expired."), Auth::Expired);
    assert_eq!(auth_failure("credential expired"), Auth::Expired);
    // Only a statement that a credential expired: not its expiry field, not a future one.
    assert_eq!(auth_failure("HTTP 400: invalid token expiry value"), Auth::SignedOut);
    assert_eq!(auth_failure("Not logged in; the credential expires in 30 days"), Auth::SignedOut);
    assert_eq!(serde_json::to_value(Auth::Expired).unwrap(), json!("expired"));
}

/// A profile whose CLI keeps its login in an account home of its own (`CODEX_HOME`,
/// `CLAUDE_CONFIG_DIR`) is checked there, so its Log In signs in there too, not the
/// default home.
#[test]
fn log_in_signs_in_the_account_home_the_check_reads() {
    let subject =
        |id: &str, family: &str, env: &[(&str, &str)], login: Option<&str>| super::Subject {
            id: id.into(),
            program: format!("/nonexistent/{family}"),
            family: family.into(),
            check: vec![],
            env: env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
            login: login.map(str::to_owned),
            unresolved: vec![],
            probe_error: None,
        };
    let home = std::path::Path::new("/nonexistent-home");
    let login = |s| super::local(s, home).login;
    assert_eq!(
        login(subject("codex-work", "codex", &[("CODEX_HOME", "/Users/me/.codex-work")], None)),
        Some("CODEX_HOME=/Users/me/.codex-work codex login".into())
    );
    assert_eq!(
        login(subject(
            "claude-two",
            "claude",
            &[("CLAUDE_CONFIG_DIR", "/Users/me/claude two")],
            None
        )),
        Some("CLAUDE_CONFIG_DIR='/Users/me/claude two' claude auth login".into())
    );
    // A profile's own login, in the same home.
    assert_eq!(
        login(subject("codex-sr", "codex", &[("CODEX_HOME", "~/.codex-sr")], Some("sr login"))),
        Some("CODEX_HOME=~/.codex-sr sr login".into())
    );
    // No account home: unchanged.
    assert_eq!(login(subject("codex", "codex", &[], None)), Some("codex login".into()));
    assert_eq!(
        login(subject("gemini", "gemini", &[("CODEX_HOME", "/elsewhere")], None)),
        Some("gemini".into())
    );
}

#[tokio::test]
async fn first_check_rebinds_a_cached_login_to_the_current_profile_home() {
    let service = HealthService::new();
    service.replace_rows(vec![HarnessHealth {
        id: "codex-sr".into(),
        program: "codex".into(),
        path: None,
        channel: Channel::Standalone,
        package: None,
        version: None,
        latest: None,
        latest_checked_at: None,
        outdated: false,
        auth: Auth::SignedOut,
        auth_detail: None,
        login: Some("codex login".into()),
        update: None,
        problem: None,
        checked_at: 1,
        auto_update: false,
        last_auto_update: None,
    }]);
    let subject = Subject {
        id: "codex-sr".into(),
        program: "codex".into(),
        family: "codex".into(),
        check: vec![],
        env: BTreeMap::from([(String::from("CODEX_HOME"), String::from("/tmp/codex-sr"))]),
        login: Some("codex login".into()),
        unresolved: vec![],
        probe_error: None,
    };
    let rows = service.first_check(vec![subject]).await;
    assert_eq!(rows[0].login.as_deref(), Some("CODEX_HOME=/tmp/codex-sr codex login"));
}

#[test]
fn successful_acp_auth_updates_health_without_a_cli_probe() {
    let service = HealthService::new();
    service.replace_rows(vec![HarnessHealth {
        id: "muse".into(),
        program: "muse-acp".into(),
        path: Some("/tmp/muse-acp".into()),
        channel: Channel::Standalone,
        package: None,
        version: None,
        latest: None,
        latest_checked_at: None,
        outdated: false,
        auth: Auth::Unknown,
        auth_detail: None,
        login: Some("muse login".into()),
        update: None,
        problem: None,
        checked_at: 1,
        auto_update: false,
        last_auto_update: None,
    }]);
    let feed = service.inventory_changes();
    service.record_acp_auth_success("muse", "ACP session/new authenticated the harness");
    let row = service.rows().pop().expect("muse health row");
    assert_eq!(row.auth, Auth::SignedIn);
    assert_eq!(row.auth_detail.as_deref(), Some("ACP session/new authenticated the harness"));
    assert!(feed.has_changed().unwrap(), "the inventory feed sees the new sign-in");

    // A later check that reads the harness signed out drops the evidence.
    let mut checked = service.rows();
    checked[0].auth = Auth::SignedOut;
    service.apply_acp_auth(&mut checked);
    assert_eq!(checked[0].auth, Auth::SignedOut);
    checked[0].auth = Auth::Unknown;
    service.apply_acp_auth(&mut checked);
    assert_eq!(checked[0].auth, Auth::Unknown, "the logout's evidence is gone");

    // An id that now runs another program does not inherit the evidence.
    service.record_acp_auth_success("muse", "ACP session/new authenticated the harness");
    let mut moved = service.rows();
    moved[0].auth = Auth::Unknown;
    moved[0].path = Some("/elsewhere/muse-acp".into());
    service.apply_acp_auth(&mut moved);
    assert_eq!(moved[0].auth, Auth::Unknown, "a repointed id is not signed in");
}

fn home_with(n: usize, config: Option<&str>) -> (std::path::PathBuf, BTreeMap<String, String>) {
    let dir = std::env::temp_dir().join(format!("amx-codex-store-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    if let Some(text) = config {
        std::fs::write(dir.join("config.toml"), text).unwrap();
    }
    let env = BTreeMap::from([("CODEX_HOME".to_owned(), dir.display().to_string())]);
    (dir, env)
}

/// `codex login status` runs only when Codex keeps its login in a file
/// (cx-hh0vu): never when it may read the keychain.
#[test]
fn codex_login_status_runs_only_for_a_file_login() {
    for (n, (config, file)) in [
        (None, true),
        (Some("model = \"o3\"\n"), true),
        (Some("cli_auth_credentials_store = \"file\"\n"), true),
        (Some("cli_auth_credentials_store = \"keyring\"\n"), false),
        (Some("cli_auth_credentials_store = \"auto\"\n"), false),
        (Some("cli_auth_credentials_store = 1\n"), false),
        (Some("not toml ["), false),
    ]
    .into_iter()
    .enumerate()
    {
        let (dir, env) = home_with(n, config);
        assert_eq!(codex_login_in_file(&env), file, "{config:?}");
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[test]
fn codex_project_config_checks_ancestors_of_the_launch_directory() {
    let root = std::env::temp_dir().join(format!(
        "amx-codex-project-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let project = root.join("project");
    let nested = project.join("src/deep");
    std::fs::create_dir_all(project.join(".codex")).unwrap();
    std::fs::create_dir_all(&nested).unwrap();
    std::fs::write(project.join(".codex/config.toml"), "model_provider = \"local\"\n").unwrap();
    let env = BTreeMap::from([("HOME".to_owned(), root.display().to_string())]);

    assert_eq!(codex_project_config(&nested, &env), Some(true));

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn codex_project_config_resolves_symlinked_directories_and_unknown_paths() {
    use std::os::unix::fs::symlink;

    let root = std::env::temp_dir().join(format!(
        "amx-codex-project-symlink-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let project = root.join("project");
    let source = project.join("src/deep");
    let alias = root.join("alias");
    std::fs::create_dir_all(project.join(".codex")).unwrap();
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(project.join(".codex/config.toml"), "model_provider = \"local\"\n").unwrap();
    symlink(project.join("src"), &alias).unwrap();
    let env = BTreeMap::from([("HOME".to_owned(), root.display().to_string())]);

    assert_eq!(codex_project_config(&alias.join("deep"), &env), Some(true));
    assert_eq!(codex_project_config(&root.join("missing"), &env), None);

    let home_codex = root.join(".codex");
    std::fs::create_dir_all(&home_codex).unwrap();
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(home_codex.join("config.toml"), "model_provider = \"local\"\n").unwrap();
    assert_eq!(codex_project_config(&root.join("src"), &env), Some(false));

    let custom_home = root.join("custom-codex");
    let custom_cwd = custom_home.join("src/deep");
    std::fs::create_dir_all(&custom_cwd).unwrap();
    std::fs::write(custom_home.join("config.toml"), "model_provider = \"local\"\n").unwrap();
    let env = BTreeMap::from([
        ("HOME".to_owned(), root.display().to_string()),
        ("CODEX_HOME".to_owned(), custom_home.display().to_string()),
    ]);
    assert_eq!(codex_project_config(&custom_cwd, &env), Some(false));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn codex_launch_overrides_do_not_produce_a_subscription_refusal() {
    for args in [
        vec!["-p", "local", "app-server"],
        vec!["--profile=local", "app-server"],
        vec!["-c", "model_provider=\"local\"", "app-server"],
        vec!["-c", "cli_auth_credentials_store=\"keyring\"", "app-server"],
    ] {
        let argv: Vec<_> = std::iter::once("codex").chain(args).collect();
        let profile = serde_json::from_value(json!({"argv": argv})).unwrap();
        let result = super::fresh_auth("codex", &profile, None);
        assert!(result.is_err(), "launch overrides require inconclusive evidence: {result:?}");
    }
}

/// A harness whose start may read the keychain is named, so a caller
/// that asks a harness its sign-in does not start it (cx-hh0vu).
#[test]
fn keychain_sign_in_names_keychain_references_and_a_codex_keychain_login() {
    let (keyring, keyring_env) = home_with(10, Some("cli_auth_credentials_store = \"keyring\"\n"));
    let (file, file_env) = home_with(11, None);
    for (argv, env, keychain) in [
        ("gemini", json!({"API_KEY": "${keychain:cmux-harness/gemini/API_KEY}"}), true),
        ("gemini", json!({"API_KEY": "${env:API_KEY}"}), false),
        ("claude-agent-acp", json!({}), true),
        ("codex-acp", json!({"CODEX_HOME": keyring_env["CODEX_HOME"]}), true),
        ("codex-acp", json!({"CODEX_HOME": file_env["CODEX_HOME"]}), false),
        ("codex-acp", json!({"CODEX_HOME": "${env:SOME_CODEX_HOME}"}), true),
    ] {
        let profile: crate::config::HarnessProfile =
            serde_json::from_value(json!({"argv": [argv], "env": env})).unwrap();
        let why = super::keychain_sign_in(argv, &profile);
        assert_eq!(why.is_some(), keychain, "{argv} {env}: {why:?}");
    }
    let _ = std::fs::remove_dir_all(keyring);
    let _ = std::fs::remove_dir_all(file);
}
