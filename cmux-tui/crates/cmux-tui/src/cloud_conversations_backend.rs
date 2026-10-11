//! The cloud transport behind `cloud-conversations-v1`
//! (plans/cmux-next/home-cloud-proxy.md section 7): HTTPS calls to the cmux
//! Cloud API with reqwest and `cmux.wire/1` sockets with tokio-tungstenite,
//! on one small runtime. The daemon calls it from its own threads (request
//! workers and one driver per upstream stream), never from a runtime thread.
//!
//! The bearer token is only ever placed in the `authorization` header or the
//! `bearer.<token>` subprotocol (the Worker reads it there so it stays out of
//! URLs and logs); errors never include it.

use std::sync::Arc;
use std::time::Duration;

use cmux_tui_core::Mux;
use cmux_tui_core::cloud_conversations::{
    CloudBackend, CloudWire, ConnectError, HttpReply, TransportError, WireRecv,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
/// A Home read returns at most 200 messages of at most 64 KiB text each.
const MAX_BODY_BYTES: usize = 32 * 1024 * 1024;
const CLIENT_VERSION_HEADER: &str = "x-cmux-client-version";

pub(crate) struct RemoteCloudBackend {
    runtime: tokio::runtime::Runtime,
    http: reqwest::Client,
}

impl RemoteCloudBackend {
    pub(crate) fn new() -> anyhow::Result<Self> {
        // reqwest's rustls-no-provider build and tokio-tungstenite's rustls
        // need the workspace's ring provider installed once per process.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("mux-cloud-io")
            .enable_all()
            .build()?;
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .connect_timeout(CONNECT_TIMEOUT)
            .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Self { runtime, http })
    }
}

impl CloudBackend for RemoteCloudBackend {
    fn post(
        &self,
        url: &str,
        bearer: &str,
        client_version: Option<&str>,
        body: &Value,
    ) -> Result<HttpReply, TransportError> {
        let mut request = self
            .http
            .post(url)
            .bearer_auth(bearer)
            .header(reqwest::header::ACCEPT, "application/json")
            .json(body);
        if let Some(version) = client_version {
            request = request.header(CLIENT_VERSION_HEADER, version);
        }
        self.runtime.block_on(async move {
            let response = request.send().await.map_err(|error| transport(&error))?;
            let status = response.status().as_u16();
            let bytes = response.bytes().await.map_err(|error| transport(&error))?;
            if bytes.len() > MAX_BODY_BYTES {
                return Err(TransportError(format!(
                    "reply of {} bytes exceeds the limit",
                    bytes.len()
                )));
            }
            Ok(HttpReply { status, body: serde_json::from_slice(&bytes).unwrap_or(Value::Null) })
        })
    }

    fn connect(
        &self,
        url: &str,
        bearer: &str,
        client_version: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError> {
        let mut request = url
            .into_client_request()
            .map_err(|error| ConnectError::Unavailable(format!("bad stream URL: {error}")))?;
        let protocols =
            HeaderValue::from_str(&format!("cmux.wire.v1, bearer.{bearer}")).map_err(|_| {
                ConnectError::Unavailable("the token is not a valid header value".into())
            })?;
        request.headers_mut().insert("sec-websocket-protocol", protocols);
        if let Some(version) =
            client_version.and_then(|version| HeaderValue::from_str(version).ok())
        {
            request.headers_mut().insert(CLIENT_VERSION_HEADER, version);
        }
        let handshake = self.runtime.block_on(async move {
            tokio::time::timeout(HANDSHAKE_TIMEOUT, tokio_tungstenite::connect_async(request)).await
        });
        match handshake {
            Err(_) => Err(ConnectError::Unavailable("handshake timed out".into())),
            Ok(Err(WsError::Http(response))) => Err(match response.status().as_u16() {
                401 => ConnectError::Unauthenticated,
                403 | 404 => ConnectError::Forbidden,
                status => ConnectError::Unavailable(format!("handshake answered HTTP {status}")),
            }),
            Ok(Err(error)) => Err(ConnectError::Unavailable(error.to_string())),
            Ok(Ok((stream, _))) => {
                Ok(Box::new(RemoteWire { handle: self.runtime.handle().clone(), stream }))
            }
        }
    }
}

/// reqwest errors can include the request URL; they never include headers.
fn transport(error: &reqwest::Error) -> TransportError {
    let kind = if error.is_timeout() {
        "timed out"
    } else if error.is_connect() {
        "could not connect"
    } else {
        "request failed"
    };
    TransportError(kind.to_string())
}

struct RemoteWire {
    handle: tokio::runtime::Handle,
    stream: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

impl CloudWire for RemoteWire {
    fn send(&mut self, text: &str) -> Result<(), TransportError> {
        let stream = &mut self.stream;
        let message = Message::Text(text.to_string().into());
        self.handle.block_on(async move {
            match tokio::time::timeout(SEND_TIMEOUT, stream.send(message)).await {
                Ok(Ok(())) => Ok(()),
                Ok(Err(error)) => Err(TransportError(error.to_string())),
                Err(_) => Err(TransportError("send timed out".into())),
            }
        })
    }

