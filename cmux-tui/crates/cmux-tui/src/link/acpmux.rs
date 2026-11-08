//! The link's `acpmux` service: an overlay stream from a paired peer that
//! goes to this machine's acpmux daemon, on its loopback WebSocket listener.
//!
//! The link only carries bytes, as acpmux's own WireGuard bridge does
//! (`acpmux/src/wireguard.rs`): the stream reaches that listener and nothing
//! else (never acpmux's local socket), and acpmux checks its listener token
//! and peer proof on the WebSocket upgrade. Pairing adds no trust to acpmux.
//!
//! The listener is the one the running daemon recorded in its home's
//! `listener.json` (this user's file), and only after it proved itself: the
//! listener answers a fresh challenge under the record's key, which only the
//! daemon that wrote the record holds (`acpmux::listener_record`).
//! Nothing else names it: `websocket.listen` in config.json outlives the
//! daemon, and a stale port there could reach any local service bound to it
//! later. Without a proven listener the stream closes before any of the
//! peer's bytes are sent.

use std::path::PathBuf;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite};

use super::inbound::InboundRefused;

/// How long finding and proving acpmux's listener may take (it is on loopback).
const CONNECT_BOUND: Duration = Duration::from_secs(10);

/// Where an inbound `acpmux` stream goes.
#[derive(Debug, Clone)]
pub(super) enum AcpmuxTarget {
    /// This link serves no `acpmux` stream.
    #[cfg_attr(not(test), allow(dead_code))]
    Off,
    /// The live listener of the acpmux daemon running from this home.
    Live(PathBuf),
}

impl AcpmuxTarget {
    /// The acpmux home this user's daemon runs from (`ACPMUX_HOME`, else
    /// `~/.acpmux`).
    pub(super) fn from_acpmux_home() -> Self {
        Self::Live(acpmux::config::home())
    }
}

/// Carry `stream` to acpmux's live listener until both sides end.
pub(super) async fn hand_to_acpmux<S>(
    mut stream: S,
    target: &AcpmuxTarget,
) -> Result<(), InboundRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let AcpmuxTarget::Live(home) = target else { return Err(InboundRefused::AcpmuxUnavailable) };
    let mut local = acpmux::listener_record::connect_live(home, CONNECT_BOUND)
        .await
        .map_err(InboundRefused::AcpmuxNotLive)?;
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut local).await;
    Ok(())
}
