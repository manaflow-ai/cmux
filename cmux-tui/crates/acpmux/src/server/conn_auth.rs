//! The proof a connection presented, one value per connection (`Conn::auth`).
//!
//! Lawrence, 2026-10-13: "remote connection must be authed, and should be
//! able to pretty much use yolo mode". Every remote connection proves a
//! credential before it gets any session or data; the mode rule may give an
//! authenticated connection every mode. That rule reads
//! [`ConnAuth::authenticated`], never the transport.
//!
//! Each transport sets the value from the proof it checked itself:
//! - the daemon socket (`stream.rs`): owner-only (0600) unix socket, or the
//!   same-user local socket on Windows: [`ConnAuth::LocalSocket`];
//! - the WebSocket listener (`mod.rs` `serve_ws_with`): the handshake checks
//!   the listener token before the upgrade, so every WebSocket connection
//!   starts at [`ConnAuth::ListenerToken`]; this launch's LocalApp token
//!   (`local_app.rs`) or peer token (`peer_auth.rs`) raises it. A paired
//!   machine's credential (`crate::pairing`) stands in for the listener
//!   token: [`ConnAuth::Device`] or [`ConnAuth::ReadOnlyDevice`].
//!
//! [`ConnAuth::None`] is the value of any connection no proof was checked
//! for. It gets no sessions and no data: every request is refused and no
//! record or notification is pushed to it (`mod.rs`).

use super::Origin;
use crate::rpc::RpcError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnAuth {
    /// No proof was checked. Refused: no sessions, no data.
    None,
    /// The daemon's own socket (owner-only file mode, same user).
    LocalSocket,
    /// The WebSocket listener token, checked at the handshake.
    ListenerToken,
    /// This launch's LocalApp token (`local_app.rs`), presented with the
    /// listener token at the upgrade. It outlives a listener token rotation.
    LocalApp,
    /// The listener token plus this launch's peer token (`peer_auth.rs`).
    PeerToken,
    /// A paired machine's `client` credential, in place of the listener
    /// token, from a loopback address (`crate::pairing`). Served as Peer.
    Device,
    /// A paired machine's `read-only` credential: served as Web, and every
    /// request goes through the read-only gate (`pairing::read_only`).
    ReadOnlyDevice,
}

impl ConnAuth {
    /// The connection proved a credential. False only for [`ConnAuth::None`].
    pub fn authenticated(self) -> bool {
        !matches!(self, ConnAuth::None)
    }

    /// The wire name (`initialize` `_meta.acpmux.auth`).
    pub fn as_str(self) -> &'static str {
        match self {
            ConnAuth::None => "none",
            ConnAuth::LocalSocket => "localSocket",
            ConnAuth::ListenerToken => "listenerToken",
            ConnAuth::LocalApp => "localApp",
            ConnAuth::PeerToken => "peerToken",
            ConnAuth::Device => "device",
            ConnAuth::ReadOnlyDevice => "readOnlyDevice",
        }
    }

    /// The proof a transport's checks give `origin`: the daemon socket's
    /// file mode, or the WebSocket handshake's listener token plus the
    /// proof that decided LocalApp or Peer. An in-process caller of
    /// `serve_connection_with` (tests, an embedding) vouches for it.
    pub fn proven_for(origin: Origin) -> Self {
        match origin {
            Origin::Local => ConnAuth::LocalSocket,
            Origin::Web => ConnAuth::ListenerToken,
            Origin::LocalApp => ConnAuth::LocalApp,
            Origin::Peer => ConnAuth::PeerToken,
        }
    }
}

/// The JSON-RPC error code of the refusal an unauthenticated connection gets.
pub const UNAUTHENTICATED: i64 = -32001;

/// The answer to the first request on an unauthenticated connection.
pub(super) fn refused() -> RpcError {
    RpcError::new(
        UNAUTHENTICATED,
        "acpmux: this connection is not authenticated; present the listener token, a LocalApp token or a peer token",
    )
}
