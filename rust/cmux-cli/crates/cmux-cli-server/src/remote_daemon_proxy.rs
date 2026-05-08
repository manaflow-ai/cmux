use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::Command;
use tokio::sync::{Mutex, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};

const REQUIRED_PROXY_STREAM_CAPABILITY: &str = "proxy.stream.push";
const MAX_HANDSHAKE_BYTES: usize = 64 * 1024;
const REMOTE_LOOPBACK_PROXY_ALIAS_HOST: &str = "cmux-loopback.localtest.me";

#[derive(Debug, Clone)]
pub(crate) struct RemoteDaemonWebSocketEndpoint {
    pub(crate) url: String,
    pub(crate) token: String,
    pub(crate) session_id: String,
    pub(crate) headers: Vec<(String, String)>,
}

#[derive(Debug, Clone)]
pub(crate) struct RemoteDaemonSshEndpoint {
    pub(crate) destination: String,
    pub(crate) port: Option<u16>,
    pub(crate) identity_file: Option<String>,
    pub(crate) ssh_options: Vec<String>,
    pub(crate) remote_path: String,
}

#[derive(Debug, Clone)]
pub(crate) enum RemoteDaemonProxyEndpoint {
    WebSocket(RemoteDaemonWebSocketEndpoint),
    Ssh(RemoteDaemonSshEndpoint),
}

#[derive(Debug, Clone)]
pub(crate) struct RemoteDaemonProxyConfig {
    pub(crate) endpoint: RemoteDaemonProxyEndpoint,
    pub(crate) local_proxy_port: Option<u16>,
}

#[derive(Debug, Clone)]
pub(crate) struct RemoteDaemonProxyHello {
    pub(crate) name: String,
    pub(crate) version: String,
    pub(crate) capabilities: Vec<String>,
    pub(crate) remote_path: String,
}

#[derive(Debug, Clone)]
pub(crate) struct RemoteDaemonProxyReady {
    pub(crate) local_port: u16,
    pub(crate) hello: RemoteDaemonProxyHello,
}

pub(crate) struct RemoteDaemonProxyHandle {
    stop_tx: watch::Sender<bool>,
    failure_rx: watch::Receiver<Option<String>>,
    accept_task: JoinHandle<()>,
}

impl RemoteDaemonProxyHandle {
    pub(crate) fn stop(&self) {
        let _ = self.stop_tx.send(true);
        self.accept_task.abort();
    }

    pub(crate) fn failure_rx(&self) -> watch::Receiver<Option<String>> {
        self.failure_rx.clone()
    }
}

impl Drop for RemoteDaemonProxyHandle {
    fn drop(&mut self) {
        let _ = self.stop_tx.send(true);
        self.accept_task.abort();
    }
}

pub(crate) async fn start_remote_daemon_proxy(
    config: RemoteDaemonProxyConfig,
) -> Result<(RemoteDaemonProxyHandle, RemoteDaemonProxyReady)> {
    let (stop_tx, stop_rx) = watch::channel(false);
    let (failure_tx, failure_rx) = watch::channel(None);
    let rpc = RemoteDaemonRpcClient::connect(config.endpoint, stop_rx.clone(), failure_tx).await?;
    let hello = rpc.hello().await?;
    if !hello
        .capabilities
        .iter()
        .any(|capability| capability == REQUIRED_PROXY_STREAM_CAPABILITY)
    {
        bail!("remote daemon missing required capability {REQUIRED_PROXY_STREAM_CAPABILITY}");
    }

    let listener = bind_loopback_listener(config.local_proxy_port).await?;
    let local_port = listener
        .local_addr()
        .context("read local daemon proxy listener address")?
        .port();
    let accept_task = tokio::spawn(accept_loop(listener, rpc, stop_rx));
    let handle = RemoteDaemonProxyHandle {
        stop_tx,
        failure_rx,
        accept_task,
    };
    Ok((handle, RemoteDaemonProxyReady { local_port, hello }))
}

async fn bind_loopback_listener(port: Option<u16>) -> Result<TcpListener> {
    let addr = format!("127.0.0.1:{}", port.unwrap_or(0));
    TcpListener::bind(&addr)
        .await
        .with_context(|| format!("bind local daemon proxy listener on {addr}"))
}

async fn accept_loop(
    listener: TcpListener,
    rpc: Arc<RemoteDaemonRpcClient>,
    mut stop_rx: watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            changed = stop_rx.changed() => {
                if changed.is_err() || *stop_rx.borrow() {
                    return;
                }
            }
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else {
                    return;
                };
                let rpc = rpc.clone();
                tokio::spawn(async move {
                    if let Err(error) = handle_proxy_connection(stream, rpc).await {
                        tracing::debug!(error = %error, "remote daemon proxy connection ended");
                    }
                });
            }
        }
    }
}

