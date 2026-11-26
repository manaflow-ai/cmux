use super::*;

const ID: &str = "aid-0123456789abcdef0123";

#[test]
fn an_opaque_id_is_found_bare_or_in_its_web_link() {
    assert_eq!(find(ID).as_deref(), Some(ID));
    assert_eq!(find(&format!("https://cmux.com/deeplink/agent?id={ID}")).as_deref(), Some(ID));
    assert_eq!(
        find(&format!("https://www.cmux.com/zh-CN/deeplink/agent/?id={ID}")).as_deref(),
        Some(ID)
    );
    assert_eq!(
        find(&format!("[big-red](https://cmux.com/deeplink/agent?id={ID})")).as_deref(),
        Some(ID)
    );
    assert_eq!(find("aid-0123"), None);
    assert_eq!(find(&format!("https://example.com/deeplink/agent?id={ID}")), None);
    assert_eq!(find(&format!("https://cmux.com/deeplink/agent?id={ID}&id={ID}")), None);
    assert_eq!(find("https://cmux.com/deeplink/agent?harness=claude&session=a1"), None);
    assert_eq!(find("reviewer"), None);
}

#[test]
fn an_id_is_the_keyed_hash_of_host_harness_and_session() {
    // The same vector the private tool that mints these ids makes (HMAC-SHA256, 80 bits).
    let key = Key::from_bytes(b"0123456789abcdef");
    let id = key.id("Lane-Host", "claude", "s1");
    assert_eq!(id, "aid-6ca1e7736f56c73fb9b8");
    assert_ne!(id, key.id("lane-host", "codex", "s1"));
    assert_ne!(id, Key::from_bytes(b"fedcba9876543210").id("lane-host", "claude", "s1"));
}

#[cfg(unix)]
#[test]
fn a_key_others_can_read_is_not_used() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(KEY_FILE);
    std::fs::write(&path, "MDEyMzQ1Njc4OWFiY2RlZg==\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(Key::read(&path).is_some());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(Key::read(&path).is_none());
}
