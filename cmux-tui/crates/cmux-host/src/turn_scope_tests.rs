use super::*;
use std::os::unix::fs::{PermissionsExt, symlink};

fn encoded(origin: &str, workspace: &str, machine: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "origin": origin, "workspace": workspace, "machine": machine,
    }))
    .unwrap()
}

#[test]
fn emits_only_exact_logical_scope_and_rejects_ambiguous_origins() {
    let scope = parse(&encoded("https://platform.example", "ws_one", "logical_machine")).unwrap();
    assert_eq!(scope.len(), 3);
    assert_eq!(scope[1], ("CMUX_PLATFORM_WORKSPACE_ID".into(), "ws_one".into()));
    assert_eq!(scope[2], ("CMUX_PLATFORM_MACHINE_ID".into(), "logical_machine".into()));
    for origin in [
        "http://platform.example",
        "https://user@platform.example",
        "https://platform.example/path",
        "https://platform.example?query",
        "https://platform.example#fragment",
    ] {
        assert!(parse(&encoded(origin, "ws_one", "logical_machine")).is_err());
    }
    for id in ["", "..", "a/b", "a\nb"] {
        assert!(parse(&encoded("https://platform.example", id, "logical_machine")).is_err());
        assert!(parse(&encoded("https://platform.example", "ws_one", id)).is_err());
    }
}

#[test]
fn requires_a_private_regular_file_and_protected_parent() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("scope.json");
    let owner = fs::metadata(dir.path()).unwrap().uid();
    assert!(read(&path, owner).unwrap().is_empty());
    fs::write(&path, encoded("https://platform.example", "ws_one", "logical_machine")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(read(&path, owner).unwrap().len(), 3);
    assert!(read(&path, owner.wrapping_add(1)).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(read(&path, owner).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let link = dir.path().join("link.json");
    symlink(&path, &link).unwrap();
    assert!(read(&link, owner).is_err());
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o777)).unwrap();
    assert!(read(&path, owner).is_err());
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(&path, vec![b' '; MAX_BYTES as usize + 1]).unwrap();
    assert!(read(&path, owner).is_err());
}
