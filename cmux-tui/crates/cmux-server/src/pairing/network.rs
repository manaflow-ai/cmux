//! HTTPS begin and one deadline-bound pushed wait; no credential in a URL.

use std::io::Read;
use std::time::Duration;

use cmux_server_core::pairing::enrollment::{
    Begun, MAX_CLOCK_SKEW_MS, MAX_FRAME_BYTES, MAX_WAIT_MS, Waited, read_frame,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

use crate::error::{Error, Result};

pub struct Network {
    http: reqwest::blocking::Client,
}

impl Network {
    pub fn new() -> Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let http = reqwest::blocking::Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(20))
            .user_agent(concat!("cmux-server/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|_| unavailable())?;
        Ok(Self { http })
    }

    fn json(&self, request: reqwest::blocking::RequestBuilder) -> Result<Value> {
        let response = request
            .send()
            .map_err(|error| if error.is_connect() { unsent() } else { unavailable() })?;
        if !response.status().is_success() {
            return Err(if response.status().is_client_error() {
                Error::rejected("server.pair.api_refused")
            } else if response.status() == reqwest::StatusCode::SERVICE_UNAVAILABLE {
                // The begin route's 503 means no free code: nothing was issued.
                unsent()
            } else {
                unavailable()
            });
        }
        let mut bytes = Vec::new();
        response
            .take(MAX_FRAME_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| unavailable())?;
        if bytes.len() > MAX_FRAME_BYTES {
            return Err(invalid());
        }
        serde_json::from_slice(&bytes).map_err(|_| invalid())
    }
}

fn unavailable() -> Error {
    Error::unreachable("server.pair.unreachable")
}
/// The request never reached the API, or the API issued nothing: a begin can be retried at once.
pub(super) fn unsent() -> Error {
    Error::unreachable(UNSENT)
}
pub(super) const UNSENT: &str = "server.pair.unsent";
fn invalid() -> Error {
    Error::verification("server.pair.invalid_frame")
}

impl super::Transport for Network {
    fn native_post(&self, origin: &str, path: &str, body: &Value) -> Result<Option<Value>> {
        let response = self
            .http
            .post(format!("{origin}{path}"))
            .json(body)
            .send()
            .map_err(|_| unavailable())?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !response.status().is_success() {
            return Err(if response.status().is_client_error() {
                Error::rejected("server.pair.network_refused")
            } else {
                unavailable()
            });
        }
        // Policy may contain the full bounded peer map. Enrollment frames keep
        // their smaller independent limit; no account header is attached here.
        let mut bytes = Vec::new();
        response.take(65_537).read_to_end(&mut bytes).map_err(|_| unavailable())?;
        if bytes.len() > 65_536 {
            return Err(invalid());
        }
        serde_json::from_slice(&bytes).map(Some).map_err(|_| invalid())
    }
    fn health(&self, api: &str) -> Result<Value> {
        self.json(self.http.get(format!("{api}/v1/health")))
    }

    fn begin(&self, api: &str, body: &Value) -> Result<Value> {
        self.json(self.http.post(format!("{api}/v1/pair/begin")).json(body))
    }

    fn wait(&self, api: &str, begun: &Begun) -> Result<Waited> {
        let left = wait_budget(begun.expires_at, crate::host::now_ms());
        if left == 0 {
            return Ok(Waited::Expired);
        }
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| unavailable())?;
        let result = runtime.block_on(wait(api, begun, Duration::from_millis(left)));
        runtime.shutdown_timeout(Duration::from_secs(1));
        result
    }
}

/// How long to wait for a code expiring at `expires_at` (the backend's clock): until the backend
/// must have expired it too, so a code is never given up while someone can still approve it.
/// The backend normally ends the wait itself (close 4408) when the code expires.
fn wait_budget(expires_at: u64, now_ms: u64) -> u64 {
    expires_at
        .saturating_add(MAX_CLOCK_SKEW_MS)
        .saturating_sub(now_ms)
        .min(MAX_WAIT_MS + MAX_CLOCK_SKEW_MS)
}

async fn wait(api: &str, begun: &Begun, remaining: Duration) -> Result<Waited> {
    let request = request(api, begun)?;
    let config = socket_config();
    let deadline = tokio::time::Instant::now() + remaining;
    let (socket, response) = match tokio::time::timeout_at(
        deadline,
        tokio_tungstenite::connect_async_with_config(request, Some(config), false),
    )
    .await
    {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => return handshake_refused(error),
        Err(_) => return Ok(Waited::Expired),
    };
    if response.headers().get("Sec-WebSocket-Protocol").and_then(|v| v.to_str().ok())
        != Some("cmux.pair.v1")
    {
        return Err(invalid());
    }
    read_wait(socket, deadline).await
}

/// A failed wait upgrade. The backend deletes a code when it expires and answers its upgrade 404;
/// the code and collect secret are ours and well formed, so a 404 only means the code is gone.
/// That ends the attempt like close 4408, including inside the clock-skew window, where a rerun
/// would otherwise report the API unreachable until the window closed.
fn handshake_refused(error: tokio_tungstenite::tungstenite::Error) -> Result<Waited> {
    match error {
        tokio_tungstenite::tungstenite::Error::Http(response)
            if response.status() == tokio_tungstenite::tungstenite::http::StatusCode::NOT_FOUND =>
        {
            Ok(Waited::Expired)
        }
        _ => Err(unavailable()),
    }
}

fn request(
    api: &str,
    begun: &Begun,
) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request> {
    let mut url = url::Url::parse(api).map_err(|_| invalid())?;
    url.set_scheme("wss").map_err(|_| invalid())?;
    url.set_path("/v1/pair/wait");
    url.query_pairs_mut().append_pair("code", begun.code.as_str());
    let mut request = url.as_str().into_client_request().map_err(|_| invalid())?;
    let mut protocol: tokio_tungstenite::tungstenite::http::HeaderValue =
        format!("cmux.pair.v1, collect.{}", begun.collect_secret())
            .parse()
            .map_err(|_| invalid())?;
    protocol.set_sensitive(true);
    request.headers_mut().insert("Sec-WebSocket-Protocol", protocol);
    Ok(request)
}

fn socket_config() -> tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
    tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES))
}

async fn read_wait<S>(
    mut socket: tokio_tungstenite::WebSocketStream<S>,
    deadline: tokio::time::Instant,
) -> Result<Waited>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    loop {
        let message = match tokio::time::timeout_at(deadline, socket.next()).await {
            Ok(Some(Ok(message))) => message,
            Ok(_) => return Err(unavailable()),
            Err(_) => return Ok(Waited::Expired),
        };
        match message {
            Message::Text(text) => {
                if let Some(done) = read_frame(&text).map_err(|_| invalid())? {
                    return Ok(done);
                }
            }
            Message::Close(Some(frame)) if u16::from(frame.code) == 4403 => {
                return Ok(Waited::Refused);
            }
            Message::Close(Some(frame)) if u16::from(frame.code) == 4408 => {
                return Ok(Waited::Expired);
            }
            Message::Close(_) => return Err(unavailable()),
            Message::Ping(bytes) => {
                if tokio::time::timeout_at(deadline, socket.send(Message::Pong(bytes)))
                    .await
                    .map_err(|_| unavailable())?
                    .is_err()
                {
                    return Err(unavailable());
                }
            }
            Message::Pong(_) => {}
            _ => return Err(invalid()),
        }
    }
}

#[cfg(test)]
#[path = "network_tests.rs"]
mod tests;
