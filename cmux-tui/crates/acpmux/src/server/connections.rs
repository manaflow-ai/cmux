//! `_acpmux/connections` and its changes (cmux-tui/docs/model-connections.md): the person's
//! ordered ways to pay for a model, which Settings > Models shows and the inference gateway
//! serves Cloud threads from.
//!
//! A connection is a route (`crate::routes`) or a CLI login: the Codex CLI's login
//! (`codex-login`), the Claude Code login (`claude-login`), an added subscription account
//! (a direct-subscription route with its own account home), a Sign in with ChatGPT account
//! (`chatgpt-plan`, `crate::chatgpt`) or a provider API key (a direct-api-key route whose secret
//! is a reference). Its `id` is the route id, `enabled` the route's routing switch.
//!
//! Order: the person's (`connection_order` in `<acpmux home>/routes/bindings.json`) first, then
//! the default order: the picker's default account of each family, then the other signed-in
//! accounts, then keys, then the rest. `spread` (default off; the person turns it on) lets the gateway move a thread to
//! the next connection that serves its model when one is out.
//!
//! Who may call: the list, also the local app; every change, every ChatGPT call and every
//! one-click Claude token call (`claude_token.*`, `crate::claude_token`), only the
//! unix socket (the app's host calls them from a person's action; the gateway asks for tokens).
//! Never Web or a peer. No secret is resolved here and no token is logged.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::Origin;
use super::accounts::{self, CLAUDE_LOGIN_ID};
use crate::chatgpt;
use crate::hub::Hub;
use crate::key_check;
use crate::routes::{self, Auth, Bindings, Route, RouteFile, RouteKind};
use crate::rpc::{RpcError, method};

pub(super) const METHODS: &[&str] = &[
    method::MUX_CONNECTIONS,
    method::MUX_CONNECTIONS_ORDER_SET,
    method::MUX_CONNECTIONS_SPREAD_SET,
    method::MUX_CONNECTIONS_REMOVE,
    method::MUX_CONNECTIONS_KEY_ADD,
    method::MUX_CONNECTIONS_KEY_CHECK,
    method::MUX_CONNECTIONS_CHATGPT_BEGIN,
    method::MUX_CONNECTIONS_CHATGPT_WAIT,
    method::MUX_CONNECTIONS_CHATGPT_CANCEL,
    method::MUX_CONNECTIONS_CHATGPT_TOKEN,
    method::MUX_CONNECTIONS_CHATGPT_IMPORT,
    method::MUX_CONNECTIONS_CLAUDE_TOKEN_ADD,
    method::MUX_CONNECTIONS_CLAUDE_TOKEN_BEGIN,
    method::MUX_CONNECTIONS_CLAUDE_TOKEN_WAIT,
    method::MUX_CONNECTIONS_CLAUDE_TOKEN_CODE,
    method::MUX_CONNECTIONS_CLAUDE_TOKEN_CANCEL,
    method::MUX_CONNECTIONS_CREDENTIAL,
];

/// The key a watch note carries a `ConnectionsState` under (`harness_admin::watch_note`).
pub(super) const CONNECTIONS_NOTE: &str = "_acpmux_connections";

/// The longest `chatgpt.wait` holds a request.
const WAIT_LIMIT: Duration = Duration::from_secs(25);

/// Whether `m` answers a connection's token (`_acpmux/connections/credential`,
/// `_acpmux/connections/chatgpt.token`): read only on a connection that proved the person
/// (`hub/person.rs`), the Mac app's person line. An agent runs as the user and reaches the same
/// socket, with a proven caller session, a wrong token, or nothing at all, so anything short of
/// the person proof is refused (`requests.rs`).
pub(super) fn reads_token(m: &str) -> bool {
    matches!(m, method::MUX_CONNECTIONS_CREDENTIAL | method::MUX_CONNECTIONS_CHATGPT_TOKEN)
}

/// Route writes that change the connection list (announced after they succeed).
pub(super) fn changes_connections(m: &str) -> bool {
    matches!(
        m,
        method::MUX_ROUTE_ADD
            | method::MUX_ROUTE_EDIT
            | method::MUX_ROUTE_REMOVE
            | method::MUX_ROUTE_RESTORE
            | method::MUX_ROUTE_DEFAULT_SET
            | method::MUX_ACCOUNT_SET
    )
}

