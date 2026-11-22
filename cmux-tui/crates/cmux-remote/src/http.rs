//! Authenticated loopback HTTP access to the transport-independent workspace RPC.

use std::collections::BTreeMap;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::SocketAddr;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Path as AxumPath, Query, Request, State};
use axum::http::header::{
    AUTHORIZATION, CACHE_CONTROL, CONNECTION, CONTENT_TYPE, ORIGIN, WWW_AUTHENTICATE,
};
use axum::http::{HeaderValue, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use base64::Engine;
use cmux_remote_protocol::{
    RpcError, RpcRequest, RpcResponse, WorkspaceId, WorkspaceRequest, WorkspaceResponse,
};
use hyper::server::conn::http1;
use hyper_util::rt::{TokioIo, TokioTimer};
use hyper_util::service::TowerToHyperService;
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, oneshot, watch};
use tokio::task::JoinSet;
use tower::ServiceBuilder;
use tower_http::timeout::RequestBodyTimeoutLayer;
use zeroize::{Zeroize, Zeroizing};

use crate::workspace::WorkspaceService;

const HTTP_TOKEN_BYTES: usize = 32;
const MAX_HTTP_TOKEN_FILE_BYTES: u64 = 256;
const MAX_HTTP_RPC_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_CONCURRENT_HTTP_REQUESTS: usize = 64;
const MAX_RAW_HTTP_CONNECTIONS: usize = 64;
const HTTP_HEADER_TIMEOUT: Duration = Duration::from_secs(5);
const HTTP_REQUEST_BODY_TIMEOUT: Duration = Duration::from_secs(5);
const HTTP_GRACEFUL_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_HTTP_HEADER_BYTES: usize = 16 * 1024;

#[derive(Clone, Copy)]
struct WorkspaceHttpAdmissionLimits {
    maximum_connections: usize,
    header_timeout: Duration,
    request_body_timeout: Duration,
    graceful_shutdown_timeout: Duration,
    maximum_header_bytes: usize,
}

const WORKSPACE_HTTP_ADMISSION_LIMITS: WorkspaceHttpAdmissionLimits =
    WorkspaceHttpAdmissionLimits {
        maximum_connections: MAX_RAW_HTTP_CONNECTIONS,
        header_timeout: HTTP_HEADER_TIMEOUT,
        request_body_timeout: HTTP_REQUEST_BODY_TIMEOUT,
        graceful_shutdown_timeout: HTTP_GRACEFUL_SHUTDOWN_TIMEOUT,
        maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
    };

#[derive(Clone)]
pub struct WorkspaceHttpBearerToken(Arc<Zeroizing<String>>);

impl fmt::Debug for WorkspaceHttpBearerToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("WorkspaceHttpBearerToken([REDACTED])")
    }
}

impl WorkspaceHttpBearerToken {
    fn new(value: String) -> Result<Self, io::Error> {
        let decoded = Zeroizing::new(
            base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(&value).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "HTTP bearer token is not valid base64url",
                )
            })?,
        );
        if decoded.len() != HTTP_TOKEN_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "HTTP bearer token is {} bytes, expected {HTTP_TOKEN_BYTES}",
                    decoded.len()
                ),
            ));
        }
        Ok(Self(Arc::new(Zeroizing::new(value))))
    }

    fn matches_authorization(&self, authorization: &[u8]) -> bool {
        let Some(provided) = authorization.strip_prefix(b"Bearer ") else { return false };
        let expected = self.0.as_bytes();
        provided.len() == expected.len() && provided.ct_eq(expected).into()
    }

    #[cfg(test)]
    fn test_value() -> Self {
        Self::new(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([7_u8; HTTP_TOKEN_BYTES]))
            .unwrap()
    }
}

