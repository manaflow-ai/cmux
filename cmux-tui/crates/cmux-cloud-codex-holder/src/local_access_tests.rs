//! The Mac's own Codex `auth.json`, read for its access token only (fixtures; never a real home).
//! Ported from CloudCodexLocalAccessTests.swift.

use super::*;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::json;
use std::os::unix::fs::PermissionsExt as _;

pub(crate) fn jwt(claims: &Value) -> String {
    let part = |value: &Value| URL_SAFE_NO_PAD.encode(value.to_string());
    format!("{}.{}.sig", part(&json!({"alg": "none"})), part(claims))
}

fn auth(access: &str, account: Option<&str>, key: Value, mode: Option<&str>) -> Vec<u8> {
    let mut tokens = json!({"access_token": access, "refresh_token": "fixture-refresh", "id_token": jwt(&json!({}))});
    if let Some(account) = account {
        tokens["account_id"] = json!(account);
    }
    let mut root = json!({"OPENAI_API_KEY": key, "tokens": tokens});
    if let Some(mode) = mode {
        root["auth_mode"] = json!(mode);
    }
    root.to_string().into_bytes()
}

fn plain(access: &str) -> Vec<u8> {
    auth(access, Some("acct"), Value::Null, Some("chatgpt"))
}

const NOW: f64 = 2_000_000_000.0;

#[test]
fn gives_only_the_access_token_account_and_expiry() {
    let access = jwt(&json!({"exp": NOW + 3600.5}));
    let grant = grant(&plain(&access), NOW).unwrap();
    assert_eq!(grant.access_token, access);
    assert_eq!(grant.account, "acct");
    assert!((grant.expires_at - (NOW + 3600.5)).abs() < 1e-6);
}

#[test]
fn reads_an_integer_expiry() {
    let access = jwt(&json!({"exp": 2_000_003_600_u64}));
    assert_eq!(grant(&plain(&access), NOW).unwrap().expires_at, NOW + 3600.0);
}

#[test]
fn reads_the_account_from_the_token_when_the_file_has_none() {
    let access = jwt(
        &json!({"exp": NOW + 3600.0, "https://api.openai.com/auth": {"chatgpt_account_id": "from-claim"}}),
    );
    let read = grant(&auth(&access, None, Value::Null, Some("chatgpt")), NOW).unwrap();
    assert_eq!(read.account, "from-claim");
    let top = jwt(&json!({"exp": NOW + 3600.0, "chatgpt_account_id": "top"}));
    assert_eq!(grant(&auth(&top, None, Value::Null, Some("chatgpt")), NOW).unwrap().account, "top");
}

#[test]
fn offers_nothing_near_its_end_for_an_api_key_or_another_mode() {
    let soon = jwt(&json!({"exp": NOW + 60.0}));
    assert!(grant(&plain(&soon), NOW).is_none());
    let fine = jwt(&json!({"exp": NOW + 3600.0}));
    assert!(grant(&auth(&fine, Some("acct"), json!("sk-fixture"), Some("chatgpt")), NOW).is_none());
    assert!(grant(&auth(&fine, Some("acct"), Value::Null, Some("apikey")), NOW).is_none());
    assert!(grant(b"not json", NOW).is_none());
    let far = jwt(&json!({"exp": 1e300}));
    assert!(grant(&plain(&far), NOW).is_none());
    // No mode at all is Codex's default ChatGPT sign-in.
    assert!(grant(&auth(&fine, Some("acct"), Value::Null, None), NOW).is_some());
}

#[test]
fn reads_only_a_private_file_in_the_file_store() {
    let home = tempfile::tempdir().unwrap();
    let file = home.path().join("auth.json");
    let access = jwt(&json!({"exp": crate::types::now() + 3600.0}));
    std::fs::write(&file, plain(&access)).unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
    let now = crate::types::now();
    assert!(read(home.path(), now).is_none(), "readable by others: not Codex's own file");
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(read(home.path(), now).unwrap().access_token, access);
    let config = home.path().join("config.toml");
    std::fs::write(&config, "cli_auth_credentials_store = \"keyring\"\n").unwrap();
    assert!(read(home.path(), now).is_none(), "the Keychain is Codex's own");
    std::fs::write(&config, "cli_auth_credentials_store = \"file\" # default\n").unwrap();
    assert_eq!(read(home.path(), now).unwrap().access_token, access);
    std::fs::write(&config, "model = \"o3\"\n").unwrap();
    assert!(read(home.path(), now).is_some(), "no store key: the file store");
}

#[test]
fn a_symlinked_auth_file_is_never_read() {
    let home = tempfile::tempdir().unwrap();
    let real = home.path().join("real.json");
    std::fs::write(&real, plain(&jwt(&json!({"exp": crate::types::now() + 3600.0})))).unwrap();
    std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::os::unix::fs::symlink(&real, home.path().join("auth.json")).unwrap();
    assert!(read(home.path(), crate::types::now()).is_none());
}

#[test]
fn home_follows_codex_home() {
    let user = Path::new("/Users/fixture");
    assert_eq!(home(None, user), PathBuf::from("/Users/fixture/.codex"));
    assert_eq!(home(Some("~/alt"), user), PathBuf::from("/Users/fixture/alt"));
    assert_eq!(home(Some("relative"), user), PathBuf::from("/Users/fixture/.codex"));
    assert_eq!(home(Some(" /abs/codex "), user), PathBuf::from("/abs/codex"));
    assert_eq!(home(Some("  "), user), PathBuf::from("/Users/fixture/.codex"));
}
