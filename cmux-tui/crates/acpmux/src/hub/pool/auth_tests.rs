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