/// Loads a stable bearer credential or creates one with owner-only permissions.
/// The token itself is never returned through daemon metadata or logs.
pub fn load_or_create_workspace_http_token(
    path: &Path,
) -> Result<WorkspaceHttpBearerToken, io::Error> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "HTTP token path has no parent")
    })?;
    fs::create_dir_all(parent)?;
    #[cfg(unix)]
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;

    loop {
        match read_workspace_http_token(path) {
            Ok(token) => return Ok(token),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }

        let mut random = [0_u8; HTTP_TOKEN_BYTES];
        getrandom::fill(&mut random).map_err(|error| {
            io::Error::other(format!("could not create HTTP bearer token: {error}"))
        })?;
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(random);
        random.zeroize();
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        match options.open(path) {
            Ok(mut file) => {
                file.write_all(encoded.as_bytes())?;
                file.write_all(b"\n")?;
                file.sync_all()?;
                return WorkspaceHttpBearerToken::new(encoded);
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
}

fn read_workspace_http_token(path: &Path) -> Result<WorkspaceHttpBearerToken, io::Error> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW);
    let mut file = options.open(path)?;
    let metadata = file.metadata()?;
    validate_workspace_http_token_metadata(&metadata)?;
    read_workspace_http_token_contents(&mut file)
}

/// Validates the token file type, size, owner, and permissions from one opened descriptor.
fn validate_workspace_http_token_metadata(metadata: &fs::Metadata) -> Result<(), io::Error> {
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "HTTP token path is not a regular file",
        ));
    }
    if metadata.len() > MAX_HTTP_TOKEN_FILE_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "HTTP token file is too large"));
    }
    #[cfg(unix)]
    {
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "HTTP token file has a different owner",
            ));
        }
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "HTTP token file must not be accessible by group or other users",
            ));
        }
    }
    Ok(())
}

/// Reads at most the configured token bound and rejects growth observed during the read.
fn read_workspace_http_token_contents(
    file: &mut fs::File,
) -> Result<WorkspaceHttpBearerToken, io::Error> {
    let mut encoded = String::new();
    (&mut *file).take(MAX_HTTP_TOKEN_FILE_BYTES + 1).read_to_string(&mut encoded)?;
    if encoded.len() > MAX_HTTP_TOKEN_FILE_BYTES as usize
        || file.metadata()?.len() > MAX_HTTP_TOKEN_FILE_BYTES
    {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "HTTP token file is too large"));
    }
    let trimmed_length = encoded.trim_end_matches(['\r', '\n']).len();
    encoded.truncate(trimmed_length);
    WorkspaceHttpBearerToken::new(encoded)
}

#[derive(Clone)]
struct WorkspaceHttpState {
    workspace: WorkspaceService,
    token: WorkspaceHttpBearerToken,
    admission: Arc<Semaphore>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkspaceHttpResponse {
    pub result: Result<WorkspaceResponse, RpcError>,
}

#[derive(Debug, Clone, Copy, Default, Deserialize)]
struct ApplyPatchQuery {
    #[serde(default)]
    dry_run: bool,
}

pub struct WorkspaceHttpServer {
    local_addr: SocketAddr,
    token_file: PathBuf,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<Result<(), io::Error>>>,
}

impl fmt::Debug for WorkspaceHttpServer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WorkspaceHttpServer")
            .field("local_addr", &self.local_addr)
            .field("token_file", &self.token_file)
            .finish_non_exhaustive()
    }
}

impl WorkspaceHttpServer {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub fn token_file(&self) -> &Path {
        &self.token_file
    }

    pub async fn shutdown(mut self) -> Result<(), io::Error> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task
            .take()
            .expect("HTTP server task is present")
            .await
            .map_err(|error| io::Error::other(format!("HTTP server task failed: {error}")))?
    }
}

impl Drop for WorkspaceHttpServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

pub async fn serve_workspace_http(
    workspace: WorkspaceService,
    address: SocketAddr,
    token_file: impl Into<PathBuf>,
) -> Result<WorkspaceHttpServer, io::Error> {
    serve_workspace_http_with_limits(
        workspace,
        address,
        token_file.into(),
        WORKSPACE_HTTP_ADMISSION_LIMITS,
    )
    .await
}

