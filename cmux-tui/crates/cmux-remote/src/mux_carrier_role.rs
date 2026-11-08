//! The carrier role stamp on a `mux-control` stream ([`cmux_link::carrier_role`]):
//! before the person's first byte reaches the session daemon, the session
//! host writes the role its verified carrier grant signed and reads the
//! daemon's one reply. A carrier stream reaches the daemon as a same-user
//! unix connection, so without the stamp a teammate's stream would get the
//! owner's word on the daemon's owner checks.
//!
//! The reply is read one byte at a time, so no byte after it is consumed here
//! and the pump that follows sees the daemon's next line whole.

use std::time::Duration;

use cmux_link::carrier_role;
use cmux_link::token::VmKind;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// How long the daemon has to answer the stamp.
pub(crate) const STAMP_TIMEOUT: Duration = Duration::from_secs(5);

/// Why a stream was refused before any of the person's bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StampRefused {
    /// The daemon closed, timed out or answered something unreadable.
    Unavailable,
    /// The daemon did not take the stamp, and the grant is not the owner's:
    /// the stream would reach it with the owner's rights.
    NotTaken,
}

/// Stamp `vm_kind` on `socket`. An owner grant's stream goes on even when
/// the daemon refuses the stamp (an older daemon does not know it): an
/// unstamped unix connection already gets the owner's rights, so nothing is
/// lost. A teammate's, or a grant with no role, goes on only once the daemon
/// took the stamp.
pub(crate) async fn stamp<S>(socket: &mut S, vm_kind: Option<VmKind>) -> Result<(), StampRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let exchange = async {
        let mut line = carrier_role::line(vm_kind).into_bytes();
        line.push(b'\n');
        socket.write_all(&line).await.map_err(|_| StampRefused::Unavailable)?;
        socket.flush().await.map_err(|_| StampRefused::Unavailable)?;
        let mut reply = Vec::with_capacity(128);
        let mut byte = [0u8; 1];
        loop {
            match socket.read(&mut byte).await {
                Ok(1) if byte[0] == b'\n' => break,
                Ok(1) if reply.len() < carrier_role::MAX_REPLY_BYTES => reply.push(byte[0]),
                _ => return Err(StampRefused::Unavailable),
            }
        }
        Ok(reply)
    };
    let reply = tokio::time::timeout(STAMP_TIMEOUT, exchange)
        .await
        .map_err(|_| StampRefused::Unavailable)??;
    let reply: serde_json::Value =
        serde_json::from_slice(&reply).map_err(|_| StampRefused::Unavailable)?;
    let taken = reply.get("id").and_then(serde_json::Value::as_str)
        == Some(carrier_role::REQUEST_ID)
        && reply.get("ok").and_then(serde_json::Value::as_bool) == Some(true);
    if taken || vm_kind == Some(VmKind::Owner) { Ok(()) } else { Err(StampRefused::NotTaken) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, BufReader, duplex};

    /// A daemon that answers the first line with `reply`, then writes `after`.
    async fn exchange(vm_kind: Option<VmKind>, reply: &str) -> (Result<(), StampRefused>, String) {
        let (mut host, daemon) = duplex(8192);
        let reply = reply.to_owned();
        let daemon = tokio::spawn(async move {
            let mut daemon = BufReader::new(daemon);
            let mut line = String::new();
            daemon.read_line(&mut line).await.unwrap();
            // A refused stream is closed mid-reply; the rest goes nowhere.
            let _ = daemon.get_mut().write_all(reply.as_bytes()).await;
            let _ = daemon.get_mut().write_all(b"{\"next\":true}\n").await;
            line
        });
        let result = stamp(&mut host, vm_kind).await;
        if result.is_ok() {
            // The pump reads the daemon's next line whole.
            let mut next = String::new();
            BufReader::new(&mut host).read_line(&mut next).await.unwrap();
            assert_eq!(next, "{\"next\":true}\n");
        }
        drop(host);
        (result, daemon.await.unwrap())
    }

    const TAKEN: &str = "{\"id\":\"carrier-role\",\"ok\":true,\"data\":{}}\n";
    const REFUSED: &str = "{\"ok\":false,\"error\":\"bad_request\"}\n";

    /// What a daemon from before the stamp answers it: an unknown command,
    /// with every command it knows listed (cmux-tui-core's
    /// `carrier_role_tests` measures the real one).
    fn legacy_reply() -> String {
        let known: Vec<String> = (0..400).map(|n| format!("`command-{n:03}`")).collect();
        let error = format!(
            "bad request: unknown variant `carrier-role`, expected one of {}",
            known.join(", ")
        );
        let reply =
            serde_json::json!({"id": carrier_role::REQUEST_ID, "ok": false, "error": error});
        format!("{reply}\n")
    }

    #[tokio::test]
    async fn the_grants_role_is_the_first_line_the_daemon_reads() {
        for role in [Some(VmKind::Owner), Some(VmKind::Team), None] {
            let (result, line) = exchange(role, TAKEN).await;
            assert_eq!(result, Ok(()), "{role:?}");
            assert_eq!(line, format!("{}\n", carrier_role::line(role)));
        }
    }

    #[tokio::test]
    async fn a_teammates_stream_never_reaches_a_daemon_that_did_not_take_the_stamp() {
        for role in [Some(VmKind::Team), None] {
            assert_eq!(exchange(role, REFUSED).await.0, Err(StampRefused::NotTaken), "{role:?}");
            // A reply for another request is not the stamp's.
            let other = "{\"id\":\"x\",\"ok\":true}\n";
            assert_eq!(exchange(role, other).await.0, Err(StampRefused::NotTaken), "{role:?}");
        }
        // The owner loses nothing on an older daemon.
        assert_eq!(exchange(Some(VmKind::Owner), REFUSED).await.0, Ok(()));
    }

    #[tokio::test]
    async fn an_older_daemons_long_unknown_command_reply_is_read_whole() {
        let legacy = legacy_reply();
        assert!(legacy.len() > 6 * 1024, "{}", legacy.len());
        // The owner's stream goes on, and the pump sees the daemon's next line whole.
        assert_eq!(exchange(Some(VmKind::Owner), &legacy).await.0, Ok(()));
        for role in [Some(VmKind::Team), None] {
            assert_eq!(exchange(role, &legacy).await.0, Err(StampRefused::NotTaken), "{role:?}");
        }
    }

    #[tokio::test]
    async fn a_reply_past_the_bound_refuses_every_stream() {
        let long = format!("{{\"error\":\"{}\"}}\n", "x".repeat(carrier_role::MAX_REPLY_BYTES));
        for role in [Some(VmKind::Owner), Some(VmKind::Team)] {
            assert_eq!(exchange(role, &long).await.0, Err(StampRefused::Unavailable), "{role:?}");
        }
    }

    #[tokio::test]
    async fn a_daemon_that_closes_or_garbles_refuses_every_stream() {
        for role in [Some(VmKind::Owner), Some(VmKind::Team)] {
            assert_eq!(exchange(role, "not json\n").await.0, Err(StampRefused::Unavailable));
            let (mut host, daemon) = duplex(64);
            drop(daemon);
            assert_eq!(stamp(&mut host, role).await, Err(StampRefused::Unavailable));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_daemon_that_never_answers_times_out() {
        let (mut host, _daemon) = duplex(8192);
        assert_eq!(stamp(&mut host, Some(VmKind::Team)).await, Err(StampRefused::Unavailable));
    }
}
