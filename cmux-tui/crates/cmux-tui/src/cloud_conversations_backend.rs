//! The cloud transport behind `cloud-conversations-v1`
//! (plans/cmux-next/home-cloud-proxy.md section 7): HTTPS calls to the cmux
//! Cloud API with reqwest and `cmux.wire/1` sockets with tokio-tungstenite,
//! on one small runtime. The daemon calls it from its own threads (request
//! workers and one driver per upstream stream), never from a runtime thread.
//!
//! The bearer token is only ever placed in the `authorization` header (HTTP
//! calls and the socket upgrade; Workers invocation logs record every header
//! but Authorization, cx-dgsp); errors never include it. The legacy
//! `bearer.<token>` subprotocol is retired: a 401 on the upgrade is final.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_tui_core::Mux;
use cmux_tui_core::cloud_conversations::{
    CloudBackend, CloudWire, ConnectError, HttpReply, PutBody, RangeReply, TransportError, WireRecv,
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
/// A derived image upload (at most 2 MB) may take longer than a JSON call.
const UPLOAD_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// A streamed attachment file has no total deadline (it may be any size);
/// it fails when no bytes moved, or no reply came after the last, this long.
const UPLOAD_STALL: Duration = Duration::from_secs(2 * 60);
/// One read of a streamed attachment file.
const UPLOAD_CHUNK_BYTES: usize = 1024 * 1024;
/// One ranged attachment read (at most 4 MiB).
const RANGE_TIMEOUT: Duration = Duration::from_secs(60);
pub(crate) struct RemoteCloudBackend {
    runtime: tokio::runtime::Runtime,
    http: reqwest::Client,
    /// Attachment slot and signed URLs: never follows a redirect (the URL
    /// the daemon checked is the one it talks to).
    files: reqwest::Client,
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
        let files = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Self { runtime, http, files })
    }
}

/// A staged attachment file as a streamed body, read a chunk at a time as
/// the connection takes it. Each read stores, in `moved`, the milliseconds
/// since `started` (hyper polls the body only when it can send more).
fn file_body(file: std::fs::File, started: Instant, moved: Arc<AtomicU64>) -> reqwest::Body {
    use tokio::io::AsyncReadExt;
    let file = tokio::fs::File::from_std(file);
    let chunks = futures_util::stream::try_unfold(file, move |mut file| {
        let moved = moved.clone();
        async move {
            let mut chunk = vec![0; UPLOAD_CHUNK_BYTES];
            let read = file.read(&mut chunk).await?;
            moved.store(elapsed_ms(started), Ordering::Relaxed);
            if read == 0 {
                return Ok::<_, std::io::Error>(None);
            }
            chunk.truncate(read);
            Ok(Some((chunk, file)))
        }
    });
    reqwest::Body::wrap_stream(chunks)
}

