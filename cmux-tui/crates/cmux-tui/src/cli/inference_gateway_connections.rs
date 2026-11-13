//! The person's ordered model connections, read from the local acpmux daemon, for the personal
//! gateway (docs/model-connections.md, "Gateway" and "The picker's model and account in Cloud").
//!
//! This module is the one seam to acpmux: the JSON shapes of `_acpmux/connections`,
//! `_acpmux/connections/chatgpt.token` and `_acpmux/route/show`, the [`Daemon`] the gateway asks,
//! and the pure rules the gateway applies to what it answers:
//!
//! - [`candidates`]: which connections may answer a call, in the order to try them. The
//!   `x-cmux-connection` route id goes first; then, only when `spread` is on, the rest of the
//!   enabled ones in the person's order. A connection whose families do not serve the call's model
//!   family is skipped, never given the call with another model.
//! - [`usage_limited`]: a 429 that says the subscription or key is out of quota (not a short rate
//!   limit), which moves the call to the next candidate when there is one.
//! - [`sanitize_plan_body`]: a Responses body made fit for the Sign in with ChatGPT plan route.
//! - [`resolve_secret`]: an api-key connection's `keychain:`/`env:`/`file:` reference, resolved by
//!   acpmux's own resolver (the one a `direct-api-key` route's spawn uses), never stored here.
//!
//! When the daemon is not running, or is a build without `_acpmux/connections`, [`Daemon::state`]
//! answers `None` and the gateway keeps today's `--mac-logins` behavior.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::Mutex;

/// The route id a machine's request names (lane E): the picker's account for that chat.
pub(super) const CONNECTION_HEADER: &str = "x-cmux-connection";
/// One daemon question: a stuck daemon must not hold a model call.
const DAEMON_BUDGET: Duration = Duration::from_secs(5);
/// JSON-RPC "method not found": a daemon from before `_acpmux/connections`.
const METHOD_NOT_FOUND: i64 = -32601;

/// `_acpmux/connections`.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub(super) struct ConnectionsState {
    #[serde(default)]
    pub connections: Vec<Connection>,
    #[serde(default = "yes")]
    pub spread: bool,
    #[serde(default)]
    pub order_explicit: bool,
}

/// One connection of `_acpmux/connections`; `id` is its acpmux route id.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub(super) struct Connection {
    pub id: String,
    /// `codex-login`, `claude-login`, `subscription`, `chatgpt-plan` or `api-key`.
    pub kind: String,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub families: Vec<String>,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default = "yes")]
    pub signed_in: bool,
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default)]
    pub default_for: Vec<String>,
    #[serde(default = "yes")]
    pub serves_cloud: bool,
}

fn yes() -> bool {
    true
}

/// The part of `_acpmux/route/show`'s RouteView the gateway needs for an `api-key` or added
/// `subscription` connection. `secret` is the reference, never the value.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(super) struct RouteView {
    #[serde(default)]
    pub anthropic_base_url: Option<String>,
    #[serde(default)]
    pub openai_base_url: Option<String>,
    /// `subscription`, `api-key`, `bearer` or `none`.
    #[serde(default)]
    pub auth: Option<String>,
    #[serde(default)]
    pub secret: Option<String>,
    #[serde(default)]
    pub account_home: Option<String>,
}

/// What the gateway asks the person's acpmux daemon.
#[async_trait::async_trait]
pub(super) trait Daemon: Send + Sync {
    /// The connections in order, or `None` when there is no daemon or it has no
    /// `_acpmux/connections` (the gateway then serves from `--mac-logins` as before).
    async fn state(&self) -> Option<ConnectionsState>;
    /// A `chatgpt-plan` connection's current access token (`_acpmux/connections/chatgpt.token`).
    async fn chatgpt_token(&self, id: &str) -> Result<String, String>;
    /// A route's base URLs, auth, secret reference and account folder (`_acpmux/route/show`).
    async fn route(&self, id: &str) -> Result<RouteView, String>;
}