    fn recv(&mut self, timeout: Duration) -> WireRecv {
        let stream = &mut self.stream;
        self.handle.block_on(async move {
            let next = match tokio::time::timeout(timeout, stream.next()).await {
                Err(_) => return WireRecv::Idle,
                Ok(next) => next,
            };
            match next {
                None | Some(Err(_)) => WireRecv::Closed { code: None },
                Some(Ok(Message::Text(text))) => WireRecv::Text(text.as_str().to_string()),
                Some(Ok(Message::Binary(bytes))) => match String::from_utf8(bytes.to_vec()) {
                    Ok(text) => WireRecv::Text(text),
                    Err(_) => WireRecv::Idle,
                },
                Some(Ok(Message::Close(frame))) => {
                    WireRecv::Closed { code: frame.map(|frame| u16::from(frame.code)) }
                }
                // tungstenite queues the pong for a ping; flush sends it.
                Some(Ok(Message::Ping(_))) => {
                    let _ = stream.flush().await;
                    WireRecv::Idle
                }
                Some(Ok(_)) => WireRecv::Idle,
            }
        })
    }
}

/// Installs the cloud transport behind `cloud-conversations-v1` on the
/// daemon's mux. The proxy stays idle until a trusted local client leases a
/// cloud session to it. A failure leaves the daemon without the capability;
/// nothing else depends on it.
pub(crate) fn install(mux: &Arc<Mux>) {
    match RemoteCloudBackend::new() {
        Ok(backend) => {
            let service =
                cmux_tui_core::cloud_conversations::CloudConversations::new(Arc::new(backend));
            mux.install_cloud_conversations(service);
        }
        Err(error) => crate::client_log::stderr_log!(
            "startup",
            "{BIN}: cloud conversations unavailable: {error}"
        ),
    }
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;

    use serde_json::json;
    use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
    use tokio_tungstenite::tungstenite::protocol::CloseFrame;
    use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

    use super::*;

    /// Serves one raw HTTP/1.1 exchange and hands back the request head.
    fn one_http_exchange(reply: &'static str) -> (String, mpsc::Receiver<(String, String)>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(socket.try_clone().unwrap());
            let mut head = String::new();
            let mut length = 0usize;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap();
                }
                if line == "\r\n" || line.is_empty() {
                    break;
                }
                head.push_str(&line);
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            socket.write_all(reply.as_bytes()).unwrap();
            sender.send((head, String::from_utf8(body).unwrap())).unwrap();
        });
        (origin, receiver)
    }

    #[test]
    fn post_sends_the_bearer_version_and_json_and_reads_any_status() {
        let backend = RemoteCloudBackend::new().unwrap();
        let (origin, seen) = one_http_exchange(
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}",
        );
        let reply = backend
            .post(
                &format!("{origin}/v1/ops"),
                "tok.en",
                Some("0.70.0"),
                &json!({"op": "title.set"}),
            )
            .unwrap();
        assert_eq!(reply, HttpReply { status: 200, body: json!({"ok": true}) });
        let (head, body) = seen.recv().unwrap();
        let head = head.to_ascii_lowercase();
        assert!(head.starts_with("post /v1/ops "), "{head}");
        assert!(head.contains("authorization: bearer tok.en"), "{head}");
        assert!(head.contains("x-cmux-client-version: 0.70.0"), "{head}");
        assert_eq!(serde_json::from_str::<Value>(&body).unwrap(), json!({"op": "title.set"}));

        let (origin, _) = one_http_exchange(
            "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
        );
        let reply = backend.post(&format!("{origin}/v1/read"), "t", None, &json!({})).unwrap();
        assert_eq!(reply, HttpReply { status: 401, body: Value::Null });

        let refused = backend.post("http://127.0.0.1:1/v1/ops", "secret-token", None, &json!({}));
        let TransportError(detail) = refused.unwrap_err();
        assert!(!detail.contains("secret-token"));
    }

    // tungstenite's handshake callback type fixes its large error variant.
    #[allow(clippy::result_large_err)]
    #[test]
    fn a_stream_carries_the_token_as_a_subprotocol_and_reports_close_codes() {
        let backend = RemoteCloudBackend::new().unwrap();
        let listener =
            backend.runtime.block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
        let address = listener.local_addr().unwrap();
        let (protocols_seen, protocols) = mpsc::channel();
        backend.runtime.spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let callback = move |request: &Request, mut response: Response| {
                let offered = request
                    .headers()
                    .get("sec-websocket-protocol")
                    .map(|value| value.to_str().unwrap().to_string())
                    .unwrap_or_default();
                protocols_seen.send(offered).unwrap();
                response
                    .headers_mut()
                    .insert("sec-websocket-protocol", HeaderValue::from_static("cmux.wire.v1"));
                Ok(response)
            };
            let mut server = tokio_tungstenite::accept_hdr_async(socket, callback).await.unwrap();
            server.send(Message::Text("{\"t\":\"welcome\"}".into())).await.unwrap();
            let subscribe = server.next().await.unwrap().unwrap();
            assert_eq!(subscribe, Message::Text("{\"t\":\"subscribe\"}".into()));
            server
                .send(Message::Close(Some(CloseFrame {
                    code: CloseCode::from(4401),
                    reason: "token expired".into(),
                })))
                .await
                .unwrap();
        });
        let mut wire = backend
            .connect(&format!("ws://{address}/v1/wire/conv/x"), "tok.en", Some("0.70.0"))
            .unwrap_or_else(|_| panic!("connect failed"));
        assert_eq!(protocols.recv().unwrap(), "cmux.wire.v1, bearer.tok.en");
        assert_eq!(
            wire.recv(Duration::from_secs(10)),
            WireRecv::Text("{\"t\":\"welcome\"}".into())
        );
        wire.send("{\"t\":\"subscribe\"}").unwrap();
        assert_eq!(wire.recv(Duration::from_secs(10)), WireRecv::Closed { code: Some(4401) });
    }

    #[test]
    fn a_refused_handshake_maps_to_unauthenticated_or_forbidden() {
        let backend = RemoteCloudBackend::new().unwrap();
        for (reply, expected) in [
            (
                "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n",
                ConnectError::Unauthenticated,
            ),
            ("HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n", ConnectError::Forbidden),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            std::thread::spawn(move || {
                let (mut socket, _) = listener.accept().unwrap();
                let mut buffer = [0u8; 4096];
                let _ = socket.read(&mut buffer);
                socket.write_all(reply.as_bytes()).unwrap();
            });
            match backend.connect(&format!("ws://{address}/v1/wire/user"), "t", None) {
                Err(error) => assert_eq!(error, expected),
                Ok(_) => panic!("the handshake must be refused"),
            }
        }
    }
}