fn elapsed_ms(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Resolves once [`UPLOAD_STALL`] passed since the body last moved. It ends
/// with its `select!`, when the upload answers first.
async fn stalled(started: Instant, moved: Arc<AtomicU64>) {
    let stall = u64::try_from(UPLOAD_STALL.as_millis()).unwrap_or(u64::MAX);
    loop {
        let idle = elapsed_ms(started).saturating_sub(moved.load(Ordering::Relaxed));
        if idle >= stall {
            return;
        }
        tokio::time::sleep(Duration::from_millis(stall - idle)).await;
    }
}

impl CloudBackend for RemoteCloudBackend {
    fn post(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
        body: &Value,
    ) -> Result<HttpReply, TransportError> {
        let mut request =
            self.http.post(url).header(reqwest::header::ACCEPT, "application/json").json(body);
        // A self-hosted server on the tailnet gets no Authorization header.
        if let Some(bearer) = bearer {
            request = request.bearer_auth(bearer);
        }
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

    fn get(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
    ) -> Result<HttpReply, TransportError> {
        let mut request = self.http.get(url).header(reqwest::header::ACCEPT, "application/json");
        if let Some(bearer) = bearer {
            request = request.bearer_auth(bearer);
        }
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

    fn put(
        &self,
        url: &str,
        headers: &[(String, String)],
        body: PutBody,
    ) -> Result<HttpReply, TransportError> {
        let headers_have_length =
            headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("content-length"));
        let mut request = self.files.put(url);
        for (name, value) in headers {
            request = request.header(name.as_str(), value.as_str());
        }
        self.runtime.block_on(async move {
            let response = match body {
                PutBody::Bytes(bytes) => request.timeout(UPLOAD_TIMEOUT).body(bytes).send().await,
                PutBody::File { file, len } => {
                    let started = Instant::now();
                    let moved = Arc::new(AtomicU64::new(0));
                    // A presigned object PUT needs a length, not a chunked body.
                    let request = if headers_have_length {
                        request
                    } else {
                        request.header(reqwest::header::CONTENT_LENGTH, len)
                    };
                    let request = request.body(file_body(file, started, moved.clone()));
                    tokio::select! {
                        response = request.send() => response,
                        () = stalled(started, moved) => {
                            return Err(TransportError(format!(
                                "attachment upload made no progress for {} s",
                                UPLOAD_STALL.as_secs()
                            )));
                        }
                    }
                }
            };
            let response = response.map_err(|error| transport(&error))?;
            let status = response.status().as_u16();
            let bytes = tokio::time::timeout(UPLOAD_STALL, response.bytes())
                .await
                .map_err(|_| TransportError("the upload reply did not finish".into()))?
                .map_err(|error| transport(&error))?;
            if bytes.len() > MAX_BODY_BYTES {
                return Err(TransportError(format!(
                    "reply of {} bytes exceeds the limit",
                    bytes.len()
                )));
            }
            Ok(HttpReply { status, body: serde_json::from_slice(&bytes).unwrap_or(Value::Null) })
        })
    }

    fn get_range(&self, url: &str, offset: u64, length: u64) -> Result<RangeReply, TransportError> {
        let last = offset + length.max(1) - 1;
        let request = self
            .files
            .get(url)
            .timeout(RANGE_TIMEOUT)
            .header(reqwest::header::RANGE, format!("bytes={offset}-{last}"));
        self.runtime.block_on(async move {
            let response = request.send().await.map_err(|error| transport(&error))?;
            let status = response.status().as_u16();
            let header = |name: reqwest::header::HeaderName| {
                response
                    .headers()
                    .get(name)
                    .and_then(|value| value.to_str().ok())
                    .map(str::to_string)
            };
            let content_type = header(reqwest::header::CONTENT_TYPE);
            // `bytes a-b/total` on a 206; the whole length on a 200.
            let total = match header(reqwest::header::CONTENT_RANGE) {
                Some(range) => range.rsplit('/').next().and_then(|total| total.trim().parse().ok()),
                None if status == 200 => response.content_length(),
                None => None,
            };
            // A server that ignores the range answers 200 with everything: only
            // a read from the start can use it, and only its first `length` bytes.
            if status == 200 && offset > 0 {
                return Err(TransportError("the attachment server ignored the byte range".into()));
            }
            let limit = usize::try_from(length).unwrap_or(usize::MAX);
            let mut response = response;
            let mut body = Vec::with_capacity(limit.min(1 << 20));
            while body.len() < limit {
                match response.chunk().await.map_err(|error| transport(&error))? {
                    Some(chunk) => {
                        body.extend_from_slice(&chunk[..chunk.len().min(limit - body.len())]);
                    }
                    None => break,
                }
            }
            Ok(RangeReply { status, content_type, total, body })
        })
    }

    fn connect(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError> {
        self.handshake(url, bearer, client_version).map(|stream| {
            Box::new(RemoteWire { handle: self.runtime.handle().clone(), stream })
                as Box<dyn CloudWire>
        })
    }
}

impl RemoteCloudBackend {
    fn handshake(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
    ) -> Result<WebSocketStream<MaybeTlsStream<TcpStream>>, ConnectError> {
        let unavailable = ConnectError::Unavailable;
        let mut request = url
            .into_client_request()
            .map_err(|error| unavailable(format!("bad stream URL: {error}")))?;
        let invalid = || unavailable("the token is not a valid header value".into());
        if let Some(bearer) = bearer {
            let authorization =
                HeaderValue::from_str(&format!("Bearer {bearer}")).map_err(|_| invalid())?;
            request.headers_mut().insert("authorization", authorization);
        }
        request
            .headers_mut()
            .insert("sec-websocket-protocol", HeaderValue::from_static("cmux.wire.v1"));
        if let Some(version) =
            client_version.and_then(|version| HeaderValue::from_str(version).ok())
        {
            request.headers_mut().insert(CLIENT_VERSION_HEADER, version);
        }
        let handshake = self.runtime.block_on(async move {
            tokio::time::timeout(HANDSHAKE_TIMEOUT, tokio_tungstenite::connect_async(request)).await
        });
        match handshake {
            Err(_) => Err(unavailable("handshake timed out".into())),
            Ok(Err(WsError::Http(response))) => Err(match response.status().as_u16() {
                401 => ConnectError::Unauthenticated,
                // 410: the host replica was dropped (its host left the team).
                403 | 404 | 410 => ConnectError::Forbidden,
                status => unavailable(format!("handshake answered HTTP {status}")),
            }),
            Ok(Err(error)) => Err(unavailable(error.to_string())),
            Ok(Ok((stream, _))) => Ok(stream),
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
            let backend = Arc::new(backend);
            let service =
                cmux_tui_core::cloud_conversations::CloudConversations::new(backend.clone());
            mux.install_cloud_conversations(service);
            // The host's read replica publisher (object-sync phase 3) shares the
            // transport; it stays off until the app leases an install token.
            let replica = cmux_tui_core::cloud_conversations::HostReplica::new(backend);
            cmux_tui_core::server::cloud_host_replica::install_host_replica(mux, replica);
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
    fn a_post_without_a_bearer_sends_no_authorization_header() {
        let backend = RemoteCloudBackend::new().unwrap();
        let (origin, seen) = one_http_exchange(
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}",
        );
        let reply = backend.post(&format!("{origin}/v1/read"), None, None, &json!({})).unwrap();
        assert_eq!(reply.status, 200);
        let (head, _) = seen.recv().unwrap();
        assert!(!head.to_ascii_lowercase().contains("authorization:"), "{head}");
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
                Some("tok.en"),
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
        let reply =
            backend.post(&format!("{origin}/v1/read"), Some("t"), None, &json!({})).unwrap();
        assert_eq!(reply, HttpReply { status: 401, body: Value::Null });

        let refused =
            backend.post("http://127.0.0.1:1/v1/ops", Some("secret-token"), None, &json!({}));
        let TransportError(detail) = refused.unwrap_err();
        assert!(!detail.contains("secret-token"));
    }

    // tungstenite's handshake callback type fixes its large error variant.
    #[allow(clippy::result_large_err)]
    #[test]
    fn a_stream_carries_the_token_in_the_authorization_header_and_reports_close_codes() {
        let backend = RemoteCloudBackend::new().unwrap();
        let listener =
            backend.runtime.block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
        let address = listener.local_addr().unwrap();
        let (protocols_seen, protocols) = mpsc::channel();
        backend.runtime.spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let callback = move |request: &Request, mut response: Response| {
                let header = |name: &str| {
                    request
                        .headers()
                        .get(name)
                        .map(|value| value.to_str().unwrap().to_string())
                        .unwrap_or_default()
                };
                protocols_seen
                    .send((header("sec-websocket-protocol"), header("authorization")))
                    .unwrap();
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
            .connect(&format!("ws://{address}/v1/wire/conv/x"), Some("tok.en"), Some("0.70.0"))
            .unwrap_or_else(|_| panic!("connect failed"));
        // cx-dgsp: the token is never in the subprotocols (Workers invocation logs record them).
        assert_eq!(
            protocols.recv().unwrap(),
            ("cmux.wire.v1".to_string(), "Bearer tok.en".to_string())
        );
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
                "HTTP/1.1 401 Unauthorized\r\nx-cmux-wire-auth: authorization, ticket\r\ncontent-length: 0\r\n\r\n",
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
            match backend.connect(&format!("ws://{address}/v1/wire/user"), Some("t"), None) {
                Err(error) => assert_eq!(error, expected),
                Ok(_) => panic!("the handshake must be refused"),
            }
        }
    }

    /// Any 401, with or without `x-cmux-wire-auth`, is final: the client never
    /// retries with the token in a subprotocol, which Workers invocation logs
    /// record (cx-dgsp; the legacy `bearer.` retry is retired).
    #[test]
    fn a_401_without_header_auth_is_final_and_sends_no_token_subprotocol() {
        let backend = RemoteCloudBackend::new().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (seen_tx, seen) = mpsc::channel();
        std::thread::spawn(move || {
            for _ in 0..2 {
                let Ok((mut socket, _)) = listener.accept() else { return };
                let mut buffer = [0u8; 4096];
                let read = socket.read(&mut buffer).unwrap();
                seen_tx
                    .send(String::from_utf8_lossy(&buffer[..read]).to_ascii_lowercase())
                    .unwrap();
                socket
                    .write_all(b"HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n")
                    .unwrap();
            }
        });
        match backend.connect(&format!("ws://{address}/v1/wire/user"), Some("tok.en"), None) {
            Err(error) => assert_eq!(error, ConnectError::Unauthenticated),
            Ok(_) => panic!("the handshake must be refused"),
        }
        let first = seen.recv().unwrap();
        assert!(first.contains("authorization: bearer tok.en"), "{first}");
        assert!(first.contains("sec-websocket-protocol: cmux.wire.v1\r\n"), "{first}");
        assert!(
            seen.recv_timeout(Duration::from_millis(500)).is_err(),
            "the client must not retry"
        );
    }
}
