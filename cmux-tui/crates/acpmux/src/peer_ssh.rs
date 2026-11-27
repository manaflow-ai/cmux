//! SSH diagnostics are untrusted (banners and ProxyCommand output can contain secrets).
//! Keep the failure class, never echo arbitrary stderr into host listings or the app.

use std::time::Duration;
use tokio::io::AsyncReadExt;

const LIMIT: usize = 8 * 1024;

/// The remote host answered TCP but not ssh's banner in time: it is slow (loaded, or a route that
/// wakes it), not gone, and the next attempts give it the long connect deadline (`Peer::ssh_connect_secs`).
pub(super) const BANNER_TIMEOUT: &str = "SSH connection timed out during the banner exchange";

/// The ssh config's ProxyCommand (a relay that tries each of the machine's routes, with
/// `ProxyUseFdpass`) answered on none of them: ssh says only "proxy dialer did not pass back a
/// connection". Nothing reached the machine; most often it is paused (a parked cloud VM, whose
/// internal name stops resolving), off or gone, and a message for it wakes it where a wake is set.
pub(super) const NO_ROUTE: &str =
    "SSH found no route to the machine (its proxy answered on none: paused, off or gone)";

/// ssh logged in, but nothing listens at the port `ssh -W` forwards to on the machine: its
/// daemon is down, or it serves on another port (it found its port taken at start and moved to a
/// free one, which its `listener.json` records). The peer reads that record and dials it
/// (`Peer::reread_listener`).
pub(super) const FORWARD_REFUSED: &str =
    "SSH logged in, but no acpmux daemon listens at the forwarded port";

pub(super) fn reason(bytes: &[u8]) -> Option<&'static str> {
    let text = String::from_utf8_lossy(bytes.get(..LIMIT).unwrap_or(bytes)).to_ascii_lowercase();
    [
        ("could not resolve hostname", "Could not resolve hostname (DNS lookup failed)"),
        ("host key verification failed", "Host key verification failed"),
        (
            "remote host identification has changed",
            "Host key verification failed (host key changed)",
        ),
        ("permission denied", "Permission denied (SSH authentication failed)"),
        ("no supported authentication methods", "SSH authentication failed (no supported methods)"),
        // `ssh -W`: "channel 0: open failed: connect failed: Connection refused". Before the
        // plain "connection refused", which is ssh's own TCP connect to the machine.
        ("open failed: connect failed", FORWARD_REFUSED),
        ("stdio forwarding failed", FORWARD_REFUSED),
        ("timed out during banner exchange", BANNER_TIMEOUT),
        ("connection timed out", "SSH connection timed out"),
        ("operation timed out", "SSH connection timed out"),
        ("connection refused", "SSH connection refused"),
        ("no route to host", "SSH connection failed (no route to host)"),
        ("network is unreachable", "SSH connection failed (network is unreachable)"),
        ("proxy dialer did not pass back a connection", NO_ROUTE),
        ("no route answered", NO_ROUTE),
        ("connection reset", "SSH connection reset"),
        ("connection closed", "SSH connection closed"),
    ]
    .into_iter()
    .find_map(|(needle, label)| text.contains(needle).then_some(label))
}

/// The route kind of an ssh failure class (`reason`'s label): a refused login or host key is
/// `auth`; None for a class that says nothing about the route (a reset, a close).
pub(super) fn dial_fail(reason: Option<&str>) -> Option<crate::protocol::peer_state::DialFail> {
    use crate::protocol::peer_state::DialFail;
    let reason = reason?;
    if login_refused(Some(reason)) {
        return Some(DialFail::Auth);
    }
    match reason {
        BANNER_TIMEOUT | "SSH connection timed out" => Some(DialFail::Timeout),
        "SSH connection refused" | FORWARD_REFUSED => Some(DialFail::Refused),
        NO_ROUTE
        | "Could not resolve hostname (DNS lookup failed)"
        | "SSH connection failed (no route to host)"
        | "SSH connection failed (network is unreachable)" => Some(DialFail::Unreachable),
        _ => None,
    }
}

/// Whether `reason` is the remote refusing this computer's login: a key or password it does not
/// take, or a host key that does not match. Another attempt soon fails the same way, and each one
/// counts against the remote's limit on failed logins (a ban tool blocks an address after a few).
pub(super) fn login_refused(reason: Option<&str>) -> bool {
    matches!(
        reason,
        Some(
            "Permission denied (SSH authentication failed)"
                | "SSH authentication failed (no supported methods)"
                | "Host key verification failed"
                | "Host key verification failed (host key changed)"
        )
    )
}

/// Whether `reason` is ssh refusing the machine's host key. ssh stops before it authenticates,
/// so no attempt counts against a ban tool's limit, and the cause is often brief (a relay that
/// reached another machine, a `known_hosts` being rewritten): its attempts wait a short bounded
/// backoff (`Backoff::host_key_refused`), not a refused login's hour.
pub(super) fn host_key_refused(reason: Option<&str>) -> bool {
    matches!(
        reason,
        Some("Host key verification failed" | "Host key verification failed (host key changed)")
    )
}

pub(super) fn describe(fallback: String, reason: Option<&str>) -> String {
    match reason {
        Some(reason) => format!("{fallback}: {reason}"),
        None => fallback,
    }
}

/// Drain for the lifetime of the SSH tunnel, retaining at most 8 KiB. Drop aborts the
/// reader on cancellation/replacement; finishing after a failed attempt has a short budget.
pub(super) struct Capture(tokio::task::JoinHandle<Option<&'static str>>);

impl Capture {
    pub(super) fn start(stderr: Option<tokio::process::ChildStderr>) -> Self {
        Self(tokio::spawn(async move {
            let mut stderr = stderr?;
            let mut saved = Vec::with_capacity(LIMIT);
            let mut chunk = [0u8; 1024];
            while let Ok(n) = stderr.read(&mut chunk).await {
                if n == 0 {
                    break;
                }
                let keep = n.min(LIMIT.saturating_sub(saved.len()));
                saved.extend_from_slice(chunk.get(..keep).unwrap_or_default());
            }
            reason(&saved)
        }))
    }

    pub(super) async fn finish(mut self) -> Option<&'static str> {
        tokio::time::timeout(Duration::from_millis(250), &mut self.0)
            .await
            .ok()
            .and_then(Result::ok)
            .flatten()
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[cfg(test)]
mod tests {
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
        assert_eq!(
            kind(b"ssh: Could not resolve hostname box: nodename"),
            Some(DialFail::Unreachable)
        );
        assert_eq!(
            kind(b"connect to host box port 22: No route to host"),
            Some(DialFail::Unreachable)
        );
        assert_eq!(
            kind(b"proxy dialer did not pass back a connection"),
            Some(DialFail::Unreachable)
        );
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
        for stderr in [
            &b"Host key verification failed."[..],
            b"WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!",
        ] {
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

    #[test]
    fn a_proxy_that_found_no_route_is_named_not_left_blank() {
        // What ssh prints when a relay ProxyCommand with ProxyUseFdpass reached none of a parked
        // machine's routes (its relay's own line first, then ssh's).
        let parked = b"fleet-relay: no route answered (exec nc box.internal 22)\n\
            mm_receive_fd: recvmsg: expected received 1 got 0\n\
            proxy dialer did not pass back a connection\n";
        assert_eq!(reason(parked), Some(NO_ROUTE));
        assert_eq!(reason(b"proxy dialer did not pass back a connection"), Some(NO_ROUTE));
        assert!(
            !NO_ROUTE.to_ascii_lowercase().contains("could not resolve"),
            "not this host's DNS"
        );
    }
}
