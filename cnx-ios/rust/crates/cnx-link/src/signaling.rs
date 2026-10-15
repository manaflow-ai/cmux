//! The signaling WebSocket (PROTOCOL.md "Signaling WebSocket"): JSON text
//! frames for hello, presence, signal and error, and binary WireGuard relay
//! frames. One task owns the socket; envelopes are routed to the dial or
//! answer that owns their `sessionId`. The first signal of a new session
//! (`webrtc-offer`, `wg-init`) opens that session's subscription atomically
//! and is handed to [`SignalingClient::next_session`] (a Mac answering
//! dials), so trickled signals that follow it are never lost. Other signals
//! for unknown sessions are dropped.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use bytes::Bytes;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use uuid::Uuid;

use crate::send_queue::{SendQueue, Signal};

/// A Mac as the backend reports it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MacPresence {
    pub device_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub last_seen_at: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_user_id: Option<String>,
}

/// `payload` of a `signal` message, tagged by `kind`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum SignalPayload {
    #[serde(rename = "webrtc-offer")]
    WebrtcOffer {
        sdp: String,
        /// Link lanes this side supports beyond the main stream (PROTOCOL.md
        /// "Lanes"); absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lanes: Vec<String>,
    },
    #[serde(rename = "webrtc-answer")]
    WebrtcAnswer {
        sdp: String,
        /// Link lanes this side supports beyond the main stream (PROTOCOL.md
        /// "Lanes"); absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lanes: Vec<String>,
    },
    #[serde(rename = "webrtc-ice")]
    WebrtcIce {
        candidate: String,
        #[serde(rename = "sdpMid", default)]
        sdp_mid: Option<String>,
        #[serde(rename = "sdpMLineIndex", default)]
        sdp_m_line_index: Option<u16>,
    },
    #[serde(rename = "wg-init")]
    WgInit {
        #[serde(rename = "publicKey")]
        public_key: String,
        endpoints: Vec<String>,
        #[serde(rename = "overlayIP")]
        overlay_ip: String,
        /// Link lanes this side supports beyond the main stream (PROTOCOL.md
        /// "Lanes"); absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lanes: Vec<String>,
        /// Which of `endpoints` are the dialer's TURN relayed addresses. The
        /// Mac sends plain UDP to them like any endpoint, so only this tells
        /// it that such a route is TURN, not direct (its path label); absent
        /// from older phones.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        relayed: Vec<String>,
    },
    #[serde(rename = "wg-resp")]
    WgResp {
        #[serde(rename = "publicKey")]
        public_key: String,
        endpoints: Vec<String>,
        #[serde(rename = "overlayIP")]
        overlay_ip: String,
        /// Link lanes this side supports beyond the main stream (PROTOCOL.md
        /// "Lanes"); absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lanes: Vec<String>,
    },
    #[serde(rename = "bye")]
    Bye {
        #[serde(default)]
        reason: String,
    },
}

/// One `signal` message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignalEnvelope {
    pub to: String,
    pub from: String,
    pub session_id: String,
    pub payload: SignalPayload,
    /// Stamped by the backend on forwarded signals: the Stack user id of the
    /// sender. Clients never set it (the backend overwrites it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_user_id: Option<String>,
}

/// Every JSON message on the socket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SignalMessage {
    Hello {
        you: String,
        #[serde(default)]
        macs: Vec<MacPresence>,
    },
    Presence {
        mac: MacPresence,
    },
    Signal(SignalEnvelope),
    Error {
        code: String,
        #[serde(default)]
        message: String,
        #[serde(default, rename = "sessionId")]
        session_id: Option<String>,
    },
}

/// A WireGuard relay frame: `[16 sessionId][16 peer deviceId][datagram]`.
/// On send the peer field is the destination; on receive the backend has
/// rewritten it to the sender.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayFrame {
    pub session_id: Uuid,
    pub peer: Uuid,
    pub datagram: Bytes,
}

impl RelayFrame {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(32 + self.datagram.len());
        out.extend_from_slice(self.session_id.as_bytes());
        out.extend_from_slice(self.peer.as_bytes());
        out.extend_from_slice(&self.datagram);
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < 32 {
            return None;
        }
        Some(Self {
            session_id: Uuid::from_slice(&bytes[..16]).ok()?,
            peer: Uuid::from_slice(&bytes[16..32]).ok()?,
            datagram: Bytes::copy_from_slice(&bytes[32..]),
        })
    }
}

