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
    AUTHORIZATION, CACHE_CONTROL, CONNECTION, CONTENT_TYPE, WWW_AUTHENTICATE,
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
    let mut encoded = String::new();
    file.read_to_string(&mut encoded)?;
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
                        let _ = stream.set_nodelay(true);
                        connections.spawn(serve_workspace_http_connection(
                            stream,
                            permit,
                            router.clone(),
                            limits,
                            connection_shutdown.subscribe(),
                        ));
                    }
                    Err(_) => {
                        drop(permit);
                        tokio::select! {
                            biased;
                            _ = &mut shutdown => break,
                            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
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
mod tests {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    use axum::body::Body;
    use axum::body::to_bytes;
    use axum::http::Request as HttpRequest;
    use cmux_remote_protocol::{RequestId, WorkspaceRequest};
    use tempfile::tempdir;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tower::ServiceExt;

    use super::*;

    fn request(authorization: Option<&str>) -> HttpRequest<Body> {
        workspace_request(authorization, 1, WorkspaceRequest::Capabilities)
    }

    fn workspace_request(
        authorization: Option<&str>,
        request_id: u128,
        request: WorkspaceRequest,
    ) -> HttpRequest<Body> {
        let rpc = RpcRequest { id: RequestId::from_u128(request_id), timeout_ms: None, request };
        let mut builder = HttpRequest::builder()
            .method("POST")
            .uri("/v1/workspace-rpc")
            .header("content-type", "application/json");
        if let Some(authorization) = authorization {
            builder = builder.header(AUTHORIZATION, authorization);
        }
        builder.body(Body::from(serde_json::to_vec(&rpc).unwrap())).unwrap()
    }

    async fn decode_rpc_response(response: Response) -> RpcResponse {
        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), MAX_HTTP_RPC_BODY_BYTES).await.unwrap();
        serde_json::from_slice(&body).unwrap()
    }

    fn raw_capabilities_request(
        address: SocketAddr,
        token: &WorkspaceHttpBearerToken,
        request_id: u128,
    ) -> Vec<u8> {
        raw_capabilities_request_with_connection(address, token, request_id, "close")
    }

    fn raw_capabilities_request_with_connection(
        address: SocketAddr,
        token: &WorkspaceHttpBearerToken,
        request_id: u128,
        connection: &str,
    ) -> Vec<u8> {
        let rpc = RpcRequest {
            id: RequestId::from_u128(request_id),
            timeout_ms: None,
            request: WorkspaceRequest::Capabilities,
        };
        let body = serde_json::to_vec(&rpc).unwrap();
        let mut request = format!(
            "POST /v1/workspace-rpc HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: {connection}\r\n\r\n",
            token.0.as_str(),
            body.len()
        )
        .into_bytes();
        request.extend_from_slice(&body);
        request
    }

    async fn read_raw_http_response(connection: &mut TcpStream) -> Vec<u8> {
        let mut response = Vec::new();
        loop {
            let header_end = response.windows(4).position(|bytes| bytes == b"\r\n\r\n");
            if let Some(header_end) = header_end {
                let headers = std::str::from_utf8(&response[..header_end]).unwrap();
                let content_length = headers
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse::<usize>().unwrap())
                    })
                    .expect("raw HTTP response omitted Content-Length");
                if response.len() >= header_end + 4 + content_length {
                    return response;
                }
            }
            let read = connection.read_buf(&mut response).await.unwrap();
            assert_ne!(read, 0, "HTTP connection closed before its response completed");
        }
    }

    #[tokio::test]
    async fn workspace_http_authenticates_before_rpc_dispatch() {
        let token = WorkspaceHttpBearerToken::test_value();
        let authorization = format!("Bearer {}", token.0.as_str());
        let router = workspace_http_router(WorkspaceService::new(), token);

        let unauthorized = router.clone().oneshot(request(None)).await.unwrap();
        assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(unauthorized.headers().get(CONNECTION).unwrap(), "close");
        assert_eq!(
            router.clone().oneshot(request(Some("Bearer wrong"))).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
        let response = router.oneshot(request(Some(&authorization))).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), MAX_HTTP_RPC_BODY_BYTES).await.unwrap();
        let response: RpcResponse = serde_json::from_slice(&body).unwrap();
        assert!(response.result.is_ok());
    }

    #[tokio::test]
    async fn dropped_http_page_keeps_its_parent_cursor_retryable() {
        let directory = tempdir().unwrap();
        for name in ["a.txt", "b.txt", "c.txt"] {
            tokio::fs::write(directory.path().join(name), name).await.unwrap();
        }
        let workspace = WorkspaceService::new();
        let opened = workspace
            .handle_request(WorkspaceRequest::OpenWorkspace {
                root: directory.path().to_string_lossy().into_owned(),
            })
            .await
            .unwrap();
        let WorkspaceResponse::Workspace { id, .. } = opened else { panic!() };
        let token = WorkspaceHttpBearerToken::test_value();
        let authorization = format!("Bearer {}", token.0.as_str());
        let router = workspace_http_router(workspace, token);

        let first = decode_rpc_response(
            router
                .clone()
                .oneshot(workspace_request(
                    Some(&authorization),
                    1,
                    WorkspaceRequest::ListDirectory {
                        workspace: id.clone(),
                        path: String::new(),
                        include_hidden: false,
                        limit: 1,
                        cursor: None,
                    },
                ))
                .await
                .unwrap(),
        )
        .await;
        let WorkspaceResponse::Directory { next_cursor: Some(parent), .. } = first.result.unwrap()
        else {
            panic!()
        };

        let dropped = router
            .clone()
            .oneshot(workspace_request(
                Some(&authorization),
                2,
                WorkspaceRequest::ListDirectory {
                    workspace: id.clone(),
                    path: String::new(),
                    include_hidden: false,
                    limit: 1,
                    cursor: Some(parent.clone()),
                },
            ))
            .await
            .unwrap();
        drop(dropped);

        let mut retries = Vec::new();
        for request_id in [3, 4] {
            let response = decode_rpc_response(
                router
                    .clone()
                    .oneshot(workspace_request(
                        Some(&authorization),
                        request_id,
                        WorkspaceRequest::ListDirectory {
                            workspace: id.clone(),
                            path: String::new(),
                            include_hidden: false,
                            limit: 1,
                            cursor: Some(parent.clone()),
                        },
                    ))
                    .await
                    .unwrap(),
            )
            .await;
            let WorkspaceResponse::Directory { entries, next_cursor: Some(successor), .. } =
                response.result.unwrap()
            else {
                panic!()
            };
            retries.push((entries, successor));
        }
        assert_eq!(retries[0].0, retries[1].0);
        assert_eq!(retries[0].0[0].name, "b.txt");
        assert_eq!(retries[0].1, retries[1].1);
    }

    #[tokio::test]
    async fn authenticated_rest_action_applies_native_codex_patch() {
        let directory = tempdir().unwrap();
        let workspace = WorkspaceService::new();
        let opened = workspace
            .handle_request(WorkspaceRequest::OpenWorkspace {
                root: directory.path().to_str().unwrap().to_owned(),
            })
            .await
            .unwrap();
        let WorkspaceResponse::Workspace { id, .. } = opened else { panic!() };
        let token = WorkspaceHttpBearerToken::test_value();
        let authorization = format!("Bearer {}", token.0.as_str());
        let router = workspace_http_router(workspace, token);
        let patch = "*** Begin Patch\n*** Add File: created.txt\n+created\n*** End Patch\n";
        let request = HttpRequest::builder()
            .method("POST")
            .uri(format!("/v1/workspaces/{}/apply-patch", id.0))
            .header(AUTHORIZATION, authorization)
            .header("content-type", "text/plain")
            .body(Body::from(patch))
            .unwrap();

        let response = router.oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), MAX_HTTP_RPC_BODY_BYTES).await.unwrap();
        let response: WorkspaceHttpResponse = serde_json::from_slice(&body).unwrap();
        assert!(response.result.is_ok());
        assert_eq!(
            tokio::fs::read(directory.path().join("created.txt")).await.unwrap(),
            b"created\n"
        );
    }

    #[test]
    fn workspace_http_token_file_is_owner_only_and_stable() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("workspace-http.token");
        let first = load_or_create_workspace_http_token(&path).unwrap();
        let second = load_or_create_workspace_http_token(&path).unwrap();
        assert!(bool::from(first.0.as_bytes().ct_eq(second.0.as_bytes())));
        #[cfg(unix)]
        assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[tokio::test]
    async fn workspace_http_refuses_plaintext_non_loopback_bind() {
        let directory = tempdir().unwrap();
        let error = serve_workspace_http(
            WorkspaceService::new(),
            "0.0.0.0:0".parse().unwrap(),
            directory.path().join("token"),
        )
        .await
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }

    #[tokio::test]
    async fn partial_headers_expire_and_raw_connection_admission_is_bounded() {
        let directory = tempdir().unwrap();
        let limits = WorkspaceHttpAdmissionLimits {
            maximum_connections: 1,
            header_timeout: Duration::from_millis(300),
            request_body_timeout: Duration::from_millis(300),
            graceful_shutdown_timeout: Duration::from_millis(300),
            maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
        };
        let server = serve_workspace_http_with_limits(
            WorkspaceService::new(),
            "127.0.0.1:0".parse().unwrap(),
            directory.path().join("token"),
            limits,
        )
        .await
        .unwrap();
        let address = server.local_addr();

        let mut slow_connections = Vec::new();
        for _ in 0..limits.maximum_connections {
            let mut connection = TcpStream::connect(address).await.unwrap();
            connection.write_all(b"POST /v1/workspace-rpc HTTP/1.1\r\nHost:").await.unwrap();
            slow_connections.push(connection);
        }
        tokio::time::sleep(Duration::from_millis(20)).await;

        let token = read_workspace_http_token(server.token_file()).unwrap();
        let request = raw_capabilities_request(address, &token, 2);
        let mut queued = TcpStream::connect(address).await.unwrap();
        queued.write_all(&request).await.unwrap();

        let mut first_byte = [0_u8; 1];
        assert!(
            tokio::time::timeout(Duration::from_millis(50), queued.read(&mut first_byte),)
                .await
                .is_err(),
            "a request bypassed raw connection admission"
        );

        let slow_result =
            tokio::time::timeout(Duration::from_secs(2), slow_connections[0].read(&mut first_byte))
                .await
                .expect("partial HTTP headers did not expire");
        assert!(matches!(slow_result, Ok(0) | Err(_)), "partial HTTP connection remained open");

        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), queued.read_to_end(&mut response))
            .await
            .expect("queued request was not admitted after the header deadline")
            .unwrap();
        assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn oversized_headers_close_and_release_raw_connection_admission() {
        let directory = tempdir().unwrap();
        let limits = WorkspaceHttpAdmissionLimits {
            maximum_connections: 1,
            header_timeout: Duration::from_secs(2),
            request_body_timeout: Duration::from_secs(2),
            graceful_shutdown_timeout: Duration::from_secs(2),
            maximum_header_bytes: 8 * 1024,
        };
        let server = serve_workspace_http_with_limits(
            WorkspaceService::new(),
            "127.0.0.1:0".parse().unwrap(),
            directory.path().join("token"),
            limits,
        )
        .await
        .unwrap();
        let address = server.local_addr();

        let mut oversized = TcpStream::connect(address).await.unwrap();
        let mut oversized_header = b"POST /v1/workspace-rpc HTTP/1.1\r\nX-Fill: ".to_vec();
        oversized_header.extend(std::iter::repeat_n(b'a', limits.maximum_header_bytes));
        oversized.write_all(&oversized_header).await.unwrap();

        let token = read_workspace_http_token(server.token_file()).unwrap();
        let request = raw_capabilities_request(address, &token, 3);
        let mut queued = TcpStream::connect(address).await.unwrap();
        queued.write_all(&request).await.unwrap();

        let mut rejected = Vec::new();
        let rejected =
            tokio::time::timeout(Duration::from_secs(1), oversized.read_to_end(&mut rejected))
                .await
                .expect("oversized HTTP headers did not close");
        if let Err(error) = rejected {
            assert!(
                matches!(
                    error.kind(),
                    io::ErrorKind::ConnectionAborted
                        | io::ErrorKind::ConnectionReset
                        | io::ErrorKind::BrokenPipe
                ),
                "unexpected oversized-header close error: {error}"
            );
        }

        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), queued.read_to_end(&mut response))
            .await
            .expect("oversized headers did not release raw connection admission")
            .unwrap();
        assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn partial_second_keep_alive_header_expires_and_releases_admission() {
        let directory = tempdir().unwrap();
        let limits = WorkspaceHttpAdmissionLimits {
            maximum_connections: 1,
            header_timeout: Duration::from_millis(200),
            request_body_timeout: Duration::from_millis(200),
            graceful_shutdown_timeout: Duration::from_millis(200),
            maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
        };
        let server = serve_workspace_http_with_limits(
            WorkspaceService::new(),
            "127.0.0.1:0".parse().unwrap(),
            directory.path().join("token"),
            limits,
        )
        .await
        .unwrap();
        let address = server.local_addr();
        let token = read_workspace_http_token(server.token_file()).unwrap();
        let mut keep_alive = TcpStream::connect(address).await.unwrap();
        keep_alive
            .write_all(&raw_capabilities_request_with_connection(address, &token, 4, "keep-alive"))
            .await
            .unwrap();
        let response = read_raw_http_response(&mut keep_alive).await;
        assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));

        keep_alive.write_all(b"POST /v1/workspace-rpc HTTP/1.1\r\nHost:").await.unwrap();
        let mut first_byte = [0_u8; 1];
        let expired =
            tokio::time::timeout(Duration::from_secs(2), keep_alive.read(&mut first_byte))
                .await
                .expect("the second keep-alive header had no deadline");
        assert!(matches!(expired, Ok(0) | Err(_)), "partial second header remained open");

        let mut replacement = TcpStream::connect(address).await.unwrap();
        replacement.write_all(&raw_capabilities_request(address, &token, 5)).await.unwrap();
        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), replacement.read_to_end(&mut response))
            .await
            .expect("expired keep-alive connection retained its admission permit")
            .unwrap();
        assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn stalled_declared_request_body_expires_and_releases_admission() {
        let directory = tempdir().unwrap();
        let limits = WorkspaceHttpAdmissionLimits {
            maximum_connections: 1,
            header_timeout: Duration::from_millis(200),
            request_body_timeout: Duration::from_millis(200),
            graceful_shutdown_timeout: Duration::from_millis(200),
            maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
        };
        let server = serve_workspace_http_with_limits(
            WorkspaceService::new(),
            "127.0.0.1:0".parse().unwrap(),
            directory.path().join("token"),
            limits,
        )
        .await
        .unwrap();
        let address = server.local_addr();
        let token = read_workspace_http_token(server.token_file()).unwrap();
        let mut stalled = TcpStream::connect(address).await.unwrap();
        stalled
            .write_all(
                format!(
                    "POST /v1/workspace-rpc HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{{",
                    token.0.as_str()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), stalled.read_to_end(&mut response))
            .await
            .expect("declared request body had no idle deadline")
            .unwrap();

        let mut replacement = TcpStream::connect(address).await.unwrap();
        replacement.write_all(&raw_capabilities_request(address, &token, 6)).await.unwrap();
        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(2), replacement.read_to_end(&mut response))
            .await
            .expect("stalled body retained its admission permit")
            .unwrap();
        assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn workspace_http_shutdown_is_bounded_with_a_stalled_request() {
        let directory = tempdir().unwrap();
        let limits = WorkspaceHttpAdmissionLimits {
            maximum_connections: 1,
            header_timeout: Duration::from_millis(100),
            request_body_timeout: Duration::from_secs(60),
            graceful_shutdown_timeout: Duration::from_millis(100),
            maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
        };
        let server = serve_workspace_http_with_limits(
            WorkspaceService::new(),
            "127.0.0.1:0".parse().unwrap(),
            directory.path().join("token"),
            limits,
        )
        .await
        .unwrap();
        let address = server.local_addr();
        let token = read_workspace_http_token(server.token_file()).unwrap();
        let mut stalled = TcpStream::connect(address).await.unwrap();
        stalled
            .write_all(
                format!(
                    "POST /v1/workspace-rpc HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{{",
                    token.0.as_str()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;

        tokio::time::timeout(Duration::from_secs(1), server.shutdown())
            .await
            .expect("workspace HTTP graceful shutdown was unbounded")
            .unwrap();
    }
}
