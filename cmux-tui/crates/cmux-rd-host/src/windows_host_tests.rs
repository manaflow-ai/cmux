use super::*;

#[test]
fn a_uniform_frame_reads_as_one_color() {
    assert_eq!(distinct_pixels(&[0u8; 64]), 1);
    assert_eq!(distinct_pixels(&[]), 0);
    let mixed: Vec<u8> = (0..64u8).flat_map(|i| [i, i, i, 0]).collect();
    assert_eq!(distinct_pixels(&mixed), 64);
    let black = CaptureCheck {
        backend: "gdi".into(),
        width: 4,
        height: 2,
        distinct: 1,
        at_ms: 0,
        error: None,
    };
    assert!(capture_line(&black).contains("one color"));
}

#[test]
fn usage_errors_and_unknown_options() {
    assert_eq!(run_cli(&["bogus".into()]), 2);
    assert_eq!(run_cli(&[]), 2);
    assert_eq!(run_cli(&["status".into(), "--nope".into(), "x".into()]), 1);
    assert_eq!(run_cli(&["run".into(), "--display".into(), ":0".into()]), 1);
    let a = Args::parse(&["enable".into(), "--allow-control".into()]).unwrap();
    assert!(a.flag("allow-control"));
    assert!(Args::parse(&["--scope".into()]).is_err());
}

#[test]
fn fatal_hub_errors_name_the_command_that_fixes_them() {
    for (code, next) in [
        ("device_removed", "cmux-rd windows-host enable"),
        ("device_key_mismatch", "cmux-rd windows-host enable"),
        ("not_anchored", "cmux-rd windows-host share on"),
    ] {
        let e: Box<dyn std::error::Error + Send + Sync> =
            HubError { status: 403, code: code.into(), message: "m".into() }.into();
        let fatal = Fatal::from_hub(&*e).unwrap_or_else(|| panic!("{code} is not fatal"));
        assert!(fatal.to_string().contains(next), "{code}: {fatal}");
    }
    let transient: Box<dyn std::error::Error + Send + Sync> =
        HubError { status: 503, code: "unavailable".into(), message: "m".into() }.into();
    assert!(Fatal::from_hub(&*transient).is_none());
}

#[test]
fn control_is_shared_only_with_allow_control() {
    assert_eq!(shares_line(&Ok(LocalConsent { view: true, full: true })), "view and control");
    assert_eq!(shares_line(&Ok(LocalConsent { view: true, full: false })), "view only");
    assert!(shares_line(&Err("missing".into())).starts_with("nothing shared"));
    // The consent this host serves with: SendInput applies input, so `full` is control.
    assert_eq!(LocalConsent { view: true, full: true }.serve("full", true), Some(false));
    assert_eq!(LocalConsent { view: true, full: false }.serve("full", true), None);
    assert_eq!(LocalConsent { view: true, full: false }.serve("view", true), Some(true));
}
