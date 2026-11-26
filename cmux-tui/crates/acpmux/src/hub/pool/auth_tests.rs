use super::*;
use serde_json::{Value, json};

struct LoginFiles(PathBuf);

impl LoginFiles {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();
        let path =
            std::env::temp_dir().join(format!("pool-auth-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn write(&self, path: &str, value: Value) {
        let path = self.0.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, value.to_string()).unwrap();
    }

    fn fingerprint(&self, cache: &AuthCache, family: &str) -> (String, Option<String>) {
        cache.fingerprint_with(family, &|_| None, &self.0)
    }
}

impl Drop for LoginFiles {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn pool_auth_claude_saved_api_key_rotation_and_removal_change_the_key() {
    let files = LoginFiles::new("claude-key");
    let cache = AuthCache::default();
    files.write(".claude.json", json!({"primaryApiKey": "fixture-key-a"}));
    let first = files.fingerprint(&cache, "claude");
    files.write(".claude.json", json!({"primaryApiKey": "fixture-key-b"}));
    let changed = files.fingerprint(&cache, "claude");
    assert_ne!(first, changed, "a session warmed with the old saved API key must not match");
    files.write(".claude.json", json!({}));
    assert_ne!(
        changed,
        files.fingerprint(&cache, "claude"),
        "removing the saved key must invalidate it"
    );
}

#[test]
fn pool_auth_codex_api_key_rotation_changes_the_key() {
    let home = LoginFiles::new("codex-env-key");
    let cache = AuthCache::default();
    let key = |value: &'static str| move |k: &str| (k == "CODEX_API_KEY").then(|| value.to_owned());
    let first = cache.fingerprint_with("codex", &key("fixture-key-a"), &home.0);
    let rotated = cache.fingerprint_with("codex", &key("fixture-key-b"), &home.0);
    assert_ne!(first, rotated, "a Codex session warmed with the old CODEX_API_KEY must not match");
    assert_ne!(
        rotated,
        cache.fingerprint_with("codex", &|_| None, &home.0),
        "unsetting CODEX_API_KEY must invalidate it"
    );
}

#[test]
fn pool_auth_claude_saved_key_uses_the_child_home() {
    let daemon = LoginFiles::new("daemon-home");
    let child = LoginFiles::new("child-home");
    let cache = AuthCache::default();
    let env = |key: &str| (key == "HOME").then(|| child.0.display().to_string());
    child.write(".claude.json", json!({"primaryApiKey": "fixture-key-a"}));
    let first = cache.fingerprint_with("claude", &env, &daemon.0);
    child.write(".claude.json", json!({"primaryApiKey": "fixture-key-b"}));
    let changed = cache.fingerprint_with("claude", &env, &daemon.0);
    assert_ne!(first, changed, "the pooled child reads its configured HOME, not the daemon's");
    child.write(".claude.json", json!({}));
    assert_ne!(changed, cache.fingerprint_with("claude", &env, &daemon.0));
}

#[test]
fn pool_auth_empty_config_directory_uses_the_child_home() {
    for (family, config, path, first, second) in [
        (
            "claude",
            "CLAUDE_CONFIG_DIR",
            ".claude.json",
            json!({"primaryApiKey": "fixture-a"}),
            json!({"primaryApiKey": "fixture-b"}),
        ),
        (
            "codex",
            "CODEX_HOME",
            ".codex/auth.json",
            json!({"OPENAI_API_KEY": "fixture-a"}),
            json!({"OPENAI_API_KEY": "fixture-b"}),
        ),
    ] {
        let daemon = LoginFiles::new("empty-config-daemon");
        let child = LoginFiles::new("empty-config-child");
        let cache = AuthCache::default();
        let env = |key: &str| {
            if key == "HOME" {
                Some(child.0.display().to_string())
            } else if key == config {
                Some(String::new())
            } else {
                None
            }
        };
        child.write(path, first);
        let before = cache.fingerprint_with(family, &env, &daemon.0);
        child.write(path, second);
        assert_ne!(before, cache.fingerprint_with(family, &env, &daemon.0), "{family}");
    }
}

#[test]
fn pool_auth_opencode_uses_only_absolute_xdg_data_home() {
    let home = LoginFiles::new("xdg-home");
    let custom = LoginFiles::new("xdg-custom");
    for value in [String::new(), "relative-data".to_owned(), custom.0.display().to_string()] {
        let cache = AuthCache::default();
        let env = |key: &str| (key == "XDG_DATA_HOME").then(|| value.clone());
        let (files, path) = if Path::new(&value).is_absolute() {
            (&custom, "opencode/auth.json")
        } else {
            (&home, ".local/share/opencode/auth.json")
        };
        files.write(path, json!({"openai": {"type": "api", "key": "fixture-a"}}));
        let before = cache.fingerprint_with("opencode", &env, &home.0);
        files.write(path, json!({"openai": {"type": "api", "key": "fixture-b"}}));
        assert_ne!(
            before,
            cache.fingerprint_with("opencode", &env, &home.0),
            "XDG_DATA_HOME={value:?}"
        );
    }
}

#[test]
fn pool_auth_claude_refresh_preserves_the_key_but_account_switch_and_logout_do_not() {
    let files = LoginFiles::new("claude-oauth");
    let cache = AuthCache::default();
    files.write(
        ".claude.json",
        json!({"oauthAccount": {"accountUuid": "account-a", "organizationUuid": "org-a"}}),
    );
    files
        .write(".claude/.credentials.json", json!({"claudeAiOauth": {"accessToken": "fixture-a"}}));
    let first = files.fingerprint(&cache, "claude");
    files
        .write(".claude/.credentials.json", json!({"claudeAiOauth": {"accessToken": "fixture-b"}}));
    assert_eq!(first, files.fingerprint(&cache, "claude"));
    files.write(
        ".claude.json",
        json!({"oauthAccount": {"accountUuid": "account-b", "organizationUuid": "org-a"}}),
    );
    let switched = files.fingerprint(&cache, "claude");
    assert_ne!(first, switched);
    std::fs::remove_file(files.0.join(".claude/.credentials.json")).unwrap();
    assert_ne!(switched, files.fingerprint(&cache, "claude"));
}

#[test]
fn pool_auth_codex_and_opencode_refresh_switch_and_logout_use_file_identity() {
    for (family, path, first, refreshed, switched) in [
        (
            "codex",
            ".codex/auth.json",
            json!({"auth_mode": "chatgpt", "tokens": {"account_id": "account-a", "access_token": "fixture-a"}}),
            json!({"auth_mode": "chatgpt", "tokens": {"account_id": "account-a", "access_token": "fixture-b"}}),
            json!({"auth_mode": "chatgpt", "tokens": {"account_id": "account-b", "access_token": "fixture-c"}}),
        ),
        (
            "opencode",
            ".local/share/opencode/auth.json",
            json!({"openai": {"type": "oauth", "accountId": "account-a", "access": "fixture-a"}}),
            json!({"openai": {"type": "oauth", "accountId": "account-a", "access": "fixture-b"}}),
            json!({"openai": {"type": "oauth", "accountId": "account-b", "access": "fixture-c"}}),
        ),
    ] {
        let files = LoginFiles::new(family);
        let cache = AuthCache::default();
        files.write(path, first);
        let before = files.fingerprint(&cache, family);
        files.write(path, refreshed);
        assert_eq!(before, files.fingerprint(&cache, family), "{family} token refresh");
        files.write(path, switched);
        let after = files.fingerprint(&cache, family);
        assert_ne!(before, after, "{family} account switch");
        std::fs::remove_file(files.0.join(path)).unwrap();
        assert_ne!(after, files.fingerprint(&cache, family), "{family} logout");
    }
}

/// Every harness login in the fingerprint list is one an agent of another
/// family loses (`agent/foreign_login.rs`), so the two lists cannot drift.
#[test]
fn every_harness_login_has_an_owner_family() {
    let owned: Vec<_> =
        crate::agent::foreign_login::LOGIN_ENV_OWNERS.iter().map(|login| login.key).collect();
    for key in AUTH_ENV.iter().filter(|k| **k != "XDG_DATA_HOME") {
        // A provider key (`GOOGLE_API_KEY`, `XAI_API_KEY`) is owned through the login shell's
        // allow-list instead (`foreign_login::provider_key_owner`).
        assert!(
            owned.contains(key) || crate::agent::foreign_login::provider_key_owner(key).is_some(),
            "{key} has no owner in LOGIN_ENV_OWNERS or provider_key_owner"
        );
    }
}

#[test]
fn pool_auth_gemini_account_switch_and_logout_change_the_key_but_refresh_does_not() {
    let files = LoginFiles::new("gemini");
    let cache = AuthCache::default();
    files.write(".gemini/google_accounts.json", json!({"active": "a@example.com", "old": []}));
    files.write(".gemini/oauth_creds.json", json!({"access_token": "fixture-a"}));
    let before = files.fingerprint(&cache, "gemini");
    assert!(before.1.is_some(), "the Google account names the pooled session's account");
    files.write(".gemini/oauth_creds.json", json!({"access_token": "fixture-b"}));
    assert_eq!(before, files.fingerprint(&cache, "gemini"), "a token refresh keeps the session");
    files.write(".gemini/google_accounts.json", json!({"active": "b@example.com", "old": []}));
    let switched = files.fingerprint(&cache, "gemini");
    assert_ne!(before, switched, "another Google account");
    std::fs::remove_file(files.0.join(".gemini/oauth_creds.json")).unwrap();
    assert_ne!(switched, files.fingerprint(&cache, "gemini"), "a logout");
}

#[test]
fn pool_auth_gemini_and_grok_homes_and_api_keys_change_the_key() {
    let home = LoginFiles::new("gemini-grok-env");
    let cache = AuthCache::default();
    for (family, key, home_key, login) in [
        ("gemini", "GEMINI_API_KEY", "GEMINI_CLI_HOME", ".gemini/oauth_creds.json"),
        ("grok", "XAI_API_KEY", "GROK_HOME", "auth.json"),
    ] {
        let with =
            |name: &'static str, value: String| move |k: &str| (k == name).then(|| value.clone());
        let a = cache.fingerprint_with(family, &with(key, "fixture-key-a".into()), &home.0);
        let b = cache.fingerprint_with(family, &with(key, "fixture-key-b".into()), &home.0);
        assert_ne!(a, b, "{family}: a rotated {key}");
        // The login under the harness's own home counts, not the one under HOME.
        let custom = home.0.join(format!("{family}-home"));
        let custom = custom.to_string_lossy().into_owned();
        let in_custom = cache.fingerprint_with(family, &with(home_key, custom.clone()), &home.0);
        home.write(&format!("{family}-home/{login}"), json!({"token": "fixture"}));
        assert_ne!(
            in_custom,
            cache.fingerprint_with(family, &with(home_key, custom.clone()), &home.0),
            "{family}: a login under {home_key}"
        );
    }
    // `grok login` writes ~/.grok/auth.json: its presence is the login.
    let before = cache.fingerprint_with("grok", &|_| None, &home.0);
    home.write(".grok/auth.json", json!({"token": "fixture"}));
    assert_ne!(before, cache.fingerprint_with("grok", &|_| None, &home.0), "grok login");
}

#[test]
fn pool_auth_grok_account_switch_changes_the_key_but_refresh_does_not() {
    let files = LoginFiles::new("grok-account");
    let cache = AuthCache::default();
    let at = ".grok/auth.json";
    files.write(at, json!({"grok.com": {"user_id": "user-a", "access_token": "fixture-a"}}));
    let before = files.fingerprint(&cache, "grok");
    files.write(at, json!({"grok.com": {"user_id": "user-a", "access_token": "fixture-b"}}));
    assert_eq!(before, files.fingerprint(&cache, "grok"), "a token refresh keeps the session");
    files.write(at, json!({"grok.com": {"user_id": "user-b", "access_token": "fixture-c"}}));
    let switched = files.fingerprint(&cache, "grok");
    assert_ne!(before, switched, "another grok account");
    std::fs::remove_file(files.0.join(at)).unwrap();
    assert_ne!(switched, files.fingerprint(&cache, "grok"), "a logout");
}

/// The cloud journey's stub chat (run 45768950539): a pooled Claude warmed before
/// `settings.json` pointed it at the stub kept the endpoint it started with, so the chat never
/// got the stub's reply. A new endpoint, credential helper or provider switch there must not match.
#[test]
fn pool_auth_claude_settings_endpoint_change_changes_the_key() {
    let files = LoginFiles::new("claude-settings");
    let cache = AuthCache::default();
    let none = files.fingerprint(&cache, "claude");
    files.write(
        ".claude/settings.json",
        json!({"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:1"}}),
    );
    let stub = files.fingerprint(&cache, "claude");
    assert_ne!(none, stub, "a session warmed before settings.json set an endpoint must not match");
    files.write(
        ".claude/settings.json",
        json!({"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:2"}}),
    );
    let moved = files.fingerprint(&cache, "claude");
    assert_ne!(stub, moved, "a session warmed for the old endpoint must not match");
    files.write(
        ".claude/settings.json",
        json!({"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:2"}, "apiKeyHelper": "/bin/key"}),
    );
    assert_ne!(
        moved,
        files.fingerprint(&cache, "claude"),
        "a new credential helper must not match"
    );
    files.write(
        ".claude/settings.json",
        json!({"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:2"}, "apiKeyHelper": "/bin/key", "theme": "dark"}),
    );
    let themed = files.fingerprint(&cache, "claude");
    files.write(
        ".claude/settings.json",
        json!({"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:2"}, "apiKeyHelper": "/bin/key", "theme": "light"}),
    );
    assert_eq!(
        themed,
        files.fingerprint(&cache, "claude"),
        "a setting that moves no endpoint or credential keeps the pooled session"
    );
}

