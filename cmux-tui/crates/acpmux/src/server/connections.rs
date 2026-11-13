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
//! accounts, then keys, then the rest. `spread` (default on) lets the gateway move a thread to
//! the next connection that serves its model when one is out.
//!
//! Who may call: the list, also the local app; every change and every ChatGPT call, only the
//! unix socket (the app's host calls them from a person's action; the gateway asks for tokens).
//! Never Web or a peer. No secret is resolved here and no token is logged.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};

use super::Origin;
use super::accounts::{self, CLAUDE_LOGIN_ID};
use crate::chatgpt;
use crate::hub::Hub;
use crate::routes::{self, Auth, Bindings, Route, RouteFile, RouteKind};
use crate::rpc::{RpcError, method};

pub(super) const METHODS: &[&str] = &[
    method::MUX_CONNECTIONS,
    method::MUX_CONNECTIONS_ORDER_SET,
    method::MUX_CONNECTIONS_SPREAD_SET,
    method::MUX_CONNECTIONS_REMOVE,
    method::MUX_CONNECTIONS_KEY_ADD,
    method::MUX_CONNECTIONS_CHATGPT_BEGIN,
    method::MUX_CONNECTIONS_CHATGPT_WAIT,
    method::MUX_CONNECTIONS_CHATGPT_CANCEL,
    method::MUX_CONNECTIONS_CHATGPT_TOKEN,
];

/// The key a watch note carries a `ConnectionsState` under (`harness_admin::watch_note`).
pub(super) const CONNECTIONS_NOTE: &str = "_acpmux_connections";

/// The longest `chatgpt.wait` holds a request.
const WAIT_LIMIT: Duration = Duration::from_secs(25);

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

