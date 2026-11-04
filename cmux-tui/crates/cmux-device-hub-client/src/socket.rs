//! The device's socket to its User DO (PROTOCOL.md, "WebSocket: User DO"):
//! pushes in, the exact `{"type":"ping"}` text frame out on an interval, and a
//! reconnect with jittered backoff whenever it drops.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt as _, StreamExt as _};
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::{broadcast, watch};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};

use crate::client::HubClient;

/// The keepalive frame; the hub's auto-response matches these bytes exactly.
pub const PING_FRAME: &str = r#"{"type":"ping"}"#;

/// A server push.
#[derive(Debug, Clone, PartialEq)]
pub enum HubPush {
    /// Refetch `GET /v1/devices`.
    DevicesChanged,
    PermissionsChanged {
        host_id: String,
    },
    RelaysChanged,
    /// To approvers: `{id, deviceId, deviceName, request, allowAlways, answerableUntil}`.
    ApprovalRequest {
        approval: Value,
    },
    /// To the asking device.
    ApprovalDecided {
        id: String,
        decision: String,
        digest: String,
        decider_id: String,
        sig: String,
    },
    /// To every other device: drop the question.
    ApprovalClosed {
        id: String,
        state: String,
        decision: Option<String>,
    },
    /// Mac Screen session messages and anything newer, as received.
    Other {
        kind: String,
        message: Value,
    },
}

impl HubPush {
    /// Decodes one text frame; `None` for `pong` and frames that are not a
    /// typed JSON object.
    pub fn parse(text: &str) -> Option<HubPush> {
        let message: Value = serde_json::from_str(text).ok()?;
        let kind = message.get("type")?.as_str()?.to_owned();
        let field = |name: &str| message.get(name).and_then(Value::as_str).map(str::to_owned);
        match kind.as_str() {
            "pong" => None,
            "devices.changed" => Some(HubPush::DevicesChanged),
            "relays.changed" => Some(HubPush::RelaysChanged),
            "permissions.changed" => {
                Some(HubPush::PermissionsChanged { host_id: field("hostId")? })
            }
            "approval.request" => {
                Some(HubPush::ApprovalRequest { approval: message.get("approval")?.clone() })
            }
            "approval.decided" => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Decided {
                    id: String,
                    decision: String,
                    digest: String,
                    decider_id: String,
                    sig: String,
                }
                let decided: Decided = serde_json::from_value(message).ok()?;
                Some(HubPush::ApprovalDecided {
                    id: decided.id,
                    decision: decided.decision,
                    digest: decided.digest,
                    decider_id: decided.decider_id,
                    sig: decided.sig,
                })
            }
            "approval.closed" => Some(HubPush::ApprovalClosed {
                id: field("id")?,
                state: field("state")?,
                decision: field("decision"),
            }),
            _ => Some(HubPush::Other { kind, message }),
        }
    }
}

/// The socket's state and pushes, in order.
#[derive(Debug, Clone, PartialEq)]
pub enum SocketEvent {
    Connecting,
    /// Open. Pushes have no backlog: refetch state now.
    Connected,
    /// The last attempt failed or the socket dropped; the next follows the backoff.
    Reconnecting(String),
    /// Another connection of this device took over (close code 4000): no reconnect.
    Replaced,
    /// The hub removed this device (close code 4001): no reconnect.
    Removed,
    /// The socket stopped (shut down).
    Disconnected,
    Push(HubPush),
}

/// Spacing between reconnects: exponential, capped and jittered.
#[derive(Debug, Clone)]
pub struct Backoff {
    pub initial: Duration,
    pub maximum: Duration,
    pub multiplier: f64,
    /// Fraction drawn at random, 0...1 (0.2: ±20%).
    pub jitter: f64,
    attempt: u32,
}

impl Backoff {
    pub fn new(initial: Duration, maximum: Duration) -> Backoff {
        Backoff { initial, maximum: maximum.max(initial), multiplier: 2.0, jitter: 0.2, attempt: 0 }
    }