/// How a relay frame is queued on the signaling socket (highest first; see
/// `send_queue`). The tunnel names the class of what its pacer sends
/// ([`SignalingClient::send_relay_as`]); otherwise [`relay_class`] infers
/// it from the WireGuard datagram's outer shape, its type and length.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum RelayClass {
    /// The "your UDP reaches me" marker, handshake messages, keepalives.
    Control,
    /// Small data datagrams: keystrokes, TCP ACKs, small requests.
    Input,
    /// Bulk data (large output, files), or full-size data of no known class.
    /// Shares the socket with [`RelayClass::Media`] by bytes; both drop.
    Bulk,
    /// Media datagrams (the media lane's RTP: browser and screen video).
    Media,
}

/// Encrypted data datagrams up to this size are [`RelayClass::Input`]: a
/// TCP segment with a few hundred bytes of payload, or a pure ACK.
pub const RELAY_INPUT_MAX: usize = 400;

impl RelayFrame {
    pub fn class(&self) -> RelayClass {
        relay_class(&self.datagram)
    }
}

/// The class of a WireGuard datagram on the relay.
pub fn relay_class(datagram: &[u8]) -> RelayClass {
    use cmux_transport::classify::WG_DATA_MIN_LEN;
    use cmux_transport::{DatagramClass, classify};
    match classify(datagram) {
        DatagramClass::WireGuardData if datagram.len() > RELAY_INPUT_MAX => RelayClass::Bulk,
        DatagramClass::WireGuardData if datagram.len() > WG_DATA_MIN_LEN => RelayClass::Input,
        _ => RelayClass::Control,
    }
}

/// A session a peer started: its first signal and the subscription that
/// receives everything after it.
#[derive(Debug)]
pub struct IncomingSession {
    pub first: SignalEnvelope,
    pub events: mpsc::UnboundedReceiver<SessionEvent>,
}

/// What a session subscription receives.
#[derive(Debug, Clone)]
pub enum SessionEvent {
    Signal(SignalEnvelope),
    Relay(Bytes),
    /// The signaling socket closed.
    Disconnected,
}

/// Events not owned by any session: hello, presence, errors, and signals of
/// sessions nobody subscribed to.
#[derive(Debug, Clone)]
pub enum SignalingEvent {
    Hello {
        you: String,
        macs: Vec<MacPresence>,
    },
    Presence(MacPresence),
    /// A backend refusal; `session_id` names the session it concerns, when
    /// the backend says.
    Error {
        code: String,
        message: String,
        session_id: Option<String>,
    },
    Disconnected(String),
}

#[derive(Debug, thiserror::Error)]
pub enum SignalingError {
    #[error("bad signaling URL: {0}")]
    BadUrl(String),
    #[error("signaling connect failed: {0}")]
    Connect(String),
    #[error("signaling socket is closed")]
    Closed,
}

/// How often an idle socket is pinged, and how long it may stay silent
/// (no frame at all, pongs included) before it counts as dead. A socket
/// kept warm across dials must not be a half-open TCP connection (a phone
/// that slept, a NAT that forgot it), or the next dial would wait out its
/// whole timeout.
pub const KEEPALIVE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(15);
pub const KEEPALIVE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(40);

struct Shared {
    device_id: String,
    /// Counts inbound frames (any kind); `probe` waits for it to move.
    inbound: tokio::sync::watch::Sender<u64>,
    opened: std::time::Instant,
    out: Arc<SendQueue>,
    sessions: Mutex<HashMap<String, mpsc::UnboundedSender<SessionEvent>>>,
    events: broadcast::Sender<SignalingEvent>,
    closed: Mutex<Option<String>>,
}

/// A connected signaling socket. Clone to share.
#[derive(Clone)]
pub struct SignalingClient {
    shared: Arc<Shared>,
    incoming: Arc<tokio::sync::Mutex<mpsc::UnboundedReceiver<IncomingSession>>>,
}

impl std::fmt::Debug for SignalingClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SignalingClient").field("device_id", &self.shared.device_id).finish_non_exhaustive()
    }
}