/// One connection, as the contract's `Connection`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub(super) struct Connection {
    pub id: String,
    pub kind: &'static str,
    pub provider: String,
    pub families: Vec<String>,
    pub label: String,
    pub email: Option<String>,
    pub plan: Option<String>,
    pub signed_in: bool,
    pub enabled: bool,
    pub default_for: Vec<String>,
    pub serves_cloud: bool,
}

/// An API-key provider: its label, the families it serves and its base URLs.
struct Provider {
    id: &'static str,
    label: &'static str,
    families: &'static [&'static str],
    anthropic: Option<&'static str>,
    openai: Option<&'static str>,
    /// OpenRouter's Anthropic endpoint takes the key as a bearer token.
    bearer: bool,
}

const PROVIDERS: &[Provider] = &[
    Provider {
        id: "anthropic",
        label: "Anthropic API key",
        families: &["claude"],
        anthropic: Some("https://api.anthropic.com"),
        openai: None,
        bearer: false,
    },
    Provider {
        id: "openai",
        label: "OpenAI API key",
        families: &["codex"],
        anthropic: None,
        openai: Some("https://api.openai.com/v1"),
        bearer: false,
    },
    Provider {
        id: "openrouter",
        label: "OpenRouter API key",
        families: &["claude", "codex"],
        anthropic: Some("https://openrouter.ai/api"),
        openai: Some("https://openrouter.ai/api/v1"),
        bearer: true,
    },
    Provider {
        id: "google",
        label: "Google AI API key",
        families: &["gemini"],
        anthropic: None,
        openai: Some("https://generativelanguage.googleapis.com/v1beta/openai"),
        bearer: false,
    },
    Provider {
        id: "xai",
        label: "xAI API key",
        families: &["codex"],
        anthropic: None,
        openai: Some("https://api.x.ai/v1"),
        bearer: false,
    },
];

fn provider(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|p| p.id == id)
}

struct Facts {
    kind: &'static str,
    provider: String,
    families: Vec<String>,
    signed_in: bool,
    email: Option<String>,
    plan: Option<String>,
    builtin: bool,
}

/// Whether a connection can serve a Cloud chat (Revision 2: its credential goes to the
/// machine's agent): a ChatGPT plan, a Claude Code token, an Anthropic or OpenAI key. The Mac's
/// CLI logins and added subscription accounts serve local chats only.
pub(super) fn serves_cloud(kind: &str, provider: &str) -> bool {
    match kind {
        "chatgpt-plan" | "claude-token" => true,
        "api-key" => matches!(provider, "anthropic" | "openai"),
        _ => false,
    }
}

fn connection(route: &Route, facts: Facts, b: &Bindings) -> Connection {
    // A connection turned off is nobody's default (account/set clears its bindings; a CLI login
    // is the default by having none).
    let default_for = if route.file.disabled {
        Vec::new()
    } else {
        facts
            .families
            .iter()
            .filter(|f| accounts::is_default(b, f, &route.id, facts.builtin))
            .cloned()
            .collect()
    };
    let serves_cloud = serves_cloud(facts.kind, &facts.provider);
    Connection {
        id: route.id.clone(),
        kind: facts.kind,
        provider: facts.provider,
        families: facts.families,
        label: route.name(),
        email: facts.email,
        plan: facts.plan,
        signed_in: facts.signed_in,
        enabled: !route.file.disabled,
        default_for,
        serves_cloud,
    }
}

