use crate::errors::{ErrorBody, SandboxError, SandboxResult};
use crate::models::{
    AwaitReadyRequest, AwaitReadyResponse, CreateSandboxRequest, ExecRequest, ExecResponse,
    HealthResponse, HostEvent, NotificationLevel, NotificationLogEntry, NotificationRequest,
    OpenUrlRequest, PruneRequest, PruneResponse, PrunedItem, PtyCaptureResponse, PtyCreateRequest,
    PtyInputRequest, PtyResizeRequest, PtySessionInfo, PtySessionList, SandboxSummary,
    ServiceReadiness,
};
use crate::notifications::NotificationStore;
use crate::service::{AppState, GhResponseRegistry, HostEventSender, SandboxService};
use crate::vnc_proxy::proxy_vnc_websocket;
use axum::body::Body;
use axum::extract::ws::WebSocketUpgrade;
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::header::HOST;
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get, post};
use axum::{Json, Router};
use serde::Deserialize;
use std::net::SocketAddr;
use std::sync::Arc;
use utoipa::OpenApi as UtoipaOpenApi;
use utoipa_swagger_ui::SwaggerUi;
use uuid::Uuid;

#[derive(Deserialize)]
struct ProxyParams {
    port: u16,
}

#[derive(Deserialize)]
struct AttachParams {
    cols: Option<u16>,
    rows: Option<u16>,
    command: Option<String>,
    #[serde(default = "default_tty")]
    tty: bool,
}

fn default_tty() -> bool {
    true
}

#[derive(UtoipaOpenApi)]
#[openapi(
    paths(
        create_sandbox,
        list_sandboxes,
        get_sandbox,
        exec_sandbox,
        delete_sandbox,
        health,
        upload_files,
        open_url_post,
        list_notifications,
        send_notification,
        prune_orphaned,
        await_ready,
        pty_list_sessions,
        pty_create_session,
        pty_get_session,
        pty_delete_session,
        pty_resize_session,
        pty_capture_session,
        pty_send_input,
    ),
    components(schemas(
        CreateSandboxRequest,
        ExecRequest,
        ExecResponse,
        SandboxSummary,
        crate::models::SandboxNetwork,
        crate::models::SandboxStatus,
        HealthResponse,
        ErrorBody,
        NotificationRequest,
        NotificationLogEntry,
        NotificationLevel,
        OpenUrlRequest,
        PruneRequest,
        PruneResponse,
        PrunedItem,
        AwaitReadyRequest,
        AwaitReadyResponse,
        ServiceReadiness,
        PtyCreateRequest,
        PtySessionInfo,
        PtySessionList,
        PtyCaptureResponse,
        PtyResizeRequest,
        PtyInputRequest
    )),
    tags(
        (name = "sandboxes", description = "Manage bubblewrap-based sandboxes"),
        (name = "pty", description = "PTY session management")
    )
)]
pub struct ApiDoc;

pub fn build_router(
    service: Arc<dyn SandboxService>,
    host_events: HostEventSender,
    gh_responses: GhResponseRegistry,
    gh_auth_cache: crate::service::GhAuthCache,
    notifications: NotificationStore,
) -> Router {
    let state = AppState::new(
        service,
        host_events,
        gh_responses,
        gh_auth_cache,
        notifications,
    );
    let openapi = ApiDoc::openapi();
    let swagger_routes: Router<AppState> =
        SwaggerUi::new("/docs").url("/openapi.json", openapi).into();

    Router::new()
        .route("/healthz", get(health))
        .route("/sandboxes", get(list_sandboxes).post(create_sandbox))
        .route("/sandboxes/{id}", get(get_sandbox).delete(delete_sandbox))
        .route("/sandboxes/{id}/exec", post(exec_sandbox))
        .route(
            "/sandboxes/{id}/files",
            post(upload_files).layer(DefaultBodyLimit::disable()),
        )
        .route("/sandboxes/{id}/attach", any(attach_sandbox))
        .route("/sandboxes/{id}/proxy", any(proxy_sandbox))
        .route("/sandboxes/{id}/await-ready", post(await_ready))
        // HTTP PTY session management - handled directly by sandboxd
        .route(
            "/sandboxes/{id}/pty/sessions",
            get(pty_list_sessions).post(pty_create_session),
        )
        .route(
            "/sandboxes/{id}/pty/sessions/{session_id}",
            get(pty_get_session).delete(pty_delete_session),
        )
        .route(
            "/sandboxes/{id}/pty/sessions/{session_id}/resize",
            post(pty_resize_session),
        )
        .route(
            "/sandboxes/{id}/pty/sessions/{session_id}/capture",
            get(pty_capture_session),
        )
        .route(
            "/sandboxes/{id}/pty/sessions/{session_id}/input",
            post(pty_send_input),
        )
        .route(
            "/sandboxes/{id}/pty/sessions/{session_id}/attach",
            any(pty_attach_session),
        )
        .route("/sandboxes/{id}/pty/signal", post(pty_signal))
        // Multiplexed WebSocket endpoint - single connection for all PTY sessions
        .route("/mux/attach", any(mux_attach))
        // Open URL on host - used by sandboxed processes to open links
        .route("/open-url", get(open_url).post(open_url_post))
        // Push a notification to connected clients
        .route(
            "/notifications",
            get(list_notifications).post(send_notification),
        )
        // Prune orphaned sandbox filesystem directories
        .route("/prune", post(prune_orphaned))
        .merge(swagger_routes)
        // Fallback for subdomain routing: {index}-{port}.host -> sandbox's internal port
        .fallback(subdomain_proxy)
        .with_state(state)
}

