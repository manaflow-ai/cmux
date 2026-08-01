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

use axum::extract::{DefaultBodyLimit, Path as AxumPath, Query, Request, State};
use axum::http::header::{AUTHORIZATION, CACHE_CONTROL, WWW_AUTHENTICATE};
use axum::http::{HeaderValue, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use base64::Engine;
use cmux_remote_protocol::{
    RpcError, RpcRequest, RpcResponse, WorkspaceId, WorkspaceRequest, WorkspaceResponse,
};
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;
use tokio::sync::{Semaphore, oneshot};
use zeroize::{Zeroize, Zeroizing};

use crate::workspace::WorkspaceService;

const HTTP_TOKEN_BYTES: usize = 32;
const MAX_HTTP_TOKEN_FILE_BYTES: u64 = 256;
const MAX_HTTP_RPC_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_CONCURRENT_HTTP_REQUESTS: usize = 64;

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
    if !address.ip().is_loopback() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "refusing plaintext workspace HTTP bind {address}; bind loopback and use SSH forwarding or a TLS reverse proxy"
            ),
        ));
    }
    let token_file = token_file.into();
    let token = load_or_create_workspace_http_token(&token_file)?;
    let listener = cmux_tui_process::tokio_net::bind_tcp_listener(address)?;
    let local_addr = listener.local_addr()?;
    let router = workspace_http_router(workspace, token);
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let task = tokio::spawn(async move {
        axum::serve(listener, router)
            .with_graceful_shutdown(async move {
                let _ = shutdown_rx.await;
            })
            .await
    });
    Ok(WorkspaceHttpServer {
        local_addr,
        token_file,
        shutdown: Some(shutdown_tx),
        task: Some(task),
    })
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
) -> Json<RpcResponse> {
    Json(state.workspace.handle_rpc(request).await)
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

    use axum::body::Body;
    use axum::body::to_bytes;
    use axum::http::Request as HttpRequest;
    use cmux_remote_protocol::{RequestId, WorkspaceRequest};
    use tempfile::tempdir;
    use tower::ServiceExt;

    use super::*;

    fn request(authorization: Option<&str>) -> HttpRequest<Body> {
        let rpc = RpcRequest {
            id: RequestId::from_u128(1),
            timeout_ms: None,
            request: WorkspaceRequest::Capabilities,
        };
        let mut builder = HttpRequest::builder()
            .method("POST")
            .uri("/v1/workspace-rpc")
            .header("content-type", "application/json");
        if let Some(authorization) = authorization {
            builder = builder.header(AUTHORIZATION, authorization);
        }
        builder.body(Body::from(serde_json::to_vec(&rpc).unwrap())).unwrap()
    }

    #[tokio::test]
    async fn workspace_http_authenticates_before_rpc_dispatch() {
        let token = WorkspaceHttpBearerToken::test_value();
        let authorization = format!("Bearer {}", token.0.as_str());
        let router = workspace_http_router(WorkspaceService::new(), token);

        assert_eq!(
            router.clone().oneshot(request(None)).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
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
}