/// Every connection, in the listing order the default order sorts (stably): the Codex CLI's
/// login, the routes by id, the Claude Code login.
pub(super) fn list(dir: Option<&Path>, home: &Path, b: &Bindings) -> Vec<Connection> {
    let mut out = Vec::new();
    if let Ok(codex) = routes::find(dir, routes::CODEX_LOGIN_ROUTE_ID) {
        let folder = codex
            .file
            .account_home
            .clone()
            .map(PathBuf::from)
            .or_else(crate::route_shadow::codex_base);
        let login = folder.as_deref().map(accounts::codex_login).unwrap_or_default();
        let facts = Facts {
            kind: "codex-login",
            provider: "openai".into(),
            families: vec!["codex".into()],
            signed_in: login.signed_in,
            email: login.email,
            plan: login.plan,
            builtin: true,
        };
        out.push(connection(&codex, facts, b));
    }
    let records: HashMap<String, chatgpt::store::Record> =
        chatgpt::store::all(home).into_iter().collect();
    for route in routes::load(dir).0 {
        if route.id == routes::CODEX_LOGIN_ROUTE_ID {
            continue;
        }
        let file = &route.file;
        let facts = match file.kind {
            RouteKind::DirectSubscription => {
                let (Some(folder), [family]) = (&file.account_home, file.families.as_slice())
                else {
                    continue;
                };
                let folder = Path::new(folder);
                let login = match family.as_str() {
                    "codex" => accounts::codex_login(folder),
                    "claude" => accounts::claude_login(Some(folder)),
                    _ => continue,
                };
                Facts {
                    kind: "subscription",
                    provider: file.provider().to_owned(),
                    families: file.families.clone(),
                    signed_in: login.signed_in,
                    email: login.email,
                    plan: login.plan,
                    builtin: false,
                }
            }
            RouteKind::ChatgptPlan => {
                let record = records.get(&route.id);
                Facts {
                    kind: "chatgpt-plan",
                    provider: "openai".into(),
                    families: vec!["codex".into()],
                    signed_in: record.is_some_and(chatgpt::store::Record::signed_in),
                    email: record.and_then(|r| r.email.clone()),
                    plan: record.and_then(|r| r.plan.clone()),
                    builtin: false,
                }
            }
            RouteKind::DirectApiKey => {
                let provider_id = file.provider().to_owned();
                let families = if file.families.is_empty() {
                    provider(&provider_id)
                        .map(|p| p.families.iter().map(|f| (*f).to_owned()).collect())
                        .unwrap_or_default()
                } else {
                    file.families.clone()
                };
                Facts {
                    kind: "api-key",
                    provider: provider_id,
                    families,
                    signed_in: file.secret.is_some(),
                    email: None,
                    plan: None,
                    builtin: false,
                }
            }
            RouteKind::ClaudeToken => Facts {
                kind: "claude-token",
                provider: "anthropic".into(),
                families: vec!["claude".into()],
                signed_in: file.secret.is_some(),
                email: None,
                plan: None,
                builtin: false,
            },
            _ => continue,
        };
        out.push(connection(&route, facts, b));
    }
    let claude = accounts::claude_login(None);
    let route = Route {
        id: CLAUDE_LOGIN_ID.into(),
        file: RouteFile {
            name: Some("Claude Code login".into()),
            kind: RouteKind::DirectSubscription,
            families: vec!["claude".into()],
            anthropic_base_url: None,
            openai_base_url: None,
            auth: None,
            secret: None,
            headers: Default::default(),
            health_url: None,
            fallback: vec![],
            auto_fallback: false,
            notes: None,
            account_home: None,
            shadow_of: None,
            disabled: !accounts::claude_login_enabled(b),
            provider: None,
        },
        path: PathBuf::new(),
    };
    let facts = Facts {
        kind: "claude-login",
        provider: "anthropic".into(),
        families: vec!["claude".into()],
        signed_in: claude.signed_in,
        email: claude.email,
        plan: claude.plan,
        builtin: true,
    };
    out.push(connection(&route, facts, b));
    out
}

/// `list` in the person's order: the ids of `explicit` that still exist, then the rest in the
/// default order (the picker's defaults, signed-in accounts, keys, the rest; stable).
pub(super) fn ordered(mut list: Vec<Connection>, explicit: &[String]) -> Vec<Connection> {
    let group = |c: &Connection| {
        if !c.enabled {
            4
        } else if !c.default_for.is_empty() {
            0
        } else if c.kind != "api-key" && c.signed_in {
            1
        } else if c.kind == "api-key" && c.signed_in {
            2
        } else {
            3
        }
    };
    list.sort_by_key(group);
    let mut out = Vec::with_capacity(list.len());
    for id in explicit {
        if let Some(at) = list.iter().position(|c| &c.id == id) {
            out.push(list.remove(at));
        }
    }
    out.extend(list);
    out
}

