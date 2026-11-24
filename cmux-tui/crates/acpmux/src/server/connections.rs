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
//! Never Web or a peer. The list exposes only public metadata and whether sign-in is available.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};

use super::Origin;
use super::accounts::{self, CLAUDE_LOGIN_ID};
use crate::agent_credentials::{AgentCredential, LaunchEndpoint};
use crate::agent_login::{Agent, Cli};
use crate::byo_endpoint::{self, Kind};
use crate::chatgpt;
use crate::config::{self, HarnessProfile, ProfileSources};
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
    method::MUX_CONNECTIONS_CHATGPT_DEVICE_BEGIN,
    method::MUX_CONNECTIONS_CHATGPT_DEVICE_WAIT,
    method::MUX_CONNECTIONS_CHATGPT_DEVICE_CANCEL,
    method::MUX_CONNECTIONS_SUBSCRIPTION_BEGIN,
    method::MUX_CONNECTIONS_SUBSCRIPTION_WAIT,
    method::MUX_CONNECTIONS_SUBSCRIPTION_CANCEL,
    method::MUX_CONNECTIONS_CHATGPT_TOKEN,
    method::MUX_CONNECTIONS_CHATGPT_IMPORT,
    method::MUX_CONNECTIONS_CREDENTIAL,
];

/// The key a watch note carries a `ConnectionsState` under (`harness_admin::watch_note`).
pub(super) const CONNECTIONS_NOTE: &str = "_acpmux_connections";

/// The longest `chatgpt.wait` holds a request.
const WAIT_LIMIT: Duration = Duration::from_secs(25);

/// Whether this method reads a token or runs the credential capture flow.
/// These require a connection that proved the person
/// (`hub/person.rs`), the Mac app's person line. An agent runs as the user and reaches the same
/// socket, with a proven caller session, a wrong token, or nothing at all, so anything short of
/// the person proof is refused (`requests.rs`).
pub(super) fn reads_token(m: &str) -> bool {
    matches!(
        m,
        method::MUX_CONNECTIONS_CREDENTIAL
            | method::MUX_CONNECTIONS_SUBSCRIPTION_BEGIN
            | method::MUX_CONNECTIONS_SUBSCRIPTION_WAIT
            | method::MUX_CONNECTIONS_SUBSCRIPTION_CANCEL
            | method::MUX_CONNECTIONS_CHATGPT_TOKEN
            | method::MUX_CONNECTIONS_CHATGPT_DEVICE_BEGIN
            | method::MUX_CONNECTIONS_CHATGPT_DEVICE_WAIT
            | method::MUX_CONNECTIONS_CHATGPT_DEVICE_CANCEL
    )
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sign_in_reason: Option<&'static str>,
    pub enabled: bool,
    pub default_for: Vec<String>,
    pub serves_cloud: bool,
    pub can_serve_cloud: bool,
    pub can_check_access: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub can_replace_key: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<EndpointFields>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint_credentials: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cloud_families: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub launch_harness: Option<&'static str>,
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
        id: "vertex-express",
        label: "Vertex AI Express key",
        families: &["gemini"],
        anthropic: None,
        openai: Some("https://aiplatform.googleapis.com"),
        bearer: false,
    },
    Provider {
        id: "xai",
        label: "xAI API key",
        families: &["grok"],
        anthropic: None,
        openai: Some("https://api.x.ai/v1"),
        bearer: false,
    },
];

fn provider(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|p| p.id == id)
}

fn model_endpoint(provider: &Provider) -> Option<(&str, crate::byo_endpoint::Kind)> {
    use crate::byo_endpoint::Kind;
    provider
        .openai
        .map(|url| (url, Kind::OpenAi))
        .or_else(|| provider.anthropic.map(|url| (url, Kind::Anthropic)))
}

fn standard_key_endpoint(file: &RouteFile) -> Option<(&'static str, crate::byo_endpoint::Kind)> {
    let provider = provider(file.provider.as_deref()?)?;
    if file.kind != RouteKind::DirectApiKey
        || file.secret.is_none()
        || !file.headers.is_empty()
        || file.anthropic_base_url.as_deref() != provider.anthropic
        || file.openai_base_url.as_deref() != provider.openai
    {
        return None;
    }
    model_endpoint(provider)
}

