/// A workflow runner (`acpmux workflow __run`) calls the daemon's Cloud in the daemon's
/// build space.
#[test]
fn a_workflow_runner_keeps_the_build_space() {
    assert!(super::RUNNER_ENV.contains(&"CMUX_BUILD_SPACE"));
}
