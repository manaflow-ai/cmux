//! The coordination and ACL service (`weft-coord`).
//!
//! Admin routes take `Authorization: Bearer <admin token>`. Device routes
//! are signed by the device's machine key ([`crate::signing`]). Every change
//! that can alter a netmap bumps one global version, which wakes every
//! netmap long-poll.

mod store;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::{HeaderMap, Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio::net::TcpListener;
use tokio::sync::watch;

pub use store::{NODE_KEY_LIFETIME_MS, address_of};
use store::{Store, hash_secret};

use crate::admin::MintAuthKey;
use crate::keys::SigningKey;
use crate::policy::Policy;
use crate::signing::{HEADER_NODE, HEADER_NONCE, HEADER_SIG, HEADER_TS, SignedHeaders, Verifier};
use crate::types::{
    CreateTailnetRequest, EndpointsRequest, ErrorBody, InboundAllow, MintAuthKeyResponse, Netmap,
    NodeState, PeerView, PolicyResponse, RegisterRequest, RegisterResponse, RelayInfo,
    RotateRequest, SelfView,
};

/// How long a netmap request waits for a change.
pub const LONG_POLL: Duration = Duration::from_secs(25);
/// Relay ticket lifetime. Clients refresh their netmap well inside it.
pub const TICKET_LIFETIME_MS: u64 = 10 * 60 * 1000;
const BODY_LIMIT: usize = 64 * 1024;

pub struct CoordConfig {
    /// SQLite database file.
    pub database: PathBuf,
    /// Bearer token for admin routes (at least 24 characters).
    pub admin_token: String,
    /// Signs relay tickets; relays hold its public half.
    pub ticket_key: SigningKey,
    /// The relay map handed to every device.
    pub relays: Vec<RelayInfo>,
}

#[derive(Debug)]
pub enum CoordError {
    BadRequest(String),
    Unauthorized(String),
    Forbidden(String),
    NotFound,
    Conflict(String),
    Internal(String),
}

impl std::fmt::Display for CoordError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadRequest(text)
            | Self::Unauthorized(text)
            | Self::Forbidden(text)
            | Self::Conflict(text) => formatter.write_str(text),
            Self::NotFound => formatter.write_str("not found"),
            Self::Internal(_) => formatter.write_str("internal error"),
        }
    }
}

impl IntoResponse for CoordError {
    fn into_response(self) -> Response {
        let status = match &self {
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            Self::Forbidden(_) => StatusCode::FORBIDDEN,
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::Conflict(_) => StatusCode::CONFLICT,
            Self::Internal(detail) => {
                eprintln!("weft-coord: internal error: {detail}");
                StatusCode::INTERNAL_SERVER_ERROR
            }
        };
        (status, Json(ErrorBody { error: self.to_string() })).into_response()
    }
}

struct Inner {
    store: Mutex<Store>,
    verifier: Mutex<Verifier>,
    version: watch::Sender<u64>,
    admin_hash: [u8; 32],
    ticket_key: SigningKey,
    relays: Vec<RelayInfo>,
}

type Shared = Arc<Inner>;

