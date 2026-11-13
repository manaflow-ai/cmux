//! Rollback tolerance of the launch key file (lane c-survive, routed from
//! c-persist). A newer build may add a field to `launch-keys.json`. An older
//! build that the person rolls back to read such a file as not trusted, made
//! new keys and wrote them over the file, so the credential in every
//! surviving terminal's environment stopped verifying. Its keys are kept now,
//! and a rotation keeps the fields it does not know.

use super::*;

fn key_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-launch-keys-{name}-{}-{}",
        std::process::id(),
        new_kid().unwrap()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn terminal_claims() -> Claims {
    Claims {
        v: 1,
        host: "host".into(),
        terminal: Some("terminal-1".into()),
        acp_session: None,
        agent: None,
        iat: 1,
    }
}

/// Rewrite the key file the way a newer build might: one more top-level field
/// and one more field in `last_rotation`.
#[cfg(unix)]
fn add_newer_fields(path: &Path) -> serde_json::Value {
    use std::os::unix::fs::PermissionsExt;
    let mut stored: serde_json::Value =
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    stored["rotated_at_ms"] = serde_json::json!(1_700_000_000_000u64);
    stored["last_rotation"] = serde_json::json!({
        "idempotency_key": "rotate-1",
        "kid": stored["current"].clone(),
        "actor": "terminal:terminal-1",
    });
    std::fs::write(path, serde_json::to_vec(&stored).unwrap()).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    stored
}

#[cfg(unix)]
#[test]
fn a_key_file_with_a_newer_field_keeps_its_keys() {
    let dir = key_dir("newer-field");
    let path = dir.join(KEY_DIRECTORY).join(KEY_FILE);
    let first = LaunchIdentity::load(Some(&dir));
    let credential = first.mint(&terminal_claims()).unwrap();
    let written = add_newer_fields(&path);

    let rolled_back = LaunchIdentity::load(Some(&dir));
    assert_eq!(
        rolled_back.verify(&credential).ok(),
        Some(terminal_claims()),
        "a surviving terminal's credential stopped verifying after a rollback"
    );
    let on_disk: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(on_disk, written, "the start rewrote a key file it could read");

    // A rotation keeps the previous key and every field this build does not know.
    let (kid, repeated) = rolled_back.rotate("rotate-2").unwrap();
    assert!(!repeated);
    assert_eq!(rolled_back.verify(&credential).ok(), Some(terminal_claims()));
    let rotated: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(rotated["current"], kid.as_str(), "{rotated}");
    assert_eq!(rotated["rotated_at_ms"], written["rotated_at_ms"], "{rotated}");
    std::fs::remove_dir_all(dir).unwrap();
}