/// `https://host` → `wss://host/v1/teams/<team>/signal?deviceId=<id>`.
pub fn signal_url(base_url: &str, team_id: &str, device_id: &str) -> Result<String, SignalingError> {
    let base = base_url.trim_end_matches('/');
    let ws = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else if base.starts_with("ws://") || base.starts_with("wss://") {
        base.to_owned()
    } else {
        return Err(SignalingError::BadUrl(base_url.to_owned()));
    };
    Ok(format!("{ws}/v1/teams/{}/signal?deviceId={}", encode_segment(team_id), encode_segment(device_id)))
}

fn encode_segment(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

impl SignalingClient {
    /// Connect with `Authorization: Bearer <token>`.
    pub async fn connect(
        base_url: &str,
        token: &str,
        team_id: &str,
        device_id: &str,
    ) -> Result<Self, SignalingError> {
        crate::install_crypto_provider();
        let url = signal_url(base_url, team_id, device_id)?;
        let mut request = url.into_client_request().map_err(|e| SignalingError::BadUrl(e.to_string()))?;
        request.headers_mut().insert(
            "authorization",
            format!("Bearer {token}")
                .parse()
                .map_err(|_| SignalingError::BadUrl("token is not a header value".into()))?,
        );
        let (socket, _) = tokio_tungstenite::connect_async(request)
            .await
            .map_err(|e| SignalingError::Connect(e.to_string()))?;
        let (sink, mut source) = socket.split();
        let out = Arc::new(SendQueue::default());
        let (incoming_tx, incoming_rx) = mpsc::unbounded_channel();
        let shared = Arc::new(Shared {
            device_id: device_id.to_owned(),
            inbound: tokio::sync::watch::channel(0).0,
            opened: std::time::Instant::now(),
            out: Arc::clone(&out),
            sessions: Mutex::new(HashMap::new()),
            events: broadcast::channel(256).0,
            closed: Mutex::new(None),
        });
        let pinger = Arc::clone(&out);
        tokio::spawn(async move { out.write_out(sink).await });
        let reader_shared = Arc::clone(&shared);
        tokio::spawn(async move {
            let shared = reader_shared;
            let mut keepalive = tokio::time::interval(KEEPALIVE_INTERVAL);
            keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            keepalive.tick().await;
            let mut last_inbound = tokio::time::Instant::now();
            let reason = loop {
                let next = tokio::select! {
                    next = source.next() => next,
                    _ = keepalive.tick() => {
                        if last_inbound.elapsed() >= KEEPALIVE_TIMEOUT {
                            pinger.close();
                            break "signaling keepalive timed out".to_owned();
                        }
                        let _ = pinger.push_signal(Signal::Ping);
                        continue;
                    }
                };
                let message = match next {
                    Some(Ok(message)) => message,
                    Some(Err(error)) => break format!("signaling read failed: {error}"),
                    None => break "signaling socket closed".to_owned(),
                };
                last_inbound = tokio::time::Instant::now();
                shared.inbound.send_modify(|count| *count += 1);
                match message {
                    Message::Text(text) => shared.dispatch_text(&text, &incoming_tx),
                    Message::Binary(bytes) => shared.dispatch_relay(&bytes),
                    Message::Close(frame) => {
                        break format!(
                            "signaling closed by server{}",
                            frame.map(|f| format!(": {} {}", f.code, f.reason)).unwrap_or_default()
                        );
                    }
                    _ => {}
                }
            };
            // The writer waits on the queue, not on the socket: stop it, so
            // it releases the socket's write half.
            pinger.close();
            *shared.closed.lock().unwrap_or_else(PoisonError::into_inner) = Some(reason.clone());
            let sessions: Vec<_> = shared
                .sessions
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .drain()
                .map(|(_, tx)| tx)
                .collect();
            for tx in sessions {
                let _ = tx.send(SessionEvent::Disconnected);
            }
            let _ = shared.events.send(SignalingEvent::Disconnected(reason));
        });
        Ok(Self { shared, incoming: Arc::new(tokio::sync::Mutex::new(incoming_rx)) })
    }

    pub fn device_id(&self) -> &str {
        &self.shared.device_id
    }

    /// Whether `other` is a handle of this same socket.
    pub fn same_socket(&self, other: &SignalingClient) -> bool {
        Arc::ptr_eq(&self.shared, &other.shared)
    }

    /// When the socket opened.
    pub fn opened_at(&self) -> std::time::Instant {
        self.shared.opened
    }

    /// Whether the socket still answers: sends a WebSocket ping and waits
    /// up to `timeout` for any inbound frame. A socket that already closed
    /// is `false` at once.
    pub async fn probe(&self, timeout: std::time::Duration) -> bool {
        if self.closed_reason().is_some() {
            return false;
        }
        let mut inbound = self.shared.inbound.subscribe();
        inbound.borrow_and_update();
        if self.shared.out.push_signal(Signal::Ping).is_err() {
            return false;
        }
        matches!(tokio::time::timeout(timeout, inbound.changed()).await, Ok(Ok(())))
            && self.closed_reason().is_none()
    }

    /// `Some(reason)` once the socket closed.
    pub fn closed_reason(&self) -> Option<String> {
        self.shared.closed.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Hello, presence, error and disconnect events.
    pub fn events(&self) -> broadcast::Receiver<SignalingEvent> {
        self.shared.events.subscribe()
    }

    /// The next session a peer started (a Mac answering dials), already
    /// subscribed; `None` once the socket is closed. Drop or
    /// [`unsubscribe`](Self::unsubscribe) a session you refuse.
    pub async fn next_session(&self) -> Option<IncomingSession> {
        self.incoming.lock().await.recv().await
    }

    /// Route every later signal and relay frame of `session_id` to the
    /// returned receiver.
    pub fn subscribe(&self, session_id: &str) -> mpsc::UnboundedReceiver<SessionEvent> {
        let (tx, rx) = mpsc::unbounded_channel();
        if self.closed_reason().is_some() {
            let _ = tx.send(SessionEvent::Disconnected);
        }
        self.shared.sessions.lock().unwrap_or_else(PoisonError::into_inner).insert(session_id.to_owned(), tx);
        rx
    }

    pub fn unsubscribe(&self, session_id: &str) {
        self.shared.sessions.lock().unwrap_or_else(PoisonError::into_inner).remove(session_id);
    }

    /// Send `payload` to `to` in `session_id`.
    pub fn send_signal(
        &self,
        to: &str,
        session_id: &str,
        payload: SignalPayload,
    ) -> Result<(), SignalingError> {
        let message = SignalMessage::Signal(SignalEnvelope {
            to: to.to_owned(),
            from: self.shared.device_id.clone(),
            session_id: session_id.to_owned(),
            payload,
            from_user_id: None,
        });
        let text = serde_json::to_string(&message).expect("signal serializes");
        self.shared.out.push_signal(Signal::Text(text))
    }

    /// Close the socket. Sessions see `Disconnected`.
    pub fn close(&self) {
        self.shared.out.close();
    }

    /// Send one WireGuard datagram through the backend relay, queued by its
    /// [`RelayClass`] (inferred from its shape): behind every signal, and
    /// dropped (oldest first) when its class is past its bound.
    pub fn send_relay(&self, frame: &RelayFrame) -> Result<(), SignalingError> {
        self.send_relay_as(frame, frame.class())
    }

    /// [`send_relay`](Self::send_relay) in a class the sender knows.
    pub fn send_relay_as(&self, frame: &RelayFrame, class: RelayClass) -> Result<(), SignalingError> {
        self.shared.out.push_relay(frame.encode(), class)
    }

    /// Relay frames of `class` dropped because the socket could not keep up.
    pub fn relay_dropped(&self, class: RelayClass) -> u64 {
        self.shared.out.dropped(class)
    }
}

impl Shared {
    fn dispatch_text(&self, text: &str, incoming: &mpsc::UnboundedSender<IncomingSession>) {
        let message = match serde_json::from_str::<SignalMessage>(text) {
            Ok(message) => message,
            Err(error) => {
                tracing::debug!(%error, "ignoring signaling message");
                return;
            }
        };
        match message {
            SignalMessage::Hello { you, macs } => {
                let _ = self.events.send(SignalingEvent::Hello { you, macs });
            }
            SignalMessage::Presence { mac } => {
                let _ = self.events.send(SignalingEvent::Presence(mac));
            }
            SignalMessage::Error { code, message, session_id } => {
                let _ = self.events.send(SignalingEvent::Error { code, message, session_id });
            }
            SignalMessage::Signal(envelope) => {
                let mut sessions = self.sessions.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(tx) = sessions.get(&envelope.session_id) {
                    if tx.send(SessionEvent::Signal(envelope.clone())).is_err() {
                        sessions.remove(&envelope.session_id);
                    }
                    return;
                }
                if !matches!(
                    envelope.payload,
                    SignalPayload::WebrtcOffer { .. } | SignalPayload::WgInit { .. }
                ) {
                    tracing::debug!(
                        session = envelope.session_id,
                        "dropping a signal for an unknown session"
                    );
                    return;
                }
                let (tx, rx) = mpsc::unbounded_channel();
                sessions.insert(envelope.session_id.clone(), tx);
                drop(sessions);
                let _ = incoming.send(IncomingSession { first: envelope, events: rx });
            }
        }
    }

    fn dispatch_relay(&self, bytes: &[u8]) {
        let Some(frame) = RelayFrame::decode(bytes) else { return };
        let key = frame.session_id.to_string();
        let sessions = self.sessions.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(tx) = sessions.get(&key) {
            let _ = tx.send(SessionEvent::Relay(frame.datagram));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_shapes_match_the_contract() {
        let offer = SignalMessage::Signal(SignalEnvelope {
            to: "mac".into(),
            from: "phone".into(),
            session_id: "s".into(),
            payload: SignalPayload::WebrtcIce {
                candidate: "c".into(),
                sdp_mid: Some("0".into()),
                sdp_m_line_index: Some(0),
            },
            from_user_id: None,
        });
        let json: serde_json::Value = serde_json::to_value(&offer).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"type":"signal","to":"mac","from":"phone","sessionId":"s",
                "payload":{"kind":"webrtc-ice","candidate":"c","sdpMid":"0","sdpMLineIndex":0}})
        );
        let init: SignalPayload = serde_json::from_value(serde_json::json!(
            {"kind":"wg-init","publicKey":"k","endpoints":["1.2.3.4:5"],"overlayIP":"10.77.0.2"}))
        .unwrap();
        assert!(matches!(init, SignalPayload::WgInit { .. }));
        let with_relayed: SignalPayload = serde_json::from_value(serde_json::json!(
            {"kind":"wg-init","publicKey":"k","endpoints":["1.2.3.4:5","9.9.9.9:7"],"overlayIP":"10.77.0.2",
             "relayed":["9.9.9.9:7"]}))
        .unwrap();
        assert!(
            matches!(with_relayed, SignalPayload::WgInit { ref relayed, .. } if relayed == &["9.9.9.9:7"])
        );
        let hello: SignalMessage = serde_json::from_str(
            r#"{"type":"hello","you":"p","macs":[{"deviceId":"m","name":"Mac","online":true,"lastSeenAt":1}]}"#,
        )
        .unwrap();
        assert!(matches!(hello, SignalMessage::Hello { .. }));
    }

    #[test]
    fn relay_frame_round_trip() {
        let frame = RelayFrame {
            session_id: Uuid::new_v4(),
            peer: Uuid::new_v4(),
            datagram: Bytes::from_static(b"wg"),
        };
        assert_eq!(RelayFrame::decode(&frame.encode()), Some(frame));
        assert_eq!(RelayFrame::decode(&[0; 31]), None);
    }

    #[test]
    fn relay_classes_follow_the_datagram_shape() {
        let data = |len: usize| {
            let mut datagram = vec![0u8; len];
            datagram[0] = 4;
            datagram
        };
        assert_eq!(relay_class(&[0xff]), RelayClass::Control);
        let mut initiation = vec![0u8; 148];
        initiation[0] = 1;
        assert_eq!(relay_class(&initiation), RelayClass::Control);
        assert_eq!(relay_class(&data(32)), RelayClass::Control, "keepalive");
        assert_eq!(relay_class(&data(32 + 64)), RelayClass::Input, "a TCP ACK");
        assert_eq!(relay_class(&data(RELAY_INPUT_MAX)), RelayClass::Input);
        assert_eq!(relay_class(&data(RELAY_INPUT_MAX + 16)), RelayClass::Bulk);
        assert_eq!(relay_class(&data(1312)), RelayClass::Bulk, "a full-size segment or RTP packet");
    }

    #[test]
    fn signal_url_shapes() {
        assert_eq!(
            signal_url("https://api.example.dev/", "team 1", "dev").unwrap(),
            "wss://api.example.dev/v1/teams/team%201/signal?deviceId=dev"
        );
        assert!(signal_url("ftp://x", "t", "d").is_err());
    }
}
