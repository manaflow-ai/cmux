//! The Peer origin: another acpmux daemon of the same user, connected over
//! the WebSocket listener. The dashboard token alone never proves a peer:
//! every Web client (the dashboard page, a paired device) holds it. A
//! connection is `Origin::Peer` only when its upgrade request carries BOTH
//! the dashboard token (checked by the handshake, as for every connection)
//! and exactly one `x-acpmux-peer-token` header equal to this launch's peer
//! token, compared in constant time. Anything else (no header, a wrong or
//! empty value, two headers, a value in the first frame or the query) stays
//! `Origin::Web`.
//!
//! Transport (PEER-ORIGIN-TRANSPORT): the connection must also come from a
//! loopback address, the end of an `ssh -W` tunnel or of a TLS terminator on
//! this machine. The listener itself has no TLS, so a plain `ws://`
//! connection from another address stays `Origin::Web` even with the right
//! token: that token crossed a network in clear. Connecting daemons never
//! send it over such a connection (`peer::carries_peer_token`).
//!
//! The peer token is 32 random bytes made at every daemon start, kept only
//! in `ACPMUX_HOME/run/peer.token` (mode 0600, created with `O_EXCL` and
//! `O_NOFOLLOW` in a private directory, removed at stop), and never
//! returned by any RPC. A connecting daemon reads it over the same ssh
//! access it already uses for the dashboard token (`peer.rs`), or takes it
//! from its local config (`peers.<name>.peerToken`, unix socket only).

use std::path::{Path, PathBuf};

/// The upgrade request header that carries the peer token.
pub const HEADER: &str = "x-acpmux-peer-token";

/// Where the peer token of `home` lives.
pub fn token_path(home: &Path) -> PathBuf {
    home.join("run").join("peer.token")
}

/// This launch's peer token.
pub struct PeerAuth {
    token: String,
    path: PathBuf,
}

impl PeerAuth {
    /// Make this launch's token (`local_app::create_secret`).
    pub fn create(home: &Path) -> anyhow::Result<Self> {
        let path = token_path(home);
        let token = super::local_app::create_secret(&path)?;
        Ok(Self { token, path })
    }

    /// Whether an upgrade request (which passed the dashboard token check)
    /// from `from` with these `x-acpmux-peer-token` values proves a peer: a
    /// loopback address, and exactly one value equal to this launch's token.
    pub fn is_peer(&self, from: std::net::SocketAddr, presented: &[String]) -> bool {
        let token = match presented {
            [one] => !one.is_empty() && cmux_local_auth::tokens_match(one, &self.token),
            _ => false,
        };
        token && from.ip().to_canonical().is_loopback()
    }

    /// The file this launch's token is in (removed when the daemon stops).
    pub fn path(&self) -> &Path {
        &self.path
    }
}
