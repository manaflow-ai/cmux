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
        b"proxy dialer did not pass back a connection",
        b"",
    ] {
        assert!(!login_refused(reason(down)), "{}", String::from_utf8_lossy(down));
    }
}

#[test]
fn a_proxy_that_found_no_route_is_named_not_left_blank() {
    // What ssh prints when a relay ProxyCommand with ProxyUseFdpass reached none of a parked
    // machine's routes (its relay's own line first, then ssh's).
    let parked = b"fleet-relay: no route answered (exec nc box.internal 22)\n\
            mm_receive_fd: recvmsg: expected received 1 got 0\n\
            proxy dialer did not pass back a connection\n";
    assert_eq!(reason(parked), Some(NO_ROUTE));
    assert_eq!(reason(b"proxy dialer did not pass back a connection"), Some(NO_ROUTE));
    assert!(!NO_ROUTE.to_ascii_lowercase().contains("could not resolve"), "not this host's DNS");
}