impl Inner {
    fn store(&self) -> Result<std::sync::MutexGuard<'_, Store>, CoordError> {
        self.store.lock().map_err(|_| CoordError::Internal("store lock poisoned".into()))
    }

    fn publish(&self, version: u64) {
        self.version.send_replace(version);
    }

    fn admin(&self, headers: &HeaderMap) -> Result<(), CoordError> {
        let token = headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .ok_or_else(|| CoordError::Unauthorized("admin token required".into()))?;
        let hash: [u8; 32] = Sha256::digest(token.as_bytes()).into();
        if bool::from(hash.ct_eq(&self.admin_hash)) {
            Ok(())
        } else {
            Err(CoordError::Unauthorized("bad admin token".into()))
        }
    }

    /// Verify a device request's signature with `machine_key`.
    fn check_signature(
        &self,
        machine_key: &[u8; 32],
        signed: &SignedHeaders,
        method: &Method,
        uri: &Uri,
        body: &[u8],
    ) -> Result<(), CoordError> {
        let path = uri.path_and_query().map(|value| value.as_str()).unwrap_or("/");
        let mut verifier = self
            .verifier
            .lock()
            .map_err(|_| CoordError::Internal("verifier lock poisoned".into()))?;
        verifier
            .verify(machine_key, signed, method.as_str(), path, body, crate::now_ms())
            .map_err(|error| CoordError::Unauthorized(error.to_string()))
    }

    /// Authenticate a device: its signature by the machine key on record.
    fn device(
        &self,
        headers: &HeaderMap,
        method: &Method,
        uri: &Uri,
        body: &[u8],
    ) -> Result<store::NodeRow, CoordError> {
        let signed = signed_headers(headers)?;
        let node = self
            .store()?
            .node(&signed.node)?
            .ok_or_else(|| CoordError::Unauthorized("unknown node".into()))?;
        self.check_signature(&node.machine_key, &signed, method, uri, body)?;
        Ok(node)
    }
}

fn signed_headers(headers: &HeaderMap) -> Result<SignedHeaders, CoordError> {
    let get = |name: &str| {
        headers
            .get(name)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned)
            .ok_or_else(|| CoordError::Unauthorized(format!("missing {name}")))
    };
    Ok(SignedHeaders {
        node: get(HEADER_NODE)?,
        ts: get(HEADER_TS)?,
        nonce: get(HEADER_NONCE)?,
        sig: get(HEADER_SIG)?,
    })
}

fn valid_tailnet(name: &str) -> bool {
    (1..=40).contains(&name.len())
        && name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn valid_node_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name.bytes().all(|byte| byte.is_ascii_graphic() || byte == b' ')
}

fn json_body<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, CoordError> {
    serde_json::from_slice(body).map_err(|error| CoordError::BadRequest(format!("body: {error}")))
}

/// Build the router; exposed for tests that want their own listener setup.
pub fn router(config: CoordConfig) -> Result<Router, CoordError> {
    if config.admin_token.len() < 24 {
        return Err(CoordError::BadRequest("admin token must be at least 24 characters".into()));
    }
    let store = Store::open(&config.database)?;
    let version = store.version()?;
    let (version_tx, _) = watch::channel(version);
    let inner = Arc::new(Inner {
        store: Mutex::new(store),
        verifier: Mutex::new(Verifier::new()),
        version: version_tx,
        admin_hash: Sha256::digest(config.admin_token.as_bytes()).into(),
        ticket_key: config.ticket_key,
        relays: config.relays,
    });
    Ok(Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/v1/tailnets", post(create_tailnet))
        .route("/v1/tailnets/{tailnet}/policy", put(set_policy).get(get_policy))
        .route("/v1/tailnets/{tailnet}/authkeys", post(mint_auth_key))
        .route("/v1/tailnets/{tailnet}/nodes", get(list_nodes))
        .route("/v1/tailnets/{tailnet}/nodes/{node}/approve", post(approve_node))
        .route("/v1/tailnets/{tailnet}/nodes/{node}", delete(revoke_node))
        .route("/v1/tailnets/{tailnet}/audit", get(audit_log))
        .route("/v1/register", post(register))
        .route("/v1/netmap", get(netmap))
        .route("/v1/endpoints", post(endpoints))
        .route("/v1/rotate", post(rotate))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
        .with_state(inner))
}

