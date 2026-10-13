//! Dialers: each turns a signaling session into one reliable byte stream
//! that a [`crate::Link`] runs on. The phone dials; the Mac answers the
//! first signal of a new session.

use std::any::Any;
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, watch};

use crate::api::IceServer;
use crate::link::{Link, LinkConfig, Role};
use crate::signaling::{SessionEvent, SignalEnvelope, SignalPayload, SignalingClient, SignalingEvent};

pub mod webrtc;
pub mod wireguard;

/// The transport switch (PROTOCOL.md "Transport switch").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransportKind {
    WebRtc,
    WireGuard,
}

impl TransportKind {
    /// The transport a session's first signal asks for, if it starts one.
    pub fn for_first_signal(payload: &SignalPayload) -> Option<Self> {
        match payload {
            SignalPayload::WebrtcOffer { .. } => Some(Self::WebRtc),
            SignalPayload::WgInit { .. } => Some(Self::WireGuard),
            _ => None,
        }
    }

    pub fn dialer(self) -> Box<dyn Dialer> {
        match self {
            Self::WebRtc => Box::new(webrtc::WebRtcDialer),
            Self::WireGuard => Box::new(wireguard::WireGuardDialer),
        }
    }
}

/// How the link's bytes travel right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LinkPath {
    /// Peer to peer (host, server-reflexive or hole-punched UDP).
    Direct,
    /// Through the backend's WireGuard relay frames.
    Relay,
    /// Through a TURN server.
    Turn,
}

#[derive(Debug, Clone)]
pub struct DialOptions {
    /// ICE servers (from `GET /v1/ice`). STUN entries also serve WireGuard
    /// endpoint discovery. Empty means host candidates only.
    pub ice_servers: Vec<IceServer>,
    /// Offer loopback candidates and endpoints (tests and same-host runs).
    pub include_loopback: bool,
    /// Never offer or use addresses in 100.64.0.0/10 (Tailscale and other
    /// carrier-grade NAT overlays), so a test measures the public path.
    pub exclude_cgnat: bool,
    /// Relay only (the app's debug "simulate distant network" mode): skip
    /// every direct path. WebRTC uses ICE transport policy `relay` (only
    /// TURN candidates from `ice_servers`; a dial without a TURN server
    /// fails at once), and WireGuard sends no endpoints and ignores the
    /// peer's, so every datagram goes through the backend relay frames.
    pub relay_only: bool,
    /// Test support: WireGuard silently drops every UDP datagram this side
    /// sends, as when the OS refuses the route (macOS Local Network
    /// privacy) or a firewall drops outbound UDP. Inbound UDP still works.
    #[doc(hidden)]
    pub drop_outbound_udp: bool,
    /// Bound on the whole dial or answer.
    pub timeout: Duration,
}

impl Default for DialOptions {
    fn default() -> Self {
        Self {
            ice_servers: Vec::new(),
            include_loopback: false,
            exclude_cgnat: false,
            relay_only: false,
            drop_outbound_udp: false,
            timeout: Duration::from_secs(25),
        }
    }
}

/// The number of TURN URLs (`turn:` or `turns:`) among `servers`.
pub fn turn_url_count(servers: &[IceServer]) -> usize {
    servers
        .iter()
        .flat_map(|server| &server.urls)
        .filter(|url| url.starts_with("turn:") || url.starts_with("turns:"))
        .count()
}

/// Whether `ip` is in 100.64.0.0/10 (Tailscale and other CGNAT overlays).
pub fn is_cgnat(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            a == 100 && (64..128).contains(&b)
        }
        // Tailscale's IPv6 range, fd7a:115c:a1e0::/48.
        std::net::IpAddr::V6(v6) => v6.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

/// A byte stream a link can run on.
pub trait LinkStream: AsyncRead + AsyncWrite + Send + Unpin + 'static {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin + 'static> LinkStream for T {}

/// A dialed or answered transport.
pub struct Dialed {
    pub stream: Box<dyn LinkStream>,
    pub path: watch::Receiver<LinkPath>,
    /// Holds the peer connection or tunnel open.
    pub guard: Box<dyn Any + Send>,
}

#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum DialError {
    #[error("signaling: {0}")]
    Signaling(String),
    #[error("refused by the backend: {code}: {message}")]
    Refused { code: String, message: String },
    #[error("the peer ended the session: {0}")]
    Bye(String),
    #[error("timed out")]
    Timeout,
    #[error("transport: {0}")]
    Transport(String),
    #[error("unexpected signal: {0}")]
    Unexpected(String),
}

pub type DialFuture<'a> = Pin<Box<dyn Future<Output = Result<Dialed, DialError>> + Send + 'a>>;

