//! HTTPS begin and one deadline-bound pushed wait; no credential in a URL.

use std::io::Read;
use std::time::Duration;

use cmux_server_core::pairing::enrollment::{
    Begun, MAX_FRAME_BYTES, MAX_WAIT_MS, Waited, read_frame,
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
        let response = request.send().map_err(|_| unavailable())?;
        if !response.status().is_success() {
            return Err(if response.status().is_client_error() {
                Error::rejected("server.pair.api_refused")
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
fn invalid() -> Error {
    Error::verification("server.pair.invalid_frame")
}

impl super::Transport for Network {
    fn health(&self, api: &str) -> Result<Value> {
        self.json(self.http.get(format!("{api}/v1/health")))
    }

    fn begin(&self, api: &str, body: &Value) -> Result<Value> {
        self.json(self.http.post(format!("{api}/v1/pair/begin")).json(body))
    }

    fn wait(&self, api: &str, begun: &Begun) -> Result<Waited> {
        let left = begun.expires_at.saturating_sub(crate::host::now_ms()).min(MAX_WAIT_MS);
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
        Ok(Err(_)) => return Err(unavailable()),
        Err(_) => return Ok(Waited::Expired),
    };
    if response.headers().get("Sec-WebSocket-Protocol").and_then(|v| v.to_str().ok())
        != Some("cmux.pair.v1")
    {
        return Err(invalid());
    }
    read_wait(socket, deadline).await
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