/// The model family a call's path asks for: Messages is Claude, Responses (and its model list) is
/// Codex. `None` for a path no connection serves.
pub(super) fn family_for_path(path: &str) -> Option<&'static str> {
    let route = path.split_once('?').map_or(path, |(route, _)| route);
    match route {
        "/v1/messages" | "/v1/messages/count_tokens" => Some("claude"),
        "/v1/responses" | "/v1/responses/compact" | "/v1/models" => Some("codex"),
        _ => None,
    }
}

/// The families a connection serves: its own list, else what its provider's API shape fits.
fn families(connection: &Connection) -> Vec<&str> {
    if !connection.families.is_empty() {
        return connection.families.iter().map(String::as_str).collect();
    }
    match (connection.kind.as_str(), connection.provider.as_deref()) {
        ("claude-login", _) | (_, Some("anthropic")) => vec!["claude"],
        ("codex-login" | "chatgpt-plan", _) | (_, Some("openai")) => vec!["codex"],
        _ => Vec::new(),
    }
}

/// Whether `connection` serves a call of model `family` (`openai` counts as `codex`).
pub(super) fn serves(connection: &Connection, family: &str) -> bool {
    families(connection).iter().any(|f| *f == family || (family == "codex" && *f == "openai"))
}

/// The connections to try for a call of `family`, in order. `pinned` (the `x-cmux-connection`
/// route id) goes first when it is signed in and serves the family: the person chose it, so it is
/// used even when routing may not move a chat onto it by itself (`enabled` false). The rest are the
/// enabled ones in the person's order, all of them when `spread` is on, else only the first, and
/// none after a pinned one when `spread` is off. An unknown pinned id counts as no pin.
pub(super) fn candidates<'a>(
    state: &'a ConnectionsState,
    family: &str,
    pinned: Option<&str>,
) -> Vec<&'a Connection> {
    let usable = |c: &&Connection| c.signed_in && c.serves_cloud && serves(c, family);
    let pin = pinned.and_then(|id| state.connections.iter().find(|c| c.id == id));
    let mut out: Vec<&Connection> = Vec::new();
    if let Some(pin) = pin {
        if usable(&pin) {
            out.push(pin);
        }
        if !state.spread {
            return out;
        }
    }
    for connection in state.connections.iter().filter(|c| c.enabled).filter(usable) {
        if out.iter().any(|c| c.id == connection.id) {
            continue;
        }
        out.push(connection);
        if !state.spread {
            break;
        }
    }
    out
}

/// Whether a 429 says the connection is out of quota (a subscription's usage limit, a key's
/// exhausted credit), not a short rate limit the same connection answers again in a moment.
pub(super) fn usage_limited(headers: &reqwest::header::HeaderMap, body: &[u8]) -> bool {
    let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok()).unwrap_or_default();
    if header("anthropic-ratelimit-unified-status").eq_ignore_ascii_case("rejected") {
        return true;
    }
    let used = |name: &str| header(name).parse::<f64>().is_ok_and(|p| p >= 100.0);
    if used("x-codex-primary-used-percent") || used("x-codex-secondary-used-percent") {
        return true;
    }
    let text = String::from_utf8_lossy(body).to_ascii_lowercase();
    ["usage_limit", "usage limit", "insufficient_quota", "quota_exceeded", "credit balance"]
        .iter()
        .any(|needle| text.contains(needle))
}

/// Fields the ChatGPT plan route does not take (docs/model-connections.md, "Gateway").
const PLAN_DROPPED: &[&str] = &[
    "previous_response_id",
    "background",
    "conversation",
    "max_output_tokens",
    "max_tool_calls",
    "metadata",
    "moderation",
    "prompt",
    "prompt_cache_retention",
    "safety_identifier",
    "temperature",
    "top_logprobs",
    "top_p",
    "truncation",
    "user",
];

