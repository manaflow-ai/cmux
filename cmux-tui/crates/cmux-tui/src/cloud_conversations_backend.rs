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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
/// it fails when its body has not moved this long. Hyper asks for the next
/// read once the last one is in its send buffer, so at a few KB/s reads still
/// come well inside the window.
const UPLOAD_STALL: Duration = Duration::from_secs(2 * 60);
/// How long the reply to a streamed upload may take after its last byte (the
/// slot commits the object first).
const UPLOAD_REPLY: Duration = Duration::from_secs(10 * 60);
/// One read of a streamed attachment file: small, so a slow uplink still
/// shows progress often (64 KiB at 1 KB/s is about a minute).
const UPLOAD_CHUNK_BYTES: usize = 64 * 1024;
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

/// How far a streamed upload got: when its body last moved (milliseconds
/// since the upload started) and whether all of it went.
#[derive(Default)]
struct UploadProgress {
    moved: AtomicU64,
    sent: AtomicBool,
}

/// A staged attachment file as a streamed body, read a chunk at a time as
/// the connection takes it. Each read stores when it happened in `progress`
/// (hyper polls the body only when it can send more). Its last `len` byte, or
/// its end, marks it sent: with a Content-Length hyper may never ask past it.
fn file_body(
    file: std::fs::File,
    len: u64,
    started: Instant,
    progress: Arc<UploadProgress>,
) -> reqwest::Body {
    reqwest::Body::wrap_stream(file_chunks(file, len, started, progress))
}

/// [`file_body`]'s chunks: `len` bytes of the file from where it stands, a chunk at a time.
fn file_chunks(
    file: std::fs::File,
    len: u64,
    started: Instant,
    progress: Arc<UploadProgress>,
) -> impl futures_util::Stream<Item = std::io::Result<Vec<u8>>> + Send + 'static {
    use tokio::io::AsyncReadExt;
    // Exactly the declared length: the Content-Length counts that many, from where the file stands.
    let file = tokio::fs::File::from_std(file).take(len);
    futures_util::stream::try_unfold((file, 0u64), move |(mut file, read_so_far)| {
        let progress = progress.clone();
        async move {
            let mut chunk = vec![0; UPLOAD_CHUNK_BYTES];
            let read = file.read(&mut chunk).await?;
            progress.moved.store(elapsed_ms(started), Ordering::Relaxed);
            let read_so_far = read_so_far + read as u64;
            if read == 0 || read_so_far >= len {
                progress.sent.store(true, Ordering::Relaxed);
            }
            if read == 0 {
                return Ok::<_, std::io::Error>(None);
            }
            chunk.truncate(read);
            Ok(Some((chunk, (file, read_so_far))))
        }
    })
}

