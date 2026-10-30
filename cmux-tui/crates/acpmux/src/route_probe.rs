//! A route's health check (routes.rs): one cheap request to its endpoint,
//! and the backoff of the automatic ones.
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::routes::{Auth, Route, RouteFile, RouteKind, local_router_with, resolve_reference};

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

/// Each route's last probe answer and when it came (ms since the epoch), whoever asked:
/// `_acpmux/route/test`, a failed turn's background probe, `_acpmux/session/auth {refresh}`.
/// Only answers at most [`KEPT_MS`] old stay, and at most [`KEPT_ROUTES`] of them: every read
/// and every probe drops the older ones ([`keep_recent`]). Each answer keeps the route file it
/// probed, so an edited route's answer is not read as the new one's.
static LAST: Mutex<BTreeMap<String, Kept>> = Mutex::new(BTreeMap::new());

/// A probe answer: when it came, the route file it probed, and the answer.
type Kept = (u64, RouteFile, Value);

/// How long a probe answer is kept for [`recent`].
pub const KEPT_MS: u64 = 5 * 60 * 1000;

/// The most routes whose answers are kept at once; past it the oldest answers go.
const KEPT_ROUTES: usize = 64;

/// The route's last probe answer, when it is at most `max_age_ms` (and [`KEPT_MS`]) old and
/// probed the route as it is now (its file unchanged since).
pub fn recent(route: &Route, max_age_ms: u64) -> Option<(u64, Value)> {
    let now = crate::store::now_ms();
    let mut last = LAST.lock().unwrap_or_else(|p| p.into_inner());
    keep_recent(&mut last, now);
    let (at, file, answer) = last.get(&route.id)?;
    (*file == route.file && now.saturating_sub(*at) <= max_age_ms).then(|| (*at, answer.clone()))
}

/// Keeps `answer` as the route's last, for [`recent`].
fn remember(route: &Route, answer: Value) {
    let now = crate::store::now_ms();
    let mut last = LAST.lock().unwrap_or_else(|p| p.into_inner());
    last.insert(route.id.clone(), (now, route.file.clone(), answer));
    keep_recent(&mut last, now);
}

/// Drops answers older than [`KEPT_MS`], then the oldest past [`KEPT_ROUTES`].
fn keep_recent(last: &mut BTreeMap<String, Kept>, now: u64) {
    last.retain(|_, (at, ..)| now.saturating_sub(*at) <= KEPT_MS);
    while last.len() > KEPT_ROUTES {
        let Some(oldest) = last.iter().min_by_key(|(_, (at, ..))| *at).map(|(k, _)| k.clone())
        else {
            break;
        };
        last.remove(&oldest);
    }
}

/// The family [`probe`] tests the route as: Claude when the route has an Anthropic base URL,
/// else Codex. It picks that family's base URL, and on a relay route that family's router key.
fn probed_family(route: &Route) -> &'static str {
    if route.file.anthropic_base_url.is_some() { "claude" } else { "codex" }
}

/// Whether [`probe`] tests what a `family` harness uses on `route`. A relay route
/// (`local-coderouter`, or `cmux-router` with no secret) mints a key for each harness family
/// (`local_router_with`), so its probe speaks only for the family it probed as
/// ([`probed_family`]). Any other route sends every family its own secret: its health URL speaks
/// for all of them, and its base URL for the families that use that endpoint (the Anthropic one
/// for Claude, the OpenAI one for the rest).
pub fn probes_for(route: &Route, family: &str) -> bool {
    use crate::routes::is_anthropic_family;
    if route.uses_relay() {
        return family == probed_family(route);
    }
    route.file.health_url.is_some()
        || is_anthropic_family(probed_family(route)) == is_anthropic_family(family)
}

/// Whether probing the route reads the login keychain: its secret or a header is a
/// `keychain:` reference. `_acpmux/session/auth` never probes such a route itself.
pub fn reads_keychain(route: &Route) -> bool {
    let keychain = |v: &str| v.starts_with("keychain:");
    route.file.secret.as_deref().is_some_and(keychain)
        || route.file.headers.values().any(|v| keychain(v))
}