/// A Responses body for the ChatGPT plan route: `store:false`, `stream:true`, the fields it does not
/// take dropped, system-role input items as developer ones. A `tool_search` tool is refused (the
/// route has none). The model is never changed.
pub(super) fn sanitize_plan_body(body: &[u8]) -> Result<Vec<u8>, String> {
    let mut doc: Value =
        serde_json::from_slice(body).map_err(|_| "the request body is not JSON".to_owned())?;
    let object = doc.as_object_mut().ok_or("the request body is not a JSON object")?;
    if object
        .get("tools")
        .and_then(Value::as_array)
        .is_some_and(|tools| tools.iter().any(|t| t.get("type") == Some(&json!("tool_search"))))
    {
        return Err("the ChatGPT plan does not serve tool_search tools".into());
    }
    for field in PLAN_DROPPED {
        object.remove(*field);
    }
    object.insert("store".into(), Value::Bool(false));
    object.insert("stream".into(), Value::Bool(true));
    if let Some(items) = object.get_mut("input").and_then(Value::as_array_mut) {
        for item in items {
            if item.get("role") == Some(&json!("system")) {
                item["role"] = json!("developer");
            }
        }
    }
    serde_json::to_vec(&doc).map_err(|e| e.to_string())
}

/// The model a call's body names, for the error that says nothing serves it.
pub(super) fn requested_model(body: &[u8]) -> Option<String> {
    let doc: Value = serde_json::from_slice(body).ok()?;
    doc.get("model").and_then(Value::as_str).map(str::to_owned)
}

/// The system secret store's lookup (service, account), as acpmux's resolver takes it.
pub(super) type KeychainLookup = dyn Fn(&str, Option<&str>) -> Result<String, String>;

/// An api-key connection's key from its reference (`keychain:ITEM`, `env:VAR` or `file:PATH`), with
/// acpmux's resolver: the one a `direct-api-key` route's `${…}` env goes through at spawn. An
/// inline value is refused: a connection holds a reference, never the key.
pub(super) fn resolve_secret(
    reference: &str,
    lookup_env: &dyn Fn(&str) -> Option<String>,
    lookup_keychain: &KeychainLookup,
) -> Result<String, String> {
    if !["keychain:", "env:", "file:"].iter().any(|p| reference.starts_with(p)) {
        return Err("the connection's key is not a keychain, env or file reference".into());
    }
    let mut env = BTreeMap::from([("SECRET".to_owned(), format!("${{{reference}}}"))]);
    acpmux::config::profiles::resolve_env_refs(&mut env, lookup_env, lookup_keychain)?;
    let value = env.remove("SECRET").unwrap_or_default();
    if value.trim().is_empty() || value.contains(char::is_whitespace) {
        return Err("the connection's key is empty".into());
    }
    Ok(value)
}

/// The default API base of an api-key provider, for one model family (a route's own base URL wins).
pub(super) fn provider_base(provider: Option<&str>, family: &str) -> Option<&'static str> {
    Some(match (provider?, family) {
        ("anthropic", "claude") => "https://api.anthropic.com",
        ("openai", "codex") => "https://api.openai.com/v1",
        ("openrouter", "claude") => "https://openrouter.ai/api",
        ("openrouter", "codex") => "https://openrouter.ai/api/v1",
        ("xai", "claude") => "https://api.x.ai",
        ("xai", "codex") => "https://api.x.ai/v1",
        _ => return None,
    })
}

/// The person's acpmux daemon on its unix socket. One client, made again after it breaks; never
/// starts a daemon.
pub(super) struct AcpmuxDaemon {
    socket: Option<PathBuf>,
    client: Mutex<Option<Arc<acpmux::client::Client>>>,
}

enum Asked {
    Answer(Value),
    /// No daemon, or a daemon without the method.
    Absent,
    Refused(String),
}