fn elapsed_ms(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// How much longer the upload may go without progress before it is given
/// up: zero once it stalled. `idle` is the time since the body last moved;
/// `sent` says the whole body went (the upload waits for its reply).
fn stall_left(idle: Duration, sent: bool) -> Duration {
    (if sent { UPLOAD_REPLY } else { UPLOAD_STALL }).saturating_sub(idle)
}

/// How long the slot's reply body may take to arrive once its head came. A
/// slot answers after it stored the bytes, a streamed file or a derived image
/// alike.
fn reply_body_window() -> Duration {
    UPLOAD_REPLY
}

/// Resolves once [`stall_left`] says the upload stalled. It ends with its
/// `select!`, when the upload answers first.
async fn stalled(started: Instant, progress: Arc<UploadProgress>) {
    loop {
        let idle = elapsed_ms(started).saturating_sub(progress.moved.load(Ordering::Relaxed));
        let left = stall_left(Duration::from_millis(idle), progress.sent.load(Ordering::Relaxed));
        if left.is_zero() {
            return;
        }
        tokio::time::sleep(left).await;
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

    fn platform(
        &self,
        method: &str,
        url: &str,
        bearer: &str,
        body: &Value,
    ) -> Result<HttpReply, TransportError> {
        let method = match method {
            "GET" => reqwest::Method::GET,
            "POST" => reqwest::Method::POST,
            "PATCH" => reqwest::Method::PATCH,
            _ => return Err(TransportError("unsupported platform method".into())),
        };
        // Reuse the no-redirect transport: an install bearer never follows an upstream redirect.
        let mut request = self
            .files
            .request(method.clone(), url)
            .timeout(REQUEST_TIMEOUT)
            .header(reqwest::header::ACCEPT, "application/json")
            .bearer_auth(bearer);
        if method != reqwest::Method::GET {
            request = request.json(body);
        }
        self.runtime.block_on(async move {
            let response = request.send().await.map_err(|error| transport(&error))?;
            let status = response.status().as_u16();
            let bytes = response.bytes().await.map_err(|error| transport(&error))?;
            if bytes.len() > MAX_BODY_BYTES {
                return Err(TransportError("platform reply exceeds the limit".into()));
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
        self.put_with_etag(url, headers, body).map(|(reply, _)| reply)
    }

    fn attachment_part_url(&self, url: &str, number: u64) -> Result<HttpReply, TransportError> {
        self.runtime.block_on(async {
            let response = self
                .files
                .post(url)
                .timeout(UPLOAD_TIMEOUT)
                .header("x-cmux-part-number", number)
                .json(&serde_json::json!({}))
                .send()
                .await
                .map_err(|error| transport(&error))?;
            let status = response.status().as_u16();
            let bytes = response.bytes().await.map_err(|error| transport(&error))?;
            if bytes.len() > MAX_BODY_BYTES {
                return Err(TransportError("part URL reply exceeds the limit".into()));
            }
            Ok(HttpReply { status, body: serde_json::from_slice(&bytes).unwrap_or(Value::Null) })
        })
    }

    fn put_with_etag(
        &self,
        url: &str,
        headers: &[(String, String)],
        body: PutBody,
    ) -> Result<(HttpReply, Option<String>), TransportError> {
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
                    let progress = Arc::new(UploadProgress::default());
                    // A presigned object PUT needs a length, not a chunked body.
                    let request = if headers_have_length {
                        request
                    } else {
                        request.header(reqwest::header::CONTENT_LENGTH, len)
                    };
                    let request = request.body(file_body(file, len, started, progress.clone()));
                    tokio::select! {
                        response = request.send() => response,
                        () = stalled(started, progress.clone()) => {
                            let waited = if progress.sent.load(Ordering::Relaxed) {
                                format!("no reply came {} s after the upload's last byte", UPLOAD_REPLY.as_secs())
                            } else {
                                format!("the upload made no progress for {} s", UPLOAD_STALL.as_secs())
                            };
                            return Err(TransportError(waited));
                        }
                    }
                }
            };
            let response = response.map_err(|error| transport(&error))?;
            let status = response.status().as_u16();
            let etag = response.headers().get(reqwest::header::ETAG)
                .and_then(|value| value.to_str().ok()).map(str::to_owned);
            let bytes = tokio::time::timeout(reply_body_window(), response.bytes())
                .await
                .map_err(|_| TransportError("the upload reply did not finish".into()))?
                .map_err(|error| transport(&error))?;
            if bytes.len() > MAX_BODY_BYTES {
                return Err(TransportError(format!(
                    "reply of {} bytes exceeds the limit",
                    bytes.len()
                )));
            }
            Ok((HttpReply { status, body: serde_json::from_slice(&bytes).unwrap_or(Value::Null) }, etag))
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
            Box::new(RemoteWire {
                handle: self.runtime.handle().clone(),
                stream,
                wake: Arc::new(tokio::sync::Notify::new()),
            }) as Box<dyn CloudWire>
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
    /// Ends a waiting `recv` early (`CloudWire::interrupter`); a wake with
    /// no receive waiting ends the next one.
    wake: Arc<tokio::sync::Notify>,
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

    fn interrupter(&self) -> Option<cmux_tui_core::cloud_conversations::WireInterrupt> {
        let wake = self.wake.clone();
        Some(Arc::new(move || wake.notify_one()))
    }

    fn recv(&mut self, timeout: Duration) -> WireRecv {
        let stream = &mut self.stream;
        let wake = self.wake.clone();
        self.handle.block_on(async move {
            // `next` is cancel safe: a frame half read stays buffered.
            let next = tokio::select! {
                next = tokio::time::timeout(timeout, stream.next()) => match next {
                    Err(_) => return WireRecv::Idle,
                    Ok(next) => next,
                },
                () = wake.notified() => return WireRecv::Idle,
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
mod tests;