async fn serve_workspace_http_with_limits(
    workspace: WorkspaceService,
    address: SocketAddr,
    token_file: PathBuf,
    admission_limits: WorkspaceHttpAdmissionLimits,
) -> Result<WorkspaceHttpServer, io::Error> {
    if !address.ip().is_loopback() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "refusing plaintext workspace HTTP bind {address}; bind loopback and use SSH forwarding or a TLS reverse proxy"
            ),
        ));
    }
    let token = load_or_create_workspace_http_token(&token_file)?;
    let listener = TcpListener::bind(address).await?;
    let local_addr = listener.local_addr()?;
    let router = workspace_http_router(workspace, token);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let task = tokio::spawn(async move {
        run_workspace_http_server(listener, router, admission_limits, shutdown_rx).await
    });
    Ok(WorkspaceHttpServer {
        local_addr,
        token_file,
        shutdown: Some(shutdown_tx),
        task: Some(task),
    })
}

async fn run_workspace_http_server(
    listener: TcpListener,
    router: Router,
    limits: WorkspaceHttpAdmissionLimits,
    mut shutdown: oneshot::Receiver<()>,
) -> Result<(), io::Error> {
    let permits = Arc::new(Semaphore::new(limits.maximum_connections));
    let (connection_shutdown, _) = watch::channel(false);
    let mut connections = JoinSet::new();
    // Spacing for accept errors that persist (descriptor exhaustion).
    let mut accept_backoff =
        cmux_tui_core::backoff::Backoff::new(Duration::from_millis(10), Duration::from_secs(1));
    loop {
        tokio::select! {
            biased;
            _ = &mut shutdown => break,
            Some(result) = connections.join_next(), if !connections.is_empty() => {
                if let Err(error) = result
                    && error.is_panic()
                {
                    return Err(io::Error::other(format!(
                        "workspace HTTP connection task panicked: {error}"
                    )));
                }
            }
            permit = permits.clone().acquire_owned() => {
                let permit = permit.expect("workspace HTTP admission semaphore is never closed");
                let accepted = tokio::select! {
                    biased;
                    _ = &mut shutdown => {
                        drop(permit);
                        break;
                    }
                    Some(result) = connections.join_next(), if !connections.is_empty() => {
                        drop(permit);
                        if let Err(error) = result
                            && error.is_panic()
                        {
                            return Err(io::Error::other(format!(
                                "workspace HTTP connection task panicked: {error}"
                            )));
                        }
                        continue;
                    }
                    accepted = listener.accept() => accepted,
                };
                match accepted {
                    Ok((stream, _)) => {
                        accept_backoff.reset();
                        let _ = stream.set_nodelay(true);
                        connections.spawn(serve_workspace_http_connection(
                            stream,
                            permit,
                            router.clone(),
                            limits,
                            connection_shutdown.subscribe(),
                        ));
                    }
                    Err(error) => {
                        drop(permit);
                        if cmux_tui_core::backoff::accept_error_needs_backoff(&error) {
                            tokio::select! {
                                biased;
                                _ = &mut shutdown => break,
                                _ = tokio::time::sleep(accept_backoff.next_delay()) => {}
                            }
                        }
                    }
                }
            }
        }
    }

    connection_shutdown.send_replace(true);
    let graceful = tokio::time::timeout(limits.graceful_shutdown_timeout, async {
        while let Some(result) = connections.join_next().await {
            if let Err(error) = result
                && error.is_panic()
            {
                return Err(io::Error::other(format!(
                    "workspace HTTP connection task panicked: {error}"
                )));
            }
        }
        Ok(())
    })
    .await;
    match graceful {
        Ok(result) => result,
        Err(_) => {
            connections.abort_all();
            while connections.join_next().await.is_some() {}
            Ok(())
        }
    }
}

