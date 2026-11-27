//! Dead-peer detection for the daemon's WebSocket listeners (`--ws` and the
//! CMXR `--remote-ws` listener).
//!
//! A peer that vanishes without closing (a laptop that slept, a NAT that
//! dropped the mapping, a pulled cable) leaves a half-open TCP connection:
//! the daemon keeps the connection, its queues and its attach taps until
//! TCP gives up, which can take hours. Each listener therefore sends a
//! WebSocket Ping after [`WebSocketKeepalive::ping_interval`] with no
//! inbound traffic and closes the connection once nothing at all (any
//! frame, including the Pong) has arrived for
//! [`WebSocketKeepalive::dead_peer_timeout`].
//!
//! RFC 6455 requires every peer to answer a Ping with a Pong, so the Ping is
//! transparent to every client: browsers, `URLSessionWebSocketTask` and
//! tungstenite answer it on their own while they read. A client that sends
//! data at least once per interval never sees a Ping. Nothing here needs a
//! flag or an environment variable; old supervisors get it with their
//! existing argv.

use std::time::Duration;

/// Inbound silence after which a listener sends a WebSocket Ping.
pub const WEBSOCKET_PING_INTERVAL: Duration = Duration::from_secs(25);

/// Inbound silence after which a listener closes the connection: three ping
/// intervals, so two Pings go unanswered first. Longer than the CMXR client
/// heartbeat timeout (15 s), so a client always notices a lost link first.
pub const WEBSOCKET_DEAD_PEER_TIMEOUT: Duration = Duration::from_secs(75);

/// Idle time before the kernel sends the first TCP keepalive probe on an
/// accepted socket: a second line for a connection whose WebSocket reader is
/// not polled (backpressure).
pub const TCP_KEEPALIVE_IDLE: Duration = Duration::from_secs(30);

/// Spacing of later TCP keepalive probes (the platform's probe count applies).
pub const TCP_KEEPALIVE_INTERVAL: Duration = Duration::from_secs(10);

/// When a daemon WebSocket listener pings an idle peer and when it gives up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WebSocketKeepalive {
    /// Inbound silence that triggers a Ping (and the spacing of later Pings).
    pub ping_interval: Duration,
    /// Inbound silence that closes the connection.
    pub dead_peer_timeout: Duration,
}

impl Default for WebSocketKeepalive {
    fn default() -> Self {
        Self {
            ping_interval: WEBSOCKET_PING_INTERVAL,
            dead_peer_timeout: WEBSOCKET_DEAD_PEER_TIMEOUT,
        }
    }
}

/// Turn on TCP keepalive ([`TCP_KEEPALIVE_IDLE`], [`TCP_KEEPALIVE_INTERVAL`])
/// on an accepted socket. Best effort: a platform that refuses the option
/// keeps the connection without it.
pub fn enable_tcp_keepalive<S>(socket: &S)
where
    for<'a> socket2::SockRef<'a>: From<&'a S>,
{
    let keepalive = socket2::TcpKeepalive::new()
        .with_time(TCP_KEEPALIVE_IDLE)
        .with_interval(TCP_KEEPALIVE_INTERVAL);
    let _ = socket2::SockRef::from(socket).set_tcp_keepalive(&keepalive);
}
