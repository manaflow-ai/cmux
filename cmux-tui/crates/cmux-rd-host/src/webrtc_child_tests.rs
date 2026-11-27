use super::*;

#[test]
fn a_relative_or_missing_executable_is_refused_before_anything_starts() {
    assert_eq!(run(&[]), 2);
    assert_eq!(run(&["cmux".into(), "--screen-stream-host".into()]), 2);
}

#[cfg(target_os = "macos")]
#[test]
fn only_a_plain_team_id_goes_into_the_requirement() {
    assert!(platform::plain_team("ABCDE12345"));
    assert!(!platform::plain_team("abcde12345"));
    assert!(!platform::plain_team("ABCDE\" or 1"));
}

#[cfg(target_os = "macos")]
#[test]
fn only_a_cmux_app_identifier_is_a_child() {
    assert!(platform::cmux_app_identifier("com.cmuxterm.app"));
    assert!(platform::cmux_app_identifier("com.cmuxterm.app.nightly"));
    assert!(platform::cmux_app_identifier("com.cmuxterm.app.debug.my-tag"));
    assert!(!platform::cmux_app_identifier("com.cmuxterm.appx"));
    assert!(!platform::cmux_app_identifier("com.cmuxterm.cli"));
    assert!(!platform::cmux_app_identifier("cmux-server-helper"));
}

#[cfg(target_os = "macos")]
#[test]
fn a_child_runs_on_this_process_stdio_and_its_status_comes_back() {
    // The test binary is ad hoc signed (no team): the child runs unchecked.
    assert_eq!(run(&["/bin/sh".into(), "-c".into(), "exit 7".into()]), 7);
    assert_eq!(run(&["/usr/bin/true".into()]), 0);
}