struct RemoteDaemonRpcClient {
    outgoing: mpsc::UnboundedSender<Message>,
    pending: Mutex<HashMap<u64, oneshot::Sender<std::result::Result<Value, String>>>>,
    stream_subscriptions: Mutex<HashMap<String, mpsc::UnboundedSender<RemoteStreamEvent>>>,
    failure_tx: watch::Sender<Option<String>>,
    remote_path: Option<String>,
    next_request_id: AtomicU64,
}

impl RemoteDaemonRpcClient {
    async fn connect(
        endpoint: RemoteDaemonProxyEndpoint,
        stop_rx: watch::Receiver<bool>,
        failure_tx: watch::Sender<Option<String>>,
    ) -> Result<Arc<Self>> {
        match endpoint {
            RemoteDaemonProxyEndpoint::WebSocket(endpoint) => {
                Self::connect_websocket(endpoint, stop_rx, failure_tx).await
            }
            RemoteDaemonProxyEndpoint::Ssh(endpoint) => {
                Self::connect_ssh(endpoint, stop_rx, failure_tx).await
            }
        }
    }

    async fn connect_websocket(
        endpoint: RemoteDaemonWebSocketEndpoint,
        mut stop_rx: watch::Receiver<bool>,
        failure_tx: watch::Sender<Option<String>>,
    ) -> Result<Arc<Self>> {
        let mut request = endpoint
            .url
            .as_str()
            .into_client_request()
            .with_context(|| format!("invalid websocket daemon URL {}", endpoint.url))?;
        for (key, value) in &endpoint.headers {
            let header_name = HeaderName::from_bytes(key.as_bytes())
                .with_context(|| format!("invalid websocket daemon header name {key:?}"))?;
            let header_value = HeaderValue::from_str(value)
                .with_context(|| format!("invalid websocket daemon header value for {key}"))?;
            request.headers_mut().insert(header_name, header_value);
        }

        let (socket, _) = connect_async(request)
            .await
            .with_context(|| format!("open websocket daemon {}", endpoint.url))?;
        let (mut sink, mut stream) = socket.split();
        let (outgoing_tx, mut outgoing_rx) = mpsc::unbounded_channel();
        let client = Arc::new(Self {
            outgoing: outgoing_tx,
            pending: Mutex::new(HashMap::new()),
            stream_subscriptions: Mutex::new(HashMap::new()),
            failure_tx: failure_tx.clone(),
            remote_path: None,
            next_request_id: AtomicU64::new(1),
        });

        let writer_stop_rx = stop_rx.clone();
        let writer_failure_tx = failure_tx.clone();
        tokio::spawn(async move {
            let mut writer_stop_rx = writer_stop_rx;
            loop {
                tokio::select! {
                    changed = writer_stop_rx.changed() => {
                        if changed.is_err() || *writer_stop_rx.borrow() {
                            let _ = sink.close().await;
                            return;
                        }
                    }
                    message = outgoing_rx.recv() => {
                        let Some(message) = message else {
                            let _ = sink.close().await;
                            return;
                        };
                        if sink.send(message).await.is_err() {
                            writer_failure_tx
                                .send(Some("daemon websocket writer failed".to_string()))
                                .ok();
                            return;
                        }
                    }
                }
            }
        });

        let reader_client = client.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    changed = stop_rx.changed() => {
                        if changed.is_err() || *stop_rx.borrow() {
                            return;
                        }
                    }
                    message = stream.next() => {
                        match message {
                            Some(Ok(message)) => {
                                reader_client.consume_message(message).await;
                            }
                            Some(Err(error)) => {
                                let detail = format!("daemon websocket failed: {error}");
                                reader_client.report_failure(detail).await;
                                return;
                            }
                            None => {
                                reader_client
                                    .report_failure("daemon websocket closed".to_string())
                                    .await;
                                return;
                            }
                        }
                    }
                }
            }
        });

        client
            .send_value(serde_json::json!({
                "type": "auth",
                "token": endpoint.token,
                "session_id": endpoint.session_id,
            }))
            .await?;
        Ok(client)
    }

    async fn connect_ssh(
        endpoint: RemoteDaemonSshEndpoint,
        mut stop_rx: watch::Receiver<bool>,
        failure_tx: watch::Sender<Option<String>>,
    ) -> Result<Arc<Self>> {
        let mut command = Command::new("/usr/bin/ssh");
        command
            .args(ssh_daemon_transport_arguments(&endpoint))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let mut child = command
            .spawn()
            .with_context(|| format!("launch SSH daemon transport to {}", endpoint.destination))?;
        let mut stdin = child.stdin.take().context("open SSH daemon stdin")?;
        let stdout = child.stdout.take().context("open SSH daemon stdout")?;
        let stderr = child.stderr.take().context("open SSH daemon stderr")?;

        let (outgoing_tx, mut outgoing_rx) = mpsc::unbounded_channel();
        let client = Arc::new(Self {
            outgoing: outgoing_tx,
            pending: Mutex::new(HashMap::new()),
            stream_subscriptions: Mutex::new(HashMap::new()),
            failure_tx: failure_tx.clone(),
            remote_path: Some(endpoint.remote_path.clone()),
            next_request_id: AtomicU64::new(1),
        });

        let writer_failure_tx = failure_tx.clone();
        let mut writer_stop_rx = stop_rx.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    changed = writer_stop_rx.changed() => {
                        if changed.is_err() || *writer_stop_rx.borrow() {
                            let _ = stdin.shutdown().await;
                            return;
                        }
                    }
                    message = outgoing_rx.recv() => {
                        let Some(message) = message else {
                            let _ = stdin.shutdown().await;
                            return;
                        };
                        let write_result = match message {
                            Message::Text(text) => {
                                if let Err(error) = stdin.write_all(text.as_bytes()).await {
                                    Err(error)
                                } else {
                                    stdin.write_all(b"\n").await
                                }
                            }
                            Message::Binary(data) => {
                                if let Err(error) = stdin.write_all(&data).await {
                                    Err(error)
                                } else {
                                    stdin.write_all(b"\n").await
                                }
                            }
                            Message::Close(_) => {
                                let _ = stdin.shutdown().await;
                                return;
                            }
                            _ => Ok(()),
                        };
                        if write_result.is_err() || stdin.flush().await.is_err() {
                            writer_failure_tx
                                .send(Some("daemon SSH writer failed".to_string()))
                                .ok();
                            return;
                        }
                    }
                }
            }
        });

        let reader_client = client.clone();
        let mut reader_stop_rx = stop_rx.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                tokio::select! {
                    changed = reader_stop_rx.changed() => {
                        if changed.is_err() || *reader_stop_rx.borrow() {
                            return;
                        }
                    }
                    line = lines.next_line() => {
                        match line {
                            Ok(Some(line)) => reader_client.consume_text_payload(&line).await,
                            Ok(None) => {
                                reader_client
                                    .report_failure("daemon SSH transport closed stdout".to_string())
                                    .await;
                                return;
                            }
                            Err(error) => {
                                reader_client
                                    .report_failure(format!("daemon SSH transport read failed: {error}"))
                                    .await;
                                return;
                            }
                        }
                    }
                }
            }
        });

        let stderr_failure_tx = failure_tx.clone();
        let mut stderr_stop_rx = stop_rx.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            loop {
                tokio::select! {
                    changed = stderr_stop_rx.changed() => {
                        if changed.is_err() || *stderr_stop_rx.borrow() {
                            return;
                        }
                    }
                    line = lines.next_line() => {
                        match line {
                            Ok(Some(line)) => {
                                let trimmed = line.trim();
                                if !trimmed.is_empty() {
                                    tracing::debug!(stderr = %trimmed, "daemon SSH stderr");
                                }
                            }
                            Ok(None) => return,
                            Err(error) => {
                                stderr_failure_tx
                                    .send(Some(format!("daemon SSH stderr read failed: {error}")))
                                    .ok();
                                return;
                            }
                        }
                    }
                }
            }
        });

        let wait_client = client.clone();
        tokio::spawn(async move {
            tokio::select! {
                changed = stop_rx.changed() => {
                    if changed.is_err() || *stop_rx.borrow() {
                        let _ = child.start_kill();
                        let _ = child.wait().await;
                    }
                }
                status = child.wait() => {
                    let detail = match status {
                        Ok(status) => format!("daemon SSH transport exited with {status}"),
                        Err(error) => format!("daemon SSH transport wait failed: {error}"),
                    };
                    wait_client.report_failure(detail).await;
                }
            }
        });

        Ok(client)
    }

    async fn hello(&self) -> Result<RemoteDaemonProxyHello> {
        let result = self
            .call("hello", serde_json::json!({}), Duration::from_secs(8))
            .await?;
        let capabilities = result
            .get("capabilities")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(ToOwned::to_owned)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        Ok(RemoteDaemonProxyHello {
            name: result
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("cmuxd-remote")
                .to_string(),
            version: result
                .get("version")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            capabilities,
            remote_path: result
                .get("remote_path")
                .or_else(|| result.get("remotePath"))
                .and_then(Value::as_str)
                .or(self.remote_path.as_deref())
                .unwrap_or("")
                .to_string(),
        })
    }

    async fn open_stream(&self, host: &str, port: u16) -> Result<String> {
        let result = self
            .call(
                "proxy.open",
                serde_json::json!({
                    "host": host,
                    "port": port,
                    "timeout_ms": 10_000,
                }),
                Duration::from_secs(12),
            )
            .await?;
        let stream_id = result
            .get("stream_id")
            .or_else(|| result.get("streamId"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| anyhow!("proxy.open missing stream_id"))?;
        Ok(stream_id.to_string())
    }

    async fn attach_stream(
        &self,
        stream_id: &str,
    ) -> Result<mpsc::UnboundedReceiver<RemoteStreamEvent>> {
        let stream_id = stream_id.trim().to_string();
        if stream_id.is_empty() {
            bail!("proxy.stream.subscribe requires stream_id");
        }
        let (tx, rx) = mpsc::unbounded_channel();
        self.stream_subscriptions
            .lock()
            .await
            .insert(stream_id.clone(), tx);
        let subscribe_result = self
            .call(
                "proxy.stream.subscribe",
                serde_json::json!({ "stream_id": stream_id }),
                Duration::from_secs(8),
            )
            .await;
        if let Err(error) = subscribe_result {
            self.stream_subscriptions
                .lock()
                .await
                .remove(stream_id.as_str());
            return Err(error);
        }
        Ok(rx)
    }

    async fn write_stream(&self, stream_id: &str, data: &[u8]) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        let encoded = base64::engine::general_purpose::STANDARD.encode(data);
        self.call(
            "proxy.write",
            serde_json::json!({
                "stream_id": stream_id,
                "data_base64": encoded,
            }),
            Duration::from_secs(8),
        )
        .await?;
        Ok(())
    }

    async fn close_stream(&self, stream_id: &str) {
        self.stream_subscriptions.lock().await.remove(stream_id);
        let _ = self
            .call(
                "proxy.close",
                serde_json::json!({ "stream_id": stream_id }),
                Duration::from_secs(4),
            )
            .await;
    }

    async fn call(&self, method: &str, params: Value, timeout_duration: Duration) -> Result<Value> {
        let id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let payload = serde_json::json!({
            "id": id,
            "method": method,
            "params": params,
        });
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id, tx);
        if let Err(error) = self.send_value(payload).await {
            self.pending.lock().await.remove(&id);
            return Err(error);
        }
        let response = tokio::time::timeout(timeout_duration, rx)
            .await
            .with_context(|| format!("daemon RPC timeout waiting for {method} response"))?
            .with_context(|| format!("daemon RPC {method} response channel closed"))?
            .map_err(|detail| anyhow!(detail))?;
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(response.get("result").cloned().unwrap_or(Value::Null));
        }
        let error_object = response.get("error").and_then(Value::as_object);
        let code = error_object
            .and_then(|object| object.get("code"))
            .and_then(Value::as_str)
            .unwrap_or("rpc_error");
        let message = error_object
            .and_then(|object| object.get("message"))
            .and_then(Value::as_str)
            .unwrap_or("daemon RPC call failed");
        bail!("{method} failed ({code}): {message}");
    }

    async fn send_value(&self, value: Value) -> Result<()> {
        let text = serde_json::to_string(&value).context("encode daemon RPC websocket payload")?;
        self.outgoing
            .send(Message::Text(text))
            .map_err(|_| anyhow!("daemon websocket writer is closed"))
    }

    async fn consume_message(&self, message: Message) {
        let value = match message {
            Message::Text(text) => serde_json::from_str::<Value>(&text).ok(),
            Message::Binary(data) => serde_json::from_slice::<Value>(&data).ok(),
            Message::Close(_) => {
                self.report_failure("daemon websocket closed".to_string())
                    .await;
                return;
            }
            _ => None,
        };
        let Some(value) = value else {
            return;
        };
        self.consume_value(value).await;
    }

    async fn consume_text_payload(&self, line: &str) {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return;
        }
        if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
            self.consume_value(value).await;
        }
    }

    async fn consume_value(&self, value: Value) {
        if let Some(id) = response_id(&value) {
            let pending = self.pending.lock().await.remove(&id);
            if let Some(pending) = pending {
                let _ = pending.send(Ok(value));
            }
            return;
        }
        self.consume_event(value).await;
    }

    async fn consume_event(&self, value: Value) {
        let event_name = value
            .get("event")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let stream_id = value
            .get("stream_id")
            .or_else(|| value.get("streamId"))
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        if event_name.is_empty() || stream_id.is_empty() {
            return;
        }

        let event = match event_name {
            "proxy.stream.data" => RemoteStreamEvent::Data(decode_event_data(&value)),
            "proxy.stream.eof" => RemoteStreamEvent::Eof(decode_event_data(&value)),
            "proxy.stream.error" => RemoteStreamEvent::Error(
                value
                    .get("error")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|error| !error.is_empty())
                    .unwrap_or("stream error")
                    .to_string(),
            ),
            _ => return,
        };
        let tx = if matches!(
            event,
            RemoteStreamEvent::Eof(_) | RemoteStreamEvent::Error(_)
        ) {
            self.stream_subscriptions.lock().await.remove(stream_id)
        } else {
            self.stream_subscriptions
                .lock()
                .await
                .get(stream_id)
                .cloned()
        };
        if let Some(tx) = tx {
            let _ = tx.send(event);
        }
    }

    async fn fail_all_pending(&self, detail: String) {
        let pending = {
            let mut pending = self.pending.lock().await;
            std::mem::take(&mut *pending)
        };
        for (_, tx) in pending {
            let _ = tx.send(Err(detail.clone()));
        }
    }

    async fn close_all_streams(&self, detail: &str) {
        let subscriptions = {
            let mut subscriptions = self.stream_subscriptions.lock().await;
            std::mem::take(&mut *subscriptions)
        };
        for (_, tx) in subscriptions {
            let _ = tx.send(RemoteStreamEvent::Error(detail.to_string()));
        }
    }

    async fn report_failure(&self, detail: String) {
        self.fail_all_pending(detail.clone()).await;
        self.close_all_streams(&detail).await;
        self.failure_tx.send(Some(detail)).ok();
    }
}