    /// The delay before the next attempt; grows until `maximum`.
    pub fn next_delay(&mut self) -> Duration {
        let base = (self.initial.as_secs_f64() * self.multiplier.powi(self.attempt.min(62) as i32))
            .min(self.maximum.as_secs_f64());
        self.attempt = self.attempt.saturating_add(1);
        let spread = base * self.jitter * (random_unit() * 2.0 - 1.0);
        let low = self.initial.as_secs_f64() * (1.0 - self.jitter);
        Duration::from_secs_f64((base + spread).max(low).min(self.maximum.as_secs_f64()))
    }

    pub fn reset(&mut self) {
        self.attempt = 0;
    }
}

/// A uniform value in 0..1.
fn random_unit() -> f64 {
    let mut bytes = [0u8; 8];
    if ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).is_err() {
        return 0.5;
    }
    (u64::from_le_bytes(bytes) >> 11) as f64 / (1u64 << 53) as f64
}

/// Socket timing.
#[derive(Debug, Clone)]
pub struct SocketOptions {
    pub ping_interval: Duration,
    pub connect_timeout: Duration,
    pub backoff: Backoff,
    /// Events kept for a slow subscriber; one that falls behind further sees
    /// `Lagged` and refetches.
    pub event_capacity: usize,
}

impl Default for SocketOptions {
    fn default() -> SocketOptions {
        SocketOptions {
            ping_interval: Duration::from_secs(30),
            connect_timeout: Duration::from_secs(20),
            backoff: Backoff::new(Duration::from_secs(1), Duration::from_secs(60)),
            event_capacity: 256,
        }
    }
}

/// The running socket. Dropping it does not stop it; call [`shutdown`](Self::shutdown).
pub struct UserSocket {
    events: broadcast::Sender<SocketEvent>,
    stop: watch::Sender<bool>,
    task: JoinHandle<()>,
}

impl UserSocket {
    /// Starts connecting and keeps connecting until shut down.
    pub fn spawn(client: Arc<HubClient>, options: SocketOptions) -> UserSocket {
        let (events, _) = broadcast::channel(options.event_capacity.max(1));
        let (stop, stopped) = watch::channel(false);
        let task = tokio::spawn(run(client, options, events.clone(), stopped));
        UserSocket { events, stop, task }
    }

    /// Every event from now on.
    pub fn subscribe(&self) -> broadcast::Receiver<SocketEvent> {
        self.events.subscribe()
    }

    /// A sender others can subscribe from (the approver keeps one).
    pub fn events(&self) -> broadcast::Sender<SocketEvent> {
        self.events.clone()
    }

    /// Closes the socket and waits for the task to end.
    pub async fn shutdown(self) {
        let _ = self.stop.send(true);
        let _ = self.task.await;
    }
}

enum ServeEnd {
    Stopped,
    Closed { code: Option<u16>, reason: String },
}

async fn run(
    client: Arc<HubClient>,
    options: SocketOptions,
    events: broadcast::Sender<SocketEvent>,
    mut stopped: watch::Receiver<bool>,
) {
    let mut backoff = options.backoff.clone();
    // wakeup-allow: the reconnect loop; each pass waits on a connect, the socket's frames, or the backoff after a failure.
    loop {
        if *stopped.borrow() {
            break;
        }
        let _ = events.send(SocketEvent::Connecting);
        let failure = match connect(&client, options.connect_timeout).await {
            Ok(stream) => {
                let _ = events.send(SocketEvent::Connected);
                backoff.reset();
                match serve(stream, &options, &events, &mut stopped).await {
                    ServeEnd::Stopped => break,
                    ServeEnd::Closed { code: Some(4000), .. } => {
                        let _ = events.send(SocketEvent::Replaced);
                        return;
                    }
                    ServeEnd::Closed { code: Some(4001), .. } => {
                        let _ = events.send(SocketEvent::Removed);
                        return;
                    }
                    ServeEnd::Closed { reason, .. } => reason,
                }
            }
            Err(error) => error,
        };
        let _ = events.send(SocketEvent::Reconnecting(failure));
        tokio::select! {
            () = tokio::time::sleep(backoff.next_delay()) => {}
            () = stop_requested(&mut stopped) => break,
        }
    }
    let _ = events.send(SocketEvent::Disconnected);
}

/// Resolves once `stop` is true (or its sender is gone).
pub(crate) async fn stop_requested(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|stop| *stop).await;
}

