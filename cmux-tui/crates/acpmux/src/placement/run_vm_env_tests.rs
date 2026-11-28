use super::*;
use std::ffi::OsString;

#[test]
fn identity_and_secrets_are_held_back_and_nothing_else() {
    for name in [
        "CMUX_VM_ID",
        "HOSTNAME",
        "SSH_AUTH_SOCK",
        "SSH_AGENT_PID",
        "GITHUB_TOKEN",
        "gh_token",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_ACCESS_KEY_ID",
        "OPENAI_API_KEY",
        "PGPASSWORD",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "NPM_CONFIG__AUTH",
        "XDG_RUNTIME_DIR",
    ] {
        assert!(dropped(OsStr::new(name)), "{name} is held back");
    }
    for name in [
        "PATH",
        "HOME",
        "USER",
        "LANG",
        "TERM",
        "RUSTFLAGS",
        "CARGO_TARGET_DIR",
        "GIT_AUTHOR_NAME",
        "KEYBOARD",
        "CMUX_CONFORMANCE_PROBE",
        "PWD",
    ] {
        assert!(!dropped(OsStr::new(name)), "{name} reaches the run VM");
    }
}

#[test]
fn every_other_variable_goes_byte_for_byte_and_held_ones_take_the_forks_value() {
    use std::os::unix::ffi::OsStringExt as _;
    let env: Vec<(OsString, OsString)> = vec![
        ("PATH".into(), "/a:/b".into()),
        ("ODD".into(), OsString::from_vec(b"x=\xff\ny".to_vec())),
        ("EMPTY".into(), "".into()),
        ("GITHUB_TOKEN".into(), "secret".into()),
        ("HOSTNAME".into(), "parent".into()),
    ];
    let (sent, held) = forward(env);
    assert_eq!(sent, vec![b"PATH=/a:/b".to_vec(), b"ODD=x=\xff\ny".to_vec(), b"EMPTY=".to_vec()]);
    assert_eq!(held, ["GITHUB_TOKEN", "HOSTNAME"]);
    let own = |k: &str| (k == "HOSTNAME").then(|| OsString::from("fork"));
    let got = fork_env(&sent, &held, own);
    assert_eq!(
        got,
        vec![
            ("PATH".into(), "/a:/b".into()),
            ("ODD".into(), OsString::from_vec(b"x=\xff\ny".to_vec())),
            ("EMPTY".into(), "".into()),
            ("HOSTNAME".into(), "fork".into()),
        ],
        "the token stays unset on the fork: it has none of its own"
    );
}

#[test]
fn every_rule_has_a_reason_and_is_upper_case() {
    for (rule, why) in DROPPED {
        assert!(!why.is_empty(), "{rule}");
        assert_eq!(*rule, rule.to_ascii_uppercase(), "rules match the upper-cased name");
    }
}
