//! Server authority for transport v3. No caller-provided roles or device tags are trusted.
pub mod auth;
pub mod proof;
pub mod store;

use axum::{
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use cmux_v3_grants::{GrantSigner, LeasePolicy};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

#[derive(Clone)]
pub struct Service {
    pub store: store::Store,
    pub stack: Arc<auth::Stack>,
    pub signer: Arc<GrantSigner>,
    pub audience: String,
}
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid request")]
    Invalid,
    #[error("unauthenticated")]
    Unauthorized,
    #[error("access denied")]
    Denied,
    #[error("revision conflict or repeated request")]
    Conflict,
    #[error("service unavailable")]
    Unavailable,
}
impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let (status, code) = match self {
            Self::Invalid => (StatusCode::BAD_REQUEST, "invalid_request"),
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            Self::Denied => (StatusCode::FORBIDDEN, "access_denied"),
            Self::Conflict => (StatusCode::CONFLICT, "conflict"),
            Self::Unavailable => (StatusCode::SERVICE_UNAVAILABLE, "unavailable"),
        };
        (
            status,
            [(axum::http::header::CACHE_CONTROL, "no-store")],
            Json(serde_json::json!({"error":code})),
        )
            .into_response()
    }
}
impl From<sqlx::Error> for Error {
    fn from(value: sqlx::Error) -> Self {
        if value
            .as_database_error()
            .is_some_and(|e| e.is_unique_violation())
        {
            return Self::Conflict;
        }
        tracing::error!(code = ?value.as_database_error().and_then(|e| e.code()), "v3 database operation failed");
        Self::Unavailable
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Signed<T> {
    pub request: T,
    pub proof: proof::Proof,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Enrollment {
    pub team: String,
    pub device_id: Uuid,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Authorization {
    pub team: String,
    pub destination: String,
    pub action: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PolicyUpdate {
    pub team: String,
    pub expected_revision: i64,
    pub cedar: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceUpdate {
    pub team: String,
    pub peer: String,
    pub expected_revision: i64,
    pub tags: Vec<String>,
    pub lease: LeasePolicy,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Revocation {
    pub team: String,
    pub peer: String,
    pub expected_revision: i64,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TeamRequest {
    pub team: String,
}

fn token(headers: &HeaderMap) -> Result<&str, Error> {
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|s| !s.is_empty() && s.len() <= 8192)
        .ok_or(Error::Unauthorized)
}
pub fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}
pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock before UNIX epoch")
        .as_secs()
}

pub fn router(service: Service) -> Router {
    let requests = Arc::new(tokio::sync::Semaphore::new(128));
    Router::new()
        .route("/healthz", get(|| async { StatusCode::OK }))
        .route("/readyz", get(ready))
        .route("/v3/enroll", post(enroll))
        .route("/v3/authorize", post(authorize))
        .route("/v3/policy", post(policy))
        .route("/v3/device-policy", post(device_policy))
        .route("/v3/revoke", post(revoke))
        .route("/v3/directory", post(directory))
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(axum::middleware::from_fn(
            move |request: axum::extract::Request, next: axum::middleware::Next| {
                let requests = requests.clone();
                async move {
                    let Ok(_permit) = requests.try_acquire() else {
                        return Error::Unavailable.into_response();
                    };
                    let mut response = next.run(request).await;
                    response.headers_mut().insert(
                        axum::http::header::CACHE_CONTROL,
                        axum::http::HeaderValue::from_static("no-store"),
                    );
                    response
                }
            },
        ))
        .with_state(service)
}
async fn ready(State(s): State<Service>) -> Result<StatusCode, Error> {
    s.store.ready().await?;
    Ok(StatusCode::OK)
}
async fn enroll(
    State(s): State<Service>,
    headers: HeaderMap,
    Json(input): Json<Signed<Enrollment>>,
) -> Result<Json<serde_json::Value>, Error> {
    let identity = s
        .stack
        .authorize(token(&headers)?, &input.request.team, false)
        .await?;
    let peer = input.proof.verify(
        &s.audience,
        &identity.user,
        "/v3/enroll",
        &input.request,
        now(),
    )?;
    let revision = s.store.enroll(&identity, &input, peer).await?;
    Ok(Json(
        serde_json::json!({"peer":peer.to_string(),"revision":revision}),
    ))
}
async fn authorize(
    State(s): State<Service>,
    headers: HeaderMap,
    Json(input): Json<Signed<Authorization>>,
) -> Result<Json<serde_json::Value>, Error> {
    let mut identity = s
        .stack
        .authorize(token(&headers)?, &input.request.team, false)
        .await?;
    let source = input.proof.verify(
        &s.audience,
        &identity.user,
        "/v3/authorize",
        &input.request,
        now(),
    )?;
    if input.request.action != "relay_reserve" {
        let owner = s
            .store
            .owner(&identity.team, &input.request.destination)
            .await?;
        identity.verified_at = identity
            .verified_at
            .min(s.stack.member_verified(&owner, &identity.team).await?);
    }
    let grant = s
        .store
        .authorize(&identity, &input, source, &s.signer)
        .await?;
    Ok(Json(serde_json::json!({"grant":grant})))
}
async fn policy(
    State(s): State<Service>,
    headers: HeaderMap,
    Json(input): Json<PolicyUpdate>,
) -> Result<Json<serde_json::Value>, Error> {
    let identity = s
        .stack
        .authorize(token(&headers)?, &input.team, true)
        .await?;
    let revision = s.store.set_policy(&identity, input).await?;
    Ok(Json(serde_json::json!({"revision":revision})))
}
async fn device_policy(
    State(s): State<Service>,
    headers: HeaderMap,
    Json(input): Json<DeviceUpdate>,
) -> Result<Json<serde_json::Value>, Error> {
    let identity = s
        .stack
        .authorize(token(&headers)?, &input.team, true)
        .await?;
    let revision = s.store.set_device_policy(&identity, input).await?;
    Ok(Json(serde_json::json!({"revision":revision})))
}
async fn revoke(
    State(s): State<Service>,
    headers: HeaderMap,
    Json(input): Json<Revocation>,
) -> Result<Json<serde_json::Value>, Error> {
    let identity = s
        .stack
        .authorize(token(&headers)?, &input.team, true)
        .await?;
    let revision = s.store.revoke(&identity, input).await?;
    Ok(Json(serde_json::json!({"revision":revision})))
}
async fn directory(
    State(s): State<Service>,
    headers: HeaderMap,
    Json(input): Json<TeamRequest>,
) -> Result<Json<serde_json::Value>, Error> {
    let identity = s
        .stack
        .authorize(token(&headers)?, &input.team, false)
        .await?;
    Ok(Json(s.store.directory(&identity).await?))
}
