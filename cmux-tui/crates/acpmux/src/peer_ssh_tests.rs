use super::*;

/// ssh's failure class names the route's kind; a class that says nothing about it (a
/// reset, a close) names none.
#[test]
fn an_ssh_failure_class_names_the_routes_kind() {
    use crate::protocol::peer_state::DialFail;
    let kind = |stderr: &[u8]| dial_fail(reason(stderr));
    assert_eq!(kind(b"leo@box: Permission denied (publickey)."), Some(DialFail::Auth));
    assert_eq!(kind(b"Host key verification failed."), Some(DialFail::Auth));
    assert_eq!(kind(b"Connection timed out during banner exchange"), Some(DialFail::Timeout));
    assert_eq!(
        kind(b"ssh: connect to host box port 22: Operation timed out"),
        Some(DialFail::Timeout)
    );
    assert_eq!(
        kind(b"ssh: connect to host box port 22: Connection refused"),
        Some(DialFail::Refused)
    );
    assert_eq!(kind(b"ssh: Could not resolve hostname box: nodename"), Some(DialFail::Unreachable));
    assert_eq!(kind(b"connect to host box port 22: No route to host"), Some(DialFail::Unreachable));
    assert_eq!(kind(b"proxy dialer did not pass back a connection"), Some(DialFail::Unreachable));
    assert_eq!(kind(b"Connection reset by peer"), None);
    assert_eq!(dial_fail(None), None);
}

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

/// `ssh -W` to a port nothing listens on: ssh logged in, so this is not the machine refusing
/// ssh, and not a refused login.
#[test]
fn a_refused_forward_is_told_apart_from_a_refused_ssh() {
    use crate::protocol::peer_state::DialFail;
    let forward = b"channel 0: open failed: connect failed: Connection refused\n\
        stdio forwarding failed\n";
    assert_eq!(reason(forward), Some(FORWARD_REFUSED));
    assert_eq!(reason(b"stdio forwarding failed"), Some(FORWARD_REFUSED));
    assert_eq!(dial_fail(reason(forward)), Some(DialFail::Refused));
    assert!(!login_refused(reason(forward)));
    assert_eq!(
        reason(b"ssh: connect to host box port 22: Connection refused"),
        Some("SSH connection refused")
    );
}

/// A host key ssh refused is a refused login for the route kind, and its own backoff class.
#[test]
fn a_refused_host_key_is_its_own_class() {
    for stderr in
        [&b"Host key verification failed."[..], b"WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"]
    {
        assert!(host_key_refused(reason(stderr)), "{}", String::from_utf8_lossy(stderr));
    }
    for stderr in [
        &b"leo@box: Permission denied (publickey)."[..],
        b"No supported authentication methods available",
        b"ssh: connect to host box port 22: Connection refused",
    ] {
        assert!(!host_key_refused(reason(stderr)), "{}", String::from_utf8_lossy(stderr));
    }
}