#[utoipa::path(
    get,
    path = "/healthz",
    responses((status = 200, description = "Server is healthy", body = HealthResponse))
)]
async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok".to_string(),
    })
}

#[utoipa::path(
    post,
    path = "/sandboxes",
    request_body = CreateSandboxRequest,
    responses(
        (status = 201, description = "Sandbox created", body = SandboxSummary),
        (status = 400, description = "Bad request", body = ErrorBody)
    )
)]
async fn create_sandbox(
    state: axum::extract::State<AppState>,
    Json(request): Json<CreateSandboxRequest>,
) -> SandboxResult<(StatusCode, Json<SandboxSummary>)> {
    let summary = state.service.create(request).await?;
    Ok((StatusCode::CREATED, Json(summary)))
}

#[utoipa::path(
    get,
    path = "/sandboxes",
    responses((status = 200, description = "List of sandboxes", body = [SandboxSummary]))
)]
async fn list_sandboxes(
    state: axum::extract::State<AppState>,
) -> SandboxResult<Json<Vec<SandboxSummary>>> {
    let sandboxes = state.service.list().await?;
    Ok(Json(sandboxes))
}

#[utoipa::path(
    get,
    path = "/sandboxes/{id}",
    params(
        ("id" = String, Path, description = "Sandbox identifier (UUID or short ID)")
    ),
    responses(
        (status = 200, description = "Sandbox detail", body = SandboxSummary),
        (status = 404, description = "Sandbox not found", body = ErrorBody)
    )
)]
async fn get_sandbox(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
) -> SandboxResult<Json<SandboxSummary>> {
    match state.service.get(id.clone()).await? {
        Some(summary) => Ok(Json(summary)),
        None => Err(SandboxError::NotFound(Uuid::nil())), // TODO: Better error
    }
}

#[utoipa::path(
    post,
    path = "/sandboxes/{id}/exec",
    params(
        ("id" = String, Path, description = "Sandbox identifier (UUID or short ID)")
    ),
    request_body = ExecRequest,
    responses(
        (status = 200, description = "Command executed", body = ExecResponse),
        (status = 404, description = "Sandbox not found", body = ErrorBody)
    )
)]
async fn exec_sandbox(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<ExecRequest>,
) -> SandboxResult<Json<ExecResponse>> {
    let response = state.service.exec(id, request).await?;
    Ok(Json(response))
}

#[utoipa::path(
    post,
    path = "/sandboxes/{id}/files",
    params(
        ("id" = String, Path, description = "Sandbox identifier (UUID or short ID)")
    ),
    request_body = Vec<u8>,
    responses(
        (status = 200, description = "Files uploaded"),
        (status = 404, description = "Sandbox not found", body = ErrorBody)
    )
)]
async fn upload_files(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
    body: Body,
) -> SandboxResult<StatusCode> {
    state.service.upload_archive(id, body).await?;
    Ok(StatusCode::OK)
}

async fn attach_sandbox(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<AttachParams>,
    ws: WebSocketUpgrade,
) -> Response {
    let initial_size = match (params.cols, params.rows) {
        (Some(c), Some(r)) => Some((c, r)),
        _ => None,
    };

    let command = params
        .command
        .map(|c| vec!["/bin/sh".to_string(), "-c".to_string(), c]);

    ws.on_upgrade(move |socket| async move {
        if let Err(e) = state
            .service
            .attach(id, socket, initial_size, command, params.tty)
            .await
        {
            tracing::error!("attach failed: {e}");
        }
    })
}

async fn proxy_sandbox(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
    Query(params): Query<ProxyParams>,
    ws: WebSocketUpgrade,
) -> Response {
    ws.on_upgrade(move |socket| async move {
        if let Err(e) = state.service.proxy(id, params.port, socket).await {
            tracing::error!("proxy failed: {e}");
        }
    })
}

/// Parse subdomain pattern to extract sandbox index and port.
/// Format: {index}-{port}.rest (e.g., "0-39380.localhost:46835")
fn parse_subdomain(host: &str) -> Option<(usize, u16)> {
    let subdomain = host.split('.').next()?;
    let parts: Vec<&str> = subdomain.split('-').collect();
    if parts.len() != 2 {
        return None;
    }
    let index = parts[0].parse::<usize>().ok()?;
    let port = parts[1].parse::<u16>().ok()?;
    Some((index, port))
}