/// One transport, both directions.
pub trait Dialer: Send + Sync {
    fn kind(&self) -> TransportKind;

    /// Phone side: start session `session_id` toward `mac` and return the
    /// stream once it is open.
    fn dial<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        mac: &'a str,
        session_id: &'a str,
        events: SessionEvents,
        options: &'a DialOptions,
    ) -> DialFuture<'a>;

    /// Mac side: answer `first`, the opening signal of a new session.
    fn answer<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        first: SignalEnvelope,
        events: SessionEvents,
        options: &'a DialOptions,
    ) -> DialFuture<'a>;
}

/// The signals and relay frames of one session, plus backend errors.
pub struct SessionEvents {
    pub session: mpsc::UnboundedReceiver<SessionEvent>,
    pub backend: tokio::sync::broadcast::Receiver<SignalingEvent>,
}

impl SessionEvents {
    pub fn subscribe(signaling: &SignalingClient, session_id: &str) -> Self {
        Self { backend: signaling.events(), session: signaling.subscribe(session_id) }
    }

    /// The next session event; a backend error or a disconnect is an error.
    pub async fn next(&mut self) -> Result<SessionEvent, DialError> {
        loop {
            tokio::select! {
                event = self.session.recv() => {
                    return match event {
                        Some(SessionEvent::Disconnected) | None => Err(DialError::Signaling("signaling socket closed".into())),
                        Some(event) => Ok(event),
                    };
                }
                event = self.backend.recv() => match event {
                    Ok(SignalingEvent::Error { code, message }) => return Err(DialError::Refused { code, message }),
                    Ok(SignalingEvent::Disconnected(reason)) => return Err(DialError::Signaling(reason)),
                    _ => {}
                },
            }
        }
    }
}

/// A connected link and how it travels.
pub struct Connected {
    pub link: Link,
    pub transport: TransportKind,
    pub path: watch::Receiver<LinkPath>,
    pub session_id: String,
}

/// Phone side: dial `mac` over `kind` and run a link on the result.
pub async fn connect(
    signaling: &SignalingClient,
    mac: &str,
    kind: TransportKind,
    options: &DialOptions,
    link_config: LinkConfig,
) -> Result<Connected, DialError> {
    if options.relay_only && kind == TransportKind::WebRtc && turn_url_count(&options.ice_servers) == 0 {
        return Err(DialError::Transport(
            "relay only needs a TURN server, and the service offered none".into(),
        ));
    }
    let session_id = uuid::Uuid::new_v4().to_string();
    let events = SessionEvents::subscribe(signaling, &session_id);
    let dialer = kind.dialer();
    let result =
        tokio::time::timeout(options.timeout, dialer.dial(signaling, mac, &session_id, events, options))
            .await;
    let dialed = match result {
        Ok(Ok(dialed)) => dialed,
        Ok(Err(error)) => {
            signaling.unsubscribe(&session_id);
            let _ = signaling.send_signal(mac, &session_id, SignalPayload::Bye { reason: error.to_string() });
            return Err(error);
        }
        Err(_) => {
            signaling.unsubscribe(&session_id);
            let _ = signaling.send_signal(mac, &session_id, SignalPayload::Bye { reason: "timeout".into() });
            return Err(DialError::Timeout);
        }
    };
    let link = Link::new(dialed.stream, Role::Phone, link_config, Some(dialed.guard));
    Ok(Connected { link, transport: kind, path: dialed.path, session_id })
}

/// Mac side: answer `first` and run a link on the result.
pub async fn answer(
    signaling: &SignalingClient,
    first: SignalEnvelope,
    events: SessionEvents,
    options: &DialOptions,
    link_config: LinkConfig,
) -> Result<Connected, DialError> {
    let kind = TransportKind::for_first_signal(&first.payload)
        .ok_or_else(|| DialError::Unexpected("first signal does not start a session".into()))?;
    let session_id = first.session_id.clone();
    let peer = first.from.clone();
    let dialer = kind.dialer();
    let result =
        tokio::time::timeout(options.timeout, dialer.answer(signaling, first, events, options)).await;
    let dialed = match result {
        Ok(Ok(dialed)) => dialed,
        Ok(Err(error)) => {
            let _ =
                signaling.send_signal(&peer, &session_id, SignalPayload::Bye { reason: error.to_string() });
            return Err(error);
        }
        Err(_) => {
            let _ =
                signaling.send_signal(&peer, &session_id, SignalPayload::Bye { reason: "timeout".into() });
            return Err(DialError::Timeout);
        }
    };
    let link = Link::new(dialed.stream, Role::Mac, link_config, Some(dialed.guard));
    Ok(Connected { link, transport: kind, path: dialed.path, session_id })
}
