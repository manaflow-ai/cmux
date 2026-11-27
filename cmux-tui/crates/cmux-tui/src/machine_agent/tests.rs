use super::*;

#[test]
fn parser_keeps_ordinary_launch_separate_and_bounds_port() {
    assert_eq!(parse_args(&[]).unwrap().session, "main");
    let parsed = parse_args(&[
        "--session".into(),
        "agents".into(),
        "--cloud-host".into(),
        "edge.example".into(),
        "--cloud-port".into(),
        "2222".into(),
    ])
    .unwrap();
    assert_eq!(parsed.session, "agents");
    assert_eq!(parsed.cloud_host, "edge.example");
    assert_eq!(parsed.cloud_port, Some(2222));
    assert!(parse_args(&["--cloud-port".into(), "0".into()]).is_err());
    assert!(parse_args(&["--headless".into()]).is_err());
}

#[test]
fn parser_errors_are_localized_without_exposing_transport_details() {
    let invalid = parse_args(&["--cloud-port".into(), "invalid".into()]).unwrap_err();
    assert_eq!(
        invalid.localized(&crate::localization::catalog_for_locale("en_US.UTF-8").machine_agent),
        "Invalid --cloud-port value: invalid"
    );
    assert_eq!(
        invalid.localized(&crate::localization::catalog_for_locale("ja_JP.UTF-8").machine_agent),
        "--cloud-port の値が無効です: invalid"
    );

    let missing = parse_args(&["--cloud-host".into()]).unwrap_err();
    assert_eq!(
        missing.localized(&crate::localization::catalog_for_locale("ja_JP.UTF-8").machine_agent),
        "オプション --cloud-host には値が必要です"
    );

    let unsafe_argument =
        parse_args(&["--cloud-port".into(), "22\u{1b}[31m\nspoof".into()]).unwrap_err();
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let message = unsafe_argument
            .localized(&crate::localization::catalog_for_locale(locale).machine_agent);
        assert!(!message.contains('\u{1b}'));
        assert!(!message.contains('\n'));
        assert!(message.contains(r"\u{1b}[31m\nspoof"));
    }
}

#[test]
fn registration_lock_conflict_has_an_actionable_localized_error() {
    for (locale, expected) in [
        (
            "en_US.UTF-8",
            "A machine agent is already sharing this session; stop it before starting another",
        ),
        (
            "ja_JP.UTF-8",
            "このセッションは別の machine-agent が共有中です。停止してからもう一度開始してください",
        ),
    ] {
        let messages = &crate::localization::catalog_for_locale(locale).machine_agent;
        let error = registration_lock_error(
            anyhow::Error::new(identity::RegistrationAlreadyRunning),
            messages,
        );
        assert_eq!(error.to_string(), expected);
    }
}

#[test]
fn pairing_code_is_written_only_to_the_verified_terminal_stream() {
    let messages = &crate::localization::catalog_for_locale("en_US.UTF-8").machine_agent;
    let mut terminal = Vec::new();
    let mut diagnostics = Vec::new();
    write_pairing_code(Some(&mut terminal), &mut diagnostics, messages, "secret-code").unwrap();
    assert!(String::from_utf8(terminal).unwrap().contains("secret-code"));
    assert!(!String::from_utf8(diagnostics).unwrap().contains("secret-code"));

    let mut diagnostics = Vec::new();
    write_pairing_code(None, &mut diagnostics, messages, "secret-code").unwrap();
    let diagnostics = String::from_utf8(diagnostics).unwrap();
    assert!(!diagnostics.contains("secret-code"));
    assert!(diagnostics.contains(messages.pairing_code_unavailable));
}

#[test]
fn missing_pairing_terminal_fails_before_agent_start_without_exposing_a_code() {
    let messages = &crate::localization::catalog_for_locale("en_US.UTF-8").machine_agent;
    let mut diagnostics = Vec::new();

    let error = require_pairing_terminal::<File>(None, &mut diagnostics, messages).unwrap_err();

    assert_eq!(error.kind(), io::ErrorKind::NotConnected);
    let diagnostics = String::from_utf8(diagnostics).unwrap();
    assert!(diagnostics.contains(messages.pairing_code_unavailable));
    assert!(!diagnostics.contains("secret-code"));
}
