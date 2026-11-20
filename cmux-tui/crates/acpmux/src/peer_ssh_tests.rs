use super::*;

#[test]
fn only_known_failure_classes_leave_the_stderr_capture() {
    assert_eq!(reason(b"banner: secret-token"), None);
    assert_eq!(
        reason(b"secret-token: Permission denied (publickey)."),
        Some("Permission denied (SSH authentication failed)")
    );
    let mut huge = vec![b'x'; LIMIT];
    huge.extend_from_slice(b"Permission denied");
    assert_eq!(reason(&huge), None, "diagnostics are bounded");
}

#[test]
fn a_refused_login_is_told_apart_from_an_unreachable_host() {
    for refused in [
        &b"leo@box: Permission denied (publickey,password)."[..],
        b"Received disconnect: No supported authentication methods available",
        b"Host key verification failed.",
        b"WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!",
    ] {
        assert!(login_refused(reason(refused)), "{}", String::from_utf8_lossy(refused));
    }
    for down in [
        &b"ssh: connect to host box port 22: Connection refused"[..],
        b"ssh: connect to host box port 22: Operation timed out",
        b"Connection timed out during banner exchange",
        b"ssh: Could not resolve hostname box",
        b"",
    ] {
        assert!(!login_refused(reason(down)), "{}", String::from_utf8_lossy(down));
    }
}
