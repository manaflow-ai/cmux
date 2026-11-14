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
mod tests;
