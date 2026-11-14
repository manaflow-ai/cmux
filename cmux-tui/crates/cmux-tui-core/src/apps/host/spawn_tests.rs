use super::HostProcess;

/// A host binary that cannot run is a spawn error. The descriptor step
/// used to close `Command::spawn`'s exec-error pipe: the child aborted
/// and the spawn looked successful.
#[test]
fn a_host_binary_that_cannot_run_is_a_spawn_error() {
    let missing = std::path::Path::new("/nonexistent/cmux-app-host");
    let result = HostProcess::spawn(missing, &[], "missing", |_| {}, |_| {});
    let error = result.err().expect("a missing binary does not start");
    assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}");
}