/// The `ConnectionsState`.
pub(super) fn state(dir: Option<&Path>, home: &Path) -> Value {
    let b = routes::bindings(home);
    let connections = ordered(list(dir, home, &b), &b.connection_order);
    json!({
        "connections": connections,
        "spread": b.spread.unwrap_or(false),
        "order_explicit": !b.connection_order.is_empty(),
    })
}

fn route_error(e: &routes::RouteError) -> RpcError {
    crate::hub::route_error(e)
}

/// Stores the person's order. Every id must name a connection, once.
pub(super) fn set_order(
    dir: Option<&Path>,
    home: &Path,
    ids: &[String],
) -> Result<Value, RpcError> {
    let known: BTreeSet<String> =
        list(dir, home, &routes::bindings(home)).into_iter().map(|c| c.id).collect();
    let mut seen = BTreeSet::new();
    for id in ids {
        if !known.contains(id) {
            return Err(RpcError::invalid_params(format!("no connection {id:?}"))
                .with_data(json!({"reason": "connections.unknown_id", "id": id})));
        }
        if !seen.insert(id) {
            return Err(RpcError::invalid_params(format!("{id:?} is listed twice"))
                .with_data(json!({"reason": "connections.duplicate_id", "id": id})));
        }
    }
    routes::update_bindings(home, |b| b.connection_order = ids.to_vec())
        .map_err(|e| route_error(&e))?;
    Ok(state(dir, home))
}

pub(super) fn set_spread(dir: Option<&Path>, home: &Path, on: bool) -> Result<Value, RpcError> {
    routes::update_bindings(home, |b| b.spread = Some(on)).map_err(|e| route_error(&e))?;
    Ok(state(dir, home))
}