/// Subdomain routing: {index}-{port}.host -> proxy to sandbox[index]'s internal port
/// Example: 0-39380.localhost:46835 -> sandbox 0's internal port 39380 (noVNC)
/// Handles both HTTP requests and WebSocket upgrades.
async fn subdomain_proxy(
    state: State<AppState>,
    ws: Result<WebSocketUpgrade, axum::extract::ws::rejection::WebSocketUpgradeRejection>,
    headers: HeaderMap,
    req: axum::http::Request<Body>,
) -> Response {
    // Get host from headers
    let host = headers
        .get(HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");

    // Parse subdomain pattern
    let Some((index, port)) = parse_subdomain(host) else {
        return (StatusCode::NOT_FOUND, "Not found").into_response();
    };

    // NOTE: We intentionally allow access to any port inside the sandbox.
    // This enables users to run dev servers (e.g., vite on :5173, next on :3000)
    // and access them via subdomain routing (e.g., 0-5173.lvh.me:46833).
    // Security is handled at the sandbox network level - each sandbox has its own
    // isolated network namespace and can only be reached through this proxy.

    // Find sandbox by index
    let sandboxes = match state.service.list().await {
        Ok(s) => s,
        Err(e) => {
            tracing::error!("Failed to list sandboxes: {e}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Failed to list sandboxes",
            )
                .into_response();
        }
    };

    let sandbox = sandboxes.iter().find(|s| s.index == index);
    let Some(sandbox) = sandbox else {
        return (
            StatusCode::NOT_FOUND,
            format!("Sandbox with index {} not found", index),
        )
            .into_response();
    };

    let sandbox_ip = sandbox.network.sandbox_ip.clone();

    // Extract parts from request before consuming body
    let (parts, body) = req.into_parts();
    let path_and_query = parts
        .uri
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/")
        .to_string();
    let method = parts.method;

    // Check if this is a WebSocket upgrade
    if let Ok(ws) = ws {
        // For noVNC port (39380), use our native Rust VNC proxy with TCP_NODELAY
        // The VNC server runs on port 5900 + display_number
        if port == 39380 {
            let vnc_port = sandbox.display.as_ref().map(|d| d.vnc_port).unwrap_or(5910); // Default to display :10

            let vnc_addr: SocketAddr = format!("{}:{}", sandbox_ip, vnc_port)
                .parse()
                .unwrap_or_else(|_| SocketAddr::from(([10, 201, 0, 2], vnc_port)));

            tracing::info!(
                sandbox_index = index,
                vnc_addr = %vnc_addr,
                "VNC WebSocket proxy (native Rust, TCP_NODELAY)"
            );

            return ws.on_upgrade(move |client_socket| async move {
                if let Err(e) = proxy_vnc_websocket(client_socket, vnc_addr).await {
                    tracing::error!("VNC proxy error: {e}");
                }
            });
        }

        // For other ports, use generic WebSocket proxy
        tracing::info!(
            sandbox_index = index,
            port = port,
            sandbox_ip = %sandbox_ip,
            path = %path_and_query,
            "subdomain WebSocket proxy"
        );

        return ws.on_upgrade(move |client_socket| async move {
            if let Err(e) = proxy_websocket(client_socket, &sandbox_ip, port, &path_and_query).await
            {
                tracing::error!("WebSocket proxy error: {e}");
            }
        });
    }

    // For noVNC port (39380), serve static files from /usr/share/novnc
    if port == 39380 {
        use std::path::Path;

        let path = if path_and_query == "/" || path_and_query.is_empty() {
            "/vnc.html"
        } else {
            path_and_query.split('?').next().unwrap_or(&path_and_query)
        };

        // Sanitize path to prevent directory traversal attacks
        let base_dir = Path::new("/usr/share/novnc");
        let requested = base_dir.join(path.trim_start_matches('/'));
        let canonical = match requested.canonicalize() {
            Ok(p) => p,
            Err(_) => {
                return (StatusCode::NOT_FOUND, "File not found").into_response();
            }
        };

        // Verify the canonical path is still under the base directory
        if !canonical.starts_with(base_dir) {
            tracing::warn!(path = %path, "blocked directory traversal attempt");
            return (StatusCode::FORBIDDEN, "Forbidden").into_response();
        }

        let file_path = canonical.to_string_lossy().to_string();
        tracing::debug!(file_path = %file_path, "serving noVNC static file");

        match tokio::fs::read(&file_path).await {
            Ok(contents) => {
                let content_type = match file_path.rsplit('.').next() {
                    Some("html") => "text/html; charset=utf-8",
                    Some("js") => "application/javascript",
                    Some("css") => "text/css",
                    Some("png") => "image/png",
                    Some("svg") => "image/svg+xml",
                    Some("ico") => "image/x-icon",
                    _ => "application/octet-stream",
                };
                return Response::builder()
                    .status(StatusCode::OK)
                    .header("Content-Type", content_type)
                    .header("Cache-Control", "public, max-age=3600")
                    .body(Body::from(contents))
                    .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
            }
            Err(_) => {
                return (StatusCode::NOT_FOUND, "File not found").into_response();
            }
        }
    }

    // HTTP reverse proxy - collect request body
    let body_bytes = match axum::body::to_bytes(body, 10 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(e) => {
            tracing::error!("Failed to read request body: {e}");
            return (StatusCode::BAD_REQUEST, "Failed to read request body").into_response();
        }
    };

    let target_url = format!("http://{}:{}{}", sandbox_ip, port, path_and_query);

    tracing::info!(
        sandbox_index = index,
        port = port,
        sandbox_ip = %sandbox_ip,
        target_url = %target_url,
        body_len = body_bytes.len(),
        "subdomain HTTP proxy"
    );

    // Build the proxied request with matching method
    // Use HTTP/1.1 only for compatibility with all upstream servers
    let client = reqwest::Client::builder()
        .http1_only()
        .timeout(std::time::Duration::from_secs(30))
        .connect_timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new());
    let proxy_req = client.request(
        reqwest::Method::from_bytes(method.as_str().as_bytes()).unwrap_or(reqwest::Method::GET),
        &target_url,
    );

    // Copy relevant request headers
    let mut proxy_req = proxy_req;

    // Forward original Host header so upstream knows the external address.
    // This is critical for VS Code which uses Host to set remoteAuthority for WebSocket connections.
    proxy_req = proxy_req.header(reqwest::header::HOST, host);

    // Add standard proxy headers
    proxy_req = proxy_req.header("X-Forwarded-Host", host);
    proxy_req = proxy_req.header("X-Forwarded-Proto", "http");

    for (key, value) in headers.iter() {
        // Skip hop-by-hop headers (we handle Host specially above)
        if key == HOST || key == "connection" || key == "upgrade" {
            continue;
        }
        if let Ok(val_str) = value.to_str() {
            if let Ok(name) = reqwest::header::HeaderName::from_bytes(key.as_str().as_bytes()) {
                proxy_req = proxy_req.header(name, val_str);
            }
        }
    }

    // Attach request body
    let proxy_req = proxy_req.body(body_bytes);

    tracing::debug!("sending proxy request to {}", target_url);
    match proxy_req.send().await {
        Ok(resp) => {
            let status = StatusCode::from_u16(resp.status().as_u16())
                .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
            tracing::debug!("proxy response status: {}", status);

            // Build response with filtered headers
            let mut response = Response::builder().status(status);

            // Copy headers from upstream, filtering out hop-by-hop headers
            // that shouldn't be forwarded by proxies (RFC 2616 Section 13.5.1)
            const HOP_BY_HOP: &[&str] = &[
                "connection",
                "keep-alive",
                "proxy-authenticate",
                "proxy-authorization",
                "te",
                "trailer",
                "transfer-encoding",
                "upgrade",
                "content-length", // We'll set our own after buffering the body
            ];

            for (key, value) in resp.headers() {
                let key_lower = key.as_str().to_lowercase();
                if HOP_BY_HOP.contains(&key_lower.as_str()) {
                    continue;
                }
                if let Ok(name) = axum::http::header::HeaderName::try_from(key.as_str()) {
                    if let Ok(val) = axum::http::header::HeaderValue::from_bytes(value.as_bytes()) {
                        response = response.header(name, val);
                    }
                }
            }

            // Read the body
            match resp.bytes().await {
                Ok(body) => {
                    tracing::debug!("proxy response body size: {} bytes", body.len());
                    response.body(Body::from(body)).unwrap_or_else(|e| {
                        tracing::error!("Failed to build response: {e}");
                        StatusCode::INTERNAL_SERVER_ERROR.into_response()
                    })
                }
                Err(e) => {
                    tracing::error!("Failed to read proxy response body: {e}");
                    StatusCode::BAD_GATEWAY.into_response()
                }
            }
        }
        Err(e) => {
            tracing::error!("Proxy request failed: {e}");
            (StatusCode::BAD_GATEWAY, format!("Proxy error: {e}")).into_response()
        }
    }
}

