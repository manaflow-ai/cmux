use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use axum::extract::ws::{Message as AxumMessage, WebSocket};
use bytes::Bytes;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::handshake::client::Request as ClientRequest;
use tokio_tungstenite::tungstenite::http::header::{HeaderValue, USER_AGENT};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async_with_config};
use url::Url;

use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
    SupportedClientAuthModes, TransportProvider, sanitized_route,
};

pub struct TungsteniteWebSocketLink<S> {
    description: String,
    maximum: usize,
    sender: Mutex<SplitSink<WebSocketStream<S>, TungsteniteMessage>>,
    receiver: Mutex<SplitStream<WebSocketStream<S>>>,
}

impl<S> TungsteniteWebSocketLink<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    pub fn new(description: impl Into<String>, maximum: usize, socket: WebSocketStream<S>) -> Self {
        let (sender, receiver) = socket.split();
        Self {
            description: description.into(),
            maximum,
            sender: Mutex::new(sender),
            receiver: Mutex::new(receiver),
        }
    }
}

impl<S> fmt::Debug for TungsteniteWebSocketLink<S> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TungsteniteWebSocketLink")
            .field("description", &self.description)
            .field("maximum", &self.maximum)
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl<S> FrameLink for TungsteniteWebSocketLink<S>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync,
{
    fn description(&self) -> &str {
        &self.description
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.maximum
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        ensure_size(frame.len(), self.maximum)?;
        self.sender
            .lock()
            .await
            .send(TungsteniteMessage::Binary(frame))
            .await
            .map_err(|error| LinkError::Transport(error.to_string()))
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        loop {
            let next = self.receiver.lock().await.next().await;
            match next {
                Some(Ok(TungsteniteMessage::Binary(frame))) => {
                    ensure_size(frame.len(), self.maximum)?;
                    return Ok(Some(frame));
                }
                Some(Ok(TungsteniteMessage::Ping(payload))) => {
                    self.sender
                        .lock()
                        .await
                        .send(TungsteniteMessage::Pong(payload))
                        .await
                        .map_err(|error| LinkError::Transport(error.to_string()))?;
                }
                Some(Ok(TungsteniteMessage::Pong(_))) => {}
                Some(Ok(TungsteniteMessage::Close(_))) | None => return Ok(None),
                Some(Ok(_)) => {
                    return Err(LinkError::Protocol(
                        "cmux remote WebSocket accepts binary messages only".into(),
                    ));
                }
                Some(Err(error)) => return Err(LinkError::Transport(error.to_string())),
            }
        }
    }

    async fn close(&self) -> Result<(), LinkError> {
        self.sender
            .lock()
            .await
            .close()
            .await
            .map_err(|error| LinkError::Transport(error.to_string()))
    }
}

/// The `User-Agent` every direct WebSocket dial carries. Hosted ingress in front of
/// cmux Cloud machines (CloudFront on the branded machine domain) refuses upgrades
/// that omit the header, and tungstenite sends none by default. No `Origin` is set:
/// the daemon rejects browser-style upgrades that carry one.
pub const CLIENT_USER_AGENT: &str = concat!("cmux-tui/", env!("CARGO_PKG_VERSION"));

/// Builds the upgrade request for a direct dial, preserving the endpoint's query
/// (route tokens and lane parameters live there).
pub fn client_request(endpoint: &Url) -> Result<ClientRequest, LinkError> {
    let mut request = endpoint
        .as_str()
        .into_client_request()
        .map_err(|error| LinkError::Transport(error.to_string()))?;
    request.headers_mut().insert(USER_AGENT, HeaderValue::from_static(CLIENT_USER_AGENT));
    Ok(request)
}

