//! WebSocket adapter (tokio-tungstenite) for pages, and a provider listener
//! that applies the localhost Host/Origin rule (cmux-local-auth) before the
//! upgrade and the first-frame token rule after it.

use std::net::SocketAddr;
use std::sync::Arc;

use cmux_local_auth::{ListenerPolicy, parse_origin};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::protocol::frame::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

use crate::frame::{MAX_MESSAGE, Message};
use crate::provider::Provider;
use crate::token::Verifier;
use crate::transport::{QUEUE, Transport};

/// The WebSocket limits matching the 16 MiB message limit.
pub fn config() -> WebSocketConfig {
    WebSocketConfig::default().max_message_size(Some(MAX_MESSAGE)).max_frame_size(Some(MAX_MESSAGE))
}

/// Adapt an upgraded WebSocket. Writes drain the queue before one flush.
pub fn adapt<S>(socket: WebSocketStream<S>) -> Transport
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut sink, mut source) = socket.split();
    let (out_tx, mut out_rx) = mpsc::channel::<Message>(QUEUE);
    let (in_tx, in_rx) = mpsc::channel::<Message>(QUEUE);
    tokio::spawn(async move {
        let to_ws = |message: Message| match message {
            Message::Text(text) => WsMessage::text(text),
            Message::Binary(bytes) => WsMessage::binary(bytes),
            Message::Close(code, reason) => WsMessage::Close(Some(CloseFrame {
                code: CloseCode::from(code),
                reason: reason.into(),
            })),
        };
        while let Some(first) = out_rx.recv().await {
            let mut next = Some(first);
            while let Some(message) = next.take() {
                let closing = matches!(message, Message::Close(..));
                if sink.feed(to_ws(message)).await.is_err() {
                    return;
                }
                if closing {
                    let _ = sink.flush().await;
                    return;
                }
                next = out_rx.try_recv().ok();
            }
            if sink.flush().await.is_err() {
                return;
            }
        }
        let _ = sink.close().await;
    });
    tokio::spawn(async move {
        while let Some(Ok(message)) = source.next().await {
            let message = match message {
                WsMessage::Text(text) => Message::Text(text.as_str().to_owned()),
                WsMessage::Binary(bytes) => Message::Binary(bytes),
                WsMessage::Close(frame) => {
                    if let Some(frame) = frame {
                        let _ = in_tx
                            .send(Message::Close(
                                frame.code.into(),
                                frame.reason.as_str().to_owned(),
                            ))
                            .await;
                    }
                    break;
                }
                _ => continue,
            };
            if in_tx.send(message).await.is_err() {
                break;
            }
        }
    });
    Transport { tx: out_tx, rx: in_rx }
}

/// Dial `url` (`ws://127.0.0.1:<port>/...`) with a tuned TCP socket.
/// `origin` is sent as the `Origin` header, as a browser would.
pub async fn connect(
    address: SocketAddr,
    url: &str,
    origin: Option<&str>,
) -> anyhow::Result<Transport> {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let stream = crate::net::connect(address).await?;
    let mut request = url.into_client_request()?;
    if let Some(origin) = origin {
        request.headers_mut().insert("Origin", origin.parse()?);
    }
    let (socket, _) =
        tokio_tungstenite::client_async_with_config(request, stream, Some(config())).await?;
    Ok(adapt(socket))
}

// The handshake callback's error type is tungstenite's HTTP response.
#[allow(clippy::result_large_err)]
/// Upgrade one accepted connection after the Host/Origin rule; returns the
/// transport and the normalized `Origin` (if any).
pub async fn accept(
    stream: TcpStream,
    policy: &ListenerPolicy,
) -> anyhow::Result<(Transport, Option<String>)> {
    let mut origin = None;
    let check = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        let values = |name: &str| -> Vec<&str> {
            request.headers().get_all(name).iter().filter_map(|value| value.to_str().ok()).collect()
        };
        let (hosts, origins) = (values("host"), values("origin"));
        // A bundled page's origin is `cmux-page://<id>`. The upgrade lets it
        // through; the first-frame token must then name exactly that origin.
        let page = match origins.as_slice() {
            [one] => parse_origin(one).filter(|origin| is_page_origin(origin)),
            _ => None,
        };
        let checked =
            if page.is_some() { policy.check(&hosts, &[]) } else { policy.check(&hosts, &origins) };
        if let Err(refusal) = checked {
            let mut error = ErrorResponse::new(Some(refusal.reason().to_owned()));
            *error.status_mut() =
                StatusCode::from_u16(refusal.status()).unwrap_or(StatusCode::FORBIDDEN);
            return Err(error);
        }
        origin = origins.first().and_then(|value| parse_origin(value));
        Ok(response)
    };
    let socket =
        tokio_tungstenite::accept_hdr_async_with_config(stream, check, Some(config())).await?;
    Ok((adapt(socket), origin))
}

/// `cmux-page://<page id>`.
pub fn is_page_origin(origin: &str) -> bool {
    origin.strip_prefix("cmux-page://").is_some_and(crate::router::valid_app_id)
}

/// Serve `provider` on `listener` until it fails: each connection is tuned,
/// checked, upgraded, authenticated by its first frame, then served.
pub async fn serve(
    listener: TcpListener,
    provider: Arc<Provider>,
    verifier: Arc<Verifier>,
    policy: ListenerPolicy,
) {
    let policy = Arc::new(policy);
    let handle = |(stream, _): (TcpStream, SocketAddr)| {
        let (provider, verifier, policy) = (provider.clone(), verifier.clone(), policy.clone());
        tokio::spawn(async move {
            if let Ok((transport, origin)) = accept(stream, &policy).await {
                let _ = provider.serve(transport, &verifier, origin).await;
            }
        });
    };
    let log = crate::net::log_accept_error("provider websocket");
    crate::net::accept_loop(|| crate::net::accept(&listener), handle, log).await;
}