fn ssh_daemon_transport_arguments(endpoint: &RemoteDaemonSshEndpoint) -> Vec<String> {
    let script = format!(
        "exec {} serve --stdio",
        shell_single_quoted(&endpoint.remote_path)
    );
    let command = remote_shell_command(&script);
    let mut args = vec!["-T".to_string()];
    args.extend(ssh_common_arguments(endpoint));
    args.extend(["-o".to_string(), "RequestTTY=no".to_string()]);
    args.push(endpoint.destination.clone());
    args.push(command);
    args
}

fn ssh_common_arguments(endpoint: &RemoteDaemonSshEndpoint) -> Vec<String> {
    let effective_options = background_ssh_options(&endpoint.ssh_options);
    let mut args = vec![
        "-o".to_string(),
        "ConnectTimeout=6".to_string(),
        "-o".to_string(),
        "ServerAliveInterval=20".to_string(),
        "-o".to_string(),
        "ServerAliveCountMax=2".to_string(),
    ];
    if !has_ssh_option_key(&effective_options, "StrictHostKeyChecking") {
        args.extend([
            "-o".to_string(),
            "StrictHostKeyChecking=accept-new".to_string(),
        ]);
    }
    args.extend(["-o".to_string(), "BatchMode=yes".to_string()]);
    args.extend(["-o".to_string(), "ControlMaster=no".to_string()]);
    if let Some(port) = endpoint.port {
        args.extend(["-p".to_string(), port.to_string()]);
    }
    if let Some(identity_file) = endpoint
        .identity_file
        .as_ref()
        .and_then(|value| non_empty(value.clone()))
    {
        args.extend(["-i".to_string(), identity_file]);
    }
    for option in effective_options {
        args.extend(["-o".to_string(), option]);
    }
    args
}

