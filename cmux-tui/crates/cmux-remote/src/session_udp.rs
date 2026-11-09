//! `session-udp-v1`: a UDP route for a daemon's sessions, next to the carrier.
//!
//! A client that is already in a session (through the carrier's relay) asks
//! the daemon for a UDP route with [`WorkspaceRequest::SessionUdpOffer`]: its
//! link key, its WireGuard key and the STUN servers to use. The daemon opens
//! one ephemeral UDP socket for the route, answers with its own keys and
//! candidates, and the client sends its candidates with
//! [`WorkspaceRequest::SessionUdpCandidates`]. Both keys cross the session's
//! authenticated stream, so the route trusts exactly what the session
//! trusts. The route carries ordinary cmux-remote links (each one Noise,
//! admitted like a relay link, by grant or resume), so the session moves
//! onto it with a resume and falls back to the carrier the same way.
//!
//! This module holds only the daemon's hook; the transport lives with the
//! binary that serves it (cmux-tui `session_udp`).
//!
//! [`WorkspaceRequest::SessionUdpOffer`]: cmux_remote_protocol::WorkspaceRequest::SessionUdpOffer
//! [`WorkspaceRequest::SessionUdpCandidates`]: cmux_remote_protocol::WorkspaceRequest::SessionUdpCandidates

use async_trait::async_trait;
use cmux_remote_protocol::{RpcError, SessionUdpAnswer, SessionUdpOffer};

/// What a daemon that serves `session-udp-v1` does with the two requests.
/// Installed with [`crate::workspace::WorkspaceService::set_session_udp`];
/// the capability is listed only once one is.
#[async_trait]
pub trait SessionUdpHandler: Send + Sync {
    /// Open a route for `offer` and answer with the daemon's half.
    async fn offer(&self, offer: SessionUdpOffer) -> Result<SessionUdpAnswer, RpcError>;

    /// The client's candidates for `route`.
    async fn candidates(&self, route: &str, candidates: Vec<String>) -> Result<(), RpcError>;
}
