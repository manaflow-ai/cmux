use async_trait::async_trait;
use axum::body::Body;
use clap::Parser;
use cmux_sandbox::bubblewrap::BubblewrapService;
use cmux_sandbox::build_router;
use cmux_sandbox::errors::{SandboxError, SandboxResult};
use cmux_sandbox::models::{
    BridgeRequest, BridgeResponse, CreateSandboxRequest, ExecRequest, ExecResponse, GhRequest,
    GhResponse, HostEvent, NotificationLevel, NotificationRequest, OpenUrlRequest, SandboxSummary,
};
use cmux_sandbox::notifications::NotificationStore;
use cmux_sandbox::service::{GhAuthCache, GhResponseRegistry, HostEventSender, SandboxService};
use cmux_sandbox::DEFAULT_HTTP_PORT;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, UnixListener};
use tokio::time::{sleep, Duration};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

#[derive(Parser, Debug)]
#[command(name = "cmux-sandboxd", author, version)]
struct Options {
    /// Address the HTTP server binds to
    #[arg(long, default_value = "0.0.0.0")]
    bind: String,
    /// Port for the HTTP server
    #[arg(long, default_value_t = DEFAULT_HTTP_PORT, env = "CMUX_SANDBOX_PORT")]
    port: u16,
    /// Directory used for sandbox workspaces
    #[arg(long, default_value = "/var/lib/cmux/sandboxes")]
    data_dir: PathBuf,
    /// Directory used for logs
    #[arg(long, default_value = "/var/log/cmux", env = "CMUX_SANDBOX_LOG_DIR")]
    log_dir: PathBuf,
    /// Path for the Unix socket used by sandboxes for bridge commands (open-url, gh, etc.)
    #[arg(
        long,
        default_value = "/var/run/cmux/bridge.sock",
        env = "CMUX_BRIDGE_SOCKET"
    )]
    bridge_socket: PathBuf,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let options = Options::parse();
    let _guard = init_tracing(&options.log_dir);

    run_server(options).await;

    Ok(())
}

fn init_tracing(log_dir: &PathBuf) -> Option<tracing_appender::non_blocking::WorkerGuard> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    let stdout_layer = tracing_subscriber::fmt::layer().with_target(false);

    // Try to create log dir
    if let Err(e) = std::fs::create_dir_all(log_dir) {
        eprintln!(
            "Failed to create log directory {:?}: {}. Logging to file disabled.",
            log_dir, e
        );
        tracing_subscriber::registry()
            .with(filter)
            .with(stdout_layer)
            .init();
        return None;
    }

    let file_appender = tracing_appender::rolling::daily(log_dir, "cmux-sandboxd.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);

    let file_layer = tracing_subscriber::fmt::layer()
        .with_writer(non_blocking)
        .with_target(false)
        .with_ansi(false);

    tracing_subscriber::registry()
        .with(filter)
        .with(stdout_layer)
        .with(file_layer)
        .init();

    Some(guard)
}

async fn shutdown_signal() {
    if let Err(error) = tokio::signal::ctrl_c().await {
        tracing::error!("failed to listen for shutdown signal: {error}");
    }
    tracing::info!("shutdown signal received");
}