/// Adds a provider API key whose secret is a reference (`keychain:ITEM`); never the key.
pub(super) fn add_key(
    dir: Option<&Path>,
    home: &Path,
    provider_id: &str,
    secret: &str,
    label: Option<&str>,
) -> Result<(String, Value), RpcError> {
    let p = provider(provider_id).ok_or_else(|| {
        RpcError::invalid_params(format!(
            "unknown provider {provider_id:?}: one of {}",
            routes::PROVIDERS.join(", ")
        ))
    })?;
    let id = std::iter::once(format!("{}-key", p.id))
        .chain((2..1000).map(|n| format!("{}-key-{n}", p.id)))
        .find(|id| routes::find(dir, id).is_err())
        .ok_or_else(|| RpcError::invalid_params("too many keys for this provider"))?;
    let file = RouteFile {
        name: Some(label.map(str::trim).filter(|l| !l.is_empty()).unwrap_or(p.label).to_owned()),
        kind: RouteKind::DirectApiKey,
        families: p.families.iter().map(|f| (*f).to_owned()).collect(),
        anthropic_base_url: p.anthropic.map(str::to_owned),
        openai_base_url: p.openai.map(str::to_owned),
        auth: p.bearer.then_some(Auth::Bearer),
        secret: Some(secret.to_owned()),
        headers: Default::default(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: None,
        account_home: None,
        shadow_of: None,
        disabled: false,
        provider: Some(p.id.to_owned()),
    };
    // `add` validates: an inline key is refused (route.secret_inline).
    routes::add(dir, &id, &file, false).map_err(|e| route_error(&e))?;
    Ok((id, state(dir, home)))
}

/// Adds Claude Code's `claude setup-token` token as a secret reference (`keychain:ITEM`).
pub(super) fn add_claude_token(
    dir: Option<&Path>,
    home: &Path,
    secret: &str,
    label: Option<&str>,
) -> Result<(String, Value), RpcError> {
    let id = std::iter::once("claude-token".to_owned())
        .chain((2..1000).map(|n| format!("claude-token-{n}")))
        .find(|id| routes::find(dir, id).is_err())
        .ok_or_else(|| RpcError::invalid_params("too many Claude tokens"))?;
    let file = RouteFile {
        name: Some(
            label
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .unwrap_or("Claude Code token")
                .to_owned(),
        ),
        kind: RouteKind::ClaudeToken,
        families: vec!["claude".into()],
        anthropic_base_url: None,
        openai_base_url: None,
        auth: None,
        secret: Some(secret.to_owned()),
        headers: Default::default(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: Some(
            "claude setup-token: serves Claude chats on this Mac and Cloud machines' Claude agents"
                .into(),
        ),
        account_home: None,
        shadow_of: None,
        disabled: false,
        provider: Some("anthropic".into()),
    };
    // `add` validates: an inline token is refused (route.secret_inline).
    routes::add(dir, &id, &file, false).map_err(|e| route_error(&e))?;
    Ok((id, state(dir, home)))
}

/// What a Cloud machine's agent needs from a secret-reference connection: its family, kind,
/// the variable it is delivered in and the reference. A ChatGPT plan is not one (its token is
/// the daemon's own, `chatgpt::Service::token_lasting`).
pub(super) fn credential_plan(
    dir: Option<&Path>,
    home: &Path,
    id: &str,
) -> Result<(String, &'static str, &'static str, Option<String>), RpcError> {
    let found = list(dir, home, &routes::bindings(home))
        .into_iter()
        .find(|c| c.id == id)
        .ok_or_else(|| RpcError::not_found(format!("no connection {id:?}")))?;
    if !found.serves_cloud {
        return Err(RpcError::invalid_params(format!("{id} does not serve Cloud chats"))
            .with_data(json!({"reason": "connections.not_cloud", "id": id})));
    }
    if !found.enabled {
        return Err(RpcError::invalid_params(format!("{id} is turned off"))
            .with_data(json!({"reason": "connections.disabled", "id": id})));
    }
    let family = found.families.first().cloned().unwrap_or_default();
    let var = match (found.kind, found.provider.as_str()) {
        ("chatgpt-plan", _) => {
            return Ok((family, "chatgpt-plan", "CMUX_CHATGPT_ACCESS_TOKEN", None));
        }
        ("claude-token", _) => "CLAUDE_CODE_OAUTH_TOKEN",
        ("api-key", "anthropic") => "ANTHROPIC_API_KEY",
        ("api-key", _) => "OPENAI_API_KEY",
        _ => unreachable_kind(id)?,
    };
    let route = routes::find(dir, id).map_err(|e| route_error(&e))?;
    let secret = route.file.secret.ok_or_else(|| {
        RpcError::invalid_params(format!("{id} has no secret"))
            .with_data(json!({"reason": "connections.no_secret", "id": id}))
    })?;
    Ok((family, found.kind, var, Some(secret)))
}

fn unreachable_kind(id: &str) -> Result<&'static str, RpcError> {
    Err(RpcError::invalid_params(format!("{id} does not serve Cloud chats"))
        .with_data(json!({"reason": "connections.not_cloud", "id": id})))
}

/// The value a connection of KIND sends: a Claude setup token with every whitespace character
/// taken out, inner ones too (a terminal wraps `claude setup-token`'s long line and pads it, and a
/// copy kept before the app stripped pastes still has it; a token has no whitespace of its own),
/// so the launch's token check (`agent_credentials::token_shaped`) takes it. Others as stored.
fn delivered(kind: &str, value: String) -> String {
    if kind == "claude-token" && value.chars().any(char::is_whitespace) {
        value.chars().filter(|c| !c.is_whitespace()).collect()
    } else {
        value
    }
}

/// The secret a reference names; the error says why it did not resolve, never a value.
fn resolve(id: &str, reference: &str) -> Result<String, RpcError> {
    routes::resolve_reference(reference).map_err(|why| {
        RpcError::invalid_params(format!("{id}'s secret did not resolve: {why}"))
            .with_data(json!({"reason": "connections.secret_unresolved", "id": id}))
    })
}

fn failure(f: chatgpt::Failure) -> RpcError {
    failure_in("chatgpt", f)
}

/// A `claude_token` failure: reason `claude_token.CODE`.
fn token_failure(f: chatgpt::Failure) -> RpcError {
    failure_in("claude_token", f)
}

fn failure_in(scope: &str, f: chatgpt::Failure) -> RpcError {
    let error = if f.code == "not_found" || f.code == "unknown_attempt" {
        RpcError::not_found(f.message)
    } else {
        RpcError::new(-32000, f.message)
    };
    error.with_data(json!({"reason": format!("{scope}.{}", f.code), "code": f.code}))
}

/// `claude_token.wait`'s answer for `status`: the connection once done (as listed), the code once
/// failed. Never the token: the attempt holds only the connection's id.
fn token_wait_reply(dir: Option<&Path>, home: &Path, status: &chatgpt::Status) -> Value {
    let connection = match status {
        chatgpt::Status::Done(id) => {
            list(dir, home, &routes::bindings(home)).into_iter().find(|c| &c.id == id)
        }
        _ => None,
    };
    let error = match status {
        chatgpt::Status::Failed(code) => Some(code.clone()),
        _ => None,
    };
    json!({"status": status.as_str(), "connection": connection, "error": error})
}

/// What `claude_token.begin` adds the stored token as: a `claude-token` connection with
/// `reference` (`keychain:cmux-model-key/claude-token-…`) and `label`; its id.
fn add_token_reference(
    dir: Option<&Path>,
    home: &Path,
    reference: &str,
    label: Option<&str>,
) -> Result<String, chatgpt::Failure> {
    add_claude_token(dir, home, reference, label)
        .map(|(id, _)| id)
        .map_err(|e| chatgpt::Failure::new("add", e.message))
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> T + Send + 'static,
) -> Result<T, RpcError> {
    tokio::task::spawn_blocking(work).await.map_err(|e| RpcError::internal(e.to_string()))
}

/// Sends the current state to watching connections.
pub(super) async fn announce(hub: &Arc<Hub>) {
    let (dir, home) = routes::places(&*hub.config.read().await);
    if let Ok(state) = blocking(move || state(dir.as_deref(), &home)).await {
        hub.send_watch_note(json!({ CONNECTIONS_NOTE: state }));
    }
}

/// `announce` without holding up the caller's answer.
pub(super) fn announce_later(hub: &Arc<Hub>) {
    let hub = hub.clone();
    announce_scope().spawn_named("connections announce", async move { announce(&hub).await });
}

/// The owner of the connection-state announcements [`announce_later`] sends.
fn announce_scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("connections announce"))
}

