//! A route's health check (routes.rs): one cheap request to its endpoint,
//! and the backoff of the automatic ones.
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::routes::{Auth, Route, RouteKind, local_router_with, resolve_reference};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeStatus {
    Ok,
    AuthNeeded,
    Unreachable,
    RateLimited,
    Unknown,
}

impl ProbeStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::AuthNeeded => "auth_needed",
            Self::Unreachable => "unreachable",
            Self::RateLimited => "rate_limited",
            Self::Unknown => "unknown",
        }
    }
}

/// The status an HTTP answer means.
pub fn classify(status: u16) -> ProbeStatus {
    match status {
        200..=299 => ProbeStatus::Ok,
        401 | 403 => ProbeStatus::AuthNeeded,
        429 | 503 | 529 => ProbeStatus::RateLimited,
        _ => ProbeStatus::Unknown,
    }
}

/// One cheap request to the route: its health URL, else the provider's model
/// list. Never logs or returns a secret.
pub async fn probe(route: &Route, home: &Path) -> Value {
    let started = Instant::now();
    let answer = |status: ProbeStatus, message: String| {
        json!({
            "id": route.id,
            "status": status.as_str(),
            "message": message,
            "ms": started.elapsed().as_millis() as u64,
        })
    };
    if route.file.kind == RouteKind::DirectSubscription && route.file.health_url.is_none() {
        return answer(
            ProbeStatus::Unknown,
            "this route uses the harness CLI's own login; `cmux harness login --status` checks it"
                .into(),
        );
    }
    let family = if route.file.anthropic_base_url.is_some() { "claude" } else { "codex" };
    let mut base =
        route.file.anthropic_base_url.clone().or_else(|| route.file.openai_base_url.clone());
    let mut secret = match route.file.secret.as_deref().map(resolve_reference) {
        Some(Ok(v)) => Some(v),
        Some(Err(e)) => {
            return answer(ProbeStatus::AuthNeeded, format!("the secret did not resolve: {e}"));
        }
        None => None,
    };
    if route.uses_relay() {
        match local_router_with(home, family, route.file.kind == RouteKind::CmuxRouter) {
            Ok((url, key)) => {
                if route.file.kind == RouteKind::CmuxRouter {
                    base = Some(url);
                    secret = Some(key);
                } else {
                    base.get_or_insert(url);
                    secret.get_or_insert(key);
                }
            }
            Err(e) => return answer(ProbeStatus::Unreachable, e.to_string()),
        }
    }
    let url = match (&route.file.health_url, &base) {
        (Some(h), _) => h.clone(),
        (None, Some(b)) => {
            let b = b.trim_end_matches('/');
            if family == "claude" || !b.ends_with("/v1") {
                format!("{b}/v1/models")
            } else {
                format!("{b}/models")
            }
        }
        (None, None) => return answer(ProbeStatus::Unknown, "the route names no endpoint".into()),
    };
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = match reqwest::Client::builder().timeout(Duration::from_secs(8)).build() {
        Ok(c) => c,
        Err(e) => return answer(ProbeStatus::Unknown, e.to_string()),
    };
    let mut request = client.get(&url);
    if family == "claude" {
        request = request.header("anthropic-version", "2023-06-01");
    }
    if let Some(s) = &secret {
        request = match route.auth() {
            Auth::ApiKey if family == "claude" => request.header("x-api-key", s),
            Auth::ApiKey | Auth::Bearer => request.bearer_auth(s),
            _ => request,
        };
    }
    for (k, v) in &route.file.headers {
        if let Ok(v) = resolve_reference(v) {
            request = request.header(k, v);
        }
    }
    match request.send().await {
        Ok(response) => {
            let code = response.status().as_u16();
            let body = response.text().await.unwrap_or_default();
            let snippet: String = body.chars().take(300).collect();
            answer(classify(code), format!("HTTP {code}: {snippet}"))
        }
        Err(e) => answer(ProbeStatus::Unreachable, format!("{url}: {e}")),
    }
}

/// Automatic probes back off after a failure: at most one per route per
/// `BACKOFF` window (on-demand tests always run).
const BACKOFF: Duration = Duration::from_secs(30);
static LAST_AUTO_PROBE: Mutex<BTreeMap<String, Instant>> = Mutex::new(BTreeMap::new());

pub fn auto_probe_allowed(route: &str) -> bool {
    let mut last = LAST_AUTO_PROBE.lock().unwrap_or_else(|p| p.into_inner());
    let now = Instant::now();
    match last.get(route) {
        Some(t) if now.duration_since(*t) < BACKOFF => false,
        _ => {
            last.insert(route.to_owned(), now);
            true
        }
    }
}