async fn run_server(options: Options) {
    use std::collections::HashMap;
    use tokio::sync::Mutex;

    let bind_ip = parse_bind_ip(&options.bind);
    // Broadcast channel for host-directed events (open-url, notifications, gh)
    let (host_event_tx, _) = tokio::sync::broadcast::channel::<HostEvent>(64);

    // Registry for pending gh requests
    let gh_responses: GhResponseRegistry = Arc::new(Mutex::new(HashMap::new()));

    // Cache for gh auth status (populated by TUI client on connect)
    let gh_auth_cache: GhAuthCache = Arc::new(Mutex::new(None));
    let notifications = NotificationStore::new();

    let service = build_service(&options).await;
    let app = build_router(
        service,
        host_event_tx.clone(),
        gh_responses.clone(),
        gh_auth_cache.clone(),
        notifications.clone(),
    );

    // Start the unified Unix socket listener for bridge requests from sandboxes
    let socket_path = options.bridge_socket.clone();
    let bridge_host_events = host_event_tx.clone();
    let bridge_gh_responses = gh_responses.clone();
    let bridge_gh_auth_cache = gh_auth_cache.clone();
    let bridge_notifications = notifications.clone();
    tokio::spawn(async move {
        if let Err(e) = run_bridge_socket(
            &socket_path,
            bridge_host_events,
            bridge_gh_responses,
            bridge_gh_auth_cache,
            bridge_notifications,
        )
        .await
        {
            tracing::error!("bridge socket failed: {e}");
        }
    });

    let addr = SocketAddr::new(bind_ip, options.port);
    let retry_delay = Duration::from_secs(5);

    loop {
        match TcpListener::bind(addr).await {
            Ok(listener) => {
                tracing::info!("cmux-sandboxd listening on http://{}", addr);
                tracing::info!("HTTP/1.1 and HTTP/2 are enabled");

                match axum::serve(listener, app.clone())
                    .with_graceful_shutdown(shutdown_signal())
                    .await
                {
                    Ok(()) => {
                        tracing::info!("server shut down gracefully");
                        break;
                    }
                    Err(error) => {
                        tracing::error!(?error, "server error; restarting");
                    }
                }
            }
            Err(error) => {
                tracing::error!(?error, %addr, "failed to bind listener");
            }
        }

        tracing::info!(
            "retrying server startup in {} seconds",
            retry_delay.as_secs()
        );
        sleep(retry_delay).await;
    }
}

fn parse_bind_ip(bind: &str) -> IpAddr {
    match bind.parse() {
        Ok(ip) => ip,
        Err(error) => {
            tracing::error!(
                ?error,
                %bind,
                "invalid bind address; defaulting to 0.0.0.0"
            );
            IpAddr::V4(Ipv4Addr::UNSPECIFIED)
        }
    }
}

async fn build_service(options: &Options) -> Arc<dyn SandboxService> {
    match BubblewrapService::new(options.data_dir.clone(), options.port).await {
        Ok(service) => Arc::new(service),
        Err(error) => {
            tracing::error!(
                ?error,
                "failed to initialize bubblewrap service; running in degraded mode"
            );
            Arc::new(UnavailableSandboxService::new(error.to_string()))
        }
    }
}

/// Run a unified Unix socket listener for bridge requests from sandboxes.
/// Protocol: JSON request line with tagged union, JSON response line.
async fn run_bridge_socket(
    socket_path: &PathBuf,
    host_events: HostEventSender,
    gh_responses: GhResponseRegistry,
    gh_auth_cache: GhAuthCache,
    notifications: NotificationStore,
) -> anyhow::Result<()> {
    // Ensure parent directory exists
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Remove existing socket file if it exists
    if socket_path.exists() {
        std::fs::remove_file(socket_path)?;
    }

    let listener = UnixListener::bind(socket_path)?;
    tracing::info!("bridge socket listening on {:?}", socket_path);

    // Make socket world-writable so sandboxes can connect
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o666))?;
    }

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                let host_events = host_events.clone();
                let gh_responses = gh_responses.clone();
                let gh_auth_cache = gh_auth_cache.clone();
                let notifications = notifications.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_bridge_connection(
                        stream,
                        host_events,
                        gh_responses,
                        gh_auth_cache,
                        notifications,
                    )
                    .await
                    {
                        tracing::warn!("bridge connection error: {e}");
                    }
                });
            }
            Err(e) => {
                tracing::error!("bridge socket accept error: {e}");
            }
        }
    }
}

