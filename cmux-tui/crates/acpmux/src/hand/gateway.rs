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
use std::path::{Path, PathBuf};

/// Longest run token accepted.
const MAX_TOKEN: usize = 4096;

#[derive(Debug, Clone)]
pub struct ModelRoute {
    pub token: String,
    /// Unix seconds (milliseconds are taken too); a token past it is refused
    /// before anything is written.
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

fn dir() -> PathBuf {
    super::config::home().join("gateway")
}

fn token_path(id: &str) -> PathBuf {
    dir().join(format!("{id}.token"))
}

/// When the run's token expires (unix seconds), kept beside it for the sweep.
fn expiry_path(id: &str) -> PathBuf {
    dir().join(format!("{id}.expires"))
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Removes every one-run route whose token expired (a minute of slack), its
/// token and its chat bindings, over a new daemon connection. Runs when the
/// hand starts and before each new route, so nothing outlives its token.
pub async fn sweep() {
    // The folder scan reads disk: off the runtime's workers.
    let stale = cmux_blocking::spawn_blocking(|| expired_routes(&dir(), now_secs()))
        .await
        .unwrap_or_default();
    if stale.is_empty() {
        return;
    }
    let Ok(client) = crate::daemon::connect(false).await else {
        // No daemon: no session can use them; the files go, the route files stay until next time.
        for id in &stale {
            let _ = tokio::fs::remove_file(token_path(id)).await;
        }
        return;
    };
    for id in stale {
        remove(&client, &id).await;
    }
}

/// The one-run routes in `dir` whose token expired more than a minute before `now`.
fn expired_routes(dir: &Path, now: u64) -> Vec<String> {
    let Ok(rd) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut stale = Vec::new();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let Some(id) = name.strip_suffix(".expires") else { continue };
        let at = std::fs::read_to_string(e.path())
            .ok()
            .and_then(|t| t.trim().parse::<u64>().ok())
            .unwrap_or(0);
        if at.saturating_add(60) < now && id.starts_with(crate::routes::ONE_RUN_PREFIX) {
            stale.push(id.to_owned());
        }
    }
    stale
}

/// A new token for a run's route (a long chat outlives one token): the route
/// reads the file at each spawn, so the next harness start uses it.
pub fn renew(id: &str, route: &ModelRoute) -> Result<(), HandError> {
    let path = token_path(id);
    if !path.exists() {
        // Swept after its token expired: the chat stays bound to the gone route, so it
        // never falls back to another route; a new session gets a new one.
        return Err(HandError::new(
            "agent.route_expired",
            format!("{id} expired; start a new agent session"),
        ));
    }
    // Written beside it and renamed over it: a spawn reading it sees the old or the
    // new token, never a half-written file.
    let tmp = dir().join(format!(".{id}.token.tmp"));
    super::config::write_private(&tmp, route.token.as_bytes())
        .and_then(|()| std::fs::rename(&tmp, &path).map_err(Into::into))
        .and_then(|()| {
            super::config::write_private(&expiry_path(id), route.expires_at.to_string().as_bytes())
        })
        .map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            HandError::new("agent.bad_route", format!("{e:#}"))
        })
}

/// Writes the token file and the run's route; returns the route id.
pub async fn prepare(client: &Client, api: &str, route: &ModelRoute) -> Result<String, HandError> {
    sweep().await;
    let api = super::pair::check_api(api)
        .map_err(|e| HandError::new("agent.bad_route", e.to_string()))?;
    let simple = uuid::Uuid::now_v7().simple().to_string();
    // The last 12 hex digits: the v7 uuid's random tail.
    let id = format!("cmux-gateway-{}", simple.get(20..).unwrap_or(&simple));
    let path = token_path(&id);
    // The folder and the owner-only files are disk writes: off the runtime's workers.
    let files = {
        let (id, path, route) = (id.clone(), path.clone(), route.clone());
        cmux_blocking::spawn_blocking(move || write_route_files(&id, &path, &route)).await
    };
    files.map_err(|e| {
        HandError::new("agent.bad_route", format!("writing the route files: {e}"))
    })??;
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
        remove_files(&id).await;
        return Err(HandError::new("agent.route_failed", format!("{e:#}")));
    }
    Ok(id)
}

/// The owner-only folder, the run's token at `path` and its expiry.
fn write_route_files(id: &str, path: &Path, route: &ModelRoute) -> Result<(), HandError> {
    let dir = path.parent().map(PathBuf::from).unwrap_or_default();
    std::fs::create_dir_all(&dir).map_err(|e| HandError::io(&dir, e))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    super::config::write_private(path, route.token.as_bytes())
        .and_then(|()| {
            super::config::write_private(&expiry_path(id), route.expires_at.to_string().as_bytes())
        })
        .map_err(|e| HandError::new("agent.bad_route", format!("{e:#}")))
}

/// The run's token and expiry files.
async fn remove_files(id: &str) {
    let _ = tokio::fs::remove_file(token_path(id)).await;
    let _ = tokio::fs::remove_file(expiry_path(id)).await;
}

/// Removes the run's route (and its chat bindings) and its token file.
pub async fn remove(client: &Client, id: &str) {
    remove_files(id).await;
    let _ = client.request(method::MUX_ROUTE_REMOVE, json!({ "id": id })).await;
}

/// [`remove`] over a new daemon connection (the session's own may be gone).
pub async fn remove_fresh(id: &str) {
    match crate::daemon::connect(false).await {
        Ok(client) => remove(&client, id).await,
        Err(_) => remove_files(id).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expired_routes_lists_only_one_run_routes_past_the_slack() {
        let dir = std::env::temp_dir()
            .join(format!("acpmux-gateway-sweep-{}", uuid::Uuid::now_v7().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        let now = 10_000;
        let write = |name: &str, at: u64| std::fs::write(dir.join(name), at.to_string()).unwrap();
        write("cmux-gateway-old.expires", now - 61);
        write("cmux-gateway-slack.expires", now - 60);
        write("cmux-gateway-live.expires", now + 600);
        write("other-route.expires", now - 600);
        write("cmux-gateway-old.token", 0);
        std::fs::write(dir.join("cmux-gateway-unreadable.expires"), "not a time").unwrap();

        let mut stale = expired_routes(&dir, now);
        stale.sort();
        assert_eq!(stale, ["cmux-gateway-old", "cmux-gateway-unreadable"]);
        assert!(expired_routes(&dir.join("missing"), now).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