/// Proxy WebSocket connection to sandbox internal port.
/// Used for noVNC websockify connections.
async fn proxy_websocket(
    client_socket: axum::extract::ws::WebSocket,
    sandbox_ip: &str,
    port: u16,
    path: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use futures::{SinkExt, StreamExt};
    use tokio::net::TcpStream;
    use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;

    let addr = format!("{}:{}", sandbox_ip, port);
    let url = format!("ws://{}{}", addr, path);
    tracing::debug!("Connecting to upstream WebSocket: {}", url);

    // Create TCP connection with TCP_NODELAY for low latency
    let stream = TcpStream::connect(&addr).await?;
    stream.set_nodelay(true)?;

    // Upgrade to WebSocket
    let (upstream_ws, _) = tokio_tungstenite::client_async(&url, stream).await?;
    let (mut upstream_sink, mut upstream_stream) = upstream_ws.split();

    let (mut client_sink, mut client_stream) = client_socket.split();

    // Spawn task to forward client -> upstream
    let client_to_upstream = tokio::spawn(async move {
        while let Some(msg_result) = client_stream.next().await {
            match msg_result {
                Ok(axum::extract::ws::Message::Binary(data)) => {
                    if upstream_sink
                        .send(TungsteniteMessage::Binary(data.to_vec()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Ok(axum::extract::ws::Message::Text(text)) => {
                    if upstream_sink
                        .send(TungsteniteMessage::Text(text.to_string()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Ok(axum::extract::ws::Message::Close(_)) => break,
                Ok(axum::extract::ws::Message::Ping(data)) => {
                    if upstream_sink
                        .send(TungsteniteMessage::Ping(data.to_vec()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Ok(axum::extract::ws::Message::Pong(data)) => {
                    if upstream_sink
                        .send(TungsteniteMessage::Pong(data.to_vec()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    // Forward upstream -> client
    while let Some(msg_result) = upstream_stream.next().await {
        match msg_result {
            Ok(TungsteniteMessage::Binary(data)) => {
                if client_sink
                    .send(axum::extract::ws::Message::Binary(data.into()))
                    .await
                    .is_err()
                {
                    break;
                }
            }
            Ok(TungsteniteMessage::Text(text)) => {
                if client_sink
                    .send(axum::extract::ws::Message::Text(text.into()))
                    .await
                    .is_err()
                {
                    break;
                }
            }
            Ok(TungsteniteMessage::Close(_)) => break,
            Ok(TungsteniteMessage::Ping(data)) => {
                if client_sink
                    .send(axum::extract::ws::Message::Ping(data.into()))
                    .await
                    .is_err()
                {
                    break;
                }
            }
            Ok(TungsteniteMessage::Pong(data)) => {
                if client_sink
                    .send(axum::extract::ws::Message::Pong(data.into()))
                    .await
                    .is_err()
                {
                    break;
                }
            }
            Ok(_) => {} // Ignore Frame messages
            Err(_) => break,
        }
    }

    client_to_upstream.abort();
    Ok(())
}

/// Multiplexed WebSocket endpoint - handles multiple PTY sessions over a single connection.
async fn mux_attach(state: axum::extract::State<AppState>, ws: WebSocketUpgrade) -> Response {
    let host_event_rx = state.host_events.subscribe();
    let gh_responses = state.gh_responses.clone();
    let gh_auth_cache = state.gh_auth_cache.clone();
    ws.on_upgrade(move |socket| async move {
        if let Err(e) = state
            .service
            .mux_attach(socket, host_event_rx, gh_responses, gh_auth_cache)
            .await
        {
            tracing::error!("mux_attach failed: {e}");
        }
    })
}

/// Open a URL on the host machine. Used by sandboxed processes to open links.
async fn open_url(
    State(state): State<AppState>,
    Query(params): Query<OpenUrlRequest>,
) -> StatusCode {
    handle_open_url(state, params).await
}

#[utoipa::path(
    post,
    path = "/open-url",
    request_body = OpenUrlRequest,
    responses(
        (status = 200, description = "URL forwarded to host"),
        (status = 400, description = "Invalid URL", body = ErrorBody),
        (status = 500, description = "Failed to dispatch open-url request", body = ErrorBody)
    )
)]
async fn open_url_post(
    State(state): State<AppState>,
    Json(body): Json<OpenUrlRequest>,
) -> StatusCode {
    handle_open_url(state, body).await
}

async fn handle_open_url(state: AppState, params: OpenUrlRequest) -> StatusCode {
    // Validate URL to prevent command injection
    if !params.url.starts_with("http://") && !params.url.starts_with("https://") {
        return StatusCode::BAD_REQUEST;
    }

    match state.host_events.send(HostEvent::OpenUrl(OpenUrlRequest {
        url: params.url.clone(),
        sandbox_id: params.sandbox_id.clone(),
        tab_id: params.tab_id.clone(),
    })) {
        Ok(_) => StatusCode::OK,
        Err(error) => {
            tracing::warn!(
                "open-url broadcast had no listeners, falling back to local open: {error}"
            );
            match open::that(&params.url) {
                Ok(()) => StatusCode::OK,
                Err(e) => {
                    tracing::error!("Failed to open URL {}: {}", params.url, e);
                    StatusCode::INTERNAL_SERVER_ERROR
                }
            }
        }
    }
}

#[utoipa::path(
    get,
    path = "/notifications",
    responses((status = 200, description = "List recent notifications", body = [NotificationLogEntry]))
)]
async fn list_notifications(State(state): State<AppState>) -> Json<Vec<NotificationLogEntry>> {
    let entries = state.notifications.list().await;
    Json(entries)
}

#[utoipa::path(
    post,
    path = "/notifications",
    request_body = NotificationRequest,
    responses(
        (status = 200, description = "Notification dispatched"),
        (status = 202, description = "No listeners available; notification accepted")
    )
)]
async fn send_notification(
    State(state): State<AppState>,
    Json(body): Json<NotificationRequest>,
) -> StatusCode {
    let _ = state
        .notifications
        .record(
            body.message.clone(),
            body.level,
            body.sandbox_id.clone(),
            body.tab_id.clone(),
            body.pane_id.clone(),
        )
        .await;
    match state
        .host_events
        .send(HostEvent::Notification(NotificationRequest {
            message: body.message.clone(),
            level: body.level,
            sandbox_id: body.sandbox_id.clone(),
            tab_id: body.tab_id.clone(),
            pane_id: body.pane_id.clone(),
        })) {
        Ok(_) => StatusCode::OK,
        Err(error) => {
            tracing::warn!("no listeners for notification: {error}");
            StatusCode::ACCEPTED
        }
    }
}

#[utoipa::path(
    delete,
    path = "/sandboxes/{id}",
    params(
        ("id" = String, Path, description = "Sandbox identifier (UUID or short ID)")
    ),
    responses(
        (status = 200, description = "Sandbox stopped", body = SandboxSummary),
        (status = 404, description = "Sandbox not found", body = ErrorBody)
    )
)]
async fn delete_sandbox(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
) -> SandboxResult<Json<SandboxSummary>> {
    match state.service.delete(id.clone()).await? {
        Some(summary) => Ok(Json(summary)),
        None => Err(SandboxError::NotFound(Uuid::nil())), // TODO: Better error handling
    }
}

#[utoipa::path(
    post,
    path = "/prune",
    request_body = PruneRequest,
    responses(
        (status = 200, description = "Prune completed", body = PruneResponse),
        (status = 500, description = "Prune failed", body = ErrorBody)
    )
)]
async fn prune_orphaned(
    state: axum::extract::State<AppState>,
    Json(request): Json<PruneRequest>,
) -> SandboxResult<Json<PruneResponse>> {
    let response = state.service.prune_orphaned(request).await?;
    Ok(Json(response))
}

#[utoipa::path(
    post,
    path = "/sandboxes/{id}/await-ready",
    request_body = AwaitReadyRequest,
    params(
        ("id" = String, Path, description = "Sandbox ID")
    ),
    responses(
        (status = 200, description = "Service readiness status", body = AwaitReadyResponse),
        (status = 404, description = "Sandbox not found", body = ErrorBody)
    )
)]
async fn await_ready(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<AwaitReadyRequest>,
) -> SandboxResult<Json<AwaitReadyResponse>> {
    let response = state.service.await_services_ready(id, request).await?;
    Ok(Json(response))
}

// ============================================================================
// HTTP PTY Session Handlers
// ============================================================================

/// List all PTY sessions in a sandbox.
#[utoipa::path(
    get,
    path = "/sandboxes/{id}/pty/sessions",
    tag = "pty",
    params(
        ("id" = String, Path, description = "Sandbox ID")
    ),
    responses(
        (status = 200, description = "List of PTY sessions", body = PtySessionList),
        (status = 404, description = "Sandbox not found", body = ErrorBody)
    )
)]
async fn pty_list_sessions(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
) -> Response {
    match state.service.pty_list_sessions(id).await {
        Ok(sessions) => Json(PtySessionList { sessions }).into_response(),
        Err(e) => e.into_response(),
    }
}

/// Create a new PTY session in a sandbox.
#[utoipa::path(
    post,
    path = "/sandboxes/{id}/pty/sessions",
    tag = "pty",
    params(
        ("id" = String, Path, description = "Sandbox ID")
    ),
    request_body = PtyCreateRequest,
    responses(
        (status = 200, description = "Created PTY session", body = PtySessionInfo),
        (status = 404, description = "Sandbox not found", body = ErrorBody),
        (status = 400, description = "Invalid request", body = ErrorBody)
    )
)]
async fn pty_create_session(
    state: axum::extract::State<AppState>,
    Path(id): Path<String>,
    Json(request): Json<PtyCreateRequest>,
) -> Response {
    match state.service.pty_create_session(id, request).await {
        Ok(session) => Json(session).into_response(),
        Err(e) => e.into_response(),
    }
}