impl AcpmuxDaemon {
    /// The daemon `cmux acp` on this Mac uses (`ACPMUX_SOCKET`, else this build's acpmux home).
    pub(super) fn local() -> Self {
        Self { socket: crate::acp::daemon_socket_path(), client: Mutex::new(None) }
    }

    async fn ask(&self, method: &str, params: Value) -> Asked {
        let Some(socket) = &self.socket else { return Asked::Absent };
        let client = {
            let mut slot = self.client.lock().await;
            if let Some(client) = slot.clone() {
                client
            } else {
                let connect = acpmux::client::Client::connect_without_caller(socket);
                match tokio::time::timeout(DAEMON_BUDGET, connect).await {
                    Ok(Ok(client)) => {
                        *slot = Some(client.clone());
                        client
                    }
                    _ => return Asked::Absent,
                }
            }
        };
        match tokio::time::timeout(DAEMON_BUDGET, client.request(method, params)).await {
            Ok(Ok(answer)) => Asked::Answer(answer),
            Ok(Err(error)) => match error.downcast_ref::<acpmux::client::DaemonError>() {
                Some(refused) if refused.0.code == METHOD_NOT_FOUND => Asked::Absent,
                Some(refused) => Asked::Refused(refused.0.message.clone()),
                // The socket broke: dial again next time.
                None => {
                    *self.client.lock().await = None;
                    Asked::Absent
                }
            },
            Err(_) => {
                *self.client.lock().await = None;
                Asked::Absent
            }
        }
    }
}

#[async_trait::async_trait]
impl Daemon for AcpmuxDaemon {
    async fn state(&self) -> Option<ConnectionsState> {
        match self.ask("_acpmux/connections", json!({})).await {
            Asked::Answer(answer) => serde_json::from_value(answer).ok(),
            Asked::Absent | Asked::Refused(_) => None,
        }
    }

