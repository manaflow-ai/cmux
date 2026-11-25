//! SSH diagnostics are untrusted (banners and ProxyCommand output can contain secrets).
//! Keep the failure class, never echo arbitrary stderr into host listings or the app.

use std::time::Duration;
use tokio::io::AsyncReadExt;

const LIMIT: usize = 8 * 1024;

/// The remote host answered TCP but not ssh's banner in time: it is slow (loaded, or a route that
/// wakes it), not gone, and the next attempts give it the long connect deadline (`Peer::ssh_connect_secs`).
pub(super) const BANNER_TIMEOUT: &str = "SSH connection timed out during the banner exchange";

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
        ("timed out during banner exchange", BANNER_TIMEOUT),
        ("connection timed out", "SSH connection timed out"),
        ("operation timed out", "SSH connection timed out"),
        ("connection refused", "SSH connection refused"),
        ("no route to host", "SSH connection failed (no route to host)"),
        ("network is unreachable", "SSH connection failed (network is unreachable)"),
        ("connection reset", "SSH connection reset"),
        ("connection closed", "SSH connection closed"),
    ]
    .into_iter()
    .find_map(|(needle, label)| text.contains(needle).then_some(label))
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
}
