//! cnx-ios link core (cnx-ios/PROTOCOL.md).
//!
//! - [`link`]: the transport-agnostic [`Link`]: framing, channel mux, ping,
//!   open and close.
//! - [`signaling`]: the backend signaling WebSocket client.
//! - [`api`]: the backend HTTP API.
//! - [`dial`]: the WebRTC and WireGuard dialers behind one [`dial::Dialer`]
//!   trait, selected by [`TransportKind`].

pub mod api;
pub mod dial;
pub mod frame;
pub mod link;
pub mod signaling;
#[cfg(feature = "testing")]
pub mod testing;

pub use dial::{Connected, DialError, DialOptions, LinkPath, TransportKind};
pub use link::{Channel, ChannelEvent, CloseInfo, IncomingChannel, Link, LinkConfig, LinkError, Role};
pub use signaling::SignalingClient;

/// Install rustls's ring provider once (HTTP and WebSocket TLS).
pub fn install_crypto_provider() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}