/// Handle a single bridge connection.
async fn handle_bridge_connection(
    stream: tokio::net::UnixStream,
    host_events: HostEventSender,
    gh_responses: GhResponseRegistry,
    gh_auth_cache: GhAuthCache,
    notifications: NotificationStore,
) -> anyhow::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut line = String::new();

    // Read a single line containing the JSON request
    reader.read_line(&mut line).await?;
    let trimmed = line.trim();

    if trimmed.is_empty() {
        let response = BridgeResponse::Error {
            message: "Empty request".to_string(),
        };
        writer
            .write_all(serde_json::to_string(&response)?.as_bytes())
            .await?;
        writer.write_all(b"\n").await?;
        return Ok(());
    }

    let request: BridgeRequest = match serde_json::from_str(trimmed) {
        Ok(req) => req,
        Err(e) => {
            let response = BridgeResponse::Error {
                message: format!("Invalid JSON request: {e}"),
            };
            writer
                .write_all(serde_json::to_string(&response)?.as_bytes())
                .await?;
            writer.write_all(b"\n").await?;
            return Ok(());
        }
    };

    let response = match request {
        BridgeRequest::OpenUrl {
            url,
            sandbox_id,
            tab_id,
        } => handle_open_url_request(&host_events, url, sandbox_id, tab_id).await,
        BridgeRequest::Gh {
            request_id,
            args,
            stdin,
            sandbox_id,
            tab_id,
        } => {
            handle_gh_request(
                &host_events,
                &gh_responses,
                &gh_auth_cache,
                request_id,
                args,
                stdin,
                sandbox_id,
                tab_id,
            )
            .await
        }
        BridgeRequest::Notify {
            message,
            level,
            sandbox_id,
            tab_id,
            pane_id,
        } => {
            handle_notify_request(
                &host_events,
                &notifications,
                message,
                level,
                sandbox_id,
                tab_id,
                pane_id,
            )
            .await
        }
    };

    writer
        .write_all(serde_json::to_string(&response)?.as_bytes())
        .await?;
    writer.write_all(b"\n").await?;

    Ok(())
}

async fn handle_open_url_request(
    host_events: &HostEventSender,
    url: String,
    sandbox_id: Option<String>,
    tab_id: Option<String>,
) -> BridgeResponse {
    // Validate URL
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return BridgeResponse::Error {
            message: "URL must start with http:// or https://".to_string(),
        };
    }

    // Broadcast URL to connected clients
    match host_events.send(HostEvent::OpenUrl(OpenUrlRequest {
        url: url.clone(),
        sandbox_id,
        tab_id,
    })) {
        Ok(receivers) => {
            tracing::info!("broadcast URL to {} clients: {}", receivers, url);
            BridgeResponse::Ok
        }
        Err(_) => {
            tracing::warn!("no clients connected to receive URL: {}", url);
            BridgeResponse::Error {
                message: "No clients connected".to_string(),
            }
        }
    }
}

async fn handle_notify_request(
    host_events: &HostEventSender,
    notifications: &NotificationStore,
    message: String,
    level: NotificationLevel,
    sandbox_id: Option<String>,
    tab_id: Option<String>,
    pane_id: Option<String>,
) -> BridgeResponse {
    let _ = notifications
        .record(
            message.clone(),
            level,
            sandbox_id.clone(),
            tab_id.clone(),
            pane_id.clone(),
        )
        .await;
    match host_events.send(HostEvent::Notification(NotificationRequest {
        message: message.clone(),
        level,
        sandbox_id,
        tab_id,
        pane_id,
    })) {
        Ok(receivers) => {
            tracing::info!(
                "broadcast notification to {} clients: {}",
                receivers,
                message
            );
            BridgeResponse::Ok
        }
        Err(_) => {
            tracing::warn!("no clients connected to receive notification: {}", message);
            // Return Ok anyway since notification delivery is best-effort
            BridgeResponse::Ok
        }
    }
}

/// Check if args represent a `gh auth status` command that can use cache.
/// Matches `gh auth status` and variations like `gh auth status --hostname github.com`.
fn is_gh_auth_status(args: &[String]) -> bool {
    args.len() >= 2 && args[0] == "auth" && args[1] == "status"
}

