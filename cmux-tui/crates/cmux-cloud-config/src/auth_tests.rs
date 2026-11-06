use std::collections::BTreeMap;

use super::*;

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

const HOME: &str = "/home/me";

fn reads(environment: &[(&str, &str)], files: &[(&str, &str)], secure: bool) -> Reads {
    Reads {
        environment: map(environment),
        home: HOME.to_owned(),
        files: map(files),
        explicit_file_secure: secure,
    }
}

fn credentials(email: &str, password: &str) -> Option<Credentials> {
    Some(Credentials { email: email.to_owned(), password: password.to_owned() })
}

#[test]
fn launch_keys_are_kept_and_the_process_value_wins() {
    let environment = map(&[("CMUX_DEV_AUTH_ACCOUNT", "a@x"), ("CMUX_TAG", "t"), ("PATH", "/bin")]);
    assert_eq!(launch_keys(&environment), map(&[("CMUX_DEV_AUTH_ACCOUNT", "a@x")]));
    let merged = auth_environment(
        &map(&[("CMUX_DEV_AUTH_ACCOUNT", "now@x")]),
        &map(&[("CMUX_DEV_AUTH_ACCOUNT", "then@x"), ("CMUX_DEV_AUTH_PROFILE", "agent")]),
    );
    assert_eq!(
        merged,
        map(&[("CMUX_DEV_AUTH_ACCOUNT", "now@x"), ("CMUX_DEV_AUTH_PROFILE", "agent")])
    );
}

#[test]
fn a_mask_keeps_the_first_letter_and_the_domain() {
    assert_eq!(mask("leo@example.com"), "l***@example.com");
    assert_eq!(mask("no-at-sign"), "***");
}

#[test]
fn the_paths_read_are_the_explicit_file_alone_or_the_ambient_ones() {
    assert_eq!(
        credential_paths(&map(&[("CMUX_AUTH_CREDENTIALS_FILE", "/c.env")]), HOME),
        ["/c.env"]
    );
    assert_eq!(
        credential_paths(&map(&[]), HOME),
        [
            "/home/me/.config/cmux/dev-account",
            "/home/me/.secrets/cmuxterm-dev.env",
            "/home/me/.secrets/cmux.env"
        ]
    );
}

#[test]
fn an_explicit_file_is_taken_as_given_unless_another_account_is_declared() {
    let file =
        "export CMUX_UITEST_STACK_EMAIL=\"agent@x\"\nCMUX_UITEST_STACK_PASSWORD='pw'\n# comment\n";
    let explicit = [("CMUX_AUTH_CREDENTIALS_FILE", "/c.env")];
    assert_eq!(
        decide(&reads(&explicit, &[("/c.env", file)], true)).credentials,
        credentials("agent@x", "pw")
    );
    // Not this user's 0600 regular file, or unreadable: nothing, and no refusal.
    assert_eq!(decide(&reads(&explicit, &[("/c.env", file)], false)), Decision::default());
    assert_eq!(decide(&reads(&explicit, &[], true)), Decision::default());
    let declared = [("CMUX_AUTH_CREDENTIALS_FILE", "/c.env"), ("CMUX_DEV_AUTH_ACCOUNT", "Owner@x")];
    assert_eq!(
        decide(&reads(&declared, &[("/c.env", file)], true)).refusal,
        Some(Refusal::AccountMismatch {
            found: "agent@x".to_owned(),
            declared: "Owner@x".to_owned()
        })
    );
}

#[test]
fn ambient_files_sign_in_only_the_declared_owner() {
    assert_eq!(decide(&reads(&[], &[], false)).refusal, Some(Refusal::NoDeclaredAccount));
    let other = "CMUX_DOGFOOD_STACK_EMAIL=someone@x\nCMUX_DOGFOOD_STACK_PASSWORD=p1\n";
    let owner = "CMUX_DOGFOOD_STACK_EMAIL=OWNER@x\nCMUX_DOGFOOD_STACK_PASSWORD=p2\n";
    let files = [
        ("/home/me/.config/cmux/dev-account", " owner@x\n"),
        ("/home/me/.secrets/cmuxterm-dev.env", other),
        ("/home/me/.secrets/cmux.env", owner),
    ];
    assert_eq!(decide(&reads(&[], &files, false)).credentials, credentials("OWNER@x", "p2"));
    let only_other = [files[0], files[1]];
    assert_eq!(
        decide(&reads(&[], &only_other, false)).refusal,
        Some(Refusal::AccountMismatch {
            found: "someone@x".to_owned(),
            declared: "owner@x".to_owned()
        })
    );
    // The environment is the last source, and the profile picks the key family.
    let exported = [("CMUX_UITEST_STACK_EMAIL", "owner@x"), ("CMUX_UITEST_STACK_PASSWORD", "p3")];
    assert_eq!(
        decide(&reads(&exported, &only_other, false)).credentials,
        credentials("owner@x", "p3")
    );
    let personal = [exported[0], exported[1], ("CMUX_DEV_AUTH_PROFILE", "personal")];
    assert!(decide(&reads(&personal, &only_other, false)).credentials.is_none());
    let unknown = [("CMUX_DEV_AUTH_PROFILE", "nobody"), ("CMUX_DEV_AUTH_ACCOUNT", "owner@x")];
    assert_eq!(decide(&reads(&unknown, &files, false)), Decision::default());
    // A half pair never mixes sources.
    let half = [
        ("/home/me/.config/cmux/dev-account", "owner@x"),
        ("/home/me/.secrets/cmux.env", "CMUX_DOGFOOD_STACK_EMAIL=owner@x\n"),
    ];
    let rest = [("CMUX_DOGFOOD_STACK_PASSWORD", "p4")];
    assert!(decide(&reads(&rest, &half, false)).credentials.is_none());
}

#[test]
fn a_call_acts_only_in_the_active_or_managed_team() {
    assert_eq!(team_refusal(None, Some("a"), None), None);
    assert_eq!(team_refusal(Some(" "), Some("a"), None), None);
    assert_eq!(team_refusal(Some("a"), Some("a"), None), None);
    assert_eq!(team_refusal(Some("b"), Some("a"), None), Some(TeamRefusal::NotActive));
    assert_eq!(team_refusal(Some("b"), None, None), Some(TeamRefusal::NotActive));
    assert_eq!(team_refusal(None, Some("a"), Some("m")), Some(TeamRefusal::Managed));
    assert_eq!(team_refusal(Some("a"), Some("m"), Some("m")), Some(TeamRefusal::Managed));
    assert_eq!(team_refusal(Some("m"), Some("m"), Some("m")), None);
}

#[test]
fn a_managed_device_uses_only_its_team() {
    let available = ["a".to_owned(), "m".to_owned()];
    assert_eq!(allowed_team_id(Some("a"), &available, None).as_deref(), Some("a"));
    assert_eq!(allowed_team_id(Some("a"), &available, Some("m")).as_deref(), Some("m"));
    assert_eq!(allowed_team_id(Some("a"), &available[..1], Some("m")), None);
}
