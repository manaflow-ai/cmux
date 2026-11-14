use super::*;

#[test]
fn the_default_verifier_refuses_every_token() {
    let expected =
        Expected { host: "host_a", epoch: 1, service: Service::Daemon, peer_key: &[1; 32] };
    assert_eq!(DenyAllTokens.verify("anything", &expected), Err(TokenRefused::NoVerifier));
}

/// RED (security, decision 2): only the daemon's own config names a real
/// verifier. An absent, unknown or unreadable value means no real
/// verifier, and then every `check` is rejected.
#[test]
fn a_missing_unknown_or_unreadable_config_rejects_every_check() {
    use std::ffi::OsStr;
    #[cfg(unix)]
    let unreadable = {
        use std::os::unix::ffi::OsStrExt;
        OsStr::from_bytes(b"control_plane\xff").to_os_string()
    };
    #[cfg(not(unix))]
    let unreadable = std::ffi::OsString::from("control_plane ");
    let values = ["", "deny_all", "CONTROL_PLANE", "control_plane ", "true"];
    let values = values.iter().map(|value| Some(OsStr::new(*value)));
    for value in [None, Some(unreadable.as_os_str())].into_iter().chain(values) {
        let config = VerifierConfig::from_daemon_config(value);
        assert_eq!(config, VerifierConfig::DenyAll, "{value:?}");
        let checks = StampChecks::at_daemon_start(config).expect("deny-all always starts");
        assert!(!checks.records(), "{value:?}");
    }
    assert!(!StampChecks::default().records());
    assert_eq!(
        VerifierConfig::from_daemon_config(Some(OsStr::new("control_plane"))),
        VerifierConfig::ControlPlane
    );
}

/// RED (security, G1): on Linux a real verifier is refused at start
/// while the entry does not bind `check` to the supervised link child.
#[test]
fn token_issue_time_g1_linux_still_requires_the_link_child_binding() {
    let iat_only = CheckBinding { link_child: false, token_iat: true };
    assert_eq!(
        StampChecks::decide(VerifierConfig::ControlPlane, true, iat_only),
        Err(VerifierRefused::LinkChildNotBound)
    );
    assert_eq!(
        StampChecks::decide(VerifierConfig::ControlPlane, true, CheckBinding::BUILT),
        Err(VerifierRefused::LinkChildNotBound)
    );
    if cfg!(any(target_os = "linux", target_os = "android")) {
        assert_eq!(
            StampChecks::at_daemon_start(VerifierConfig::ControlPlane),
            Err(VerifierRefused::LinkChildNotBound)
        );
    }
}

/// RED (security, G2): on every OS a real verifier is refused at start
/// while the recorded check uses the read time instead of the token's
/// issue time. With both bindings the guards pass (they are the only
/// gate).
#[test]
fn token_issue_time_g2_requires_issued_time_and_the_built_entry_retains_it() {
    for linux in [false, true] {
        let child_only = CheckBinding { link_child: true, token_iat: false };
        assert_eq!(
            StampChecks::decide(VerifierConfig::ControlPlane, linux, child_only),
            Err(VerifierRefused::CheckTimeNotTokenIat)
        );
        let both = CheckBinding { link_child: true, token_iat: true };
        let checks = StampChecks::decide(VerifierConfig::ControlPlane, linux, both).unwrap();
        assert!(checks.records());
    }
    assert!(
        StampChecks::decide(VerifierConfig::ControlPlane, false, CheckBinding::BUILT)
            .unwrap()
            .records()
    );
    let checks = StampChecks::at_daemon_start(VerifierConfig::ControlPlane);
    if cfg!(any(target_os = "linux", target_os = "android")) {
        assert_eq!(checks, Err(VerifierRefused::LinkChildNotBound));
    } else {
        assert!(checks.unwrap().records());
    }
}

/// RED (G3): the start log line names the mode and the reason, and
/// never the raw value.
#[test]
fn token_issue_time_g3_start_log_names_mode_and_reason_but_never_the_value() {
    use std::ffi::OsStr;
    let line = |value: Option<&str>| {
        let choice = VerifierChoice::from_daemon_config(value.map(OsStr::new));
        mode_log_line(choice, &StampChecks::at_daemon_start(choice.config))
    };
    assert_eq!(
        line(None),
        "cmux link: token verifier mode deny_all: CMUX_LINK_TOKEN_VERIFIER is not set"
    );
    assert_eq!(
        line(Some("deny_all")),
        "cmux link: token verifier mode deny_all: named by CMUX_LINK_TOKEN_VERIFIER"
    );
    let unknown = line(Some("hunter2-secret"));
    assert_eq!(
        unknown,
        "cmux link: token verifier mode deny_all: CMUX_LINK_TOKEN_VERIFIER holds an \
             unrecognized value (not shown)"
    );
    assert!(!unknown.contains("hunter2"));
    let control = line(Some("control_plane"));
    if cfg!(any(target_os = "linux", target_os = "android")) {
        let refused = "cmux link: token verifier mode control_plane: refused at start: ";
        assert!(control.starts_with(refused), "{control}");
        assert!(control.contains("(G1)"), "{control}");
    } else {
        assert_eq!(
            control,
            "cmux link: token verifier mode control_plane: named by CMUX_LINK_TOKEN_VERIFIER"
        );
    }
    assert!(!line(None).contains('\n'));
}
