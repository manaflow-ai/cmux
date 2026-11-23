use super::*;

#[test]
fn permission_probe_read_failure_emits_no_snapshot() {
    let mut output = Vec::new();
    let result = write_snapshot(&mut output, Err("framework unavailable".into()));
    assert!(result.is_err());
    assert!(output.is_empty());
}

#[test]
fn permission_probe_snapshot_keeps_grants_independent() {
    for (screen_recording, accessibility) in [(true, false), (false, true)] {
        let mut output = Vec::new();
        write_snapshot(&mut output, Ok(Permissions { screen_recording, accessibility }))
            .expect("snapshot");
        let value: serde_json::Value = serde_json::from_slice(&output).expect("JSON");
        assert_eq!(value["screen_recording"], screen_recording);
        assert_eq!(value["accessibility"], accessibility);
        assert_eq!(output.last(), Some(&b'\n'));
    }
}

#[test]
fn permission_probe_rejects_options_that_could_imply_prompting() {
    assert_eq!(crate::run_cli(&["permissions".into(), "--request".into(), "1".into()]), 2);
}

#[test]
fn a_request_names_exactly_one_known_grant() {
    assert_eq!(Grant::parse("screen-recording"), Some(Grant::ScreenRecording));
    assert_eq!(Grant::parse("accessibility"), Some(Grant::Accessibility));
    for word in ["", "all", "screen_recording", "Accessibility", "camera"] {
        assert_eq!(Grant::parse(word), None, "{word}");
    }
    assert_eq!(crate::run_cli(&["request-permission".into()]), 2);
    assert_eq!(crate::run_cli(&["request-permission".into(), "camera".into()]), 2);
    let two = ["request-permission".into(), "accessibility".into(), "screen-recording".into()];
    assert_eq!(crate::run_cli(&two), 2);
}

#[test]
fn a_launch_services_open_is_recognized_only_inside_a_bundle() {
    use std::path::Path;
    let helper = Path::new("/x/cmux Helper.app/Contents/MacOS/cmux-screen-sharing");
    let cli = Path::new("/usr/local/bin/cmux-rd");
    assert!(crate::is_launch_services_open(&[], helper));
    assert!(crate::is_launch_services_open(&["-psn_0_1234".into()], helper));
    assert!(!crate::is_launch_services_open(&["serve".into()], helper));
    assert!(!crate::is_launch_services_open(&[], cli));
}

#[cfg(not(target_os = "macos"))]
#[test]
fn permission_probe_unsupported_platform_emits_no_snapshot() {
    let mut output = Vec::new();
    assert!(write_snapshot(&mut output, read()).is_err());
    assert!(output.is_empty());
}