pub async fn connect_websocket(
    endpoint: &Url,
    maximum: usize,
) -> Result<TungsteniteWebSocketLink<MaybeTlsStream<tokio::net::TcpStream>>, LinkError> {
    let description = sanitized_route(endpoint);
    let config =
        WebSocketConfig::default().max_message_size(Some(maximum)).max_frame_size(Some(maximum));
    let request = client_request(endpoint)?;
    let (socket, _) = connect_async_with_config(request, Some(config), true)
        .await
        .map_err(|error| LinkError::Transport(error.to_string()))?;
    Ok(TungsteniteWebSocketLink::new(description, maximum, socket))
}

pub struct AxumWebSocketLink {
    description: String,
    maximum: usize,
    sender: Mutex<SplitSink<WebSocket, AxumMessage>>,
    receiver: Mutex<SplitStream<WebSocket>>,
}

impl AxumWebSocketLink {
    pub fn new(description: impl Into<String>, maximum: usize, socket: WebSocket) -> Self {
        let (sender, receiver) = socket.split();
        Self {
            description: description.into(),
            maximum,
            sender: Mutex::new(sender),
            receiver: Mutex::new(receiver),
        }
    }
}

#[async_trait]
impl FrameLink for AxumWebSocketLink {
    fn description(&self) -> &str {
        &self.description
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.maximum
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        ensure_size(frame.len(), self.maximum)?;
        self.sender
            .lock()
            .await
            .send(AxumMessage::Binary(frame))
            .await
            .map_err(|error| LinkError::Transport(error.to_string()))
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        loop {
            match self.receiver.lock().await.next().await {
                Some(Ok(AxumMessage::Binary(frame))) => {
                    ensure_size(frame.len(), self.maximum)?;
                    return Ok(Some(frame));
                }
                Some(Ok(AxumMessage::Ping(_))) | Some(Ok(AxumMessage::Pong(_))) => {}
                Some(Ok(AxumMessage::Close(_))) | None => return Ok(None),
                Some(Ok(_)) => {
                    return Err(LinkError::Protocol(
                        "cmux remote WebSocket accepts binary messages only".into(),
                    ));
                }
                Some(Err(error)) => return Err(LinkError::Transport(error.to_string())),
            }
        }
    }

    async fn close(&self) -> Result<(), LinkError> {
        self.sender
            .lock()
            .await
            .close()
            .await
            .map_err(|error| LinkError::Transport(error.to_string()))
    }
}

fn ensure_size(actual: usize, maximum: usize) -> Result<(), LinkError> {
    if actual > maximum { Err(LinkError::FrameTooLarge { actual, maximum }) } else { Ok(()) }
}

#[derive(Debug, Clone)]
pub struct DirectWebSocketProvider {
    maximum: usize,
}

impl DirectWebSocketProvider {
    pub fn new(maximum: usize) -> Self {
        Self { maximum }
    }
}

#[async_trait]
impl TransportProvider for DirectWebSocketProvider {
    fn name(&self) -> &'static str {
        "direct-websocket"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["ws", "wss"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOnly
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        if !self.schemes().contains(&request.endpoint.scheme()) {
            return Err(ProviderError::UnsupportedScheme(request.endpoint.scheme().into()));
        }
        let evidence = if request.endpoint.scheme() == "wss" {
            CarrierEvidence::Tls {
                server_name: request.endpoint.host_str().unwrap_or_default().into(),
            }
        } else {
            CarrierEvidence::None
        };
        let description = sanitized_route(&request.endpoint);
        Ok(Arc::new(WebSocketLinkGroup {
            endpoint: request.endpoint,
            session: request.session,
            description,
            evidence,
            maximum: self.maximum,
            closed: AtomicBool::new(false),
        }))
    }
}

struct WebSocketLinkGroup {
    endpoint: Url,
    session: cmux_remote_protocol::SessionId,
    description: String,
    evidence: CarrierEvidence,
    maximum: usize,
    closed: AtomicBool,
}