fn connection(route: &Route, facts: Facts, b: &Bindings) -> Connection {
    let default_for = facts
        .families
        .iter()
        .filter(|f| accounts::is_default(b, f, &route.id, facts.builtin))
        .cloned()
        .collect();
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
        serves_cloud: true,
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
            disabled: false,
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
        if !c.default_for.is_empty() {
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
        "spread": b.spread.unwrap_or(true),
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

fn failure(f: chatgpt::Failure) -> RpcError {
    let error = if f.code == "not_found" || f.code == "unknown_attempt" {
        RpcError::not_found(f.message)
    } else {
        RpcError::new(-32000, f.message)
    };
    error.with_data(json!({"reason": format!("chatgpt.{}", f.code), "code": f.code}))
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
    tokio::spawn(async move { announce(&hub).await });
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
mod tests {
    use super::*;

    fn conn(id: &str, kind: &'static str, signed_in: bool, default_for: &[&str]) -> Connection {
        Connection {
            id: id.into(),
            kind,
            provider: "openai".into(),
            families: vec!["codex".into()],
            label: id.into(),
            email: None,
            plan: None,
            signed_in,
            enabled: true,
            default_for: default_for.iter().map(|f| (*f).to_owned()).collect(),
            serves_cloud: true,
        }
    }

    fn ids(list: &[Connection]) -> Vec<&str> {
        list.iter().map(|c| c.id.as_str()).collect()
    }

    #[test]
    fn the_default_order_is_picker_defaults_then_signed_in_accounts_then_keys() {
        let listed = vec![
            conn("codex-login", "codex-login", true, &[]),
            conn("openai-key", "api-key", true, &[]),
            conn("chatgpt", "chatgpt-plan", true, &[]),
            conn("work", "subscription", false, &[]),
            conn("codex-2", "subscription", true, &["codex"]),
            conn("claude-login", "claude-login", true, &["claude"]),
        ];
        assert_eq!(
            ids(&ordered(listed.clone(), &[])),
            ["codex-2", "claude-login", "codex-login", "chatgpt", "openai-key", "work"]
        );
        // The person's order first; ids that are gone are skipped; the rest keep the default.
        let explicit = vec!["openai-key".to_owned(), "gone".to_owned(), "work".to_owned()];
        assert_eq!(
            ids(&ordered(listed, &explicit)),
            ["openai-key", "work", "codex-2", "claude-login", "codex-login", "chatgpt"]
        );
    }

    struct Dirs {
        _root: tempfile::TempDir,
        routes: PathBuf,
        home: PathBuf,
    }

    fn dirs() -> Dirs {
        let root = tempfile::tempdir().unwrap();
        let (routes, home) = (root.path().join("routes"), root.path().join("home"));
        std::fs::create_dir_all(&routes).unwrap();
        Dirs { _root: root, routes, home }
    }

    fn state_ids(state: &Value) -> Vec<String> {
        state["connections"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["id"].as_str().unwrap().to_owned())
            .collect()
    }

    #[test]
    fn order_set_refuses_an_unknown_id_and_stores_a_known_order() {
        let d = dirs();
        let (_, _) =
            add_key(Some(&d.routes), &d.home, "anthropic", "keychain:cmux-test-key", None).unwrap();
        let error = set_order(Some(&d.routes), &d.home, &["nope".to_owned()]).unwrap_err();
        assert_eq!(error.data.as_ref().unwrap()["reason"], "connections.unknown_id");
        assert!(routes::bindings(&d.home).connection_order.is_empty(), "nothing stored");
        let twice = vec!["anthropic-key".to_owned(), "anthropic-key".to_owned()];
        assert!(set_order(Some(&d.routes), &d.home, &twice).is_err());

        let state = set_order(Some(&d.routes), &d.home, &["anthropic-key".to_owned()]).unwrap();
        assert_eq!(state["order_explicit"], true);
        assert_eq!(state_ids(&state)[0], "anthropic-key");
        let text = std::fs::read_to_string(d.home.join("routes/bindings.json")).unwrap();
        assert!(text.contains("\"connection_order\""), "{text}");
        // Removing the route drops it from the order.
        routes::remove(Some(&d.routes), &d.home, "anthropic-key").unwrap();
        assert!(routes::bindings(&d.home).connection_order.is_empty());
    }

    #[test]
    fn spread_defaults_on_and_is_stored() {
        let d = dirs();
        assert_eq!(state(Some(&d.routes), &d.home)["spread"], true);
        assert_eq!(set_spread(Some(&d.routes), &d.home, false).unwrap()["spread"], false);
        assert_eq!(routes::bindings(&d.home).spread, Some(false));
    }

    #[test]
    fn a_key_is_added_as_a_reference_and_listed_with_its_provider() {
        let d = dirs();
        let inline = add_key(Some(&d.routes), &d.home, "openrouter", "sk-or-v1-abc", None);
        assert_eq!(inline.unwrap_err().data.unwrap()["reason"], "route.secret_inline");
        assert!(add_key(Some(&d.routes), &d.home, "mistral", "keychain:x", None).is_err());
        let (id, state) =
            add_key(Some(&d.routes), &d.home, "openrouter", "keychain:cmux-or", Some("Mine"))
                .unwrap();
        assert_eq!(id, "openrouter-key");
        let key = state["connections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["id"] == "openrouter-key")
            .cloned()
            .unwrap();
        assert_eq!(key["kind"], "api-key");
        assert_eq!(key["provider"], "openrouter");
        assert_eq!(key["families"], json!(["claude", "codex"]));
        assert_eq!(key["label"], "Mine");
        assert_eq!(key["signed_in"], true);
        assert_eq!(key["serves_cloud"], true);
        let (second, _) =
            add_key(Some(&d.routes), &d.home, "openrouter", "keychain:cmux-or-2", None).unwrap();
        assert_eq!(second, "openrouter-key-2");
        let route = routes::find(Some(&d.routes), "openrouter-key").unwrap();
        assert_eq!(route.file.secret.as_deref(), Some("keychain:cmux-or"));
        assert_eq!(route.file.provider.as_deref(), Some("openrouter"));
    }

    #[test]
    fn a_chatgpt_plan_route_is_listed_from_its_record() {
        let d = dirs();
        let record = chatgpt::store::Record {
            client_id: "oaiapp_x".into(),
            sub: "user-1".into(),
            email: Some("alex@example.com".into()),
            plan: Some("plus".into()),
            refresh_token: "r".into(),
            ..Default::default()
        };
        chatgpt::store::write(&d.home, "chatgpt", &record).unwrap();
        let file = RouteFile {
            name: Some("ChatGPT plan".into()),
            kind: RouteKind::ChatgptPlan,
            families: vec!["codex".into()],
            anthropic_base_url: None,
            openai_base_url: Some(chatgpt::RESOURCE.into()),
            auth: None,
            secret: None,
            headers: Default::default(),
            health_url: None,
            fallback: vec![],
            auto_fallback: false,
            notes: None,
            account_home: None,
            shadow_of: None,
            disabled: false,
            provider: Some("openai".into()),
        };
        routes::add(Some(&d.routes), "chatgpt", &file, false).unwrap();
        let list = list(Some(&d.routes), &d.home, &routes::bindings(&d.home));
        let plan = list.iter().find(|c| c.id == "chatgpt").unwrap();
        assert_eq!(plan.kind, "chatgpt-plan");
        assert!(plan.signed_in);
        assert_eq!(plan.email.as_deref(), Some("alex@example.com"));
        assert_eq!(plan.plan.as_deref(), Some("plus"));
        // A local chat never spawns on it.
        let route = routes::find(Some(&d.routes), "chatgpt").unwrap();
        assert!(matches!(
            routes::env_for(&route, "codex", &d.home),
            Err(routes::RouteError::Unavailable(_))
        ));
    }
}
