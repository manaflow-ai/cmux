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