/// Get a specific PTY session.
#[utoipa::path(
    get,
    path = "/sandboxes/{id}/pty/sessions/{session_id}",
    tag = "pty",
    params(
        ("id" = String, Path, description = "Sandbox ID"),
        ("session_id" = String, Path, description = "PTY session ID")
    ),
    responses(
        (status = 200, description = "PTY session info", body = PtySessionInfo),
        (status = 404, description = "Sandbox or session not found", body = ErrorBody)
    )
)]
async fn pty_get_session(
    state: axum::extract::State<AppState>,
    Path((id, session_id)): Path<(String, String)>,
) -> Response {
    match state.service.pty_get_session(id, session_id).await {
        Ok(Some(session)) => Json(session).into_response(),
        Ok(None) => {
            SandboxError::InvalidRequest("PTY session not found".to_string()).into_response()
        }
        Err(e) => e.into_response(),
    }
}

/// Delete a PTY session.
#[utoipa::path(
    delete,
    path = "/sandboxes/{id}/pty/sessions/{session_id}",
    tag = "pty",
    params(
        ("id" = String, Path, description = "Sandbox ID"),
        ("session_id" = String, Path, description = "PTY session ID")
    ),
    responses(
        (status = 204, description = "Session deleted"),
        (status = 404, description = "Sandbox or session not found", body = ErrorBody)
    )
)]
async fn pty_delete_session(
    state: axum::extract::State<AppState>,
    Path((id, session_id)): Path<(String, String)>,
) -> Response {
    match state.service.pty_delete_session(id, session_id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => e.into_response(),
    }
}

