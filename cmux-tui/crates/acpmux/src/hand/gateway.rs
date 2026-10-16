//! A per-run model route to the Cloud's model gateway (agent.start
//! `model_route: {kind: "anthropic", token, expires_at}`).
//!
//! The Cloud sends only a short-lived run token. The hand decides the rest:
//! the gateway URL is its own API origin (`<api>/v1/model-gateway`, the
//! origin it paired with), never a URL from the request; the token goes to an
//! owner-only file; and an acpmux route of this run reads that file at each
//! spawn (`secret = "file:<path>"`), so the token is never in a route file,
//! the session's recorded env, an argument list or a log. The route is bound
//! to the new chat before its harness starts and removed with the session.

use super::HandError;
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::path::PathBuf;

/// Longest run token accepted.
const MAX_TOKEN: usize = 4096;

#[derive(Debug, Clone)]
pub struct ModelRoute {
    pub token: String,
    /// Unix seconds; a token past it is refused before anything is written.
    pub expires_at: u64,
}

pub fn parse(v: &Value) -> Result<ModelRoute, HandError> {
    let bad = |m: &str| HandError::new("agent.bad_route", m);
    if v.get("kind").and_then(Value::as_str) != Some("anthropic") {
        return Err(bad("model_route.kind must be \"anthropic\""));
    }
    let token = v
        .get("token")
        .and_then(Value::as_str)
        .ok_or_else(|| bad("model_route.token is required"))?;
    // A JWT (or any bearer) in URL-safe characters: nothing that could break a header or a file.
    if token.is_empty()
        || token.len() > MAX_TOKEN
        || !token.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    {
        return Err(bad("model_route.token is not a bearer token"));
    }
    let expires_at = v
        .get("expires_at")
        .and_then(Value::as_u64)
        .ok_or_else(|| bad("model_route.expires_at is required"))?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if expires_at <= now {
        return Err(bad("model_route.token has expired"));
    }
    Ok(ModelRoute { token: token.to_owned(), expires_at })
}

fn token_path(id: &str) -> PathBuf {
    super::config::home().join("gateway").join(format!("{id}.token"))
}

/// Writes the token file and the run's route; returns the route id.
pub async fn prepare(client: &Client, api: &str, route: &ModelRoute) -> Result<String, HandError> {
    let api = super::pair::check_api(api)
        .map_err(|e| HandError::new("agent.bad_route", e.to_string()))?;
    let id = format!("cmux-gateway-{}", &uuid::Uuid::now_v7().simple().to_string()[20..]);
    let path = token_path(&id);
    let dir = path.parent().map(PathBuf::from).unwrap_or_default();
    std::fs::create_dir_all(&dir).map_err(|e| HandError::io(&dir, e))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    super::config::write_private(&path, route.token.as_bytes())
        .map_err(|e| HandError::new("agent.bad_route", format!("{e:#}")))?;
    let added = client
        .request(
            method::MUX_ROUTE_ADD,
            json!({
                "id": id,
                "name": "cmux model gateway (one run)",
                "kind": "custom-anthropic",
                "families": ["claude"],
                "anthropicBaseUrl": format!("{api}/v1/model-gateway"),
                "auth": "bearer",
                "secret": format!("file:{}", path.display()),
                "notes": format!("made by cmux-hand for one agent session; token expires at {}", route.expires_at),
            }),
        )
        .await;
    if let Err(e) = added {
        let _ = std::fs::remove_file(&path);
        return Err(HandError::new("agent.route_failed", format!("{e:#}")));
    }
    Ok(id)
}

/// Removes the run's route and its token file (best effort: the token expires anyway).
pub async fn remove(client: &Client, id: &str) {
    let _ = std::fs::remove_file(token_path(id));
    let _ = client.request(method::MUX_ROUTE_REMOVE, json!({ "id": id })).await;
}
