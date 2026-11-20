//! One connection to the owner's user socket (`/v1/wire/user`,
//! `cmux.wire/1`), read for the hand frames only. The bearer goes in the
//! Authorization header; the engine reconnects with a backoff.

use std::time::Duration;

use cmux_cloud_wire::hands::{self, HandFrame};
use futures_util::{SinkExt as _, StreamExt as _};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

// timeout: a WebSocket upgrade that never completes fails the connect.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
/// The subscribe answer is the user owner's snapshot (up to about 1.5 MB).
const MAX_MESSAGE: usize = 8 << 20;

/// What a connection tells the engine.
pub(super) enum Seen {
    /// Subscribed: read the waiting approvals now (the backoff starts over).
    Subscribed,
    Frame(HandFrame),
}

/// Runs one connection until it closes; `seen` gets its frames. Errors are
/// the reason it ended.
pub(super) async fn session(
    api: &str,
    credential: Option<String>,
    app_version: Option<&str>,
    now_ms: impl Fn() -> f64,
    mut seen: impl FnMut(Seen),
) -> Result<(), String> {
    let credential = credential.filter(|c| !c.is_empty()).ok_or("not signed in")?;
    let mut request = hands::user_socket_url(api)
        .into_client_request()
        .map_err(|e| format!("bad socket URL: {e}"))?;
    let headers = request.headers_mut();
    headers.insert("sec-websocket-protocol", HeaderValue::from_static(hands::SUBPROTOCOL));
    let mut bearer = HeaderValue::from_str(&format!("Bearer {credential}"))
        .map_err(|_| "the token is not a valid header value")?;
    bearer.set_sensitive(true);
    headers.insert("authorization", bearer);
    // updates.minimumVersion: an owner refuses a client that does not name its version.
    if let Some(version) = app_version.and_then(|v| HeaderValue::from_str(v).ok()) {
        headers.insert("x-cmux-client-version", version);
    }
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE))
        .max_frame_size(Some(MAX_MESSAGE));
    let connect = tokio_tungstenite::connect_async_with_config(request, Some(config), false);
    let (mut stream, _) = tokio::time::timeout(HANDSHAKE_TIMEOUT, connect)
        .await
        .map_err(|_| "handshake timed out".to_owned())?
        .map_err(|e| e.to_string())?;
    while let Some(message) = stream.next().await {
        let text = match message.map_err(|e| e.to_string())? {
            Message::Text(text) => text.as_str().as_bytes().to_vec(),
            Message::Binary(bytes) => bytes.to_vec(),
            Message::Ping(_) => {
                // tungstenite queues the pong for a ping; flush sends it.
                let _ = stream.flush().await;
                continue;
            }
            Message::Close(_) => break,
            _ => continue,
        };
        match HandFrame::decode(&text, now_ms()) {
            HandFrame::Welcome => {
                stream
                    .send(Message::Text(hands::SUBSCRIBE.to_owned().into()))
                    .await
                    .map_err(|e| e.to_string())?;
            }
            HandFrame::Snapshot => seen(Seen::Subscribed),
            HandFrame::Ignored => {}
            frame => seen(Seen::Frame(frame)),
        }
    }
    Ok(())
}