#[async_trait]
impl LinkGroup for WebSocketLinkGroup {
    fn description(&self) -> &str {
        &self.description
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            carrier_encryption: self.endpoint.scheme() == "wss",
            ..ProviderCapabilities::WEBSOCKET
        }
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn transport_snapshot(&self) -> TransportSnapshot {
        TransportSnapshot {
            provider: "direct-websocket".into(),
            route: sanitized_route(&self.endpoint),
            selected_path: Some(TransportPathSnapshot {
                kind: TransportPathKind::Direct,
                remote: self.endpoint.host_str().map(str::to_owned),
                rtt_micros: None,
            }),
        }
    }

    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ProviderError::Transport("connection group is closed".into()));
        }
        let mut endpoint = self.endpoint.clone();
        endpoint.query_pairs_mut().extend_pairs([
            ("cmux_session", format!("{:?}", self.session)),
            ("cmux_lane", request.lane.to_string()),
            ("cmux_generation", request.generation.to_string()),
        ]);
        let link = connect_websocket(&endpoint, self.maximum).await?;
        Ok(Box::new(link))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn client_request_sets_user_agent_and_keeps_the_query() {
        let endpoint = Url::parse("wss://machine-1337.vm.cmux.sh/v1/link?bl_preview_token=t&cmux_lane=control").unwrap();
        let request = super::client_request(&endpoint).unwrap();
        assert_eq!(
            request.headers().get("user-agent").and_then(|value| value.to_str().ok()),
            Some(super::CLIENT_USER_AGENT)
        );
        assert!(request.headers().get("origin").is_none());
        assert_eq!(request.uri().query(), Some("bl_preview_token=t&cmux_lane=control"));
        assert_eq!(request.uri().host(), Some("machine-1337.vm.cmux.sh"));
    }

    use std::collections::BTreeMap;

    use cmux_remote_protocol::{LanePolicy, SessionId};
    use tokio_tungstenite::tungstenite::protocol::frame::Frame;
    use tokio_tungstenite::tungstenite::protocol::frame::coding::{Data, OpCode};

    use super::*;

    #[tokio::test]
    async fn provider_description_redacts_websocket_endpoint_secrets() {
        let endpoint = Url::parse(
            "wss://alice:password@example.test/capability?ticket=bearer-secret#fragment",
        )
        .unwrap();
        let group = DirectWebSocketProvider::new(65_535)
            .connect(ConnectRequest {
                endpoint,
                session: SessionId::ZERO,
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            })
            .await
            .unwrap();

        assert_eq!(group.description(), "wss://example.test/");
    }

    #[tokio::test]
    async fn connected_link_description_redacts_websocket_capabilities() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            let _ = socket.next().await;
        });
        let endpoint =
            Url::parse(&format!("ws://{address}/capability-path?ticket=query-secret#fragment"))
                .unwrap();

        let link = connect_websocket(&endpoint, 65_535).await.unwrap();

        assert_eq!(link.description(), sanitized_route(&endpoint));
        link.close().await.unwrap();
        server.await.unwrap();
    }

    #[tokio::test]
    async fn fragmented_oversize_message_is_rejected_by_websocket_codec() {
        const MAXIMUM: usize = 8;

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            socket
                .send(TungsteniteMessage::Frame(Frame::message(
                    Bytes::from_static(b"12345"),
                    OpCode::Data(Data::Binary),
                    false,
                )))
                .await
                .unwrap();
            socket
                .send(TungsteniteMessage::Frame(Frame::message(
                    Bytes::from_static(b"67890"),
                    OpCode::Data(Data::Continue),
                    true,
                )))
                .await
                .unwrap();
        });
        let endpoint = Url::parse(&format!("ws://{address}/v1/link")).unwrap();
        let link = connect_websocket(&endpoint, MAXIMUM).await.unwrap();

        let error = link.receive().await.expect_err("oversize fragmented message was accepted");
        assert!(
            matches!(
                error,
                LinkError::Transport(ref reason)
                    if reason.contains("Message too long") && reason.contains("> 8")
            ),
            "message reached cmux's post-reassembly size check instead of the WebSocket codec: {error}"
        );
        server.await.unwrap();
    }
}