type Stream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(client: &HubClient, timeout: Duration) -> Result<Stream, String> {
    let handshake = client.user_socket_handshake().await.map_err(|error| error.to_string())?;
    let mut request =
        handshake.url.as_str().into_client_request().map_err(|error| error.to_string())?;
    for (name, value) in handshake.headers {
        let name = HeaderName::from_bytes(name.as_bytes()).map_err(|error| error.to_string())?;
        let value = HeaderValue::from_str(&value).map_err(|error| error.to_string())?;
        request.headers_mut().insert(name, value);
    }
    match tokio::time::timeout(timeout, tokio_tungstenite::connect_async(request)).await {
        Ok(Ok((stream, _))) => Ok(stream),
        Ok(Err(error)) => Err(error.to_string()),
        Err(_) => Err("the socket did not open in time".to_owned()),
    }
}

async fn serve(
    stream: Stream,
    options: &SocketOptions,
    events: &broadcast::Sender<SocketEvent>,
    stopped: &mut watch::Receiver<bool>,
) -> ServeEnd {
    let (mut sink, mut source) = stream.split();
    let now = tokio::time::Instant::now();
    let first_ping = now.checked_add(options.ping_interval).unwrap_or(now);
    let mut ping = tokio::time::interval_at(first_ping, options.ping_interval);
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // wakeup-allow: each pass waits for a frame, the keepalive tick or shutdown.
    loop {
        tokio::select! {
            frame = source.next() => match frame {
                Some(Ok(Message::Text(text))) => {
                    if let Some(push) = HubPush::parse(text.as_str()) {
                        let _ = events.send(SocketEvent::Push(push));
                    }
                }
                Some(Ok(Message::Binary(data))) => {
                    if let Some(push) = std::str::from_utf8(&data).ok().and_then(HubPush::parse) {
                        let _ = events.send(SocketEvent::Push(push));
                    }
                }
                Some(Ok(Message::Close(frame))) => {
                    let code = frame.as_ref().map(|frame| u16::from(frame.code));
                    let reason = match &frame {
                        Some(frame) => format!("closed {} {}", u16::from(frame.code), frame.reason),
                        None => "closed".to_owned(),
                    };
                    return ServeEnd::Closed { code, reason };
                }
                Some(Ok(_)) => {}
                Some(Err(error)) => return ServeEnd::Closed { code: None, reason: error.to_string() },
                None => return ServeEnd::Closed { code: None, reason: "the socket closed".to_owned() },
            },
            _ = ping.tick() => {
                if let Err(error) = sink.send(Message::text(PING_FRAME)).await {
                    return ServeEnd::Closed { code: None, reason: error.to_string() };
                }
            }
            () = stop_requested(stopped) => {
                let _ = sink.send(Message::Close(None)).await;
                return ServeEnd::Stopped;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_approval_pushes() {
        let decided = HubPush::parse(
            r#"{"type":"approval.decided","id":"a","decision":"once","digest":"d","deciderId":"p","sig":"s"}"#,
        );
        assert_eq!(
            decided,
            Some(HubPush::ApprovalDecided {
                id: "a".into(),
                decision: "once".into(),
                digest: "d".into(),
                decider_id: "p".into(),
                sig: "s".into(),
            })
        );
        let closed = HubPush::parse(
            r#"{"type":"approval.closed","id":"a","state":"expired","decision":null}"#,
        );
        assert_eq!(
            closed,
            Some(HubPush::ApprovalClosed {
                id: "a".into(),
                state: "expired".into(),
                decision: None
            })
        );
        assert_eq!(HubPush::parse(r#"{"type":"devices.changed"}"#), Some(HubPush::DevicesChanged));
        assert_eq!(HubPush::parse(r#"{"type":"pong"}"#), None);
    }

    #[test]
    fn backoff_grows_and_caps() {
        let mut backoff = Backoff::new(Duration::from_secs(1), Duration::from_secs(4));
        backoff.jitter = 0.0;
        let delays: Vec<_> = (0..4).map(|_| backoff.next_delay()).collect();
        assert_eq!(delays, [1, 2, 4, 4].map(Duration::from_secs));
        backoff.reset();
        assert_eq!(backoff.next_delay(), Duration::from_secs(1));
    }
}
