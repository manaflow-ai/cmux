use super::*;

const COMMIT: &str = "5bdd4c9e4de3d3e93809a65135a039effc453c05";

fn pin(sha256: &str, commit: &str) -> cmux_remote::LinuxPin {
    cmux_remote::LinuxPin { sha256: sha256.to_owned(), commit: commit.to_owned() }
}

#[test]
fn a_pin_answers_its_commit_digest_and_target() {
    let digest = "b".repeat(64);
    assert_eq!(
        answer(Ok(Some(pin(&digest, COMMIT)))),
        json!({"ok": true, "commit": COMMIT, "sha256": digest, "target": "x86_64-unknown-linux-musl"})
    );
}

#[test]
fn no_pin_or_a_malformed_one_is_unavailable_or_rejected() {
    let none = answer(Ok(None));
    assert_eq!(none["ok"], json!(false));
    assert_eq!(none["error_code"], json!("machine_update_unavailable"));
    assert!(none["error"].as_str().is_some_and(|e| !e.is_empty()));

    for (sha256, commit) in
        [("short", COMMIT), (&*"b".repeat(64), "local"), (&*"B".repeat(64), COMMIT)]
    {
        let line = answer(Ok(Some(pin(sha256, commit))));
        assert_eq!(line["error_code"], json!("machine_update_payload_rejected"), "{line}");
    }

    let error = answer(Err(cmux_remote::ssh_bootstrap::BootstrapError::Configuration(
        "invalid published cmux-tui manifest".into(),
    )));
    assert_eq!(error["ok"], json!(false));
    assert_eq!(error["error_code"], json!("machine_update_unavailable"));
}

#[test]
fn only_a_bare_pin_is_usage() {
    assert_eq!(run(&["pin-extra".to_owned()]), 64);
    assert_eq!(run(&["--help".to_owned()]), 0);
}