fn background_ssh_options(options: &[String]) -> Vec<String> {
    options
        .iter()
        .filter_map(|option| non_empty(option.clone()))
        .filter(|option| {
            ssh_option_key(option)
                .is_none_or(|key| key != "controlmaster" && key != "controlpersist")
        })
        .collect()
}

fn has_ssh_option_key(options: &[String], key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    options
        .iter()
        .any(|option| ssh_option_key(option).as_deref() == Some(key.as_str()))
}

fn ssh_option_key(option: &str) -> Option<String> {
    option
        .trim()
        .split(|ch: char| ch == '=' || ch.is_whitespace())
        .next()
        .and_then(|key| non_empty(key.to_string()))
        .map(|key| key.to_ascii_lowercase())
}

fn remote_shell_command(script: &str) -> String {
    format!("sh -c {}", shell_single_quoted(script))
}

fn shell_single_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn non_empty(raw: String) -> Option<String> {
    let trimmed = raw.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn response_id(value: &Value) -> Option<u64> {
    value
        .get("id")
        .and_then(|id| id.as_u64().or_else(|| id.as_str()?.parse::<u64>().ok()))
}

fn decode_event_data(value: &Value) -> Vec<u8> {
    value
        .get("data_base64")
        .or_else(|| value.get("dataBase64"))
        .and_then(Value::as_str)
        .and_then(|encoded| {
            base64::engine::general_purpose::STANDARD
                .decode(encoded.as_bytes())
                .ok()
        })
        .unwrap_or_default()
}

enum RemoteStreamEvent {
    Data(Vec<u8>),
    Eof(Vec<u8>),
    Error(String),
}

struct EstablishedProxyStream {
    local: TcpStream,
    stream_id: String,
    events: mpsc::UnboundedReceiver<RemoteStreamEvent>,
    pending_payload: Vec<u8>,
    rewrite_loopback_headers: bool,
}

async fn handle_proxy_connection(local: TcpStream, rpc: Arc<RemoteDaemonRpcClient>) -> Result<()> {
    let EstablishedProxyStream {
        local,
        stream_id,
        events,
        pending_payload,
        rewrite_loopback_headers,
    } = establish_proxy_stream(local, rpc.clone()).await?;
    pump_proxy_stream(
        local,
        rpc,
        stream_id,
        events,
        pending_payload,
        rewrite_loopback_headers,
    )
    .await
}

async fn establish_proxy_stream(
    mut local: TcpStream,
    rpc: Arc<RemoteDaemonRpcClient>,
) -> Result<EstablishedProxyStream> {
    let mut buffer = Vec::new();
    let mut protocol = HandshakeProtocol::Undecided;
    let mut socks_stage = SocksStage::Greeting;
    loop {
        if buffer.len() > MAX_HANDSHAKE_BYTES {
            bail!("proxy handshake exceeded {MAX_HANDSHAKE_BYTES} bytes");
        }
        if matches!(protocol, HandshakeProtocol::Undecided) {
            if buffer.is_empty() {
                read_more_handshake_bytes(&mut local, &mut buffer).await?;
                continue;
            }
            protocol = if buffer.first() == Some(&0x05) {
                HandshakeProtocol::Socks5
            } else {
                HandshakeProtocol::Connect
            };
        }

        match protocol {
            HandshakeProtocol::Undecided => {}
            HandshakeProtocol::Socks5 => match socks_stage {
                SocksStage::Greeting => {
                    if buffer.len() < 2 {
                        read_more_handshake_bytes(&mut local, &mut buffer).await?;
                        continue;
                    }
                    let method_count = usize::from(buffer[1]);
                    let total = 2usize.saturating_add(method_count);
                    if buffer.len() < total {
                        read_more_handshake_bytes(&mut local, &mut buffer).await?;
                        continue;
                    }
                    let supports_no_auth = buffer[2..total].contains(&0x00);
                    buffer.drain(0..total);
                    if !supports_no_auth {
                        let _ = local.write_all(&[0x05, 0xff]).await;
                        bail!("SOCKS5 client did not offer no-auth method");
                    }
                    local.write_all(&[0x05, 0x00]).await?;
                    socks_stage = SocksStage::Request;
                }
                SocksStage::Request => {
                    let Some(request) = parse_socks_request(&buffer)? else {
                        read_more_handshake_bytes(&mut local, &mut buffer).await?;
                        continue;
                    };
                    let pending_payload = buffer
                        .get(request.consumed_bytes..)
                        .map(ToOwned::to_owned)
                        .unwrap_or_default();
                    if request.command != 0x01 {
                        let _ = local
                            .write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                            .await;
                        bail!("SOCKS5 command is not CONNECT");
                    }
                    return open_proxy_stream(
                        local,
                        rpc,
                        request.host,
                        request.port,
                        &mut [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0],
                        &mut [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0],
                        pending_payload,
                    )
                    .await;
                }
            },
            HandshakeProtocol::Connect => {
                if let Some((host, port, consumed_bytes)) = parse_connect_request(&buffer)? {
                    let pending_payload = buffer
                        .get(consumed_bytes..)
                        .map(ToOwned::to_owned)
                        .unwrap_or_default();
                    let mut success =
                        b"HTTP/1.1 200 Connection Established\r\nProxy-Agent: cmux\r\n\r\n"
                            .to_vec();
                    let mut failure =
                        b"HTTP/1.1 502 Bad Gateway\r\nProxy-Agent: cmux\r\nConnection: close\r\n\r\n"
                            .to_vec();
                    return open_proxy_stream(
                        local,
                        rpc,
                        host,
                        port,
                        &mut success,
                        &mut failure,
                        pending_payload,
                    )
                    .await;
                }
                read_more_handshake_bytes(&mut local, &mut buffer).await?;
            }
        }
    }
}

async fn read_more_handshake_bytes(local: &mut TcpStream, buffer: &mut Vec<u8>) -> Result<()> {
    let mut chunk = [0u8; 4096];
    let read = local
        .read(&mut chunk)
        .await
        .context("read proxy handshake")?;
    if read == 0 {
        bail!("proxy client closed during handshake");
    }
    buffer.extend_from_slice(&chunk[..read]);
    Ok(())
}

async fn open_proxy_stream(
    mut local: TcpStream,
    rpc: Arc<RemoteDaemonRpcClient>,
    host: String,
    port: u16,
    success_response: &mut [u8],
    failure_response: &mut [u8],
    pending_payload: Vec<u8>,
) -> Result<EstablishedProxyStream> {
    let target_host = normalized_proxy_target_host(&host);
    let rewrite_loopback_headers = is_loopback_alias_host(&host);
    let stream_id = match rpc.open_stream(&target_host, port).await {
        Ok(stream_id) => stream_id,
        Err(error) => {
            let _ = local.write_all(failure_response).await;
            return Err(error);
        }
    };
    let events = match rpc.attach_stream(&stream_id).await {
        Ok(events) => events,
        Err(error) => {
            rpc.close_stream(&stream_id).await;
            let _ = local.write_all(failure_response).await;
            return Err(error);
        }
    };
    local.write_all(success_response).await?;
    Ok(EstablishedProxyStream {
        local,
        stream_id,
        events,
        pending_payload,
        rewrite_loopback_headers,
    })
}

async fn pump_proxy_stream(
    local: TcpStream,
    rpc: Arc<RemoteDaemonRpcClient>,
    stream_id: String,
    mut events: mpsc::UnboundedReceiver<RemoteStreamEvent>,
    pending_payload: Vec<u8>,
    rewrite_loopback_headers: bool,
) -> Result<()> {
    let (mut local_read, mut local_write) = local.into_split();
    let local_rpc = rpc.clone();
    let local_stream_id = stream_id.clone();
    let mut local_to_remote = tokio::spawn(async move {
        let mut request_rewriter = LoopbackHTTPHeaderRewriter::new(
            rewrite_loopback_headers,
            REMOTE_LOOPBACK_PROXY_ALIAS_HOST,
            "localhost",
        );
        if !pending_payload.is_empty() {
            let pending_payload = request_rewriter.rewrite_next(&pending_payload, false);
            if !pending_payload.is_empty() {
                local_rpc
                    .write_stream(&local_stream_id, &pending_payload)
                    .await?;
            }
        }
        let mut chunk = [0u8; 32 * 1024];
        loop {
            let read = local_read
                .read(&mut chunk)
                .await
                .context("read local proxy payload")?;
            if read == 0 {
                let final_payload = request_rewriter.rewrite_next(&[], true);
                if !final_payload.is_empty() {
                    local_rpc
                        .write_stream(&local_stream_id, &final_payload)
                        .await?;
                }
                return Ok::<(), anyhow::Error>(());
            }
            let outgoing = request_rewriter.rewrite_next(&chunk[..read], false);
            if outgoing.is_empty() {
                continue;
            }
            local_rpc.write_stream(&local_stream_id, &outgoing).await?;
        }
    });

    let mut local_read_finished = false;
    let mut response_rewriter = LoopbackHTTPHeaderRewriter::new(
        rewrite_loopback_headers,
        "localhost",
        REMOTE_LOOPBACK_PROXY_ALIAS_HOST,
    );
    loop {
        tokio::select! {
            local_result = &mut local_to_remote, if !local_read_finished => {
                local_read_finished = true;
                match local_result {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => {
                        rpc.close_stream(&stream_id).await;
                        return Err(error);
                    }
                    Err(error) => {
                        rpc.close_stream(&stream_id).await;
                        return Err(anyhow!("local proxy forwarding task failed: {error}"));
                    }
                }
            }
            event = events.recv() => {
                match event {
                    Some(RemoteStreamEvent::Data(data)) => {
                        let data = response_rewriter.rewrite_next(&data, false);
                        if !data.is_empty() {
                            local_write.write_all(&data).await?;
                        }
                    }
                    Some(RemoteStreamEvent::Eof(data)) => {
                        let data = response_rewriter.rewrite_next(&data, true);
                        if !data.is_empty() {
                            local_write.write_all(&data).await?;
                        }
                        let _ = local_write.shutdown().await;
                        rpc.close_stream(&stream_id).await;
                        local_to_remote.abort();
                        return Ok(());
                    }
                    Some(RemoteStreamEvent::Error(detail)) => {
                        rpc.close_stream(&stream_id).await;
                        local_to_remote.abort();
                        bail!("proxy.stream failed: {detail}");
                    }
                    None => {
                        rpc.close_stream(&stream_id).await;
                        local_to_remote.abort();
                        bail!("proxy stream subscription closed");
                    }
                }
            }
        }
    }
}

enum HandshakeProtocol {
    Undecided,
    Socks5,
    Connect,
}

enum SocksStage {
    Greeting,
    Request,
}

struct SocksRequest {
    host: String,
    port: u16,
    command: u8,
    consumed_bytes: usize,
}

fn parse_socks_request(data: &[u8]) -> Result<Option<SocksRequest>> {
    if data.len() < 4 {
        return Ok(None);
    }
    if data[0] != 0x05 {
        bail!("invalid SOCKS version");
    }
    let command = data[1];
    let address_type = data[3];
    let mut cursor = 4usize;
    let host = match address_type {
        0x01 => {
            if data.len() < cursor.saturating_add(4).saturating_add(2) {
                return Ok(None);
            }
            let host = format!(
                "{}.{}.{}.{}",
                data[cursor],
                data[cursor + 1],
                data[cursor + 2],
                data[cursor + 3]
            );
            cursor += 4;
            host
        }
        0x03 => {
            if data.len() < cursor.saturating_add(1) {
                return Ok(None);
            }
            let length = usize::from(data[cursor]);
            cursor += 1;
            if data.len() < cursor.saturating_add(length).saturating_add(2) {
                return Ok(None);
            }
            let host = String::from_utf8(data[cursor..cursor + length].to_vec())
                .context("decode SOCKS domain name")?;
            cursor += length;
            host
        }
        0x04 => {
            if data.len() < cursor.saturating_add(16).saturating_add(2) {
                return Ok(None);
            }
            let octets = data[cursor..cursor + 16]
                .chunks(2)
                .map(|chunk| {
                    let high = chunk.first().copied().unwrap_or(0);
                    let low = chunk.get(1).copied().unwrap_or(0);
                    format!("{:x}", u16::from_be_bytes([high, low]))
                })
                .collect::<Vec<_>>();
            cursor += 16;
            octets.join(":")
        }
        _ => bail!("invalid SOCKS address type"),
    };
    if host.trim().is_empty() {
        bail!("empty SOCKS host");
    }
    if data.len() < cursor.saturating_add(2) {
        return Ok(None);
    }
    let port = u16::from_be_bytes([data[cursor], data[cursor + 1]]);
    cursor += 2;
    if port == 0 {
        bail!("invalid SOCKS port");
    }
    Ok(Some(SocksRequest {
        host,
        port,
        command,
        consumed_bytes: cursor,
    }))
}

fn parse_connect_request(data: &[u8]) -> Result<Option<(String, u16, usize)>> {
    let Some(header_end) = find_header_end(data) else {
        return Ok(None);
    };
    let header_text =
        std::str::from_utf8(&data[..header_end]).context("decode HTTP CONNECT header")?;
    let first_line = header_text.lines().next().unwrap_or("").trim();
    let parts = first_line.split_whitespace().collect::<Vec<_>>();
    if parts.len() < 2 || !parts[0].eq_ignore_ascii_case("CONNECT") {
        bail!("invalid HTTP CONNECT request");
    }
    let (host, port) = parse_connect_authority(parts[1])
        .ok_or_else(|| anyhow!("invalid HTTP CONNECT authority"))?;
    Ok(Some((host, port, header_end)))
}

fn find_header_end(data: &[u8]) -> Option<usize> {
    data.windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| index + 4)
}

