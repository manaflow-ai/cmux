//! The machine login probe's reading (moved from the app's `CloudMachineLoginTests`).

use super::*;

#[test]
fn only_a_missing_or_rejected_login_is_replaced() {
    assert!(MachineLogin::None.needs_login());
    assert!(MachineLogin::Rejected.needs_login());
    assert!(!MachineLogin::Session.needs_login());
    assert!(!MachineLogin::Cached.needs_login());
    assert!(!MachineLogin::Working.needs_login());
}

#[test]
fn the_probes_word_is_the_answer_else_its_exit_code() {
    for login in [
        MachineLogin::None,
        MachineLogin::Session,
        MachineLogin::Cached,
        MachineLogin::Working,
        MachineLogin::Rejected,
    ] {
        assert_eq!(parse(0, &format!("{}\n", login.as_str())), login);
        // The word wins over the exit code, and surrounding blanks are not part of it.
        assert_eq!(parse(1, &format!(" \t{}\r\n", login.as_str())), login);
    }
    // An old probe's bare exit code, or noise: 0 is a login that stays, as before.
    assert_eq!(parse(0, ""), MachineLogin::Working);
    assert_eq!(parse(1, ""), MachineLogin::None);
    assert_eq!(parse(127, "python3: not found"), MachineLogin::None);
    assert_eq!(parse(0, "Working"), MachineLogin::Working);
    assert_eq!(parse(2, "Rejected"), MachineLogin::None);
}

#[test]
fn the_fingerprint_is_the_tokens_sha256_in_hex() {
    let token = b"sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789";
    let print = fingerprint(token);
    assert_eq!(print.len(), 64);
    assert!(print.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    assert!(!print.contains("sk-ant"));
    assert_eq!(
        fingerprint(b""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        fingerprint(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_ne!(print, fingerprint(b"sk-ant-oat01-0123456789zyxwvutsrqponmlkjihgfedcba"));
}

#[test]
fn the_wire_is_the_apps_shape() {
    let probe: Probe = serde_json::from_str(r#"{"exitCode":0,"stdout":"rejected\n"}"#).unwrap();
    assert_eq!(parse(probe.exit_code, &probe.stdout), MachineLogin::Rejected);
}

#[test]
fn a_manual_recovery_mints_a_new_login_only_when_the_machine_has_the_cached_one() {
    // The machine runs cmux's own cached token and its turn failed: that token is what the
    // provider refused, so the recovery asks for a new one.
    assert!(recovery_refreshes(Some(MachineLogin::Cached)));
    // Any other login on the machine: the cached token never reached it, so the recovery
    // installs the cached one and the person signs in again only when there is none.
    for login in [
        MachineLogin::None,
        MachineLogin::Session,
        MachineLogin::Working,
        MachineLogin::Rejected,
    ] {
        assert!(!recovery_refreshes(Some(login)), "{login:?}");
    }
    // A probe that did not answer: the recovery mints a new login, as before.
    assert!(recovery_refreshes(None));
}
