use super::*;

fn home(tag: &str, body: Option<&str>) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-rd-machine-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    identity::private_dir(&dir).unwrap();
    if let Some(body) = body {
        identity::write_private(&dir.join(CREDENTIAL_FILE), body.as_bytes()).unwrap();
    }
    dir
}

#[test]
fn a_joined_machine_has_a_credential() {
    let dir = home(
        "joined",
        Some(
            r#"{"credential":"cmm_x","machine_id":"m","team_id":"t","name":"vm-1","hub_origin":"https://p","last_heartbeat":null,"revoked":false,"wgPublicKey":""}"#,
        ),
    );
    let c = load(&dir).unwrap().unwrap();
    assert_eq!((c.credential.as_str(), c.name.as_str()), ("cmm_x", "vm-1"));
    assert!(!format!("{c:?}").contains("cmm_x"), "the credential is never printed");
}

#[test]
fn a_join_signs_in_at_its_own_deployments_hub() {
    let dir = home(
        "deployment",
        Some(
            r#"{"credential":"cmm_x","machine_id":"m","hub_origin":"https://cmux-platform-production.debussy.workers.dev"}"#,
        ),
    );
    let join = Join::read(&dir).unwrap().unwrap();
    assert_eq!(join.hub, "https://cmux-device-hub.debussy.workers.dev");
    assert_eq!(join.home, dir);
    let unknown = r#"{"credential":"cmm_x","hub_origin":"https://elsewhere.example"}"#;
    let e = Join::read(&home("deployment-unknown", Some(unknown))).unwrap_err();
    assert!(e.to_string().contains("no device hub serves"), "{e}");
    assert!(Join::read(&home("deployment-none", None)).unwrap().is_none());
}

#[test]
fn revoked_copied_empty_or_missing_records_sign_nothing_in() {
    assert!(load(&home("none", None)).unwrap().is_none());
    for body in [
        r#"{"credential":"cmm_x","revoked":true}"#,
        r#"{"credential":"cmm_x","cloned":true}"#,
        r#"{"credential":" "}"#,
    ] {
        assert!(load(&home("unusable", Some(body))).unwrap().is_none(), "{body}");
    }
}

#[test]
fn a_record_others_can_read_is_refused() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = home("open", Some(r#"{"credential":"cmm_x"}"#));
    std::fs::set_permissions(dir.join(CREDENTIAL_FILE), std::fs::Permissions::from_mode(0o644))
        .unwrap();
    assert!(load(&dir).is_err());
}
