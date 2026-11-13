//! The accept loop's decision for one accepted connection (#27698): a
//! process in one of the session's terminals holds a slot of the terminals'
//! lane, any other client holds a slot of the session alone.
//!
//! The decision reads the terminals' seats (`diagnostics/terminal_seats.rs`)
//! and nothing else. It takes no `Mux`: the session state and its lock are
//! out of its reach, so the accept loop cannot wait for a commit and cannot
//! answer from a stale set of terminals.

use std::sync::Arc;

use super::origin_gate::{peer_pid, peer_session_id};
use super::{ConnectionPermit, claim_watched_connection, claim_watched_terminal_connection};
use crate::diagnostics::{ClientKind, ConnectionStats};
use crate::platform::transport;

/// The slot of the connection on `stream`, or the lane that refused it at
/// its limit.
pub(super) fn admit(
    connections: &Arc<ConnectionStats>,
    stream: &dyn transport::Stream,
) -> Result<ConnectionPermit, ClientKind> {
    let key = stream.peer_process_key();
    admit_session(connections, stream, peer_session(key.as_deref()))
}

/// The process session of the peer that the kernel names with `key`. Nil
/// for no key, for a key that names no process, and for a process that is
/// gone: such a client is an outside one.
pub(super) fn peer_session(key: Option<&str>) -> Option<u32> {
    key.and_then(peer_pid).and_then(peer_session_id)
}

/// [`admit`] for a client in process session `session` (nil when the kernel
/// names no peer process).
pub(super) fn admit_session(
    connections: &Arc<ConnectionStats>,
    stream: &dyn transport::Stream,
    session: Option<u32>,
) -> Result<ConnectionPermit, ClientKind> {
    admit_session_by(connections, stream, session, parent_process)
}

/// The parent of process `pid`, as the seats ask for it
/// (`ConnectionStats::seated_terminal`): one read of that process.
pub(super) fn parent_process(pid: u32) -> Option<u32> {
    crate::process_resources::parent_process(pid)
}

/// [`admit_session`] with the read of a process's parent (`parent_of`).
///
/// A session with a seat is a terminal's, and so is a session whose leader
/// is the child of a host that starts a terminal: the connection is counted
/// in that terminal's share from its first moment, by its session. A
/// session with neither is an outside client's now; the lease keeps the
/// session, and a terminal that takes its seat for it later takes the
/// connection over (`ConnectionLease::admitted_outside`).
pub(super) fn admit_session_by(
    connections: &Arc<ConnectionStats>,
    stream: &dyn transport::Stream,
    session: Option<u32>,
    parent_of: impl FnOnce(u32) -> Option<u32>,
) -> Result<ConnectionPermit, ClientKind> {
    if let Some(session) = session
        && connections.seated_terminal(session, parent_of).is_some()
    {
        return claim_watched_terminal_connection(connections, stream, Some(session))
            .ok_or(ClientKind::Terminal);
    }
    let permit = claim_watched_connection(connections, stream).ok_or(ClientKind::Local)?;
    if let Some(session) = session {
        permit.lease().admitted_outside(session);
    }
    Ok(permit)
}