/// Resize a PTY session.
#[utoipa::path(
    post,
    path = "/sandboxes/{id}/pty/sessions/{session_id}/resize",
    tag = "pty",
    params(
        ("id" = String, Path, description = "Sandbox ID"),
        ("session_id" = String, Path, description = "PTY session ID")
    ),
    request_body = PtyResizeRequest,
    responses(
        (status = 204, description = "Session resized"),
        (status = 404, description = "Sandbox or session not found", body = ErrorBody)
    )
)]
async fn pty_resize_session(
    state: axum::extract::State<AppState>,
    Path((id, session_id)): Path<(String, String)>,
    Json(request): Json<PtyResizeRequest>,
) -> Response {
    match state
        .service
        .pty_resize_session(id, session_id, request)
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => e.into_response(),
    }
}

/// Capture PTY session content.
#[utoipa::path(
    get,
    path = "/sandboxes/{id}/pty/sessions/{session_id}/capture",
    tag = "pty",
    params(
        ("id" = String, Path, description = "Sandbox ID"),
        ("session_id" = String, Path, description = "PTY session ID")
    ),
    responses(
        (status = 200, description = "Terminal content", body = PtyCaptureResponse),
        (status = 404, description = "Sandbox or session not found", body = ErrorBody)
    )
)]
async fn pty_capture_session(
    state: axum::extract::State<AppState>,
    Path((id, session_id)): Path<(String, String)>,
) -> Response {
    match state.service.pty_capture_session(id, session_id).await {
        Ok(capture) => Json(capture).into_response(),
        Err(e) => e.into_response(),
    }
}

