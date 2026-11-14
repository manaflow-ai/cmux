//! An `ssh://` peer redials as soon as its network is back, not when its backoff wait ends.
//!
//! An attempt that failed because the network was gone (ssh timed out connecting, no route,
//! the network unreachable, a DNS lookup that failed) leaves the peer in a backoff wait that
//! grows to a minute (`Backoff::CAP`). When the network came back during that wait, the link
//! stayed down for the rest of it, and the person saw "Reconnecting" over a working network:
//! 25.6 s after a 90 s outage, measured on a Linux host (2026-11-10). A client that asks for the
//! peer already cuts the wait (`peer_wanted.rs`); this covers the link nobody is asking for yet,
//! whose state the sidebar and the chat header show.
//!
//! During such a wait, every [`EVERY`] one TCP connect to the host's ssh port (a SYN and a close:
//! no ssh login, no process, nothing sent) asks whether the network is back, and the first one
//! that connects ends the wait. The host and port come from `ssh -G` once per peer (ssh's own
//! reading of its config; no network). A host reached through a ProxyCommand or ProxyJump has no
//! port of its own to try, so its waits run as before, as do waits after any other failure (a
//! refused login, a daemon that is down: its port answers while the link cannot come up) and the
//! hourly waits of a peer parked after a day down.

use std::time::Duration;

/// How often a wait after a network failure tries the host's ssh port.
pub(super) const EVERY: Duration = Duration::from_secs(2);

/// How long one try may take: a dropped network does not answer a SYN at all.
const TRY_FOR: Duration = Duration::from_secs(1);

/// How long `ssh -G` may take (it reads files; a `Match exec` may run a command).
const RESOLVE_FOR: Duration = Duration::from_secs(3);

/// Whether an ssh failure (`peer_ssh.rs` `reason`) says the network, not the host, failed.
pub(super) fn network_failure(reason: Option<&str>) -> bool {
    let Some(reason) = reason else { return false };
    reason == "SSH connection timed out"
        || reason.contains("no route to host")
        || reason.contains("network is unreachable")
        || reason.contains("DNS lookup failed")
}

/// The host and port ssh connects to for `destination`, from `ssh -G` output: None when it
/// goes through a ProxyCommand or ProxyJump (no direct port to try) or names none.
pub(super) fn direct_target(ssh_g: &str) -> Option<(String, u16)> {
    let mut host = None;
    let mut port = 22;
    for line in ssh_g.lines() {
        let Some((key, value)) = line.trim().split_once(' ') else { continue };
        let value = value.trim();
        match key.to_ascii_lowercase().as_str() {
            "hostname" => host = Some(value.to_owned()),
            "port" => port = value.parse().ok()?,
            "proxycommand" | "proxyjump" if !value.eq_ignore_ascii_case("none") => return None,
            _ => {}
        }
    }
    host.filter(|h| !h.is_empty()).map(|h| (h, port))
}

/// `ssh -G -- destination`, parsed by [`direct_target`].
pub(super) async fn resolve(
    mut ssh: tokio::process::Command,
    destination: &str,
) -> Option<(String, u16)> {
    let out = ssh
        .args(["-G", "--", destination])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(RESOLVE_FOR, out).await.ok()?.ok()?;
    out.status.success().then(|| direct_target(&String::from_utf8_lossy(&out.stdout))).flatten()
}

/// Whether a TCP connect to `host:port` succeeds within [`TRY_FOR`]; the connection is closed
/// at once.
pub(super) async fn answers(host: &str, port: u16) -> bool {
    tokio::time::timeout(TRY_FOR, tokio::net::TcpStream::connect((host, port)))
        .await
        .is_ok_and(|connected| connected.is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_proxied_host_has_no_direct_target() {
        let direct = "user cmux\nhostname 10.0.0.5\nport 2222\nproxycommand none\n";
        assert_eq!(direct_target(direct), Some(("10.0.0.5".into(), 2222)));
        assert_eq!(direct_target("hostname box\nproxyjump bastion\n"), None);
        assert_eq!(direct_target("hostname box\nproxycommand nc %h %p\n"), None);
        assert_eq!(direct_target("hostname box\n"), Some(("box".into(), 22)));
        assert_eq!(direct_target("port 22\n"), None);
    }

    #[test]
    fn only_network_failures_probe() {
        assert!(network_failure(Some("SSH connection timed out")));
        assert!(network_failure(Some("SSH connection failed (no route to host)")));
        assert!(network_failure(Some("SSH connection failed (network is unreachable)")));
        assert!(network_failure(Some("Could not resolve hostname (DNS lookup failed)")));
        assert!(!network_failure(Some("SSH connection refused")));
        assert!(!network_failure(Some("Permission denied (SSH authentication failed)")));
        assert!(!network_failure(Some(super::super::ssh_errors::BANNER_TIMEOUT)));
        assert!(!network_failure(None));
    }

    #[tokio::test]
    async fn a_port_answers_once_something_listens_there() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        assert!(!answers("127.0.0.1", port).await, "nothing listens yet");
        let _listener = std::net::TcpListener::bind(("127.0.0.1", port)).unwrap();
        assert!(answers("127.0.0.1", port).await, "the network is back");
    }
}