fn parse_connect_authority(authority: &str) -> Option<(String, u16)> {
    let trimmed = authority.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(rest) = trimmed.strip_prefix('[') {
        let closing = rest.find(']')?;
        let host = &rest[..closing];
        let port_text = rest.get(closing + 1..)?.strip_prefix(':')?;
        let port = port_text.parse::<u16>().ok().filter(|port| *port > 0)?;
        return Some((host.to_string(), port));
    }
    let colon = trimmed.rfind(':')?;
    let host = &trimmed[..colon];
    let port = trimmed[colon + 1..]
        .parse::<u16>()
        .ok()
        .filter(|port| *port > 0)?;
    if host.is_empty() {
        return None;
    }
    Some((host.to_string(), port))
}

fn normalized_proxy_target_host(host: &str) -> String {
    if is_loopback_alias_host(host) {
        "127.0.0.1".to_string()
    } else {
        host.to_string()
    }
}

fn is_loopback_alias_host(host: &str) -> bool {
    host.trim().trim_matches('.').to_ascii_lowercase() == REMOTE_LOOPBACK_PROXY_ALIAS_HOST
}

struct LoopbackHTTPHeaderRewriter {
    enabled: bool,
    from: &'static str,
    to: &'static str,
    pending: Vec<u8>,
    forwarded_headers: bool,
}

