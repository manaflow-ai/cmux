//! The WireGuard carrier: RTP and RTCP in UDP inside the tunnel (no SRTP;
//! WireGuard encrypts). Not built yet, so the dialer never offers the video
//! lane on WireGuard and the phone keeps the reliable path.

use super::MediaError;

/// The WireGuard media carrier for a dialed tunnel.
pub fn carrier() -> Result<std::sync::Arc<dyn super::MediaCarrier>, MediaError> {
    Err(MediaError::Unsupported)
}