#[allow(clippy::too_many_arguments)]
async fn handle_gh_request(
    host_events: &HostEventSender,
    gh_responses: &GhResponseRegistry,
    gh_auth_cache: &GhAuthCache,
    mut request_id: String,
    args: Vec<String>,
    stdin: Option<String>,
    sandbox_id: Option<String>,
    tab_id: Option<String>,
) -> BridgeResponse {
    // Generate a request ID if not provided
    if request_id.is_empty() {
        request_id = uuid::Uuid::new_v4().to_string();
    }

    tracing::info!("gh request: id={} args={:?}", request_id, args);

    // Check cache for `gh auth status` requests
    if is_gh_auth_status(&args) && stdin.is_none() {
        let cache = gh_auth_cache.lock().await;
        if let Some(cached) = cache.as_ref() {
            tracing::info!("gh auth status: returning cached result");
            return BridgeResponse::Gh {
                request_id,
                exit_code: cached.exit_code,
                stdout: cached.stdout.clone(),
                stderr: cached.stderr.clone(),
            };
        }
        // Cache empty - fall through to original codepath
        tracing::info!("gh auth status: cache empty, using WebSocket round-trip");
    }

    // Create a oneshot channel for the response
    let (response_tx, response_rx) = tokio::sync::oneshot::channel::<GhResponse>();

    // Register the pending request
    {
        let mut registry = gh_responses.lock().await;
        registry.insert(request_id.clone(), response_tx);
    }

    // Broadcast the request to connected clients
    let gh_request = GhRequest {
        request_id: request_id.clone(),
        args,
        stdin,
        sandbox_id,
        tab_id,
    };

    match host_events.send(HostEvent::GhRequest(gh_request)) {
        Ok(receivers) => {
            tracing::info!(
                "broadcast gh request to {} clients: id={}",
                receivers,
                request_id
            );
        }
        Err(_) => {
            // No receivers - clean up and return error
            {
                let mut registry = gh_responses.lock().await;
                registry.remove(&request_id);
            }
            return BridgeResponse::Gh {
                request_id,
                exit_code: 1,
                stdout: String::new(),
                stderr: "No clients connected to handle gh request".to_string(),
            };
        }
    }

    // Wait for the response with a timeout
    let response = match tokio::time::timeout(Duration::from_secs(30), response_rx).await {
        Ok(Ok(response)) => response,
        Ok(Err(_)) => GhResponse {
            request_id: request_id.clone(),
            exit_code: 1,
            stdout: String::new(),
            stderr: "Response channel closed".to_string(),
        },
        Err(_) => {
            // Timeout - clean up pending request
            {
                let mut registry = gh_responses.lock().await;
                registry.remove(&request_id);
            }
            GhResponse {
                request_id: request_id.clone(),
                exit_code: 1,
                stdout: String::new(),
                stderr: "Timeout waiting for gh response".to_string(),
            }
        }
    };

    tracing::info!(
        "gh response: id={} exit_code={}",
        response.request_id,
        response.exit_code
    );

    BridgeResponse::Gh {
        request_id: response.request_id,
        exit_code: response.exit_code,
        stdout: response.stdout,
        stderr: response.stderr,
    }
}

#[derive(Clone)]
struct UnavailableSandboxService {
    reason: String,
}

impl UnavailableSandboxService {
    fn new(reason: String) -> Self {
        Self { reason }
    }

    fn error(&self, operation: &str) -> SandboxError {
        SandboxError::Internal(format!(
            "{operation} unavailable: sandbox service failed to start ({})",
            self.reason
        ))
    }
}

#[async_trait]
impl SandboxService for UnavailableSandboxService {
    async fn create(&self, _request: CreateSandboxRequest) -> SandboxResult<SandboxSummary> {
        Err(self.error("create sandbox"))
    }

    async fn list(&self) -> SandboxResult<Vec<SandboxSummary>> {
        Err(self.error("list sandboxes"))
    }

    async fn get(&self, _id: String) -> SandboxResult<Option<SandboxSummary>> {
        Err(self.error("get sandbox"))
    }

    async fn exec(&self, _id: String, _exec: ExecRequest) -> SandboxResult<ExecResponse> {
        Err(self.error("exec sandbox command"))
    }

    async fn attach(
        &self,
        _id: String,
        _socket: axum::extract::ws::WebSocket,
        _initial_size: Option<(u16, u16)>,
        _command: Option<Vec<String>>,
        _tty: bool,
    ) -> SandboxResult<()> {
        Err(self.error("attach sandbox session"))
    }

    async fn mux_attach(
        &self,
        _socket: axum::extract::ws::WebSocket,
        _host_event_rx: cmux_sandbox::service::HostEventReceiver,
        _gh_responses: GhResponseRegistry,
        _gh_auth_cache: GhAuthCache,
    ) -> SandboxResult<()> {
        Err(self.error("mux attach"))
    }

    async fn proxy(
        &self,
        _id: String,
        _port: u16,
        _socket: axum::extract::ws::WebSocket,
    ) -> SandboxResult<()> {
        Err(self.error("proxy sandbox port"))
    }

    async fn upload_archive(&self, _id: String, _archive: Body) -> SandboxResult<()> {
        Err(self.error("upload archive"))
    }

    async fn delete(&self, _id: String) -> SandboxResult<Option<SandboxSummary>> {
        Err(self.error("delete sandbox"))
    }
}