    async fn chatgpt_token(&self, id: &str) -> Result<String, String> {
        match self.ask("_acpmux/connections/chatgpt.token", json!({"id": id})).await {
            Asked::Answer(answer) => answer
                .get("access_token")
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty() && !t.contains(char::is_whitespace))
                .map(str::to_owned)
                .ok_or_else(|| "the ChatGPT sign-in gave no access token".to_owned()),
            Asked::Absent => Err("this Mac's acpmux is not running".into()),
            Asked::Refused(message) => Err(message),
        }
    }

    async fn route(&self, id: &str) -> Result<RouteView, String> {
        match self.ask("_acpmux/route/show", json!({"id": id})).await {
            Asked::Answer(answer) => serde_json::from_value(answer).map_err(|e| e.to_string()),
            Asked::Absent => Err("this Mac's acpmux is not running".into()),
            Asked::Refused(message) => Err(message),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn connection(id: &str, kind: &str, families: &[&str]) -> Connection {
        Connection {
            id: id.into(),
            kind: kind.into(),
            provider: None,
            families: families.iter().map(|f| (*f).to_owned()).collect(),
            label: None,
            signed_in: true,
            enabled: true,
            default_for: Vec::new(),
            serves_cloud: true,
        }
    }

    fn state(spread: bool, connections: Vec<Connection>) -> ConnectionsState {
        ConnectionsState { connections, spread, order_explicit: true }
    }

    fn ids(list: Vec<&Connection>) -> Vec<&str> {
        list.into_iter().map(|c| c.id.as_str()).collect()
    }

    #[test]
    fn parses_the_contracts_connections_state() {
        let parsed: ConnectionsState = serde_json::from_value(json!({
            "connections": [{
                "id": "codex-login", "kind": "codex-login", "provider": "openai",
                "families": ["codex"], "label": "ChatGPT", "email": "a@b.c", "plan": "pro",
                "signed_in": true, "enabled": true, "default_for": ["codex"], "serves_cloud": true
            }, {
                "id": "my-key", "kind": "api-key", "provider": "anthropic", "families": [],
                "label": "Anthropic", "email": null, "plan": null, "signed_in": true,
                "enabled": false, "default_for": [], "serves_cloud": true
            }],
            "spread": false, "order_explicit": false
        }))
        .unwrap();
        assert!(!parsed.spread);
        assert_eq!(parsed.connections[0].default_for, vec!["codex"]);
        assert!(!parsed.connections[1].enabled);
        // No families listed: the provider's API shape decides.
        assert!(serves(&parsed.connections[1], "claude"));
        assert!(!serves(&parsed.connections[1], "codex"));
    }

    #[test]
    fn the_order_is_the_persons_and_spread_off_keeps_only_the_first() {
        let list = vec![
            connection("claude-login", "claude-login", &["claude"]),
            connection("codex-login", "codex-login", &["codex"]),
            connection("plan", "chatgpt-plan", &["codex"]),
            connection("or-key", "api-key", &["claude", "codex"]),
        ];
        let on = state(true, list.clone());
        assert_eq!(ids(candidates(&on, "codex", None)), vec!["codex-login", "plan", "or-key"]);
        assert_eq!(ids(candidates(&on, "claude", None)), vec!["claude-login", "or-key"]);
        let off = state(false, list);
        assert_eq!(ids(candidates(&off, "codex", None)), vec!["codex-login"]);
    }

    #[test]
    fn the_pinned_connection_goes_first_and_alone_without_spread() {
        let mut disabled = connection("plan", "chatgpt-plan", &["codex"]);
        disabled.enabled = false;
        let list = vec![
            connection("codex-login", "codex-login", &["codex"]),
            disabled,
            connection("key", "api-key", &["codex"]),
        ];
        let on = state(true, list.clone());
        // The person's pick is used even though routing may not move a chat onto it by itself.
        assert_eq!(ids(candidates(&on, "codex", Some("plan"))), vec!["plan", "codex-login", "key"]);
        assert_eq!(ids(candidates(&on, "codex", Some("key"))), vec!["key", "codex-login"]);
        let off = state(false, list);
        assert_eq!(ids(candidates(&off, "codex", Some("key"))), vec!["key"]);
        // An unknown id is no pin.
        assert_eq!(ids(candidates(&off, "codex", Some("gone"))), vec!["codex-login"]);
    }

    #[test]
    fn a_connection_of_another_family_is_skipped_never_swapped() {
        let list = vec![
            connection("claude-login", "claude-login", &["claude"]),
            connection("codex-login", "codex-login", &["codex"]),
        ];
        let off = state(false, list.clone());
        // Pinned to a Claude login for a Codex call: nothing, rather than another model.
        assert!(candidates(&off, "codex", Some("claude-login")).is_empty());
        let on = state(true, list);
        assert_eq!(ids(candidates(&on, "codex", Some("claude-login"))), vec!["codex-login"]);
        // `openai` as a family serves Codex calls.
        let openai = state(true, vec![connection("k", "api-key", &["openai"])]);
        assert_eq!(ids(candidates(&openai, "codex", None)), vec!["k"]);
    }

    #[test]
    fn signed_out_and_non_cloud_connections_are_skipped() {
        let mut out = connection("a", "subscription", &["codex"]);
        out.signed_in = false;
        let mut local = connection("b", "subscription", &["codex"]);
        local.serves_cloud = false;
        let on = state(true, vec![out, local, connection("c", "codex-login", &["codex"])]);
        assert_eq!(ids(candidates(&on, "codex", Some("a"))), vec!["c"]);
    }

    #[test]
    fn paths_name_their_model_family() {
        assert_eq!(family_for_path("/v1/messages?beta=true"), Some("claude"));
        assert_eq!(family_for_path("/v1/messages/count_tokens"), Some("claude"));
        assert_eq!(family_for_path("/v1/responses"), Some("codex"));
        assert_eq!(family_for_path("/v1/models?client_version=1"), Some("codex"));
        assert_eq!(family_for_path("/v1/chat/completions"), None);
    }

    #[test]
    fn a_usage_limit_429_is_told_from_a_rate_limit() {
        let none = reqwest::header::HeaderMap::new();
        assert!(usage_limited(&none, br#"{"error":{"type":"usage_limit_reached"}}"#));
        assert!(usage_limited(&none, br#"{"error":{"code":"insufficient_quota"}}"#));
        assert!(!usage_limited(&none, br#"{"error":{"type":"rate_limit_error"}}"#));
        let mut rejected = reqwest::header::HeaderMap::new();
        rejected.insert("anthropic-ratelimit-unified-status", "rejected".parse().unwrap());
        assert!(usage_limited(&rejected, b"{}"));
        let mut used = reqwest::header::HeaderMap::new();
        used.insert("x-codex-primary-used-percent", "100".parse().unwrap());
        assert!(usage_limited(&used, b"{}"));
    }

    #[test]
    fn a_plan_body_is_made_fit_for_the_chatgpt_route() {
        let body = json!({
            "model": "gpt-5.5-codex", "store": true, "stream": false,
            "previous_response_id": "resp_1", "temperature": 0.2, "top_p": 1, "metadata": {},
            "max_output_tokens": 10, "user": "u", "truncation": "auto", "background": false,
            "instructions": "keep",
            "input": [
                {"type": "message", "role": "system", "content": "s"},
                {"type": "message", "role": "user", "content": "u"}
            ],
            "tools": [{"type": "function", "name": "f"}]
        });
        let out: Value =
            serde_json::from_slice(&sanitize_plan_body(body.to_string().as_bytes()).unwrap())
                .unwrap();
        assert_eq!(out["model"], "gpt-5.5-codex", "the model is never changed");
        assert_eq!(out["store"], false);
        assert_eq!(out["stream"], true);
        assert_eq!(out["instructions"], "keep");
        for gone in PLAN_DROPPED {
            assert!(out.get(*gone).is_none(), "{gone}");
        }
        assert_eq!(out["input"][0]["role"], "developer");
        assert_eq!(out["input"][1]["role"], "user");
        assert_eq!(out["tools"][0]["name"], "f");
        let search = json!({"model": "m", "tools": [{"type": "tool_search"}]});
        assert!(sanitize_plan_body(search.to_string().as_bytes()).is_err());
        assert!(sanitize_plan_body(b"not json").is_err());
    }

    #[test]
    fn a_key_reference_resolves_through_acpmuxs_resolver_and_inline_keys_are_refused() {
        let env = |k: &str| (k == "MY_KEY").then(|| "sk-env".to_owned());
        let keychain = |service: &str, account: Option<&str>| match (service, account) {
            ("cmux-harness", Some("anthropic")) => Ok("sk-keychain".to_owned()),
            _ => Err("not found".to_owned()),
        };
        assert_eq!(resolve_secret("env:MY_KEY", &env, &keychain).unwrap(), "sk-env");
        assert_eq!(
            resolve_secret("keychain:cmux-harness/anthropic", &env, &keychain).unwrap(),
            "sk-keychain"
        );
        assert!(resolve_secret("keychain:missing", &env, &keychain).is_err());
        assert!(resolve_secret("sk-inline", &env, &keychain).is_err());
        assert!(resolve_secret("env:UNSET", &env, &keychain).is_err());
    }

    #[test]
    fn provider_bases_fit_the_family() {
        assert_eq!(provider_base(Some("anthropic"), "claude"), Some("https://api.anthropic.com"));
        assert_eq!(provider_base(Some("anthropic"), "codex"), None);
        assert_eq!(provider_base(Some("openai"), "codex"), Some("https://api.openai.com/v1"));
        assert_eq!(provider_base(None, "codex"), None);
    }
}