/// List models for a draft or a saved API-key route. A saved credential uses only its
/// configured provider's standard endpoint. The call never changes a profile or a key.
pub(super) async fn check_models(dir: Option<PathBuf>, params: &Value) -> Result<Value, RpcError> {
    use crate::byo_endpoint::{self, Kind};
    use zeroize::Zeroizing;

    let (base, kind, key) = if let Some(id) = params["id"].as_str() {
        let id = id.to_owned();
        blocking(move || {
            let route = routes::find(dir.as_deref(), &id).map_err(|e| route_error(&e))?;
            let Some(((url, kind), reference)) =
                standard_key_endpoint(&route.file).zip(route.file.secret.as_deref())
            else {
                return Err(RpcError::invalid_params(
                    "only standard API-key connections can list models",
                ));
            };
            Ok((url.to_owned(), kind, Some(Zeroizing::new(resolve(&id, reference)?))))
        })
        .await??
    } else {
        let key = params["apiKey"].as_str().filter(|key| !key.is_empty());
        if key.is_some_and(|key| {
            key.len() > 16_384 || !key.bytes().all(|b| (0x21..=0x7e).contains(&b))
        }) {
            return Err(RpcError::invalid_params("invalid API key format"));
        }
        let (url, kind) = if let Some(id) = params["provider"].as_str() {
            if key.is_none() {
                return Err(RpcError::invalid_params("an API key is required"));
            }
            provider(id)
                .and_then(model_endpoint)
                .ok_or_else(|| RpcError::invalid_params("unknown API-key provider"))?
        } else {
            (
                params["baseUrl"]
                    .as_str()
                    .ok_or_else(|| RpcError::invalid_params("a base URL is required"))?,
                Kind::OpenAi,
            )
        };
        (url.to_owned(), kind, key.map(|key| Zeroizing::new(key.to_owned())))
    };
    let key = key.as_ref().map(|key| key.as_str());
    let answer = if base == "https://openrouter.ai/api/v1" && key.is_some() {
        // The public catalog can answer without authentication. This one requires a valid key.
        byo_endpoint::fetch_model_list(
            kind,
            "https://openrouter.ai/api/v1/models/user",
            key,
            byo_endpoint::FETCH_TIMEOUT,
        )
        .await
    } else {
        byo_endpoint::fetch_models(kind, &base, key, byo_endpoint::FETCH_TIMEOUT).await
    };
    match answer {
        Ok(mut models) => {
            // A model list is untrusted provider data. Never echo a key back to the page.
            models.retain(|id| {
                id != "*"
                    && !key.is_some_and(|key| id.contains(key))
                    && !byo_endpoint::looks_like_secret(id)
            });
            Ok(json!({"models": models}))
        }
        Err(message) => Ok(json!({"failure": message})),
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct EndpointFields {
    kind: &'static str,
    base_url: String,
    models: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    preset: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    revision: Option<String>,
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
/// machine's agent): a ChatGPT plan, an Anthropic or OpenAI key. The Mac's
/// CLI logins and added subscription accounts serve local chats only.
pub(super) fn serves_cloud(kind: &str, provider: &str) -> bool {
    match kind {
        "chatgpt-plan" | "grok-plan" | "copilot-plan" | "kimi-plan" => true,
        "api-key" => matches!(
            provider,
            "anthropic" | "openai" | "openrouter" | "google" | "vertex-express" | "xai"
        ),
        _ => false,
    }
}

fn token_expired(expires_at: Option<u64>) -> bool {
    expires_at.is_some_and(|expiry| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .is_ok_and(|time| time.as_secs() >= expiry)
    })
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
    let openrouter = facts.kind == "api-key" && facts.provider == "openrouter";
    let native = route.native_key_provider();
    let standard_endpoint = standard_key_endpoint(&route.file).is_some();
    let can_check_access = standard_endpoint && facts.provider != "vertex-express";
    let mut families = facts.families;
    if openrouter && can_check_access && !families.iter().any(|family| family == "openrouter") {
        families.push("openrouter".into());
    }
    let can_serve_cloud =
        serves_cloud(facts.kind, &facts.provider) && (facts.kind != "api-key" || standard_endpoint);
    Connection {
        id: route.id.clone(),
        kind: facts.kind,
        provider: facts.provider,
        families,
        label: route.name(),
        email: facts.email,
        plan: facts.plan,
        signed_in: facts.signed_in && !token_expired(route.file.claude_token_expires_at),
        sign_in_reason: None,
        enabled: !route.file.disabled,
        default_for,
        serves_cloud: can_serve_cloud && route.file.cloud_enabled != Some(false),
        can_serve_cloud,
        can_check_access,
        can_replace_key: standard_endpoint.then_some(true),
        endpoint: None,
        expires_at: route.file.claude_token_expires_at,
        endpoint_credentials: (openrouter
            || native.is_some()
            || matches!(
                route.file.kind,
                RouteKind::GrokPlan | RouteKind::CopilotPlan | RouteKind::KimiPlan
            ))
        .then_some(true),
        cloud_families: native
            .map(|provider| vec![provider.name().into()])
            .or_else(|| openrouter.then(|| vec!["claude".into(), "openrouter".into()])),
        launch_harness: native
            .map(|provider| provider.name())
            .or_else(|| openrouter.then_some("claude"))
            .or_else(|| {
                crate::subscriptions::Provider::for_kind(route.file.kind).map(|provider| {
                    if provider.family() == "github-copilot" {
                        "opencode"
                    } else {
                        provider.family()
                    }
                })
            }),
    }
}

/// Read the endpoint fields without resolving its Keychain reference.
fn endpoint_fields(profile: &HarnessProfile) -> Option<EndpointFields> {
    let kind = Kind::of_env(&profile.env)?;
    let models = profile
        .models
        .iter()
        .map(|model| {
            let id = model.id();
            match kind {
                Kind::OpenAi => id.strip_prefix("byo/").unwrap_or(id),
                Kind::Anthropic => id,
            }
            .to_owned()
        })
        .collect::<Vec<_>>();
    let config;
    let base_url = match kind {
        Kind::Anthropic => profile.env.get("ANTHROPIC_BASE_URL")?,
        Kind::OpenAi => {
            config =
                serde_json::from_str::<Value>(profile.env.get("OPENCODE_CONFIG_CONTENT")?).ok()?;
            config["provider"][byo_endpoint::OPENCODE_PROVIDER]["options"]["baseURL"].as_str()?
        }
    };
    let base_url = byo_endpoint::check_base_url(base_url).ok()?;
    Some(EndpointFields {
        kind: match kind {
            Kind::Anthropic => "anthropic-endpoint",
            Kind::OpenAi => "openai-endpoint",
        },
        base_url,
        models,
        preset: None,
        revision: None,
    })
}

/// Read endpoint metadata from the profile that already owns the Keychain reference.
fn profile_endpoint<'a>(
    id: &str,
    profile: &'a HarnessProfile,
) -> Option<(LaunchEndpoint, Option<&'a str>)> {
    let kind = Kind::of_env(&profile.env)?;
    let fields = endpoint_fields(profile)?;
    let reference = profile
        .env
        .get(kind.secret_key())
        .and_then(|value| value.strip_prefix("${"))
        .and_then(|value| value.strip_suffix('}'))
        .filter(|reference| {
            let Some(item) = reference.strip_prefix("keychain:") else { return false };
            let (service, account) = item
                .split_once('/')
                .map_or((item, None), |(service, account)| (service, Some(account)));
            !byo_endpoint::is_own_service(service)
                || account.is_some_and(|account| byo_endpoint::is_own_account(account, Some(id)))
        });
    Some((LaunchEndpoint::checked(kind, &fields.base_url, &fields.models)?, reference))
}

fn endpoint_connection(
    id: &str,
    profile: &HarnessProfile,
    display_name: Option<&str>,
    revision: Option<String>,
    cloud_enabled: Option<bool>,
    preset: Option<String>,
) -> Option<Connection> {
    let kind = Kind::of_env(&profile.env)?;
    let has_key = profile
        .env
        .get(kind.secret_key())
        .is_some_and(|value| value.starts_with("${keychain:") && value.ends_with('}'));
    let can_serve_cloud =
        profile_endpoint(id, profile).is_some_and(|(_, reference)| reference.is_some());
    Some(Connection {
        id: id.to_owned(),
        kind: "endpoint",
        provider: id.to_owned(),
        families: vec![id.to_owned()],
        label: display_name.unwrap_or(id).to_owned(),
        email: None,
        plan: None,
        signed_in: has_key,
        sign_in_reason: None,
        enabled: true,
        default_for: vec![],
        serves_cloud: can_serve_cloud && cloud_enabled != Some(false),
        can_serve_cloud,
        can_check_access: false,
        can_replace_key: None,
        endpoint: revision.and_then(|revision| {
            let mut fields = endpoint_fields(profile)?;
            if !byo_endpoint::check_models(&fields.models)
                .is_ok_and(|models| models == fields.models)
            {
                return None;
            }
            fields.revision = Some(revision);
            fields.preset = preset;
            Some(fields)
        }),
        expires_at: None,
        endpoint_credentials: Some(true),
        cloud_families: None,
        launch_harness: Some(kind.harness()),
    })
}

/// Every connection, in the listing order the default order sorts (stably): the Codex CLI's
/// login, the routes by id, the Claude Code login.
fn list(
    dir: Option<&Path>,
    home: &Path,
    b: &Bindings,
    sources: &ProfileSources,
) -> Vec<Connection> {
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
    let records: HashMap<String, chatgpt::store::Metadata> =
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
                    signed_in: record.is_some_and(chatgpt::store::Metadata::signed_in),
                    email: record.and_then(|r| r.email.clone()),
                    plan: record.and_then(|r| r.plan.clone()),
                    builtin: false,
                }
            }
            RouteKind::GrokPlan | RouteKind::CopilotPlan | RouteKind::KimiPlan => {
                let Some(provider) = crate::subscriptions::Provider::for_kind(file.kind) else {
                    continue;
                };
                Facts {
                    kind: file.kind.as_str(),
                    provider: if provider == crate::subscriptions::Provider::Kimi {
                        "kimi-code"
                    } else {
                        provider.name()
                    }
                    .into(),
                    families: file.families.clone(),
                    signed_in: provider.signed_in(home, &route.id),
                    email: provider.login(home, &route.id),
                    plan: None,
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
            claude_token_expires_at: None,
            cloud_enabled: None,
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
    for (id, (profile, meta)) in config::profiles::load(sources).profiles {
        let editable = meta.source == config::profiles::ProfileSource::UserFile
            && sources.user_dir.as_ref().is_some_and(|dir| {
                Path::new(&meta.source_path) == dir.join(format!("{id}.toml")).as_path()
            });
        if out.iter().all(|connection| connection.id != id)
            && let Some(endpoint) = endpoint_connection(
                &id,
                &profile,
                meta.display_name.as_deref(),
                if editable { meta.content_revision } else { None },
                meta.cloud_enabled,
                meta.endpoint_preset,
            )
        {
            out.push(endpoint);
        }
    }
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
fn state(dir: Option<&Path>, home: &Path, sources: &ProfileSources) -> Value {
    let b = routes::bindings(home);
    let mut connections = list(dir, home, &b, sources);
    for connection in &mut connections {
        if !connection.signed_in {
            continue;
        }
        let available = if connection.kind == "chatgpt-plan" {
            chatgpt::store::available(home, &connection.id)
        } else if let Some(provider) =
            RouteKind::parse(connection.kind).and_then(crate::subscriptions::Provider::for_kind)
        {
            provider.available(home, &connection.id)
        } else {
            continue;
        };
        match available {
            Err(error @ crate::subscription_store::Error::KeychainOtherBuild) => {
                connection.signed_in = false;
                connection.sign_in_reason = Some(error.code());
            }
            Ok(false) => connection.signed_in = false,
            _ => {}
        }
    }
    json!({
        "connections": ordered(connections, &b.connection_order),
        "spread": b.spread.unwrap_or(true),
        "order_explicit": !b.connection_order.is_empty(),
    })
}

fn route_error(e: &routes::RouteError) -> RpcError {
    crate::hub::route_error(e)
}

/// Stores the person's order of managed connections, ignoring detected sign-ins.
pub(super) fn set_order(
    dir: Option<&Path>,
    home: &Path,
    ids: &[String],
    sources: &ProfileSources,
) -> Result<Value, RpcError> {
    let known: BTreeSet<String> =
        list(dir, home, &routes::bindings(home), sources).into_iter().map(|c| c.id).collect();
    let mut seen = BTreeSet::new();
    let mut order = Vec::new();
    for id in ids {
        if !known.contains(id) {
            if NATIVE_SIGN_INS.iter().any(|(_, native_id, _)| id.as_str() == *native_id) {
                continue;
            }
            return Err(RpcError::invalid_params(format!("no connection {id:?}"))
                .with_data(json!({"reason": "connections.unknown_id", "id": id})));
        }
        if !seen.insert(id) {
            return Err(RpcError::invalid_params(format!("{id:?} is listed twice"))
                .with_data(json!({"reason": "connections.duplicate_id", "id": id})));
        }
        order.push(id.clone());
    }
    routes::update_bindings(home, |b| b.connection_order = order).map_err(|e| route_error(&e))?;
    Ok(state(dir, home, sources))
}

fn set_spread(
    dir: Option<&Path>,
    home: &Path,
    on: bool,
    sources: &ProfileSources,
) -> Result<Value, RpcError> {
    routes::update_bindings(home, |b| b.spread = Some(on)).map_err(|e| route_error(&e))?;
    Ok(state(dir, home, sources))
}

/// Adds a provider API key whose secret is a reference (`keychain:ITEM`); never the key.
pub(super) fn add_key(
    dir: Option<&Path>,
    home: &Path,
    provider_id: &str,
    secret: &str,
    label: Option<&str>,
    sources: &ProfileSources,
    cloud_enabled: Option<bool>,
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
        claude_token_expires_at: None,
        cloud_enabled,
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
    Ok((id, state(dir, home, sources)))
}

/// Replace a standard provider key in its existing route.
fn replace_key(
    dir: Option<&Path>,
    home: &Path,
    id: &str,
    provider: &str,
    secret: &str,
    sources: &ProfileSources,
) -> Result<Value, RpcError> {
    let (_, previous) = routes::edit(dir, id, |file| {
        if file.provider.as_deref() != Some(provider) || standard_key_endpoint(file).is_none() {
            return Err(routes::RouteError::BadParams(
                "replacement needs a matching API-key connection".into(),
            ));
        }
        Ok(file.secret.replace(secret.to_owned()))
    })
    .map_err(|e| route_error(&e))?;
    let mut result = state(dir, home, sources);
    if let Some(reference) = previous.filter(|reference| {
        reference.starts_with(&format!("keychain:cmux-model-key/{provider}-"))
            && !routes::load(dir)
                .0
                .iter()
                .any(|route| route.file.secret.as_ref() == Some(reference))
    }) {
        result["replaced_secret"] = json!(reference);
    }
    Ok(result)
}

/// What a Cloud machine's agent needs from a secret-reference connection: its family, kind,
/// the variable it is delivered in and the reference. A ChatGPT plan is not one (its token is
/// the daemon's own, `chatgpt::Service::token_lasting`).
pub(super) fn credential_plan(
    dir: Option<&Path>,
    home: &Path,
    id: &str,
) -> Result<(String, &'static str, &'static str, Option<String>), RpcError> {
    let found = list(dir, home, &routes::bindings(home), &ProfileSources::none())
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
    if token_expired(found.expires_at) {
        return Err(RpcError::invalid_params("Claude Cloud access has expired")
            .with_data(json!({"reason": "connections.expired", "id": id})));
    }
    if found.endpoint_credentials == Some(true) && found.provider == "openrouter" {
        return Err(not_cloud(id));
    }
    let family = found
        .cloud_families
        .as_ref()
        .unwrap_or(&found.families)
        .first()
        .cloned()
        .unwrap_or_default();
    let var = match (found.kind, found.provider.as_str()) {
        ("api-key", "google") => "GEMINI_API_KEY",
        ("api-key", "vertex-express") => "GOOGLE_API_KEY",
        ("api-key", "xai") => "XAI_API_KEY",
        ("grok-plan" | "copilot-plan", provider) => {
            let provider = crate::subscriptions::Provider::parse(provider)
                .ok_or_else(|| RpcError::invalid_params("invalid subscription provider"))?;
            return Ok((family, found.kind, provider.credential(), None));
        }
        ("chatgpt-plan", _) => {
            return Ok((family, "chatgpt-plan", "CMUX_CHATGPT_ACCESS_TOKEN", None));
        }
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

fn not_cloud(id: &str) -> RpcError {
    RpcError::invalid_params(format!("{id} does not serve Cloud chats"))
        .with_data(json!({"reason": "connections.not_cloud", "id": id}))
}

struct EndpointPlan {
    endpoint: LaunchEndpoint,
    reference: String,
    model: String,
}

#[cfg(test)]
fn endpoint_plan(
    dir: Option<&Path>,
    id: &str,
    model: Option<&str>,
    profiles: &config::profiles::LoadedProfiles,
) -> Result<Option<EndpointPlan>, RpcError> {
    endpoint_plan_with_catalog(dir, id, model, profiles, None)
}

fn endpoint_plan_with_catalog(
    dir: Option<&Path>,
    id: &str,
    model: Option<&str>,
    profiles: &config::profiles::LoadedProfiles,
    catalog: Option<&crate::catalog::Catalog>,
) -> Result<Option<EndpointPlan>, RpcError> {
    if let Ok(route) = routes::find(dir, id) {
        if route.file.kind != RouteKind::DirectApiKey || route.file.provider() != "openrouter" {
            return Ok(None);
        }
        if route.file.cloud_enabled == Some(false) {
            return Err(not_cloud(id));
        }
        if route.file.disabled {
            return Err(RpcError::invalid_params(format!("{id} is turned off"))
                .with_data(json!({"reason": "connections.disabled", "id": id})));
        }
        let Some((_, reference)) =
            standard_key_endpoint(&route.file).zip(route.file.secret.as_deref())
        else {
            return Err(not_cloud(id));
        };
        let openai_model = model.and_then(|model| {
            model.strip_prefix("openrouter/").or_else(|| model.strip_prefix("byo/")).or_else(|| {
                (model.contains('/') && !model.starts_with("anthropic/")).then_some(model)
            })
        });
        if let Some(model) = openai_model {
            let (base, kind) = standard_key_endpoint(&route.file).ok_or_else(|| not_cloud(id))?;
            let endpoint = LaunchEndpoint::checked(kind, base, &[model.to_owned()])
                .ok_or_else(|| not_cloud(id))?;
            let model = endpoint_launch_model(&endpoint, None)?;
            return Ok(Some(EndpointPlan { endpoint, reference: reference.to_owned(), model }));
        }
        let model = match model.unwrap_or("default") {
            alias @ ("default" | "sonnet" | "opus" | "haiku") => {
                let bundled;
                let catalog = match catalog {
                    Some(catalog) => catalog,
                    None => {
                        bundled = crate::catalog::CatalogService::new().current();
                        &bundled
                    }
                };
                let claude = catalog
                    .harnesses
                    .iter()
                    .find(|harness| harness.id == "claude")
                    .ok_or_else(|| not_cloud(id))?;
                let model = if alias == "default" {
                    claude
                        .default_model
                        .as_deref()
                        .and_then(|id| claude.models.iter().find(|model| model.id == id))
                } else {
                    claude.models.iter().find(|model| {
                        model
                            .family
                            .as_deref()
                            .is_some_and(|family| family.eq_ignore_ascii_case(alias))
                    })
                };
                let model = model
                    .and_then(|model| model.reference.as_deref().or(Some(model.id.as_str())))
                    .ok_or_else(|| not_cloud(id))?;
                if model.starts_with("anthropic/") {
                    model.to_owned()
                } else {
                    format!("anthropic/{model}")
                }
            }
            id if id.contains('/') => id.to_owned(),
            id if id.starts_with("claude-") => {
                let words = id.split('-').collect::<Vec<_>>();
                match words.as_slice() {
                    ["claude", family, major, minor, ..] if minor.len() == 1 => {
                        format!("anthropic/claude-{family}-{major}.{minor}")
                    }
                    _ => format!("anthropic/{id}"),
                }
            }
            _ => {
                return Err(RpcError::invalid_params(
                    "this model is unavailable on the connection",
                ));
            }
        };
        let base_url =
            provider("openrouter").and_then(|p| p.anthropic).ok_or_else(|| not_cloud(id))?;
        let endpoint = LaunchEndpoint::checked(Kind::Anthropic, base_url, &[model])
            .ok_or_else(|| not_cloud(id))?;
        let model = endpoint_launch_model(&endpoint, None)?;
        return Ok(Some(EndpointPlan { endpoint, reference: reference.to_owned(), model }));
    }
    let Some((profile, meta)) = profiles.profiles.get(id) else { return Ok(None) };
    if Kind::of_env(&profile.env).is_none() {
        return Ok(None);
    }
    if meta.cloud_enabled == Some(false) {
        return Err(not_cloud(id));
    }
    let (endpoint, reference) = profile_endpoint(id, profile).ok_or_else(|| not_cloud(id))?;
    let reference = reference.ok_or_else(|| not_cloud(id))?;
    let model = endpoint_launch_model(&endpoint, model)?;
    Ok(Some(EndpointPlan { endpoint, reference: reference.to_owned(), model }))
}

fn endpoint_launch_model(
    endpoint: &LaunchEndpoint,
    picked: Option<&str>,
) -> Result<String, RpcError> {
    let prefix = if endpoint.kind == Kind::OpenAi { "byo/" } else { "" };
    let model = match picked {
        Some(id) => endpoint
            .models
            .iter()
            .find(|model| id == model.as_str() || id.strip_prefix(prefix) == Some(model.as_str())),
        None => endpoint.models.first(),
    }
    .ok_or_else(|| {
        RpcError::invalid_params(
            "This connection cannot use this model. Choose another model or connection.",
        )
        .with_data(json!({"reason": "connections.model_unavailable"}))
    })?;
    Ok(format!("{prefix}{model}"))
}

fn endpoint_reply(plan: &EndpointPlan, value: &str) -> Result<Value, RpcError> {
    launch_endpoint_reply(&plan.endpoint, &plan.model, value, None)
}

fn launch_endpoint_reply(
    endpoint: &LaunchEndpoint,
    model: &str,
    value: &str,
    expires_at: Option<i64>,
) -> Result<Value, RpcError> {
    let harness = endpoint.harness();
    let wire = json!({"env": {endpoint.kind.secret_key(): value}, "endpoint": endpoint});
    AgentCredential::parse(&wire)?;
    Ok(json!({
        "family": harness, "kind": "endpoint", "harness": harness, "model": model,
        "env": wire["env"], "endpoint": wire["endpoint"], "expires_at": expires_at,
    }))
}

fn unreachable_kind(id: &str) -> Result<&'static str, RpcError> {
    Err(RpcError::invalid_params(format!("{id} does not serve Cloud chats"))
        .with_data(json!({"reason": "connections.not_cloud", "id": id})))
}

/// The secret a reference names; the error says why it did not resolve, never a value.
fn resolve(id: &str, reference: &str) -> Result<String, RpcError> {
    routes::resolve_reference(reference).map_err(|why| {
        RpcError::invalid_params(format!("{id}'s secret did not resolve: {why}"))
            .with_data(json!({"reason": "connections.secret_unresolved", "id": id}))
    })
}

fn subscription_failure(code: crate::subscriptions::Failure) -> RpcError {
    let message = if code == "keychain_other_build" {
        crate::subscription_store::Error::KeychainOtherBuild.message()
    } else {
        "Subscription sign-in is unavailable"
    };
    RpcError::new(-32000, message)
        .with_data(json!({"reason": format!("subscription.{code}"), "code": code}))
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

const NATIVE_SIGN_INS: [(Agent, &str, &str); 3] = [
    (Agent::Gemini, "gemini-login", "Gemini CLI"),
    (Agent::Grok, "grok-native-login", "Grok Build"),
    (Agent::Cursor, "cursor-native-login", "Cursor"),
];

/// The CLI owns these credentials. They appear in Models without a route or a Cloud credential.
fn native_sign_in(agent: Agent, id: &str, label: &str, cli: &Cli) -> Option<Connection> {
    cli.has_stored_sign_in(agent).then(|| Connection {
        id: id.into(),
        kind: "native-login",
        provider: agent.name().into(),
        families: vec![agent.name().into()],
        label: label.into(),
        email: None,
        plan: None,
        signed_in: true,
        sign_in_reason: None,
        enabled: true,
        default_for: vec![],
        serves_cloud: false,
        can_serve_cloud: false,
        can_check_access: false,
        can_replace_key: None,
        endpoint: None,
        expires_at: None,
        endpoint_credentials: None,
        cloud_families: None,
        launch_harness: None,
    })
}

async fn include_native_sign_ins(hub: &Hub, mut state: Value) -> Value {
    let Some(connections) = state.get_mut("connections").and_then(Value::as_array_mut) else {
        return state;
    };
    let config = hub.config.read().await.clone();
    if let Ok((rows, claude_available)) = blocking(move || {
        let claude_available = cfg!(target_os = "macos") && installed_claude_cli(&config).is_some();
        let rows = NATIVE_SIGN_INS
            .into_iter()
            .filter_map(|(agent, id, label)| {
                let cli = super::agent_login::cli_for(&config, agent, None)?;
                native_sign_in(agent, id, label, &cli)
            })
            .collect::<Vec<_>>();
        (rows, claude_available)
    })
    .await
    {
        for row in rows {
            if !connections
                .iter()
                .any(|connection| connection["id"].as_str() == Some(row.id.as_str()))
            {
                connections.push(json!(row));
            }
        }
        state["claude_code_available"] = json!(claude_available);
    }
    state
}

fn installed_claude_cli(config: &config::Config) -> Option<Cli> {
    let mut cli = super::agent_login::cli_for(config, Agent::Claude, None)?;
    let program = Path::new(&cli.program);
    if program.is_absolute() {
        return crate::harness_install::is_executable(program).then_some(cli);
    }
    cli.program = config::which(&cli.program)?;
    Some(cli)
}

/// Sends the current state to watching connections.
async fn announce(hub: &Arc<Hub>) {
    let (dir, home, sources) = places(hub).await;
    if let Ok(state) = blocking(move || state(dir.as_deref(), &home, &sources)).await {
        let state = include_native_sign_ins(hub, state).await;
        hub.send_watch_note(json!({ CONNECTIONS_NOTE: state }));
    }
}

/// `announce` without holding up the caller's answer.
pub(crate) fn announce_later(hub: &Arc<Hub>) {
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
fn connection_state(dir: Option<&Path>, home: &Path, id: &str, sources: &ProfileSources) -> Value {
    let b = routes::bindings(home);
    let found = list(dir, home, &b, sources).into_iter().find(|c| c.id == id);
    json!({"connection": found})
}

async fn places(hub: &Hub) -> (Option<PathBuf>, PathBuf, ProfileSources) {
    let config = hub.config.read().await;
    let (dir, home) = routes::places(&config);
    (dir, home, config.profile_sources.clone())
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
    let (dir, home, sources) = places(hub).await;
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    let need = |key: &str| {
        text(key)
            .map(str::to_owned)
            .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
    };
    match m {
        method::MUX_CONNECTIONS => {
            let state = blocking(move || state(dir.as_deref(), &home, &sources)).await?;
            Ok(include_native_sign_ins(hub, state).await)
        }
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
            let state =
                blocking(move || set_order(dir.as_deref(), &home, &ids, &sources)).await??;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_SPREAD_SET => {
            let on = params
                .get("on")
                .and_then(Value::as_bool)
                .ok_or_else(|| RpcError::invalid_params("on is required (true or false)"))?;
            let state = blocking(move || set_spread(dir.as_deref(), &home, on, &sources)).await??;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_KEY_ADD => {
            let provider = need("provider")?;
            let secret = need("secret")?;
            let label = text("label").map(str::to_owned);
            let replace = text("replace").map(str::to_owned);
            let cloud_enabled = params
                .get("servesCloud")
                .map(|value| {
                    value
                        .as_bool()
                        .ok_or_else(|| RpcError::invalid_params("servesCloud must be a boolean"))
                })
                .transpose()?;
            let state = blocking(move || {
                if let Some(id) = replace {
                    replace_key(dir.as_deref(), &home, &id, &provider, &secret, &sources)
                } else {
                    add_key(
                        dir.as_deref(),
                        &home,
                        &provider,
                        &secret,
                        label.as_deref(),
                        &sources,
                        cloud_enabled,
                    )
                    .map(|(_, state)| state)
                }
            })
            .await??;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_REMOVE => {
            let id = need("id")?;
            let (d, h, i) = (dir.clone(), home.clone(), id.clone());
            let found = blocking(move || {
                list(d.as_deref(), &h, &routes::bindings(&h), &ProfileSources::none())
                    .into_iter()
                    .find(|c| c.id == i)
            })
            .await?
            .ok_or_else(|| RpcError::not_found(format!("no connection {id:?}")))?;
            if let Some(provider) = crate::routes::RouteKind::parse(found.kind)
                .and_then(crate::subscriptions::Provider::for_kind)
            {
                hub.subscriptions
                    .remove(
                        provider,
                        chatgpt::Places { routes: dir.clone(), home: home.clone() },
                        id,
                    )
                    .await
                    .map_err(subscription_failure)?;
                let state = blocking(move || state(dir.as_deref(), &home, &sources)).await?;
                announce_later(hub);
                return Ok(include_native_sign_ins(hub, state).await);
            }
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
            let state = blocking(move || {
                let legacy = if found.kind == "claude-token" {
                    routes::find(dir.as_deref(), &id).ok().and_then(|route| route.file.secret)
                } else {
                    None
                };
                routes::remove(dir.as_deref(), &home, &id).map_err(|e| route_error(&e))?;
                let mut result = state(dir.as_deref(), &home, &sources);
                if let Some(reference) = legacy.filter(|reference| {
                    reference.starts_with("keychain:cmux-model-key/claude-token-")
                        && !routes::load(dir.as_deref())
                            .0
                            .iter()
                            .any(|route| route.file.secret.as_ref() == Some(reference))
                }) {
                    result["replaced_secret"] = json!(reference);
                }
                Ok::<_, RpcError>(result)
            })
            .await??;
            announce_later(hub);
            Ok(state)
        }
        method::MUX_CONNECTIONS_SUBSCRIPTION_BEGIN => {
            let name = need("provider")?;
            let owner = Arc::downgrade(hub);
            let on_finish = move || {
                if let Some(hub) = owner.upgrade() {
                    announce_later(&hub);
                }
            };
            if matches!(name.as_str(), "grok" | "copilot") {
                return Err(RpcError::invalid_params("This subscription cannot be connected here"));
            }
            let provider = crate::subscriptions::Provider::parse(&name)
                .ok_or_else(|| RpcError::invalid_params("invalid subscription provider"))?;
            let region = text("region")
                .map(|value| {
                    crate::subscriptions::KimiRegion::parse(value)
                        .ok_or_else(|| RpcError::invalid_params("invalid Kimi Code region"))
                })
                .transpose()?;
            let challenge = hub
                .subscriptions
                .begin(
                    provider,
                    chatgpt::Places { routes: dir, home },
                    text("id").map(str::to_owned),
                    region,
                    on_finish,
                )
                .await
                .map_err(subscription_failure)?;
            Ok(json!({"attempt": challenge.attempt, "verification_url": challenge.url,
            "user_code": challenge.user_code, "expires_at": challenge.expires_at, "interval": challenge.interval}))
        }
        method::MUX_CONNECTIONS_SUBSCRIPTION_WAIT | method::MUX_CONNECTIONS_SUBSCRIPTION_CANCEL => {
            use crate::subscriptions::Status;
            let attempt = need("attempt")?;
            let status = if m == method::MUX_CONNECTIONS_SUBSCRIPTION_WAIT {
                hub.subscriptions.wait(&attempt, WAIT_LIMIT).await
            } else {
                hub.subscriptions.cancel(&attempt).await
            }
            .map_err(subscription_failure)?;
            Ok(match status {
                Status::Pending => json!({"status": "pending"}),
                Status::Done(id) => json!({"status": "done", "connection_id": id}),
                Status::Cancelled => json!({"status": "cancelled"}),
                Status::Failed(code) => json!({"status": "failed", "error": code}),
            })
        }
        method::MUX_CONNECTIONS_CHATGPT_BEGIN | method::MUX_CONNECTIONS_CHATGPT_DEVICE_BEGIN => {
            let reauth = text("id").map(str::to_owned);
            if let Some(id) = reauth.clone() {
                let lookup_dir = dir.clone();
                blocking(move || {
                    let route =
                        routes::find(lookup_dir.as_deref(), &id).map_err(|e| route_error(&e))?;
                    if route.file.kind != RouteKind::ChatgptPlan {
                        return Err(RpcError::invalid_params("id is not a ChatGPT sign-in"));
                    }
                    Ok(())
                })
                .await??;
            }
            let places = chatgpt::Places { routes: dir, home };
            let announcer = hub.clone();
            let finished = move |status: &chatgpt::Status| {
                if matches!(status, chatgpt::Status::Done(_)) {
                    announce_later(&announcer);
                }
            };
            if m == method::MUX_CONNECTIONS_CHATGPT_DEVICE_BEGIN {
                let begun =
                    hub.chatgpt.begin_device(places, reauth, finished).await.map_err(failure)?;
                Ok(json!({
                    "attempt": begun.attempt, "user_code": begun.user_code,
                    "verification_url": begun.verification_url,
                    "expires_at": begun.expires_at, "interval": begun.interval,
                }))
            } else {
                let begun = hub.chatgpt.begin(places, reauth, finished).await.map_err(failure)?;
                Ok(json!({"attempt": begun.attempt, "url": begun.url}))
            }
        }
        method::MUX_CONNECTIONS_CHATGPT_WAIT | method::MUX_CONNECTIONS_CHATGPT_DEVICE_WAIT => {
            let attempt = need("attempt")?;
            let status = if m == method::MUX_CONNECTIONS_CHATGPT_DEVICE_WAIT {
                hub.chatgpt.wait_device(&attempt, WAIT_LIMIT).await
            } else {
                hub.chatgpt.wait(&attempt, WAIT_LIMIT).await
            }
            .map_err(failure)?;
            let connection = match &status {
                chatgpt::Status::Done(id) => {
                    let id = id.clone();
                    blocking(move || {
                        let b = routes::bindings(&home);
                        list(dir.as_deref(), &home, &b, &ProfileSources::none())
                            .into_iter()
                            .find(|c| c.id == id)
                    })
                    .await?
                }
                _ => None,
            };
            let error = match &status {
                chatgpt::Status::Failed(code) => Some(code.clone()),
                _ => None,
            };
            if let chatgpt::Status::WrongAccount { actual, expected } = &status {
                return Ok(json!({"status": "failed", "error": "different_account",
                    "actual": actual, "expected": expected}));
            }
            Ok(json!({"status": status.as_str(), "connection": connection, "error": error}))
        }
        method::MUX_CONNECTIONS_CHATGPT_CANCEL | method::MUX_CONNECTIONS_CHATGPT_DEVICE_CANCEL => {
            let attempt = need("attempt")?;
            if m == method::MUX_CONNECTIONS_CHATGPT_DEVICE_CANCEL {
                let status = hub.chatgpt.cancel_device(&attempt).await.map_err(failure)?;
                let id = match &status {
                    chatgpt::Status::Done(id) => Some(id),
                    _ => None,
                };
                return Ok(
                    json!({"attempt": attempt, "status": status.as_str(), "connection_id": id}),
                );
            }
            let status = hub.chatgpt.cancel(&attempt).await.map_err(failure)?;
            Ok(json!({"attempt": attempt, "status": status.as_str()}))
        }
        method::MUX_CONNECTIONS_CREDENTIAL => {
            let id = need("id")?;
            let (d, i) = (dir.clone(), id.clone());
            let kimi_route = blocking(move || {
                routes::find(d.as_deref(), &i)
                    .ok()
                    .filter(|route| route.file.kind == RouteKind::KimiPlan)
            })
            .await?;
            if let Some(route) = kimi_route {
                if route.file.disabled || route.file.cloud_enabled == Some(false) {
                    return Err(not_cloud(&id));
                }
                let models = [crate::subscriptions::KIMI_MODEL.to_owned()];
                let picked = text("model").filter(|model| *model != "default");
                let (token, expiry, region) = hub
                    .subscriptions
                    .grant(
                        crate::subscriptions::Provider::Kimi,
                        &home,
                        &id,
                        chatgpt::CREDENTIAL_MARGIN_SECS,
                    )
                    .await
                    .map_err(|code| {
                        if matches!(code, "reauth_required" | "signed_out") {
                            announce_later(hub);
                        }
                        subscription_failure(code)
                    })?;
                let region = region.ok_or_else(|| subscription_failure("reauth_required"))?;
                let endpoint = LaunchEndpoint::checked(Kind::OpenAi, region.base_url(), &models)
                    .ok_or_else(|| not_cloud(&id))?;
                let model = endpoint_launch_model(&endpoint, picked)?;
                return launch_endpoint_reply(&endpoint, &model, &token, Some(expiry));
            }
            if text("model") == Some("openrouter/default") {
                let (folder, route_id) = (dir.clone(), id.clone());
                let (base, kind, value) = blocking(move || {
                    let route = routes::find(folder.as_deref(), &route_id)
                        .map_err(|error| route_error(&error))?;
                    if !route.is_openrouter()
                        || route.file.disabled
                        || route.file.cloud_enabled == Some(false)
                    {
                        return Err(not_cloud(&route_id));
                    }
                    let (base, kind) =
                        standard_key_endpoint(&route.file).ok_or_else(|| not_cloud(&route_id))?;
                    let reference =
                        route.file.secret.as_deref().ok_or_else(|| not_cloud(&route_id))?;
                    let value = resolve(&route_id, reference)?;
                    Ok((base, kind, zeroize::Zeroizing::new(value)))
                })
                .await??;
                let models = crate::byo_endpoint::fetch_model_list(
                    kind,
                    "https://openrouter.ai/api/v1/models/user",
                    Some(value.as_str()),
                    crate::byo_endpoint::FETCH_TIMEOUT,
                )
                .await
                .map_err(|_| {
                    RpcError::invalid_params("OpenRouter did not list an available model.")
                        .with_data(json!({"reason": "connections.model_unavailable"}))
                })?;
                let endpoint = LaunchEndpoint::checked(kind, base, &models[..models.len().min(1)])
                    .ok_or_else(|| not_cloud(&id))?;
                let model = endpoint_launch_model(&endpoint, None)?;
                return launch_endpoint_reply(&endpoint, &model, &value, None);
            }
            let (d, h, i) = (dir.clone(), home.clone(), id.clone());
            let (family, kind, var, reference) = {
                let model = text("model").map(str::to_owned);
                let endpoint_id = id.clone();
                let endpoint_dir = dir.clone();
                let catalog = hub.catalog.current();
                if let Some(reply) = blocking(move || {
                    let profiles = config::profiles::load(&sources);
                    endpoint_plan_with_catalog(
                        endpoint_dir.as_deref(),
                        &endpoint_id,
                        model.as_deref(),
                        &profiles,
                        Some(&catalog),
                    )?
                    .map(|plan| {
                        let value = resolve(&endpoint_id, &plan.reference)?;
                        endpoint_reply(&plan, &value)
                    })
                    .transpose()
                })
                .await??
                {
                    return Ok(reply);
                }
                blocking(move || credential_plan(d.as_deref(), &h, &i)).await??
            };
            let (value, expires_at) = match reference {
                None if matches!(kind, "grok-plan" | "copilot-plan") => {
                    let provider = RouteKind::parse(kind)
                        .and_then(crate::subscriptions::Provider::for_kind)
                        .ok_or_else(|| RpcError::invalid_params("invalid subscription provider"))?;
                    let (token, expiry) = hub
                        .subscriptions
                        .token(provider, &home, &id, chatgpt::CREDENTIAL_MARGIN_SECS)
                        .await
                        .map_err(|code| {
                            if matches!(code, "reauth_required" | "signed_out") {
                                announce_later(hub);
                            }
                            subscription_failure(code)
                        })?;
                    if provider == crate::subscriptions::Provider::Copilot
                        && let Err(code @ ("reauth_required" | "no_copilot_access")) =
                            crate::subscriptions::copilot_endpoint(&token).await
                    {
                        #[cfg(unix)]
                        if code == "reauth_required" {
                            crate::subscriptions::Provider::forget_lapsed_copilot(home, id, token)
                                .await
                                .map_err(subscription_failure)?;
                            announce_later(hub);
                        }
                        return Err(subscription_failure(code));
                    }
                    (token, (expiry > 0).then_some(expiry))
                }
                None => {
                    let (token, expires_at) = hub
                        .chatgpt
                        .token_lasting(&home, &id, chatgpt::CREDENTIAL_MARGIN_SECS)
                        .await
                        .map_err(|error| {
                            if matches!(error.code.as_str(), "reauth_required" | "signed_out") {
                                announce_later(hub);
                            }
                            failure(error)
                        })?;
                    (token, Some(expires_at))
                }
                // The keychain may ask: off the runtime's threads.
                Some(reference) => (blocking(move || resolve(&id, &reference)).await??, None),
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
            blocking(move || connection_state(dir.as_deref(), &home, &id, &sources)).await
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
            sign_in_reason: None,
            enabled: true,
            default_for: default_for.iter().map(|f| (*f).to_owned()).collect(),
            serves_cloud: true,
            can_serve_cloud: true,
            can_check_access: kind == "api-key",
            can_replace_key: None,
            endpoint: None,
            expires_at: None,
            endpoint_credentials: None,
            cloud_families: None,
            launch_harness: None,
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
        let (_, _) = add_key(
            Some(&d.routes),
            &d.home,
            "anthropic",
            "keychain:cmux-test-key",
            None,
            &ProfileSources::none(),
            None,
        )
        .unwrap();
        let error =
            set_order(Some(&d.routes), &d.home, &["nope".to_owned()], &ProfileSources::none())
                .unwrap_err();
        assert_eq!(error.data.as_ref().unwrap()["reason"], "connections.unknown_id");
        assert!(routes::bindings(&d.home).connection_order.is_empty(), "nothing stored");
        let twice = vec!["anthropic-key".to_owned(), "anthropic-key".to_owned()];
        assert!(set_order(Some(&d.routes), &d.home, &twice, &ProfileSources::none()).is_err());

        let state = set_order(
            Some(&d.routes),
            &d.home,
            &[
                "cursor-native-login".to_owned(),
                "anthropic-key".to_owned(),
                "grok-native-login".to_owned(),
                "gemini-login".to_owned(),
            ],
            &ProfileSources::none(),
        )
        .unwrap();
        assert_eq!(state["order_explicit"], true);
        assert_eq!(state_ids(&state)[0], "anthropic-key");
        assert_eq!(routes::bindings(&d.home).connection_order, ["anthropic-key"]);
        let text = std::fs::read_to_string(d.home.join("routes/bindings.json")).unwrap();
        assert!(text.contains("\"connection_order\""), "{text}");
        // Removing the route drops it from the order.
        routes::remove(Some(&d.routes), &d.home, "anthropic-key").unwrap();
        assert!(routes::bindings(&d.home).connection_order.is_empty());
    }

    #[test]
    fn spread_defaults_on_and_is_stored() {
        let d = dirs();
        assert_eq!(state(Some(&d.routes), &d.home, &ProfileSources::none())["spread"], true);
        assert_eq!(
            set_spread(Some(&d.routes), &d.home, false, &ProfileSources::none()).unwrap()["spread"],
            false
        );
        assert_eq!(routes::bindings(&d.home).spread, Some(false));
    }

    #[test]
    fn a_key_is_added_as_a_reference_and_listed_with_its_provider() {
        let d = dirs();
        let inline = add_key(
            Some(&d.routes),
            &d.home,
            "openrouter",
            "sk-or-v1-abc",
            None,
            &ProfileSources::none(),
            None,
        );
        assert_eq!(inline.unwrap_err().data.unwrap()["reason"], "route.secret_inline");
        assert!(
            add_key(
                Some(&d.routes),
                &d.home,
                "mistral",
                "keychain:x",
                None,
                &ProfileSources::none(),
                None,
            )
            .is_err()
        );
        let (id, state) = add_key(
            Some(&d.routes),
            &d.home,
            "openrouter",
            "keychain:cmux-or",
            Some("Mine"),
            &ProfileSources::none(),
            None,
        )
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
        assert_eq!(key["families"], json!(["claude", "codex", "openrouter"]));
        assert_eq!(key["label"], "Mine");
        assert_eq!(key["signed_in"], true);
        assert_eq!(key["can_check_access"], true);
        assert_eq!(key["serves_cloud"], true);
        let (second, _) = add_key(
            Some(&d.routes),
            &d.home,
            "openrouter",
            "keychain:cmux-or-2",
            None,
            &ProfileSources::none(),
            None,
        )
        .unwrap();
        assert_eq!(second, "openrouter-key-2");
        let route = routes::find(Some(&d.routes), "openrouter-key").unwrap();
        assert_eq!(route.file.secret.as_deref(), Some("keychain:cmux-or"));
        assert_eq!(route.file.provider.as_deref(), Some("openrouter"));
    }

    #[test]
    fn access_check_will_only_send_saved_keys_to_their_configured_provider() {
        let d = dirs();
        let (id, _) = add_key(
            Some(&d.routes),
            &d.home,
            "google",
            "keychain:cmux-google",
            None,
            &ProfileSources::none(),
            None,
        )
        .unwrap();
        let mut file = routes::find(Some(&d.routes), &id).unwrap().file;
        let (base, kind) = standard_key_endpoint(&file).unwrap();
        assert_eq!(
            crate::byo_endpoint::models_url(kind, base),
            "https://generativelanguage.googleapis.com/v1beta/openai/models"
        );
        file.openai_base_url = Some("https://example.com/v1".into());
        assert!(standard_key_endpoint(&file).is_none());
        file.openai_base_url = None;
        assert!(standard_key_endpoint(&file).is_none());
    }

    fn secret_file(d: &Dirs, name: &str, value: &str) -> String {
        let path = d._root.path().join(name);
        std::fs::write(&path, format!("{value}\n")).unwrap();
        crate::router_socket::owner_only(&path);
        format!("file:{}", path.display())
    }

    fn find<'a>(state: &'a Value, id: &str) -> &'a Value {
        state["connections"].as_array().unwrap().iter().find(|c| c["id"] == id).unwrap()
    }

    #[test]
    fn keychain_other_build_shows_a_signed_out_settings_row() {
        let d = dirs();
        let dir = Some(d.routes.as_path());
        let file = routes::file_from_json(&json!({
            "kind": "chatgpt-plan", "provider": "openai", "families": ["codex"],
        }))
        .unwrap();
        let id = "chatgpt";
        routes::add(dir, id, &file, false).unwrap();
        let store = crate::subscription_store::Store::new(&d.home, "chatgpt");
        let record = chatgpt::store::Record {
            client_id: chatgpt::CODEX_CLIENT_ID.into(),
            sub: "fixture-user".into(),
            refresh_token: "fixture-refresh".into(),
            ..Default::default()
        };
        store.write(id, &record).unwrap();
        store.refuse_test_item(id, crate::subscription_store::Error::KeychainOtherBuild);

        let settings = state(dir, &d.home, &ProfileSources::none());
        assert_eq!(find(&settings, id)["signed_in"], false);
        assert_eq!(find(&settings, id)["sign_in_reason"], "keychain_other_build");
        assert!(store.metadata(id).is_some_and(|record| record["signed_in"] == true));
    }

    #[test]
    fn saved_claude_token_route_is_listed_only_for_migration() {
        let d = dirs();
        let dir = Some(d.routes.as_path());
        let id = "claude-token";
        let path = d.routes.join("claude-token.toml");
        std::fs::write(
            &path,
            concat!(
                "kind = \"claude-token\"\n",
                "families = [\"claude\"]\n",
                "provider = \"anthropic\"\n",
                "secret = \"keychain:cmux-model-key/claude-token-1234abcd\"\n",
                "notes = \"claude setup-token: served to Cloud machines' Claude agents\"\n",
            ),
        )
        .unwrap();

        let settings = state(dir, &d.home, &ProfileSources::none());
        assert_eq!(find(&settings, id)["can_serve_cloud"], false);
        let route = routes::find(dir, id).unwrap();
        assert_eq!(
            routes::env_for(&route, "claude", &d.home).unwrap(),
            routes::RouteEnv::default()
        );
        let error = credential_plan(dir, &d.home, id).unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "connections.not_cloud");
        accounts::set_for_test(dir, &d.home, id, Some(false)).unwrap();
        assert!(routes::find(dir, id).unwrap().file.disabled);
        routes::remove(dir, &d.home, id).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn chatgpt_and_claude_login_turn_off_and_a_disabled_plan_gets_no_credential() {
        let d = dirs();
        let plan = RouteFile {
            name: Some("ChatGPT plan".into()),
            kind: RouteKind::ChatgptPlan,
            families: vec!["codex".into()],
            anthropic_base_url: None,
            openai_base_url: Some(chatgpt::CODEX_BACKEND.into()),
            auth: None,
            secret: None,
            claude_token_expires_at: None,
            cloud_enabled: None,
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
        routes::add(Some(&d.routes), "chatgpt", &plan, false).unwrap();
        for id in ["chatgpt", "claude-login"] {
            let answer = accounts::set_for_test(Some(&d.routes), &d.home, id, Some(false));
            assert_eq!(answer.unwrap()["enabled"], false, "{id}");
            let s = state(Some(&d.routes), &d.home, &ProfileSources::none());
            let c = find(&s, id);
            assert_eq!(c["enabled"], false, "{id}");
            assert_eq!(c["default_for"], json!([]), "{id} is nobody's default when off");
            assert_eq!(
                state_ids(&s).last().map(String::as_str),
                Some(id),
                "{id}: a turned-off connection sorts last"
            );
            if id == "chatgpt" {
                let e = credential_plan(Some(&d.routes), &d.home, id).unwrap_err();
                assert_eq!(e.data.unwrap()["reason"], "connections.disabled", "{id}");
            }
            accounts::set_for_test(Some(&d.routes), &d.home, id, Some(true)).unwrap();
            assert_eq!(
                find(&state(Some(&d.routes), &d.home, &ProfileSources::none()), id)["enabled"],
                true,
                "{id}"
            );
        }
        assert!(routes::bindings(&d.home).disabled_connections.is_empty());
        // The switch of claude-login lives in the bindings, not a route file.
        assert!(routes::find(Some(&d.routes), "claude-login").is_err());
    }

    #[test]
    fn replacing_a_key_keeps_the_connection_and_its_route_settings() {
        let d = dirs();
        let dir = Some(d.routes.as_path());
        let sources = ProfileSources::none();
        let old = "keychain:cmux-model-key/openai-previous";
        let new = "keychain:cmux-model-key/openai-replacement";
        let (id, _) =
            add_key(dir, &d.home, "openai", old, Some("Research"), &sources, None).unwrap();
        let mut expected = routes::find(dir, &id).unwrap().file;
        expected.disabled = true;
        routes::add(dir, &id, &expected, true).unwrap();
        set_order(dir, &d.home, std::slice::from_ref(&id), &sources).unwrap();

        assert!(replace_key(dir, &d.home, &id, "anthropic", new, &sources).is_err());
        assert_eq!(routes::find(dir, &id).unwrap().file.secret.as_deref(), Some(old));

        let state = replace_key(dir, &d.home, &id, "openai", new, &sources).unwrap();
        assert_eq!(state_ids(&state)[0], id);
        assert_eq!(state["replaced_secret"], old);
        expected.secret = Some(new.to_owned());
        assert_eq!(routes::find(dir, &id).unwrap().file, expected);
        assert_eq!(routes::load(dir).0.len(), 1);
        routes::remove(dir, &d.home, &id).unwrap();
        assert!(replace_key(dir, &d.home, &id, "openai", old, &sources).is_err());
        assert!(routes::find(dir, &id).is_err());
    }

    #[test]
    fn local_only_keys_do_not_release_cloud_credentials() {
        let d = dirs();
        let dir = Some(d.routes.as_path());
        let sources = ProfileSources::none();
        let (openai, _) =
            add_key(dir, &d.home, "openai", "keychain:fixture", None, &sources, Some(false))
                .unwrap();
        let (openrouter, _) =
            add_key(dir, &d.home, "openrouter", "keychain:fixture", None, &sources, Some(false))
                .unwrap();

        for id in [&openai, &openrouter] {
            let listed = state(dir, &d.home, &sources);
            let key = find(&listed, id);
            assert_eq!(key["can_serve_cloud"], true);
            assert_eq!(key["serves_cloud"], false);
            assert_eq!(key["enabled"], true);
            assert_eq!(key["signed_in"], true);
        }
        assert_eq!(
            credential_plan(dir, &d.home, &openai).unwrap_err().data.unwrap()["reason"],
            "connections.not_cloud"
        );
        let profiles = config::profiles::load(&sources);
        assert_eq!(
            endpoint_plan(dir, &openrouter, None, &profiles).err().unwrap().data.unwrap()["reason"],
            "connections.not_cloud"
        );

        replace_key(dir, &d.home, &openai, "openai", "keychain:replacement", &sources).unwrap();
        assert_eq!(find(&state(dir, &d.home, &sources), &openai)["serves_cloud"], false);
    }

    #[test]
    fn keyed_endpoint_profiles_are_cloud_connections_only_for_public_https() {
        let d = dirs();
        let folder = d.home.join("harnesses");
        std::fs::create_dir_all(&folder).unwrap();
        let profiles = config::profiles::ProfileSources {
            user_dir: Some(folder.clone()),
            ..Default::default()
        };
        for (id, base_url, can_serve_cloud, cloud_enabled) in [
            ("hosted", "https://models.example/v1", true, None),
            ("local", "http://127.0.0.1:11434/v1", false, None),
            ("off", "https://models.example/v1", true, Some(false)),
        ] {
            let cloud = can_serve_cloud && cloud_enabled != Some(false);
            let account = format!("cmux-harness/{id}/CMUX_BYO_API_KEY");
            let profile = byo_endpoint::profile_text(&byo_endpoint::Endpoint {
                cloud_enabled,
                preset: None,
                id,
                name: id,
                kind: Kind::OpenAi,
                base_url,
                models: &["some-model".into()],
                keychain_item: Some(&account),
            });
            std::fs::write(folder.join(format!("{id}.toml")), profile).unwrap();
            let loaded = config::profiles::load(&profiles);
            let row = list(Some(&d.routes), &d.home, &Bindings::default(), &profiles)
                .into_iter()
                .find(|connection| connection.id == id)
                .unwrap();
            assert_eq!(row.can_serve_cloud, can_serve_cloud);
            assert_eq!(row.serves_cloud, cloud);
            let fields = row.endpoint.unwrap();
            assert_eq!(fields.base_url, base_url);
            assert_eq!(fields.models, ["some-model"]);
            assert_eq!(fields.kind, "openai-endpoint");
            let planned = endpoint_plan(Some(&d.routes), id, None, &loaded);
            if cloud {
                let plan = planned.unwrap().unwrap();
                assert_eq!(plan.reference, "keychain:cmux-harness/hosted/CMUX_BYO_API_KEY");
                let reply = endpoint_reply(&plan, "test-token").unwrap();
                assert_eq!(reply["harness"], "opencode");
                assert_eq!(reply["model"], "byo/some-model");
                assert!(endpoint_plan(Some(&d.routes), id, Some("other"), &loaded).is_err());
                assert_eq!(reply["endpoint"]["models"], json!(["some-model"]));
            } else {
                assert_eq!(planned.err().unwrap().data.unwrap()["reason"], "connections.not_cloud");
            }
        }
    }

    #[test]
    fn native_key_routes_set_the_variable_the_harness_uses() {
        let d = dirs();
        for (provider, family, variable) in
            [("google", "gemini", "GEMINI_API_KEY"), ("xai", "grok", "XAI_API_KEY")]
        {
            let (id, _) = add_key(
                Some(&d.routes),
                &d.home,
                provider,
                "keychain:fixture",
                None,
                &ProfileSources::none(),
                None,
            )
            .unwrap();
            let route = routes::find(Some(&d.routes), &id).unwrap();
            let env = routes::env_for(&route, family, &d.home).unwrap();
            assert_eq!(env.set[variable], "${keychain:fixture}");
            assert!(!env.set.contains_key("OPENAI_API_KEY"));
            let (launch_family, _, launch_variable, _) =
                credential_plan(Some(&d.routes), &d.home, &id).unwrap();
            assert_eq!((launch_family.as_str(), launch_variable), (family, variable));
        }
    }

    #[test]
    fn which_connections_serve_cloud() {
        for (kind, provider, cloud) in [
            ("chatgpt-plan", "openai", true),
            ("claude-token", "anthropic", false),
            ("api-key", "anthropic", true),
            ("api-key", "openai", true),
            ("api-key", "openrouter", true),
            ("api-key", "google", true),
            ("api-key", "xai", true),
            ("codex-login", "openai", false),
            ("claude-login", "anthropic", false),
            ("subscription", "openai", false),
        ] {
            assert_eq!(serves_cloud(kind, provider), cloud, "{kind} {provider}");
        }
        let d = dirs();
        let s = state(Some(&d.routes), &d.home, &ProfileSources::none());
        assert_eq!(find(&s, "codex-login")["serves_cloud"], false);
        assert_eq!(find(&s, "claude-login")["serves_cloud"], false);
    }

    #[test]
    fn an_openrouter_key_can_launch_non_claude_models_on_opencode() {
        let d = dirs();
        let key = secret_file(&d, "openrouter", "fixture-openrouter-key");
        let (id, _) = add_key(
            Some(&d.routes),
            &d.home,
            "openrouter",
            &key,
            None,
            &ProfileSources::none(),
            None,
        )
        .unwrap();
        let route = routes::find(Some(&d.routes), &id).unwrap();
        let local = routes::env_for(&route, "openrouter", &d.home).unwrap();
        assert!(local.set["OPENROUTER_API_KEY"].contains(&key));
        let profiles = config::profiles::load(&ProfileSources::none());
        for model in ["openrouter/openai/gpt-5.4-mini", "openai/gpt-5.4-mini"] {
            let plan =
                endpoint_plan(Some(&d.routes), &id, Some(model), &profiles).unwrap().unwrap();
            assert_eq!(plan.endpoint.harness(), "opencode");
            assert_eq!(plan.endpoint.base_url, "https://openrouter.ai/api/v1");
            assert_eq!(plan.model, "byo/openai/gpt-5.4-mini");
            assert_eq!(plan.reference, key);
        }
        let plan =
            endpoint_plan(Some(&d.routes), &id, Some("anthropic/claude-sonnet-4.6"), &profiles)
                .unwrap()
                .unwrap();
        assert_eq!(plan.endpoint.harness(), "claude");
        assert_eq!(plan.endpoint.base_url, "https://openrouter.ai/api");
        assert_eq!(plan.model, "anthropic/claude-sonnet-4.6");
    }

    #[test]
    fn keys_are_delivered_in_their_providers_variable_and_logins_not_at_all() {
        let d = dirs();
        let anthropic = secret_file(&d, "a", "sk-ant-api-1");
        let openai = secret_file(&d, "o", "sk-proj-1");
        add_key(
            Some(&d.routes),
            &d.home,
            "anthropic",
            &anthropic,
            None,
            &ProfileSources::none(),
            None,
        )
        .unwrap();
        add_key(Some(&d.routes), &d.home, "openai", &openai, None, &ProfileSources::none(), None)
            .unwrap();
        add_key(
            Some(&d.routes),
            &d.home,
            "openrouter",
            "keychain:cmux-or",
            None,
            &ProfileSources::none(),
            None,
        )
        .unwrap();
        let (family, kind, var, _) =
            credential_plan(Some(&d.routes), &d.home, "anthropic-key").unwrap();
        assert_eq!((family.as_str(), kind, var), ("claude", "api-key", "ANTHROPIC_API_KEY"));
        let (family, _, var, secret) =
            credential_plan(Some(&d.routes), &d.home, "openai-key").unwrap();
        assert_eq!((family.as_str(), var), ("codex", "OPENAI_API_KEY"));
        assert_eq!(resolve("openai-key", &secret.unwrap()).unwrap(), "sk-proj-1");
        let plan = endpoint_plan(
            Some(&d.routes),
            "openrouter-key",
            Some("claude-sonnet-4-6"),
            &Default::default(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(plan.reference, "keychain:cmux-or");
        let reply = endpoint_reply(&plan, "fixture-key").unwrap();
        assert_eq!(reply["harness"], "claude");
        assert_eq!(reply["endpoint"]["models"], json!(["anthropic/claude-sonnet-4.6"]));
        for id in ["codex-login", "claude-login"] {
            let e = credential_plan(Some(&d.routes), &d.home, id).unwrap_err();
            assert_eq!(e.data.unwrap()["reason"], "connections.not_cloud", "{id}");
        }
        let e = credential_plan(Some(&d.routes), &d.home, "nope").unwrap_err();
        assert_eq!(e.code, RpcError::not_found("").code);
    }

    #[test]
    fn a_chatgpt_plan_route_is_listed_from_its_record() {
        let d = dirs();
        let record = chatgpt::store::Record {
            client_id: chatgpt::CODEX_CLIENT_ID.into(),
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
            openai_base_url: Some(chatgpt::CODEX_BACKEND.into()),
            auth: None,
            secret: None,
            claude_token_expires_at: None,
            cloud_enabled: None,
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
        let list =
            list(Some(&d.routes), &d.home, &routes::bindings(&d.home), &ProfileSources::none());
        let plan = list.iter().find(|c| c.id == "chatgpt").unwrap();
        assert_eq!(plan.kind, "chatgpt-plan");
        assert!(plan.signed_in);
        assert_eq!(plan.email.as_deref(), Some("alex@example.com"));
        assert_eq!(plan.plan.as_deref(), Some("plus"));
        assert!(plan.serves_cloud);
        let (family, kind, var, secret) =
            credential_plan(Some(&d.routes), &d.home, "chatgpt").unwrap();
        assert_eq!(
            (family.as_str(), kind, var),
            ("codex", "chatgpt-plan", "CMUX_CHATGPT_ACCESS_TOKEN")
        );
        assert!(secret.is_none(), "the daemon's own token, not a reference");
        // A sign-in from the retired token-sharing client (`oaiapp_...`) reads signed out: its
        // token is refused by OpenAI, so the person signs in again (cmux#45774).
        let old = chatgpt::store::Record { client_id: "oaiapp_x".into(), ..record.clone() };
        chatgpt::store::write(&d.home, "chatgpt", &old).unwrap();
        let list = super::list(
            Some(&d.routes),
            &d.home,
            &routes::bindings(&d.home),
            &ProfileSources::none(),
        );
        assert!(!list.iter().find(|c| c.id == "chatgpt").unwrap().signed_in);
        let route = routes::find(Some(&d.routes), "chatgpt").unwrap();
        assert!(route.serves("codex"));
        assert!(!route.serves("opencode"));
        let launch = routes::env_for(&route, "codex", &d.home).unwrap();
        assert!(launch.set.is_empty(), "the hub resolves a fresh ChatGPT token at launch");
        assert!(launch.unset.iter().any(|key| key == "OPENAI_API_KEY"));
    }

    fn auth_file(d: &Dirs, text: &str) -> PathBuf {
        std::fs::create_dir_all(&d.home).unwrap();
        let path = d.home.join("auth.json");
        std::fs::write(&path, text).unwrap();
        path
    }

    fn import(d: &Dirs, origin: Origin, enabled: bool, text: &str) -> Result<String, RpcError> {
        let path = auth_file(d, text);
        import_chatgpt(
            origin,
            enabled,
            Some(d.routes.clone()),
            d.home.clone(),
            path.to_str().unwrap(),
        )
    }

    fn codex_auth(refresh: Option<&str>) -> String {
        chatgpt::import_test_auth(chatgpt::CODEX_CLIENT_ID, refresh, true)
    }

    fn reason(e: &RpcError) -> String {
        e.data.as_ref().and_then(|d| d["reason"].as_str()).unwrap_or_default().to_owned()
    }

    #[test]
    fn chatgpt_import_is_refused_unless_the_switch_is_set() {
        let d = dirs();
        let error = import(&d, Origin::Local, false, &codex_auth(Some("rt"))).unwrap_err();
        assert_eq!(reason(&error), "chatgpt.import_disabled");
        assert!(chatgpt::store::all(&d.home).is_empty(), "nothing stored");
        assert!(routes::find(Some(&d.routes), "chatgpt").is_err(), "no route written");
    }

    #[test]
    fn chatgpt_import_is_refused_off_the_local_socket_even_with_the_switch() {
        let d = dirs();
        for origin in [Origin::Web, Origin::Peer, Origin::LocalApp] {
            let error = import(&d, origin, true, &codex_auth(Some("rt"))).unwrap_err();
            assert_eq!(reason(&error), "chatgpt.import_local_only", "{origin:?}");
        }
        assert!(chatgpt::store::all(&d.home).is_empty(), "nothing stored");
    }

    #[test]
    fn chatgpt_import_refuses_another_client_and_a_missing_refresh_token() {
        let d = dirs();
        let other = chatgpt::import_test_auth("app_someone_else", Some("rt"), true);
        let error = import(&d, Origin::Local, true, &other).unwrap_err();
        assert_eq!(reason(&error), "chatgpt.wrong_client");
        let error = import(&d, Origin::Local, true, &codex_auth(None)).unwrap_err();
        assert_eq!(reason(&error), "chatgpt.no_refresh_token");
        let no_account = chatgpt::import_test_auth(chatgpt::CODEX_CLIENT_ID, Some("rt"), false);
        let error = import(&d, Origin::Local, true, &no_account).unwrap_err();
        assert_eq!(reason(&error), "chatgpt.no_chatgpt_account");
        let error = import(&d, Origin::Local, true, "not json").unwrap_err();
        assert_eq!(reason(&error), "chatgpt.import_invalid");
        assert!(chatgpt::store::all(&d.home).is_empty(), "nothing stored");
    }

    #[test]
    fn an_imported_codex_login_lists_as_a_cloud_serving_chatgpt_plan() {
        let d = dirs();
        let id = import(&d, Origin::Local, true, &codex_auth(Some("rt-1"))).unwrap();
        assert_eq!(id, "chatgpt");
        let record = chatgpt::store::read(&d.home, &id).unwrap().unwrap();
        assert!(record.signed_in());
        assert_eq!(record.client_id, chatgpt::CODEX_CLIENT_ID);
        assert_eq!(record.refresh_token, "rt-1");
        assert_eq!(record.sub, "user-1");
        assert_eq!(record.plan.as_deref(), Some("plus"));
        let route = routes::find(Some(&d.routes), &id).unwrap();
        assert_eq!(route.file.kind, RouteKind::ChatgptPlan);
        assert_eq!(route.file.families, vec!["codex".to_owned()]);
        let response = connection_state(Some(&d.routes), &d.home, &id, &ProfileSources::default());
        let plan = &response["connection"];
        assert_eq!(plan["id"], "chatgpt");
        assert_eq!(plan["kind"], "chatgpt-plan");
        assert_eq!(plan["serves_cloud"], true);
        assert_eq!(plan["signed_in"], true);
        assert_eq!(plan["email"], "ci@example.com");
        // Importing the same account again replaces its record: no second connection.
        let again = import(&d, Origin::Local, true, &codex_auth(Some("rt-2"))).unwrap();
        assert_eq!(again, "chatgpt");
        assert_eq!(
            chatgpt::store::read(&d.home, "chatgpt").unwrap().unwrap().refresh_token,
            "rt-2"
        );
    }
}
