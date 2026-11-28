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
fn a_missing_screen_recording_grant_names_the_mac_and_the_item_to_turn_on() {
    use std::path::Path;
    let old = Path::new(
        "/Applications/cmux NIGHTLY.app/Contents/Library/cmux NIGHTLY Screen Sharing.app/Contents/MacOS/cmux-screen-sharing",
    );
    assert_eq!(listed_as(old), "cmux NIGHTLY Screen Sharing");
    let cua = Path::new("/Applications/cmux Computer Use.app/Contents/MacOS/cmux-screen-sharing");
    assert_eq!(listed_as(cua), "cmux Computer Use");
    assert_eq!(listed_as(Path::new("/usr/local/bin/cmux-rd")), "cmux Computer Use");
    let words = screen_recording_missing("cosmic-gray", "cmux Computer Use");
    assert!(words.starts_with("Screen Recording not granted on cosmic-gray."), "{words}");
    assert!(words.contains(
        "System Settings > Privacy & Security > Screen & System Audio Recording and turn on \"cmux Computer Use\""
    ));
    assert!(!host_name().is_empty());
}

#[test]
fn a_grant_that_lists_no_display_is_its_own_cause() {
    let words = no_display_listed("cosmic-gray", "cmux NIGHTLY Screen Sharing");
    assert!(words.contains("macOS listed no display to capture"), "{words}");
    assert!(words.contains("turn \"cmux NIGHTLY Screen Sharing\" off and on again"), "{words}");
    assert!(!words.contains("not granted"), "never read as a missing grant: {words}");
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