/// Send input to a PTY session.
#[utoipa::path(
    post,
    path = "/sandboxes/{id}/pty/sessions/{session_id}/input",
    tag = "pty",
    params(
        ("id" = String, Path, description = "Sandbox ID"),
        ("session_id" = String, Path, description = "PTY session ID")
    ),
    request_body = PtyInputRequest,
    responses(
        (status = 204, description = "Input sent"),
        (status = 404, description = "Sandbox or session not found", body = ErrorBody)
    )
)]
async fn pty_send_input(
    state: axum::extract::State<AppState>,
    Path((id, session_id)): Path<(String, String)>,
    Json(request): Json<PtyInputRequest>,
) -> Response {
    match state
        .service
        .pty_send_input(id, session_id, request.data)
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => e.into_response(),
    }
}

/// WebSocket attach to a PTY session.
/// Note: For HTTP PTY sessions, prefer using input/capture endpoints.
/// This endpoint is kept for compatibility but requires cmux-pty to be running.
async fn pty_attach_session(
    _state: axum::extract::State<AppState>,
    Path((_id, _session_id)): Path<(String, String)>,
    _ws: WebSocketUpgrade,
) -> Response {
    // HTTP PTY sessions use input/capture endpoints instead of WebSocket attach
    // For real-time streaming, use the /mux/attach endpoint instead
    (
        StatusCode::NOT_IMPLEMENTED,
        "WebSocket attach not supported for HTTP PTY sessions. Use /mux/attach for streaming or input/capture endpoints for polling.",
    )
        .into_response()
}

