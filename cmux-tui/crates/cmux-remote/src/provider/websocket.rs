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
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};
use url::Url;

use crate::link::{FrameLink, LinkError};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
    TransportProvider,
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

pub async fn connect_websocket(
    endpoint: &Url,
    maximum: usize,
) -> Result<TungsteniteWebSocketLink<MaybeTlsStream<tokio::net::TcpStream>>, LinkError> {
    let (socket, _) = connect_async(endpoint.as_str())
        .await
        .map_err(|error| LinkError::Transport(error.to_string()))?;
    set_no_delay(socket.get_ref())?;
    Ok(TungsteniteWebSocketLink::new(endpoint.as_str(), maximum, socket))
}

fn set_no_delay(stream: &MaybeTlsStream<tokio::net::TcpStream>) -> Result<(), LinkError> {
    let tcp = match stream {
        MaybeTlsStream::Plain(stream) => stream,
        MaybeTlsStream::Rustls(stream) => stream.get_ref().0,
        _ => return Ok(()),
    };
    tcp.set_nodelay(true).map_err(|error| LinkError::Transport(error.to_string()))
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
        let description = request.endpoint.to_string();
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
