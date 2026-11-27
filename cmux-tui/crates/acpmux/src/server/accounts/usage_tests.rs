use super::*;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");

fn home(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("acpmux-account-usage-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn only_a_signed_in_file_login_on_the_openai_sign_in_is_read() {
    let dir = home("readable");
    assert_eq!(readable(&dir), Target::Skip("signedOut"));
    std::fs::write(dir.join("auth.json"), r#"{"tokens": {"access_token": "x"}}"#).unwrap();
    assert_eq!(readable(&dir), Target::Read(dir.clone()));
    // A login Codex may keep in the keychain is never asked for (cx-hh0vu).
    for store in ["keyring", "auto"] {
        let config = format!("cli_auth_credentials_store = \"{store}\"\n");
        std::fs::write(dir.join("config.toml"), config).unwrap();
        assert_eq!(readable(&dir), Target::Skip("keychain"), "{store}");
    }
    std::fs::write(dir.join("config.toml"), "cli_auth_credentials_store = \"file\"\n").unwrap();
    assert_eq!(readable(&dir), Target::Read(dir.clone()));
    // A provider without the OpenAI sign-in has no plan limits.
    let sr = "model_provider = \"sr\"\n[model_providers.sr]\nexperimental_bearer_token = \"t\"\n";
    std::fs::write(dir.join("config.toml"), sr).unwrap();
    assert_eq!(readable(&dir), Target::Skip("provider"));
    let _ = std::fs::remove_dir_all(&dir);
}

fn acp(argv: &[&str], env: &[(&str, &str)]) -> crate::config::HarnessProfile {
    crate::config::HarnessProfile {
        kind: crate::config::HarnessKind::Acp,
        argv: argv.iter().map(|s| s.to_string()).collect(),
        env: env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

#[test]
fn the_codex_a_codex_profile_names_is_the_one_that_reads() {
    let home = Path::new("/Users/someone");
    let mut config = crate::config::Config::default();
    assert_eq!(codex_path(&config, home), None, "no profile: the one on PATH");
    config
        .harnesses
        .insert("codex-work".into(), acp(&["codex", "app-server"], &[("CODEX_PATH", "/opt/b")]));
    assert_eq!(codex_path(&config, home).as_deref(), Some("/opt/b"));
    config
        .harnesses
        .insert("codex".into(), acp(&["codex", "app-server"], &[("CODEX_PATH", "/opt/a")]));
    assert_eq!(codex_path(&config, home).as_deref(), Some("/opt/a"), "the codex profile first");
    config
        .harnesses
        .insert("codex".into(), acp(&["codex", "app-server"], &[("CODEX_PATH", "${X}")]));
    assert_eq!(
        codex_path(&config, home).as_deref(),
        Some("/opt/b"),
        "an unresolved one is not a path"
    );
    // The family's defaults fill in a profile without its own, as a chat launch merges them.
    config.harnesses.insert("codex".into(), acp(&["codex", "app-server"], &[]));
    let mut family = crate::config::SessionDefaults::default();
    family.env.insert("CODEX_PATH".into(), "/opt/family".into());
    config.defaults.insert("codex".into(), family);
    assert_eq!(codex_path(&config, home).as_deref(), Some("/opt/family"), "defaults.codex.env");
    config.harnesses.remove("codex");
    assert_eq!(codex_path(&config, home).as_deref(), Some("/opt/b"), "the profile's own wins");
}

#[test]
fn an_interpolated_codex_path_expands_as_a_chat_launch_expands_it() {
    let home = Path::new("/Users/someone");
    let codex = |path: &str| {
        let mut config = crate::config::Config::default();
        let mut family = crate::config::SessionDefaults::default();
        family.env.insert("CODEX_PATH".into(), path.into());
        family.model = Some("gpt-5".into());
        config.defaults.insert("codex".into(), family);
        config.harnesses.insert("codex".into(), acp(&["codex", "app-server"], &[]));
        codex_path(&config, home)
    };
    assert_eq!(codex("${home}/bin/codex").as_deref(), Some("/Users/someone/bin/codex"));
    assert_eq!(codex("~/bin/codex").as_deref(), Some("/Users/someone/bin/codex"));
    assert_eq!(codex("/opt/${model}/codex").as_deref(), Some("/opt/gpt-5/codex"));
    // No directory at rest, and an unknown variable stays unresolved: the one on PATH.
    assert_eq!(codex("${cwd}/codex"), None);
    assert_eq!(codex("${X}/codex"), None);
}

#[cfg(unix)]
#[tokio::test]
async fn a_read_runs_codex_in_the_accounts_home_with_a_file_login_and_maps_its_windows() {
    let dir = home("read");
    let args = dir.join("args.jsonl");
    let seen = dir.join("codex-home.txt");
    // FAKE_CODEX_ARGS: where the fake records its arguments; FAKE_CODEX_HOME_SEEN: its CODEX_HOME.
    let env = BTreeMap::from([
        ("FAKE_CODEX_ARGS".to_owned(), args.display().to_string()),
        ("FAKE_CODEX_HOME_SEEN".to_owned(), seen.display().to_string()),
    ]);
    let limits = read_with(vec!["python3".into(), FAKE.into()], &dir, env).await.unwrap();
    assert_eq!(
        limits,
        json!({
            "windows": [
                {"id": "session", "usedPercent": 22.0, "windowMins": 300, "resetsAt": 1_790_000_000},
                {"id": "weekly", "usedPercent": 41.0, "windowMins": 10080, "resetsAt": 1_790_500_000},
            ],
            "plan": "pro",
            "credits": {"balance": "56766"},
        })
    );
    let recorded = std::fs::read_to_string(&args).unwrap();
    let first: Vec<String> = serde_json::from_str(recorded.lines().next().unwrap()).unwrap();
    assert_eq!(first, ["-c", "cli_auth_credentials_store=\"file\"", "app-server"]);
    let home_seen = std::fs::read_to_string(&seen).unwrap();
    assert_eq!(home_seen.trim(), dir.display().to_string());
    let _ = std::fs::remove_dir_all(&dir);
}