/// Send a signal to PTY processes in a sandbox.
/// Note: Signal sending is not yet implemented for HTTP PTY sessions.
async fn pty_signal(
    _state: axum::extract::State<AppState>,
    Path(_id): Path<String>,
    _body: axum::body::Bytes,
) -> Response {
    // TODO: Implement signal sending for HTTP PTY sessions
    (
        StatusCode::NOT_IMPLEMENTED,
        "Signal sending not yet implemented for HTTP PTY sessions",
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{SandboxNetwork, SandboxStatus};
    use async_trait::async_trait;
    use axum::body::Body;
    use axum::extract::ws::WebSocket;
    use axum::http::Request;
    use chrono::Utc;
    use std::sync::Arc;
    use tokio::sync::Mutex;
    use tower::ServiceExt;
    use uuid::Uuid;

    #[derive(Clone, Default)]
    struct MockService {
        calls: Arc<Mutex<usize>>,
    }

    #[async_trait]
    impl SandboxService for MockService {
        async fn create(&self, request: CreateSandboxRequest) -> SandboxResult<SandboxSummary> {
            let mut calls = self.calls.lock().await;
            *calls += 1;
            Ok(fake_summary(request.name.unwrap_or_else(|| "mock".into())))
        }

        async fn list(&self) -> SandboxResult<Vec<SandboxSummary>> {
            Ok(vec![fake_summary("mock-list".into())])
        }

        async fn get(&self, _id: String) -> SandboxResult<Option<SandboxSummary>> {
            Ok(Some(fake_summary("mock-one".into())))
        }

        async fn exec(&self, _id: String, _exec: ExecRequest) -> SandboxResult<ExecResponse> {
            Ok(ExecResponse {
                exit_code: 0,
                stdout: "ok".into(),
                stderr: String::new(),
            })
        }

        async fn attach(
            &self,
            _id: String,
            _socket: WebSocket,
            _initial_size: Option<(u16, u16)>,
            _command: Option<Vec<String>>,
            _tty: bool,
        ) -> SandboxResult<()> {
            Ok(())
        }

        async fn mux_attach(
            &self,
            _socket: WebSocket,
            _host_event_rx: crate::service::HostEventReceiver,
            _gh_responses: crate::service::GhResponseRegistry,
            _gh_auth_cache: crate::service::GhAuthCache,
        ) -> SandboxResult<()> {
            Ok(())
        }

        async fn proxy(&self, _id: String, _port: u16, _socket: WebSocket) -> SandboxResult<()> {
            Ok(())
        }

        async fn upload_archive(&self, _id: String, _archive: Body) -> SandboxResult<()> {
            Ok(())
        }

        async fn delete(&self, _id: String) -> SandboxResult<Option<SandboxSummary>> {
            Ok(Some(fake_summary("mock-delete".into())))
        }

        async fn prune_orphaned(&self, request: PruneRequest) -> SandboxResult<PruneResponse> {
            Ok(PruneResponse {
                deleted_count: 0,
                failed_count: 0,
                items: vec![],
                dry_run: request.dry_run,
                bytes_freed: 0,
            })
        }

        async fn await_services_ready(
            &self,
            _id: String,
            _request: AwaitReadyRequest,
        ) -> SandboxResult<AwaitReadyResponse> {
            Ok(AwaitReadyResponse {
                ready: true,
                services: ServiceReadiness {
                    vnc: true,
                    vscode: false,
                    pty: false,
                },
                timed_out: vec![],
            })
        }

        async fn pty_create_session(
            &self,
            _sandbox_id: String,
            _request: PtyCreateRequest,
        ) -> SandboxResult<PtySessionInfo> {
            unimplemented!("mock pty_create_session")
        }

        async fn pty_list_sessions(
            &self,
            _sandbox_id: String,
        ) -> SandboxResult<Vec<PtySessionInfo>> {
            Ok(vec![])
        }

        async fn pty_get_session(
            &self,
            _sandbox_id: String,
            _session_id: String,
        ) -> SandboxResult<Option<PtySessionInfo>> {
            Ok(None)
        }

        async fn pty_capture_session(
            &self,
            _sandbox_id: String,
            _session_id: String,
        ) -> SandboxResult<PtyCaptureResponse> {
            Ok(PtyCaptureResponse {
                content: String::new(),
                cursor_x: 0,
                cursor_y: 0,
            })
        }

        async fn pty_resize_session(
            &self,
            _sandbox_id: String,
            _session_id: String,
            _request: PtyResizeRequest,
        ) -> SandboxResult<()> {
            Ok(())
        }

        async fn pty_send_input(
            &self,
            _sandbox_id: String,
            _session_id: String,
            _data: Vec<u8>,
        ) -> SandboxResult<()> {
            Ok(())
        }

        async fn pty_delete_session(
            &self,
            _sandbox_id: String,
            _session_id: String,
        ) -> SandboxResult<()> {
            Ok(())
        }
    }

    fn fake_summary(name: String) -> SandboxSummary {
        SandboxSummary {
            index: 0,
            id: Uuid::new_v4(),
            name,
            created_at: Utc::now(),
            workspace: "/tmp/mock".to_string(),
            status: SandboxStatus::Running,
            network: SandboxNetwork {
                host_interface: "vethh-mock".to_string(),
                sandbox_interface: "vethn-mock".to_string(),
                host_ip: "10.0.0.1".to_string(),
                sandbox_ip: "10.0.0.2".to_string(),
                cidr: 30,
            },
            display: None,
            correlation_id: None,
        }
    }

    fn make_test_router() -> Router {
        use std::collections::HashMap;
        let (host_event_tx, _) = tokio::sync::broadcast::channel(16);
        let gh_responses = Arc::new(Mutex::new(HashMap::new()));
        let gh_auth_cache = Arc::new(Mutex::new(None));
        let notifications = NotificationStore::new();
        build_router(
            Arc::new(MockService::default()),
            host_event_tx,
            gh_responses,
            gh_auth_cache,
            notifications,
        )
    }

    #[tokio::test]
    async fn serves_openapi_document() {
        let app = make_test_router();
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/openapi.json")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn create_endpoint_returns_summary() {
        let app = make_test_router();
        let request = CreateSandboxRequest {
            name: Some("demo".into()),
            workspace: None,
            tab_id: None,
            read_only_paths: Vec::new(),
            tmpfs: Vec::new(),
            env: Vec::new(),
        };

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/sandboxes")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_vec(&request).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CREATED);
    }
}
