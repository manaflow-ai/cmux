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
#[path = "peer_ssh_tests.rs"]
mod tests;
