//! The daemon's HTTP API (bearer token). Every mutating reply carries its timings in ms.
//!
//! ```text
//! POST   /v1/machines                 {name?, image?, vcpus?, mem_mib?, labels?, egress?}
//! GET    /v1/machines
//! GET    /v1/machines/{id}
//! DELETE /v1/machines/{id}
//! POST   /v1/machines/{id}/pause | /resume | /snapshot
//! GET    /v1/machines/{id}/files?path=P      raw bytes
//! PUT    /v1/machines/{id}/files?path=P      raw bytes (&mode=octal)
//! POST   /v1/machines/{id}/exec       {program, args?, env?, cwd?, stdin? (b64), timeout_ms?}
//! GET    /v1/machines/{id}/ports
//! GET    /v1/snapshots
//! DELETE /v1/snapshots/{id}
//! POST   /v1/snapshots/{id}/fork      same body as create (image ignored)
//! GET    /healthz                     (no token)
//! /v1/vms..., /v1/templates...        cmux-platform's own-host contract (ownhost.rs)
//! ```

use std::sync::Arc;

use axum::Json;
use axum::Router;
use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use serde::Deserialize;
use serde_json::json;

use crate::host::{CreateRequest, ExecRequest, Host, VmdError};
use crate::ownhost::OwnHost;

/// Largest request body (file uploads).
pub const MAX_BODY: usize = 192 * 1024 * 1024;

#[derive(Clone)]
struct AppState {
    host: Arc<Host>,
    token: Arc<str>,
}

pub fn router(host: Arc<Host>, own: Arc<OwnHost>, token: String) -> Router {
    let state = AppState { host, token: token.into() };
    let api = Router::new()
        .route("/v1/machines", post(create).get(list))
        .route("/v1/machines/{id}", get(get_one).delete(remove))
        .route("/v1/machines/{id}/pause", post(pause))
        .route("/v1/machines/{id}/resume", post(resume))
        .route("/v1/machines/{id}/snapshot", post(snapshot))
        .route("/v1/machines/{id}/files", get(read_file).put(write_file))
        .route("/v1/machines/{id}/exec", post(exec))
        .route("/v1/machines/{id}/ports", get(ports))
        .route("/v1/snapshots", get(snapshots))
        .route("/v1/snapshots/{id}", delete(remove_snapshot))
        .route("/v1/snapshots/{id}/fork", post(fork))
        .merge(crate::ownhost::routes(own))
        .layer(middleware::from_fn_with_state(state.clone(), auth));
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .merge(api)
        .layer(DefaultBodyLimit::max(MAX_BODY))
        .with_state(state)
}

/// Constant-time comparison, so the token cannot be found byte by byte from reply timing.
fn token_matches(given: &[u8], want: &[u8]) -> bool {
    given.len() == want.len() && given.iter().zip(want).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

async fn auth(
    State(st): State<AppState>,
    headers: HeaderMap,
    req: Request,
    next: Next,
) -> Response {
    let given = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if !token_matches(given.as_bytes(), st.token.as_bytes()) {
        return ApiError(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "missing or wrong bearer token".into(),
        )
        .into_response();
    }
    next.run(req).await
}

pub(crate) struct ApiError(pub(crate) StatusCode, pub(crate) &'static str, pub(crate) String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error": {"code": self.1, "message": self.2}}))).into_response()
    }
}

impl From<VmdError> for ApiError {
    fn from(e: VmdError) -> Self {
        let msg = e.to_string();
        match e {
            VmdError::MachineNotFound => Self(StatusCode::NOT_FOUND, "machine_not_found", msg),
            VmdError::SnapshotNotFound => Self(StatusCode::NOT_FOUND, "snapshot_not_found", msg),
            VmdError::InvalidState { .. } => Self(StatusCode::CONFLICT, "invalid_state", msg),
            VmdError::InvalidInput(_) => Self(StatusCode::BAD_REQUEST, "invalid_input", msg),
            VmdError::HostFull(_) => Self(StatusCode::SERVICE_UNAVAILABLE, "host_full", msg),
            VmdError::Backend(_) => Self(StatusCode::INTERNAL_SERVER_ERROR, "backend", msg),
        }
    }
}

pub(crate) type ApiResult = Result<Response, ApiError>;

async fn create(State(st): State<AppState>, Json(req): Json<CreateRequest>) -> ApiResult {
    let (machine, timing) = st.host.create(req).await?;
    Ok((StatusCode::CREATED, Json(json!({"machine": machine, "timing": timing}))).into_response())
}

async fn list(State(st): State<AppState>) -> ApiResult {
    Ok(Json(json!({"machines": st.host.list()})).into_response())
}

async fn get_one(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult {
    Ok(Json(json!({"machine": st.host.get(&id)?})).into_response())
}

async fn remove(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult {
    st.host.delete(&id).await?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

async fn pause(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult {
    Ok(Json(json!({"timing": st.host.pause(&id).await?})).into_response())
}

async fn resume(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult {
    Ok(Json(json!({"timing": st.host.resume(&id).await?})).into_response())
}

async fn snapshot(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult {
    let (snapshot, timing) = st.host.snapshot(&id).await?;
    Ok((StatusCode::CREATED, Json(json!({"snapshot": snapshot, "timing": timing}))).into_response())
}

async fn snapshots(State(st): State<AppState>) -> ApiResult {
    Ok(Json(json!({"snapshots": st.host.snapshots()})).into_response())
}

async fn remove_snapshot(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult {
    st.host.delete_snapshot(&id).await?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

async fn fork(
    State(st): State<AppState>,
    Path(id): Path<String>,
    body: Option<Json<CreateRequest>>,
) -> ApiResult {
    let req = body.map(|Json(r)| r).unwrap_or_default();
    let (machine, timing) = st.host.fork(&id, req).await?;
    Ok((StatusCode::CREATED, Json(json!({"machine": machine, "timing": timing}))).into_response())
}

#[derive(Deserialize)]
struct FileQuery {
    path: String,
    #[serde(default)]
    mode: Option<String>,
}

async fn read_file(
    State(st): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<FileQuery>,
) -> ApiResult {
    let data = st.host.read_file(&id, &q.path).await?;
    Ok(([(header::CONTENT_TYPE, "application/octet-stream")], data).into_response())
}

async fn write_file(
    State(st): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<FileQuery>,
    body: Bytes,
) -> ApiResult {
    let mode = match q.mode.as_deref() {
        None => None,
        Some(m) => Some(u32::from_str_radix(m, 8).map_err(|_| {
            ApiError(StatusCode::BAD_REQUEST, "invalid_input", format!("bad mode {m:?}"))
        })?),
    };
    st.host.write_file(&id, &q.path, &body, mode).await?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

async fn exec(
    State(st): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<ExecRequest>,
) -> ApiResult {
    let (exit_code, stdout, stderr) = st.host.exec(&id, req).await?;
    Ok(Json(
        json!({"exit_code": exit_code, "stdout": B64.encode(stdout), "stderr": B64.encode(stderr)}),
    )
    .into_response())
}

async fn ports(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult {
    st.host.get(&id)?;
    // Inbound is denied by default and no forward API exists yet: nothing is exposed.
    Ok(Json(json!({"ports": []})).into_response())
}

#[cfg(test)]
mod tests {
    use super::token_matches;

    #[test]
    fn token_comparison() {
        assert!(token_matches(b"abc", b"abc"));
        assert!(!token_matches(b"abd", b"abc"));
        assert!(!token_matches(b"ab", b"abc"));
        assert!(!token_matches(b"", b"abc"));
    }
}