/// `_acpmux/connections/chatgpt.import`: refused on any connection but the local socket (the
/// remote relay and the web listener never reach a login file here) and unless the daemon's
/// environment turned it on (`enabled`, [`chatgpt::CI_IMPORT_ENV`]); the connection's id.
fn import_chatgpt(
    origin: Origin,
    enabled: bool,
    dir: Option<PathBuf>,
    home: PathBuf,
    secret_file: &str,
) -> Result<String, RpcError> {
    if origin != Origin::Local {
        return Err(RpcError::invalid_params(
            "chatgpt.import is read from the local unix socket only, never a remote",
        )
        .with_data(json!({"reason": "chatgpt.import_local_only"})));
    }
    if !enabled {
        return Err(RpcError::invalid_params(format!(
            "chatgpt.import is a CI-only method: set {} in the daemon's environment",
            chatgpt::CI_IMPORT_ENV
        ))
        .with_data(json!({"reason": "chatgpt.import_disabled"})));
    }
    chatgpt::import_codex_auth(
        &chatgpt::Places { routes: dir, home },
        std::path::Path::new(secret_file),
    )
    .map_err(failure)
}

/// The listed connection `id`, as `chatgpt.wait` answers a finished sign-in.
fn connection_state(dir: Option<&Path>, home: &Path, id: &str) -> Result<Value, RpcError> {
    let b = routes::bindings(home);
    let found = list(dir, home, &b).into_iter().find(|c| c.id == id);
    Ok(json!({"connection": found}))
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "connections are read and changed only from the local app or the unix socket",
        ));
    }
    if m != method::MUX_CONNECTIONS && origin != Origin::Local {
        return Err(RpcError::invalid_params(
            "changing a connection or reading its token: only the unix socket may ask",
        ));
    }
    let (dir, home) = routes::places(&*hub.config.read().await);
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let need = |key: &str| {
        text(key)
            .map(str::to_owned)
            .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
    };
    match m {
        method::MUX_CONNECTIONS => blocking(move || state(dir.as_deref(), &home)).await,
        method::MUX_CONNECTIONS_ORDER_SET => {
            let ids = params
                .get("ids")
                .and_then(Value::as_array)
                .ok_or_else(|| RpcError::invalid_params("ids is required"))?
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| RpcError::invalid_params("ids are strings"))
                })
                .collect::<Result<Vec<_>, _>>()?;
            let state = blocking(move || set_order(dir.as_deref(), &home, &ids)).await??;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_SPREAD_SET => {
            let on = params
                .get("on")
                .and_then(Value::as_bool)
                .ok_or_else(|| RpcError::invalid_params("on is required (true or false)"))?;
            let state = blocking(move || set_spread(dir.as_deref(), &home, on)).await??;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_KEY_ADD => {
            let provider = need("provider")?;
            let secret = need("secret")?;
            let label = text("label").map(str::to_owned);
            let (_, state) = blocking(move || {
                add_key(dir.as_deref(), &home, &provider, &secret, label.as_deref())
            })
            .await??;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_KEY_CHECK => {
            let provider = need("provider")?;
            let secret = need("secret")?;
            // The keychain may ask: off the runtime's threads. The key stays in this arm.
            let key = Zeroizing::new(blocking(move || resolve("the key", &secret)).await??);
            let verdict = key_check::check(&provider, &key, None, key_check::CHECK_TIMEOUT).await;
            let (status, detail) = match &verdict {
                key_check::Verdict::BadKey(code) => (Some(*code), None),
                key_check::Verdict::Unreachable(why) => (None, Some(why.clone())),
                _ => (None, None),
            };
            Ok(json!({
                "provider": provider,
                "result": verdict.as_str(),
                "save": !verdict.rejects(),
                "http_status": status,
                "detail": detail,
                "message": verdict.sentence(&provider),
            }))
        }
        method::MUX_CONNECTIONS_REMOVE => {
            let id = need("id")?;
            let (d, h, i) = (dir.clone(), home.clone(), id.clone());
            let found = blocking(move || {
                list(d.as_deref(), &h, &routes::bindings(&h)).into_iter().find(|c| c.id == i)
            })
            .await?
            .ok_or_else(|| RpcError::not_found(format!("no connection {id:?}")))?;
            match found.kind {
                "codex-login" | "claude-login" => {
                    return Err(RpcError::invalid_params(format!(
                        "{id} is the CLI's own login: sign out in the CLI, or turn it off"
                    )));
                }
                "chatgpt-plan" => {
                    hub.chatgpt.remove(&home, &id).await.map_err(failure)?;
                }
                _ => {}
            }
            let (d, h) = (dir.clone(), home.clone());
            blocking(move || routes::remove(d.as_deref(), &h, &id))
                .await?
                .map_err(|e| route_error(&e))?;
            let state = blocking(move || state(dir.as_deref(), &home)).await?;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_CHATGPT_BEGIN => {
            let reauth = text("id").map(str::to_owned);
            if let Some(id) = &reauth {
                let route = routes::find(dir.as_deref(), id).map_err(|e| route_error(&e))?;
                if route.file.kind != RouteKind::ChatgptPlan {
                    return Err(RpcError::invalid_params(format!("{id} is not a ChatGPT sign-in")));
                }
            }
            let places = chatgpt::Places { routes: dir, home };
            let announcer = hub.clone();
            let begun = hub
                .chatgpt
                .begin(places, reauth, move |status| {
                    if matches!(status, chatgpt::Status::Done(_)) {
                        announce_later(&announcer);
                    }
                })
                .await
                .map_err(failure)?;
            Ok(json!({"attempt": begun.attempt, "url": begun.url}))
        }
        method::MUX_CONNECTIONS_CHATGPT_WAIT => {
            let attempt = need("attempt")?;
            let status = hub.chatgpt.wait(&attempt, WAIT_LIMIT).await.map_err(failure)?;
            let connection = match &status {
                chatgpt::Status::Done(id) => {
                    let id = id.clone();
                    blocking(move || {
                        let b = routes::bindings(&home);
                        list(dir.as_deref(), &home, &b).into_iter().find(|c| c.id == id)
                    })
                    .await?
                }
                _ => None,
            };
            let error = match &status {
                chatgpt::Status::Failed(code) => Some(code.clone()),
                _ => None,
            };
            Ok(json!({"status": status.as_str(), "connection": connection, "error": error}))
        }
        method::MUX_CONNECTIONS_CHATGPT_CANCEL => {
            let attempt = need("attempt")?;
            let status = hub.chatgpt.cancel(&attempt).await.map_err(failure)?;
            Ok(json!({"attempt": attempt, "status": status.as_str()}))
        }
        method::MUX_CONNECTIONS_CLAUDE_TOKEN_ADD => {
            let secret = need("secret")?;
            let label = text("label").map(str::to_owned);
            let (_, state) = blocking(move || {
                add_claude_token(dir.as_deref(), &home, &secret, label.as_deref())
            })
            .await??;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_CLAUDE_TOKEN_BEGIN => {
            let label = text("label").map(str::to_owned);
            let announcer = hub.clone();
            let begun = hub
                .claude_token
                .begin(
                    move |reference| {
                        add_token_reference(dir.as_deref(), &home, reference, label.as_deref())
                    },
                    move |status| {
                        if matches!(status, chatgpt::Status::Done(_)) {
                            announce_later(&announcer);
                        }
                    },
                )
                .await
                .map_err(token_failure)?;
            Ok(json!({"attempt": begun.attempt, "url": begun.url}))
        }
        method::MUX_CONNECTIONS_CLAUDE_TOKEN_WAIT => {
            let attempt = need("attempt")?;
            let status =
                hub.claude_token.wait(&attempt, WAIT_LIMIT).await.map_err(token_failure)?;
            blocking(move || token_wait_reply(dir.as_deref(), &home, &status)).await
        }
        method::MUX_CONNECTIONS_CLAUDE_TOKEN_CODE => {
            let attempt = need("attempt")?;
            let code = params.get("code").and_then(Value::as_str).unwrap_or_default();
            hub.claude_token.code(&attempt, code).await.map_err(token_failure)?;
            Ok(json!({"attempt": attempt, "status": "pending"}))
        }
        method::MUX_CONNECTIONS_CLAUDE_TOKEN_CANCEL => {
            let attempt = need("attempt")?;
            let status = hub.claude_token.cancel(&attempt).await.map_err(token_failure)?;
            Ok(json!({"attempt": attempt, "status": status.as_str()}))
        }
        method::MUX_CONNECTIONS_CREDENTIAL => {
            let id = need("id")?;
            let (d, h, i) = (dir.clone(), home.clone(), id.clone());
            let (family, kind, var, reference) =
                blocking(move || credential_plan(d.as_deref(), &h, &i)).await??;
            let (value, expires_at) = match reference {
                None => {
                    let (token, expires_at) = hub
                        .chatgpt
                        .token_lasting(&home, &id, chatgpt::CREDENTIAL_MARGIN_SECS)
                        .await
                        .map_err(failure)?;
                    (token, Some(expires_at))
                }
                // The keychain may ask: off the runtime's threads.
                Some(reference) => {
                    (delivered(kind, blocking(move || resolve(&id, &reference)).await??), None)
                }
            };
            Ok(
                json!({"family": family, "kind": kind, "env": {var: value}, "expires_at": expires_at}),
            )
        }
        method::MUX_CONNECTIONS_CHATGPT_IMPORT => {
            let secret_file = need("secret_file")?;
            let enabled = chatgpt::ci_import_enabled();
            let (d, h) = (dir.clone(), home.clone());
            let id =
                blocking(move || import_chatgpt(origin, enabled, d, h, &secret_file)).await??;
            announce_later(hub);
            blocking(move || connection_state(dir.as_deref(), &home, &id)).await?
        }
        method::MUX_CONNECTIONS_CHATGPT_TOKEN => {
            let id = need("id")?;
            let (access_token, expires_at) =
                hub.chatgpt.token(&home, &id).await.map_err(failure)?;
            Ok(json!({"access_token": access_token, "expires_at": expires_at}))
        }
        _ => Err(RpcError::method_not_found(m)),
    }
}

#[cfg(test)]
#[path = "connections_tests.rs"]
mod tests;
