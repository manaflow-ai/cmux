use super::*;

#[test]
fn a_mode_the_environment_names_wins() {
    assert!(should_set(None));
    assert!(!should_set(Some(std::ffi::OsStr::new("0"))));
    assert!(!should_set(Some(std::ffi::OsStr::new("1"))));
}

#[cfg(target_os = "macos")]
#[test]
fn the_child_gets_the_variable_and_its_marker() {
    if std::env::var_os(ENV).is_some() {
        return;
    }
    assert_eq!(child_env(), vec![(ENV, "1"), (MARKER_ENV, "1")]);
}

#[cfg(not(target_os = "macos"))]
#[test]
fn other_systems_leave_the_child_alone() {
    assert!(child_env().is_empty());
}
