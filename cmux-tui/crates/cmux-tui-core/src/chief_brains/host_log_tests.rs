use super::*;

/// A brain's log does not grow for the brain's whole life: a launch moves a log over the
/// limit aside (one older log kept) and starts a new one.
#[test]
fn a_launch_rotates_a_host_log_over_the_limit() {
    let dir = std::env::temp_dir().join(format!("cmux-chief-log-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("host.log");
    let limit = usize::try_from(HOST_LOG_ROTATE_BYTES).unwrap();
    std::fs::write(&log, vec![b'x'; limit + 1]).unwrap();
    drop(open_host_log(&log).unwrap());
    assert_eq!(std::fs::metadata(&log).unwrap().len(), 0, "a new log starts");
    let kept = dir.join("host.log.1");
    assert_eq!(std::fs::metadata(&kept).unwrap().len(), HOST_LOG_ROTATE_BYTES + 1);

    // A log under the limit is appended to.
    std::fs::write(&log, b"small").unwrap();
    use std::io::Write as _;
    open_host_log(&log).unwrap().write_all(b" more").unwrap();
    assert_eq!(std::fs::read(&log).unwrap(), b"small more");
    let _ = std::fs::remove_dir_all(&dir);
}