/// Serve the coordinator on `listener` until the task is dropped.
pub async fn serve_coord(listener: TcpListener, config: CoordConfig) -> anyhow::Result<()> {
    let app = router(config).map_err(|error| anyhow::anyhow!("{error}"))?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn create_tailnet(
    State(state): State<Shared>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, CoordError> {
    state.admin(&headers)?;
    let request: CreateTailnetRequest = json_body(&body)?;
    if !valid_tailnet(&request.name) {
        return Err(CoordError::BadRequest("tailnet name: 1-40 of a-z 0-9 -".into()));
    }
    let now = crate::now_ms();
    let store = state.store()?;
    store.create_tailnet(&request.name, request.require_approval, now)?;
    store.audit(
        &request.name,
        "admin",
        "tailnet.create",
        &serde_json::json!({"require_approval": request.require_approval}),
        now,
    )?;
    Ok((StatusCode::CREATED, Json(serde_json::json!({"id": request.name}))))
}

async fn set_policy(
    State(state): State<Shared>,
    Path(tailnet): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<PolicyResponse>, CoordError> {
    state.admin(&headers)?;
    let text = std::str::from_utf8(&body)
        .map_err(|_| CoordError::BadRequest("policy must be UTF-8".into()))?;
    Policy::parse(text).map_err(|error| CoordError::BadRequest(format!("policy: {error}")))?;
    let if_version = match headers.get("if-version") {
        Some(value) => Some(
            value
                .to_str()
                .ok()
                .and_then(|text| text.parse::<u64>().ok())
                .ok_or_else(|| CoordError::BadRequest("bad if-version".into()))?,
        ),
        None => None,
    };
    let now = crate::now_ms();
    let store = state.store()?;
    let before = store.tailnet(&tailnet)?;
    let version = store.set_policy(&tailnet, text, if_version)?;
    store.audit(
        &tailnet,
        "admin",
        "policy.set",
        &serde_json::json!({"version": version, "before": before.policy_text, "after": text}),
        now,
    )?;
    let global = store.bump()?;
    drop(store);
    state.publish(global);
    Ok(Json(PolicyResponse { version, policy: text.to_owned() }))
}

async fn get_policy(
    State(state): State<Shared>,
    Path(tailnet): Path<String>,
    headers: HeaderMap,
) -> Result<Json<PolicyResponse>, CoordError> {
    state.admin(&headers)?;
    let row = state.store()?.tailnet(&tailnet)?;
    Ok(Json(PolicyResponse { version: row.policy_version, policy: row.policy_text }))
}

async fn mint_auth_key(
    State(state): State<Shared>,
    Path(tailnet): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, CoordError> {
    state.admin(&headers)?;
    let request: MintAuthKey = json_body(&body)?;
    let now = crate::now_ms();
    let store = state.store()?;
    let row = store.tailnet(&tailnet)?;
    if request.tags.is_empty() && request.user.is_none() {
        return Err(CoordError::BadRequest("a key needs tags or a user".into()));
    }
    for tag in &request.tags {
        if !row.policy.has_tag(tag) {
            return Err(CoordError::BadRequest(format!(
                "tag {tag} has no tagOwners entry in the policy"
            )));
        }
    }
    let ttl_ms = request.ttl_seconds.saturating_mul(1000);
    if ttl_ms == 0 || ttl_ms > store::MAX_AUTHKEY_TTL_MS {
        return Err(CoordError::BadRequest("ttl_seconds must be 1..=7776000".into()));
    }
    let secret = format!("weftkey-{}", crate::random_hex(24));
    let expires_ms = now + ttl_ms;
    store.mint_auth_key(
        &tailnet,
        &secret,
        &request.tags,
        request.user.as_deref(),
        request.reusable,
        request.preapproved,
        expires_ms,
        "admin",
    )?;
    store.audit(
        &tailnet,
        "admin",
        "authkey.mint",
        &serde_json::json!({
            "key_hash_prefix": &hash_secret(&secret)[..12],
            "tags": request.tags,
            "user": request.user,
            "reusable": request.reusable,
            "preapproved": request.preapproved,
            "expires_ms": expires_ms,
        }),
        now,
    )?;
    Ok((StatusCode::CREATED, Json(MintAuthKeyResponse { key: secret, expires_ms })))
}

async fn list_nodes(
    State(state): State<Shared>,
    Path(tailnet): Path<String>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, CoordError> {
    state.admin(&headers)?;
    let store = state.store()?;
    store.tailnet(&tailnet)?;
    let nodes: Vec<_> = store.nodes(&tailnet)?.iter().map(store::NodeRow::summary).collect();
    Ok(Json(nodes))
}

async fn approve_node(
    State(state): State<Shared>,
    Path((tailnet, node)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, CoordError> {
    state.admin(&headers)?;
    let now = crate::now_ms();
    let store = state.store()?;
    store.set_state(&tailnet, &node, NodeState::Approved)?;
    store.audit(&tailnet, "admin", "node.approve", &serde_json::json!({"node": node}), now)?;
    let global = store.bump()?;
    drop(store);
    state.publish(global);
    Ok(StatusCode::NO_CONTENT)
}

async fn revoke_node(
    State(state): State<Shared>,
    Path((tailnet, node)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, CoordError> {
    state.admin(&headers)?;
    let now = crate::now_ms();
    let store = state.store()?;
    let row =
        store.node(&node)?.filter(|row| row.tailnet == tailnet).ok_or(CoordError::NotFound)?;
    store.delete_node(&tailnet, &node)?;
    store.audit(
        &tailnet,
        "admin",
        "node.revoke",
        &serde_json::json!({"node": node, "name": row.name, "node_key": row.node_key}),
        now,
    )?;
    let global = store.bump()?;
    drop(store);
    state.publish(global);
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct AuditQuery {
    limit: Option<u32>,
}

async fn audit_log(
    State(state): State<Shared>,
    Path(tailnet): Path<String>,
    Query(query): Query<AuditQuery>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, CoordError> {
    state.admin(&headers)?;
    let limit = query.limit.unwrap_or(200).min(1000);
    Ok(Json(state.store()?.audit_log(&tailnet, limit)?))
}

async fn register(
    State(state): State<Shared>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, CoordError> {
    let request: RegisterRequest = json_body(&body)?;
    let machine_key = crate::b64::decode_key(&request.machine_key)
        .ok_or_else(|| CoordError::BadRequest("machine_key: 32 bytes, base64".into()))?;
    crate::b64::decode_key(&request.node_key)
        .ok_or_else(|| CoordError::BadRequest("node_key: 32 bytes, base64".into()))?;
    if !valid_node_name(&request.name) {
        return Err(CoordError::BadRequest("name: 1-64 printable characters".into()));
    }
    // Proof of possession: the request is signed by the machine key it
    // registers, so a captured auth key alone cannot enroll someone else's key.
    let signed = signed_headers(&headers)?;
    if signed.node != "register" {
        return Err(CoordError::Unauthorized("register requests sign as `register`".into()));
    }
    state.check_signature(&machine_key, &signed, &method, &uri, &body)?;

    let now = crate::now_ms();
    let store = state.store()?;
    let tailnet = store.tailnet(&request.tailnet).map_err(|error| match error {
        CoordError::NotFound => CoordError::Unauthorized("invalid auth key".into()),
        other => other,
    })?;
    let grant = store.use_auth_key(&request.tailnet, &request.auth_key, now)?;
    let state_after = if grant.preapproved || !tailnet.require_approval {
        NodeState::Approved
    } else {
        NodeState::Pending
    };
    let node = store.insert_node(
        &request.tailnet,
        &request.name,
        &machine_key,
        &request.node_key,
        &grant,
        state_after,
        now,
    )?;
    store.audit(
        &request.tailnet,
        &format!("node:{}", node.id),
        "node.register",
        &serde_json::json!({
            "node": node.id, "name": node.name, "tags": node.tags, "user": node.user,
            "state": node.state.as_str(), "node_key": node.node_key,
        }),
        now,
    )?;
    let global = store.bump()?;
    drop(store);
    state.publish(global);
    Ok((
        StatusCode::CREATED,
        Json(RegisterResponse { node_id: node.id, address: node.address, state: node.state }),
    ))
}

#[derive(Deserialize)]
struct NetmapQuery {
    since: Option<u64>,
}

async fn netmap(
    State(state): State<Shared>,
    Query(query): Query<NetmapQuery>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
) -> Result<Json<Netmap>, CoordError> {
    let node = state.device(&headers, &method, &uri, b"")?;
    if let Some(since) = query.since {
        let mut versions = state.version.subscribe();
        // Wait for a newer version or the long-poll limit, whichever first.
        let _ =
            tokio::time::timeout(LONG_POLL, versions.wait_for(|version| *version > since)).await;
    }
    build_netmap(&state, &node.id).map(Json)
}

fn build_netmap(state: &Inner, node_id: &str) -> Result<Netmap, CoordError> {
    let now = crate::now_ms();
    let store = state.store()?;
    // Re-read: the node may have been revoked during the long-poll.
    let node =
        store.node(node_id)?.ok_or_else(|| CoordError::Unauthorized("unknown node".into()))?;
    store.touch(&node.id, None, now)?;
    let version = store.version()?;
    let tailnet = store.tailnet(&node.tailnet)?;
    let self_view = SelfView {
        id: node.id.clone(),
        name: node.name.clone(),
        address: node.address,
        node_key: node.node_key.clone(),
        tags: node.tags.clone(),
        state: node.state,
        key_expires_ms: node.key_expires_ms,
    };
    if node.state != NodeState::Approved || node.key_expires_ms <= now {
        return Ok(Netmap {
            version,
            node: self_view,
            peers: Vec::new(),
            inbound: Vec::new(),
            relays: state.relays.clone(),
            relay_ticket: None,
        });
    }
    let others: Vec<_> = store
        .nodes(&node.tailnet)?
        .into_iter()
        .filter(|other| {
            other.id != node.id && other.state == NodeState::Approved && other.key_expires_ms > now
        })
        .collect();
    let identities: Vec<_> = others.iter().map(store::NodeRow::identity).collect();
    let me = node.identity();
    let peer_ids = tailnet.policy.peers_of(&me, &identities);
    let inbound_map = tailnet.policy.inbound_for(&me, &identities);
    let peers = others
        .iter()
        .filter(|other| peer_ids.contains(&other.id))
        .map(|other| PeerView {
            id: other.id.clone(),
            name: other.name.clone(),
            node_key: other.node_key.clone(),
            address: other.address,
            home_relay: other.home_relay.clone(),
            tags: other.tags.clone(),
            user: other.user.clone(),
        })
        .collect();
    let inbound = others
        .iter()
        .filter_map(|other| {
            inbound_map.get(&other.id).map(|ports| InboundAllow {
                node_key: other.node_key.clone(),
                ports: ports.clone(),
            })
        })
        .collect();
    let ticket = crate::b64::decode_key(&node.node_key).map(|key| {
        crate::ticket::issue(&state.ticket_key, &node.tailnet, &key, now + TICKET_LIFETIME_MS)
    });
    Ok(Netmap {
        version,
        node: self_view,
        peers,
        inbound,
        relays: state.relays.clone(),
        relay_ticket: ticket,
    })
}

async fn endpoints(
    State(state): State<Shared>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, CoordError> {
    let node = state.device(&headers, &method, &uri, &body)?;
    let request: EndpointsRequest = json_body(&body)?;
    if let Some(relay) = &request.home_relay
        && !state.relays.iter().any(|known| &known.url == relay)
    {
        return Err(CoordError::BadRequest("home_relay is not in the relay map".into()));
    }
    let store = state.store()?;
    if store.touch(&node.id, Some(request.home_relay.as_deref()), crate::now_ms())? {
        let global = store.bump()?;
        drop(store);
        state.publish(global);
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn rotate(
    State(state): State<Shared>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, CoordError> {
    let node = state.device(&headers, &method, &uri, &body)?;
    let request: RotateRequest = json_body(&body)?;
    crate::b64::decode_key(&request.node_key)
        .ok_or_else(|| CoordError::BadRequest("node_key: 32 bytes, base64".into()))?;
    let now = crate::now_ms();
    let store = state.store()?;
    store.rotate(&node.id, &request.node_key, now)?;
    store.audit(
        &node.tailnet,
        &format!("node:{}", node.id),
        "node.rotate",
        &serde_json::json!({"node": node.id, "old": node.node_key, "new": request.node_key}),
        now,
    )?;
    let global = store.bump()?;
    drop(store);
    state.publish(global);
    Ok(StatusCode::NO_CONTENT)
}