#[test]
fn pool_auth_claude_settings_follow_claude_config_dir() {
    let files = LoginFiles::new("claude-settings-dir");
    let cache = AuthCache::default();
    let dir = files.0.join("cfg").to_string_lossy().into_owned();
    let env = move |k: &str| (k == "CLAUDE_CONFIG_DIR").then(|| dir.clone());
    let before = cache.fingerprint_with("claude", &env, &files.0);
    files.write("cfg/settings.json", json!({"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:1"}}));
    assert_ne!(before, cache.fingerprint_with("claude", &env, &files.0));
}

/// The own-or-team choice file (`CHOICE_DIR`) decides own or team at spawn (`hub/spawn.rs`): a session
/// warmed under the other choice must not match, for every family that has a choice.
#[test]
fn pool_auth_own_or_team_choice_changes_the_key() {
    for family in ["claude", "codex", "gemini", "grok"] {
        let files = LoginFiles::new(&format!("choice-{family}"));
        let cache = AuthCache::default();
        let unchosen = files.fingerprint(&cache, family);
        let choice = files.0.join(crate::codex_cloud_auth::CHOICE_DIR).join(family);
        std::fs::create_dir_all(choice.parent().unwrap()).unwrap();
        std::fs::write(&choice, "own\n").unwrap();
        let own = files.fingerprint(&cache, family);
        assert_ne!(unchosen, own, "{family}: choosing own must not keep a team-mode session");
        std::fs::write(&choice, "team\n").unwrap();
        let team = files.fingerprint(&cache, family);
        assert_ne!(own, team, "{family}: choosing team must not keep an own-mode session");
        std::fs::write(&choice, "team").unwrap();
        assert_eq!(
            team,
            files.fingerprint(&cache, family),
            "{family}: whitespace is no new choice"
        );
        assert_eq!(own.1, unchosen.1, "{family}: a choice names no account");
    }
}

#[test]
fn pool_auth_endpoint_env_and_pins_change_the_key() {
    let home = LoginFiles::new("endpoint-env");
    let cache = AuthCache::default();
    for (family, name) in [
        ("claude", "ANTHROPIC_BASE_URL"),
        ("claude", "CMUX_CLAUDE_AUTH"),
        ("codex", "OPENAI_BASE_URL"),
        ("codex", "CMUX_CODEX_AUTH"),
        ("gemini", "GOOGLE_GEMINI_BASE_URL"),
        ("grok", "GROK_MODELS_BASE_URL"),
    ] {
        let set = move |k: &str| (k == name).then(|| "own".to_owned());
        assert_ne!(
            cache.fingerprint_with(family, &|_| None, &home.0),
            cache.fingerprint_with(family, &set, &home.0),
            "{family}: {name} must count"
        );
    }
}