async fn serve_workspace_http_connection(
    stream: TcpStream,
    _permit: OwnedSemaphorePermit,
    router: Router,
    limits: WorkspaceHttpAdmissionLimits,
    mut shutdown: watch::Receiver<bool>,
) {
    let service = ServiceBuilder::new()
        .layer(RequestBodyTimeoutLayer::new(limits.request_body_timeout))
        .service(router);
    let mut builder = http1::Builder::new();
    builder
        .timer(TokioTimer::new())
        .header_read_timeout(limits.header_timeout)
        .max_buf_size(limits.maximum_header_bytes.max(8 * 1024));
    let connection =
        builder.serve_connection(TokioIo::new(stream), TowerToHyperService::new(service));
    tokio::pin!(connection);
    tokio::select! {
        _ = &mut connection => {}
        _ = shutdown.changed() => {
            connection.as_mut().graceful_shutdown();
            let _ = connection.await;
        }
    }
}

fn workspace_http_router(workspace: WorkspaceService, token: WorkspaceHttpBearerToken) -> Router {
    let state = WorkspaceHttpState {
        workspace,
        token,
        admission: Arc::new(Semaphore::new(MAX_CONCURRENT_HTTP_REQUESTS)),
    };
    Router::new()
        .route("/v1/workspace-rpc", post(workspace_rpc))
        .route("/v1/workspaces/{workspace}/apply-patch", post(apply_patch))
        .layer(DefaultBodyLimit::max(MAX_HTTP_RPC_BODY_BYTES))
        .layer(middleware::from_fn_with_state(state.clone(), authenticate_and_admit))
        .with_state(state)
}

async fn authenticate_and_admit(
    State(state): State<WorkspaceHttpState>,
    request: Request,
    next: Next,
) -> Response {
    // No browser page is a client of this listener (the localhost listener
    // rule, plans/cmux-next/identity.md section 4). Refusing every Origin
    // stops cross-site form posts and DNS-rebound pages before the token check.
    if request.headers().contains_key(ORIGIN) {
        let mut response = StatusCode::FORBIDDEN.into_response();
        response.headers_mut().insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
        response.headers_mut().insert(CONNECTION, HeaderValue::from_static("close"));
        return response;
    }
    let authorized = request
        .headers()
        .get(AUTHORIZATION)
        .is_some_and(|value| state.token.matches_authorization(value.as_bytes()));
    if !authorized {
        let mut response = StatusCode::UNAUTHORIZED.into_response();
        response.headers_mut().insert(WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
        response.headers_mut().insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
        // The admission stream enforces its header deadline through the first authentication
        // decision, so an unauthorized client must not reuse the physical connection.
        response.headers_mut().insert(CONNECTION, HeaderValue::from_static("close"));
        return response;
    }
    let Ok(_permit) = state.admission.clone().try_acquire_owned() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let mut response = next.run(request).await;
    response.headers_mut().insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

async fn workspace_rpc(
    State(state): State<WorkspaceHttpState>,
    Json(request): Json<RpcRequest>,
) -> Response {
    let mut prepared = state.workspace.prepare_rpc(request).await;
    let response = prepared.take_response();
    let response_id = response.id;
    let encoded = match serde_json::to_vec(&response) {
        Ok(encoded) => encoded,
        Err(error) => {
            drop(prepared);
            eprintln!("cmux workspace HTTP response serialization failed: {error}");
            return Json(RpcResponse {
                id: response_id,
                result: Err(RpcError::new("internal", "workspace response encoding failed")),
            })
            .into_response();
        }
    };
    prepared.commit_delivery();
    let mut response = Response::new(Body::from(encoded));
    response.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    response
}

async fn apply_patch(
    State(state): State<WorkspaceHttpState>,
    AxumPath(workspace): AxumPath<String>,
    Query(query): Query<ApplyPatchQuery>,
    body: String,
) -> Json<WorkspaceHttpResponse> {
    let result = state
        .workspace
        .handle_request(WorkspaceRequest::ApplyPatch {
            workspace: WorkspaceId(workspace),
            patch: body,
            dry_run: query.dry_run,
            preconditions: BTreeMap::new(),
        })
        .await;
    Json(WorkspaceHttpResponse { result })
}

#[cfg(test)]
#[path = "http_tests.rs"]
mod tests;