impl LoopbackHTTPHeaderRewriter {
    fn new(enabled: bool, from: &'static str, to: &'static str) -> Self {
        Self {
            enabled,
            from,
            to,
            pending: Vec::new(),
            forwarded_headers: false,
        }
    }

    fn rewrite_next(&mut self, data: &[u8], eof: bool) -> Vec<u8> {
        if !self.enabled || self.forwarded_headers {
            return data.to_vec();
        }
        self.pending.extend_from_slice(data);
        if self.pending.len() > MAX_HANDSHAKE_BYTES {
            self.forwarded_headers = true;
            return rewrite_header_block(&std::mem::take(&mut self.pending), self.from, self.to);
        }
        if find_header_end(&self.pending).is_none() && !eof {
            return Vec::new();
        }
        self.forwarded_headers = true;
        rewrite_header_block(&std::mem::take(&mut self.pending), self.from, self.to)
    }
}

fn rewrite_header_block(data: &[u8], from: &str, to: &str) -> Vec<u8> {
    let header_end = find_header_end(data).unwrap_or(data.len());
    let Ok(header_text) = std::str::from_utf8(&data[..header_end]) else {
        return data.to_vec();
    };
    let rewritten = replace_ascii_case_insensitive(header_text, from, to);
    if rewritten == header_text {
        return data.to_vec();
    }
    let mut output = rewritten.into_bytes();
    if header_end < data.len() {
        output.extend_from_slice(&data[header_end..]);
    }
    output
}

fn replace_ascii_case_insensitive(input: &str, needle: &str, replacement: &str) -> String {
    let lower_input = input.to_ascii_lowercase();
    let lower_needle = needle.to_ascii_lowercase();
    let mut cursor = 0usize;
    let mut output = String::with_capacity(input.len());
    while let Some(relative_index) = lower_input[cursor..].find(&lower_needle) {
        let index = cursor + relative_index;
        output.push_str(&input[cursor..index]);
        output.push_str(replacement);
        cursor = index.saturating_add(needle.len());
    }
    output.push_str(&input[cursor..]);
    output
}