/// One cheap request to the route: its health URL, else the provider's model
/// list. Never logs or returns a secret. The answer is kept for [`recent`].
pub async fn probe(route: &Route, home: &Path) -> Value {
    let answer = probe_once(route, home).await;
    remember(route, answer.clone());
    answer
}

async fn probe_once(route: &Route, home: &Path) -> Value {
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
    let family = probed_family(route);
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

#[cfg(test)]
mod tests {
    use crate::routes::{Route, file_from_json};

    fn route(file: serde_json::Value) -> Route {
        Route { id: "r".into(), file: file_from_json(&file).unwrap(), path: Default::default() }
    }

    /// A probe of a route's Anthropic endpoint says nothing of its OpenAI one, and back.
    #[test]
    fn a_probe_speaks_for_the_family_whose_endpoint_it_tests() {
        let both = route(json!({"kind": "custom-anthropic", "anthropicBaseUrl": "http://a",
                                "openaiBaseUrl": "http://o"}));
        assert!(probes_for(&both, "claude") && !probes_for(&both, "codex"));
        let openai = route(json!({"kind": "custom-openai", "openaiBaseUrl": "http://o"}));
        assert!(probes_for(&openai, "codex") && !probes_for(&openai, "claude"));
        // Every family that uses the OpenAI endpoint sends the route's own secret to it.
        assert!(probes_for(&openai, "opencode") && probes_for(&openai, "pi"));
        let health = route(json!({"kind": "custom-anthropic", "anthropicBaseUrl": "http://a",
                                  "openaiBaseUrl": "http://o", "healthUrl": "http://h"}));
        assert!(probes_for(&health, "claude") && probes_for(&health, "codex"));
        // A relay route mints a key per family: a probe with Codex's says nothing of Claude's,
        // OpenCode's or Pi's, health URL or not.
        let relay = route(json!({"kind": "local-coderouter"}));
        assert!(probes_for(&relay, "codex") && !probes_for(&relay, "claude"));
        assert!(!probes_for(&relay, "opencode") && !probes_for(&relay, "pi"));
        let relay = route(json!({"kind": "cmux-router", "healthUrl": "http://h"}));
        assert!(probes_for(&relay, "codex") && !probes_for(&relay, "claude"));
        let relay = route(json!({"kind": "local-coderouter", "anthropicBaseUrl": "http://a"}));
        assert!(probes_for(&relay, "claude") && !probes_for(&relay, "codex"));
    }

    use super::*;

    /// The kept answers stay young and few, however many routes were probed.
    #[test]
    fn kept_answers_are_recent_and_bounded() {
        let file = route(json!({"kind": "custom-openai", "openaiBaseUrl": "http://o"})).file;
        let mut last = BTreeMap::new();
        last.insert("stale".to_owned(), (0, file.clone(), json!({})));
        for i in 0..100u64 {
            last.insert(format!("r{i}"), (KEPT_MS + i, file.clone(), json!({})));
        }
        keep_recent(&mut last, KEPT_MS + 100);
        assert_eq!(last.len(), KEPT_ROUTES);
        assert!(!last.contains_key("stale") && !last.contains_key("r0"), "{last:?}");
        assert!(last.contains_key("r99"), "{last:?}");
    }

    /// An answer is for the route as it was probed: once its file changes (another endpoint),
    /// the answer is not read as the edited route's.
    #[test]
    fn a_kept_answer_is_for_the_route_as_probed() {
        let mut probed = route(json!({"kind": "custom-anthropic", "anthropicBaseUrl": "http://a",
                                      "openaiBaseUrl": "http://o"}));
        probed.id = "kept-answer-edited-route".into();
        remember(&probed, json!({"status": "auth_needed"}));
        assert_eq!(
            recent(&probed, KEPT_MS).map(|(_, a)| a["status"].clone()),
            Some(json!("auth_needed"))
        );
        let mut edited = probed.clone();
        edited.file.anthropic_base_url = None;
        assert!(recent(&edited, KEPT_MS).is_none());
    }
}
