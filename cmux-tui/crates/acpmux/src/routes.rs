//! Routes (ROUTES, recorded 2026-10-09; Lawrence: "fully user configurable,
//! including base url etc. profiles … switch from proxy A to proxy B without
//! quit/restarting"). A route is how a harness reaches its model provider:
//! data in `<cmux config>/routes/<id>.toml`, never code, secrets only as
//! references (`keychain:ITEM`, `env:VAR`). acpmux owns the store; the CLI
//! (`cmux route …`) and the daemon RPC (`_acpmux/route/*`, server/routes.rs)
//! share this file.
//!
//! Which route a session uses: its chat binding, else its workspace's, else
//! its family's default, else the global default (bindings live in
//! `<acpmux home>/routes/bindings.json`, so a chat keeps its route across
//! restarts). No binding anywhere: the harness runs as before (its profile env
//! decides), so nothing changes until the user picks a route.
//!
//! A bound route rewrites the provider variables of the spawn: every variable
//! in [`SCRUBBED`] is removed from the profile env AND from the environment the
//! harness inherits (agent.rs reads [`UNSET_KEY`]), then the route sets its own.
//! So switching from route A to route B never leaks A's key into B's process.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Provider variables a bound route owns: removed before the route sets its
/// own, so no other route's endpoint or key survives a switch.
pub const SCRUBBED: &[&str] = &[
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "OPENAI_BASE_URL",
    "OPENAI_API_KEY",
];

/// The profile-env key that carries the comma-separated variables the spawn
/// must also remove from the inherited environment (agent.rs). Internal: never
/// reaches the harness.
pub const UNSET_KEY: &str = "ACPMUX_ROUTE_UNSET";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RouteKind {
    /// The CLI's own login; no endpoint override.
    DirectSubscription,
    /// The provider's API with a key.
    DirectApiKey,
    /// cmux's local Rust CodeRouter (crate cmux-coderouter, LOCAL-CODEROUTER):
    /// its loopback port and a per-install key come from the running router.
    LocalCoderouter,
    /// A team subrouter.
    Subrouter,
    /// CLIProxyAPI (an Anthropic/OpenAI-compatible proxy over subscription logins).
    Cliproxyapi,
    /// The hosted cmux model router (open-source models), reached through the
    /// local relay (crate cmux-coderouter): the relay holds the app's upstream
    /// bearer; a harness gets only the relay's loopback URL and a crl_ key.
    /// Serves both families (Messages API and OpenAI chat/completions).
    CmuxRouter,
    CustomAnthropic,
    CustomOpenai,
}

impl RouteKind {
    pub const ALL: &[RouteKind] = &[
        Self::DirectSubscription,
        Self::DirectApiKey,
        Self::LocalCoderouter,
        Self::Subrouter,
        Self::Cliproxyapi,
        Self::CmuxRouter,
        Self::CustomAnthropic,
        Self::CustomOpenai,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::DirectSubscription => "direct-subscription",
            Self::DirectApiKey => "direct-api-key",
            Self::LocalCoderouter => "local-coderouter",
            Self::Subrouter => "subrouter",
            Self::Cliproxyapi => "cliproxyapi",
            Self::CmuxRouter => "cmux-router",
            Self::CustomAnthropic => "custom-anthropic",
            Self::CustomOpenai => "custom-openai",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|k| k.as_str() == text)
    }

    /// Kinds whose URL and key come from the running local router.
    pub fn relayed(self) -> bool {
        matches!(self, Self::LocalCoderouter | Self::CmuxRouter)
    }

    /// The auth a preset of this kind starts with.
    fn default_auth(self) -> Auth {
        match self {
            Self::DirectSubscription => Auth::Subscription,
            Self::DirectApiKey => Auth::ApiKey,
            Self::LocalCoderouter | Self::CmuxRouter => Auth::Bearer,
            Self::Subrouter | Self::Cliproxyapi | Self::CustomAnthropic | Self::CustomOpenai => {
                Auth::None
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Auth {
    /// The harness CLI's own login (claude auth, codex login).
    Subscription,
    /// `x-api-key` / `Authorization: Bearer` from `secret`.
    ApiKey,
    /// A bearer token from `secret`.
    Bearer,
    /// The endpoint injects auth itself (a proxy over the user's logins).
    #[default]
    None,
}

impl Auth {
    fn as_str(self) -> &'static str {
        match self {
            Self::Subscription => "subscription",
            Self::ApiKey => "api-key",
            Self::Bearer => "bearer",
            Self::None => "none",
        }
    }
}

/// One route file. Field names are the TOML keys.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouteFile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub kind: RouteKind,
    /// Harness families it serves (`claude`, `codex`, …); empty: every family
    /// its endpoint shape fits.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub families: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anthropic_base_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub openai_base_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<Auth>,
    /// `keychain:ITEM` or `env:VAR`; never the secret itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secret: Option<String>,
    /// Extra request headers (Claude Code: ANTHROPIC_CUSTOM_HEADERS). A
    /// secret-looking header's value must be a reference.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub headers: BTreeMap<String, String>,
    /// A URL the probe GETs instead of the provider's model list.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub health_url: Option<String>,
    /// Routes to offer, in order, when a turn on this one fails for auth,
    /// overload or a server error.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fallback: Vec<String>,
    /// Move the chat to the first fallback by itself (else only offer it).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub auto_fallback: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Route {
    pub id: String,
    pub file: RouteFile,
    pub path: PathBuf,
}

impl Route {
    pub fn name(&self) -> String {
        self.file.name.clone().unwrap_or_else(|| self.id.clone())
    }

    pub fn auth(&self) -> Auth {
        self.file.auth.unwrap_or_else(|| self.file.kind.default_auth())
    }

    /// Whether a spawn takes its URL and key from the local relay: always for
    /// local-coderouter; for cmux-router unless the route file names its own
    /// secret (a route made before the relay: it stays direct, as it was).
    pub fn uses_relay(&self) -> bool {
        uses_relay(&self.file)
    }

    /// Whether it serves `family`.
    pub fn serves(&self, family: &str) -> bool {
        if !self.file.families.is_empty() {
            return self.file.families.iter().any(|f| f == family || f == "*");
        }
        // The hosted model router speaks the Messages API and OpenAI
        // chat/completions, not the Responses API codex needs.
        if self.file.kind == RouteKind::CmuxRouter && self.uses_relay() {
            return is_anthropic_family(family) || matches!(family, "opencode" | "pi");
        }
        match self.file.kind {
            RouteKind::DirectSubscription | RouteKind::DirectApiKey => true,
            _ => {
                if is_anthropic_family(family) {
                    self.file.anthropic_base_url.is_some() || self.file.kind.relayed()
                } else {
                    self.file.openai_base_url.is_some() || self.file.kind.relayed()
                }
            }
        }
    }

    /// The JSON the RPC and `cmux route list --json` show. Never a secret: the
    /// reference only.
    pub fn view(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name(),
            "kind": self.file.kind.as_str(),
            "families": self.file.families,
            "anthropicBaseUrl": self.file.anthropic_base_url,
            "openaiBaseUrl": self.file.openai_base_url,
            "auth": self.auth().as_str(),
            "secret": self.file.secret,
            "headers": self.file.headers.keys().collect::<Vec<_>>(),
            "healthUrl": self.file.health_url,
            "fallback": self.file.fallback,
            "autoFallback": self.file.auto_fallback,
            "notes": self.file.notes,
            "path": self.path,
        })
    }
}

fn uses_relay(file: &RouteFile) -> bool {
    match file.kind {
        RouteKind::LocalCoderouter => true,
        RouteKind::CmuxRouter => file.secret.is_none(),
        _ => false,
    }
}

fn is_anthropic_family(family: &str) -> bool {
    family == "claude"
}

#[derive(Debug, PartialEq)]
pub enum RouteError {
    BadParams(String),
    Exists(String),
    NotFound(String),
    SecretInline(String),
    Unavailable(String),
    Failed(String),
}

impl RouteError {
    pub fn message(&self) -> &str {
        match self {
            Self::BadParams(m)
            | Self::Exists(m)
            | Self::NotFound(m)
            | Self::SecretInline(m)
            | Self::Unavailable(m)
            | Self::Failed(m) => m,
        }
    }

    /// The `error.data.reason` the RPC carries.
    pub fn reason(&self) -> Option<&'static str> {
        match self {
            Self::Exists(_) => Some("route.exists"),
            Self::NotFound(_) => Some("route.not_found"),
            Self::SecretInline(_) => Some("route.secret_inline"),
            Self::Unavailable(_) => Some("route.unavailable"),
            Self::BadParams(_) => Some("route.invalid"),
            Self::Failed(_) => None,
        }
    }
}

impl std::fmt::Display for RouteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

/// `<cmux config>/routes`: beside the user harness folder.
pub fn routes_dir(user_harness_dir: Option<&Path>) -> Option<PathBuf> {
    user_harness_dir.and_then(Path::parent).map(|d| d.join("routes"))
}

/// The route folder and acpmux's state folder (bindings, backups, the local
/// router's socket) of a config: the folder its config.json is in, else
/// `ACPMUX_HOME`.
pub fn places(cfg: &crate::config::Config) -> (Option<PathBuf>, PathBuf) {
    let state = cfg
        .path
        .as_ref()
        .and_then(|p| p.parent())
        .map(Path::to_path_buf)
        .unwrap_or_else(crate::config::home);
    (routes_dir(cfg.profile_sources.user_dir.as_deref()), state)
}

fn backups_dir(home: &Path) -> PathBuf {
    home.join("route-backups")
}

fn bindings_path(home: &Path) -> PathBuf {
    home.join("routes").join("bindings.json")
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !id.starts_with('-')
}

fn is_reference(value: &str) -> bool {
    value.starts_with("keychain:") || value.starts_with("env:")
}

fn secret_looking(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    ["authorization", "api-key", "apikey", "x-api-key", "token", "secret", "key", "password"]
        .iter()
        .any(|w| n.contains(w))
}

fn valid_url(url: &str) -> bool {
    (url.starts_with("http://") || url.starts_with("https://"))
        && !url.contains(char::is_whitespace)
        && url.len() <= 2048
}

/// Checks a route file before it is written or used.
pub fn validate(file: &RouteFile) -> Result<(), RouteError> {
    for url in
        [&file.anthropic_base_url, &file.openai_base_url, &file.health_url].into_iter().flatten()
    {
        if !valid_url(url) {
            return Err(RouteError::BadParams(format!("{url:?} is not an http(s) URL")));
        }
    }
    match &file.secret {
        Some(s) if s.starts_with("op://") => {
            return Err(RouteError::BadParams(
                "op:// references are not supported yet: store the secret with `cmux harness secret set NAME` and use keychain:NAME".into(),
            ));
        }
        Some(s) if !is_reference(s) => {
            return Err(RouteError::SecretInline(
                "secret must be a reference (keychain:ITEM or env:VAR), never the secret itself: store it with `cmux harness secret set NAME` and pass keychain:NAME".into(),
            ));
        }
        _ => {}
    }
    for (name, value) in &file.headers {
        if name.is_empty() || name.contains([':', '\n', '\r']) {
            return Err(RouteError::BadParams(format!("{name:?} is not a header name")));
        }
        if value.contains(['\n', '\r']) {
            return Err(RouteError::BadParams(format!("header {name} has a line break")));
        }
        if secret_looking(name) && !is_reference(value) {
            return Err(RouteError::SecretInline(format!(
                "header {name} looks secret: its value must be keychain:ITEM or env:VAR"
            )));
        }
    }
    let auth = file.auth.unwrap_or_else(|| file.kind.default_auth());
    if matches!(auth, Auth::ApiKey | Auth::Bearer) && file.secret.is_none() && !uses_relay(file) {
        return Err(RouteError::BadParams(format!(
            "auth {} needs secret (keychain:ITEM or env:VAR)",
            auth.as_str()
        )));
    }
    let needs_url = matches!(
        file.kind,
        RouteKind::Subrouter
            | RouteKind::Cliproxyapi
            | RouteKind::CustomAnthropic
            | RouteKind::CustomOpenai
    ) || (file.kind == RouteKind::CmuxRouter && !uses_relay(file));
    if needs_url && file.anthropic_base_url.is_none() && file.openai_base_url.is_none() {
        return Err(RouteError::BadParams(format!(
            "a {} route needs anthropicBaseUrl or openaiBaseUrl",
            file.kind.as_str()
        )));
    }
    if file.kind == RouteKind::CustomAnthropic && file.anthropic_base_url.is_none() {
        return Err(RouteError::BadParams(
            "a custom-anthropic route needs anthropicBaseUrl".into(),
        ));
    }
    if file.kind == RouteKind::CustomOpenai && file.openai_base_url.is_none() {
        return Err(RouteError::BadParams("a custom-openai route needs openaiBaseUrl".into()));
    }
    Ok(())
}

/// Every route in `dir`, sorted by id, and the problems of the files that do
/// not parse (named, never their secret references' values).
pub fn load(dir: Option<&Path>) -> (Vec<Route>, Vec<String>) {
    let mut routes = Vec::new();
    let mut problems = Vec::new();
    let Some(dir) = dir else { return (routes, problems) };
    let Ok(entries) = std::fs::read_dir(dir) else { return (routes, problems) };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "toml"))
        .collect();
    paths.sort();
    for path in paths {
        let Some(id) = path.file_stem().and_then(|s| s.to_str()).map(str::to_owned) else {
            continue;
        };
        if !valid_id(&id) {
            problems.push(format!("{}: the file name is not a route id", path.display()));
            continue;
        }
        let parsed = std::fs::read_to_string(&path)
            .map_err(|e| e.to_string())
            .and_then(|t| toml::from_str::<RouteFile>(&t).map_err(|e| e.to_string()))
            .and_then(|f| validate(&f).map(|()| f).map_err(|e| e.to_string()));
        match parsed {
            Ok(file) => routes.push(Route { id, file, path }),
            Err(e) => problems.push(format!("{}: {e}", path.display())),
        }
    }
    (routes, problems)
}

pub fn find(dir: Option<&Path>, id: &str) -> Result<Route, RouteError> {
    load(dir)
        .0
        .into_iter()
        .find(|r| r.id == id)
        .ok_or_else(|| RouteError::NotFound(format!("no route {id:?}")))
}

/// The route file the RPC `add`/`edit` params (camelCase) describe.
pub fn file_from_json(params: &Value) -> Result<RouteFile, RouteError> {
    let text = |k: &str| {
        params.get(k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_owned)
    };
    let kind = text("kind")
        .ok_or_else(|| RouteError::BadParams("kind is required".into()))
        .and_then(|k| {
            RouteKind::parse(&k).ok_or_else(|| {
                RouteError::BadParams(format!(
                    "unknown kind {k:?}: one of {}",
                    RouteKind::ALL.iter().map(|k| k.as_str()).collect::<Vec<_>>().join(", ")
                ))
            })
        })?;
    let auth = match text("auth").as_deref() {
        None => None,
        Some("subscription") => Some(Auth::Subscription),
        Some("api-key") => Some(Auth::ApiKey),
        Some("bearer") => Some(Auth::Bearer),
        Some("none") => Some(Auth::None),
        Some(other) => {
            return Err(RouteError::BadParams(format!(
                "unknown auth {other:?}: subscription, api-key, bearer or none"
            )));
        }
    };
    let strings = |k: &str| -> Vec<String> {
        params
            .get(k)
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default()
    };
    let headers = params
        .get("headers")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned()))).collect()
        })
        .unwrap_or_default();
    let file = RouteFile {
        name: text("name"),
        kind,
        families: strings("families"),
        anthropic_base_url: text("anthropicBaseUrl"),
        openai_base_url: text("openaiBaseUrl"),
        auth,
        secret: text("secret"),
        headers,
        health_url: text("healthUrl"),
        fallback: strings("fallback"),
        auto_fallback: params.get("autoFallback").and_then(Value::as_bool).unwrap_or(false),
        notes: text("notes"),
    };
    validate(&file)?;
    Ok(file)
}

fn write_file(path: &Path, file: &RouteFile) -> Result<(), RouteError> {
    use std::os::unix::fs::PermissionsExt;
    let text = toml::to_string_pretty(file).map_err(|e| RouteError::Failed(e.to_string()))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| RouteError::Failed(e.to_string()))?;
    }
    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, text).map_err(|e| RouteError::Failed(e.to_string()))?;
    let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    std::fs::rename(&tmp, path).map_err(|e| RouteError::Failed(e.to_string()))
}

/// Write a new route (`replace`: over an existing one).
pub fn add(
    dir: Option<&Path>,
    id: &str,
    file: &RouteFile,
    replace: bool,
) -> Result<Route, RouteError> {
    if !valid_id(id) {
        return Err(RouteError::BadParams(format!(
            "{id:?} is not a route id (lowercase letters, digits and -)"
        )));
    }
    validate(file)?;
    let dir = dir.ok_or_else(|| RouteError::Failed("no cmux config folder".into()))?;
    let path = dir.join(format!("{id}.toml"));
    if path.exists() && !replace {
        return Err(RouteError::Exists(format!("a route {id:?} exists (pass replace)")));
    }
    write_file(&path, file)?;
    Ok(Route { id: id.to_owned(), file: file.clone(), path })
}

/// Move a route to the backup folder; the backup's name restores it.
pub fn remove(dir: Option<&Path>, home: &Path, id: &str) -> Result<String, RouteError> {
    let route = find(dir, id)?;
    let backups = backups_dir(home);
    std::fs::create_dir_all(&backups).map_err(|e| RouteError::Failed(e.to_string()))?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let name = format!("{id}.{stamp}.toml");
    std::fs::rename(&route.path, backups.join(&name))
        .map_err(|e| RouteError::Failed(e.to_string()))?;
    Ok(name)
}

pub fn restore(dir: Option<&Path>, home: &Path, backup: &str) -> Result<Route, RouteError> {
    if backup.contains('/') || backup.contains("..") || !backup.ends_with(".toml") {
        return Err(RouteError::BadParams("backup is a name _acpmux/route/remove returned".into()));
    }
    let id = backup.split('.').next().unwrap_or_default().to_owned();
    let from = backups_dir(home).join(backup);
    if !from.exists() {
        return Err(RouteError::NotFound(format!("no backup {backup:?}")));
    }
    let dir = dir.ok_or_else(|| RouteError::Failed("no cmux config folder".into()))?;
    let to = dir.join(format!("{id}.toml"));
    if to.exists() {
        return Err(RouteError::Exists(format!("a route {id:?} exists again")));
    }
    std::fs::create_dir_all(dir).map_err(|e| RouteError::Failed(e.to_string()))?;
    std::fs::rename(&from, &to).map_err(|e| RouteError::Failed(e.to_string()))?;
    find(Some(dir), &id)
}

// ----------------------------------------------------------------- bindings

/// Which route each scope uses. `chats` is keyed by acpmux session id.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bindings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub global: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub families: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub workspaces: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub chats: BTreeMap<String, String>,
}

static BINDINGS_LOCK: Mutex<()> = Mutex::new(());

pub fn bindings(home: &Path) -> Bindings {
    std::fs::read_to_string(bindings_path(home))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// Change the bindings under one lock and write them atomically.
pub fn update_bindings(
    home: &Path,
    change: impl FnOnce(&mut Bindings),
) -> Result<Bindings, RouteError> {
    let _guard = BINDINGS_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut b = bindings(home);
    change(&mut b);
    let path = bindings_path(home);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| RouteError::Failed(e.to_string()))?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(&b).unwrap_or_default())
        .map_err(|e| RouteError::Failed(e.to_string()))?;
    std::fs::rename(&tmp, &path).map_err(|e| RouteError::Failed(e.to_string()))?;
    Ok(b)
}

/// The scope a binding names: `chat:<session id>`, `workspace:<id>`,
/// `family:<family>` or `global`.
pub fn set_binding(home: &Path, scope: &str, route: Option<&str>) -> Result<Bindings, RouteError> {
    let route = route.map(str::to_owned);
    let (kind, key) = scope.split_once(':').unwrap_or((scope, ""));
    if !matches!(kind, "global" | "chat" | "workspace" | "family") {
        return Err(RouteError::BadParams(format!(
            "unknown scope {scope:?}: global, chat:ID, workspace:ID or family:NAME"
        )));
    }
    if (kind == "global") != key.is_empty() {
        return Err(RouteError::BadParams(format!(
            "scope {scope:?}: global takes no key, the others need one"
        )));
    }
    update_bindings(home, |b| {
        let map = match kind {
            "global" => {
                b.global = route;
                return;
            }
            "chat" => &mut b.chats,
            "workspace" => &mut b.workspaces,
            _ => &mut b.families,
        };
        match route {
            Some(r) => {
                map.insert(key.to_owned(), r);
            }
            None => {
                map.remove(key);
            }
        }
    })
}

/// The route id for a session, and the scope that chose it.
pub fn bound_route(
    b: &Bindings,
    session_id: &str,
    workspace: Option<&str>,
    family: &str,
) -> Option<(String, &'static str)> {
    if let Some(r) = b.chats.get(session_id) {
        return Some((r.clone(), "chat"));
    }
    if let Some(r) = workspace.and_then(|w| b.workspaces.get(w)) {
        return Some((r.clone(), "workspace"));
    }
    if let Some(r) = b.families.get(family) {
        return Some((r.clone(), "family"));
    }
    b.global.clone().map(|r| (r, "global"))
}

// ---------------------------------------------------------------- spawn env

/// What a bound route does to a spawn's env: the variables it sets (secret
/// references stay `${keychain:…}` / `${env:…}`, resolved at spawn like a
/// profile's) and the ones every spawn on it removes.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RouteEnv {
    pub set: BTreeMap<String, String>,
    pub unset: Vec<String>,
}

fn reference_value(secret: &str) -> String {
    format!("${{{secret}}}")
}

/// The local CodeRouter's loopback base URL and a key it minted for acpmux.
/// Read from the running router (crate cmux-coderouter: its admin socket in
/// `<acpmux home>/router/router.sock`), never from a settings copy. One key
/// per family per router run (minting the same id again would revoke the key
/// running harnesses hold), so a spawn's env stays the same and the session
/// pool's env key still matches.
pub fn local_router(home: &Path, family: &str) -> Result<(String, String), RouteError> {
    local_router_with(home, family, false)
}

/// `local_router`, and for the cmux model router also a live upstream (the app
/// signed the relay in), else `route.unavailable` with the reason.
pub fn local_router_with(
    home: &Path,
    family: &str,
    need_upstream: bool,
) -> Result<(String, String), RouteError> {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    static MINTED: Mutex<BTreeMap<(u64, String), String>> = Mutex::new(BTreeMap::new());
    let socket = home.join("router").join("router.sock");
    let unavailable = |what: String| {
        RouteError::Unavailable(format!(
            "the local CodeRouter is not running ({what}); start it with `acpmux router serve`"
        ))
    };
    let stream = UnixStream::connect(&socket).map_err(|e| unavailable(e.to_string()))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let mut writer = stream.try_clone().map_err(|e| unavailable(e.to_string()))?;
    let mut reader = BufReader::new(stream);
    let mut ask = |line: Value| -> Result<Value, RouteError> {
        writer.write_all(format!("{line}\n").as_bytes()).map_err(|e| unavailable(e.to_string()))?;
        let mut answer = String::new();
        reader.read_line(&mut answer).map_err(|e| unavailable(e.to_string()))?;
        serde_json::from_str(&answer).map_err(|e| unavailable(e.to_string()))
    };
    let status = ask(json!({"op": "status"}))?;
    let port = status
        .get("port")
        .and_then(Value::as_u64)
        .ok_or_else(|| unavailable("it is older than this acpmux: no port".into()))?;
    if need_upstream {
        let live = status
            .get("upstream")
            .and_then(|u| u.get("live"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !live {
            return Err(RouteError::Unavailable(
                "the cmux model router is not connected (open cmux to sign the local router in)"
                    .into(),
            ));
        }
    }
    let url = format!("http://127.0.0.1:{port}");
    let mut minted = MINTED.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(key) = minted.get(&(port, family.to_owned())) {
        return Ok((url, key.clone()));
    }
    // A key id may not hold `_`, the key format's separator.
    // A random id per daemon run keeps a restarted daemon from re-minting (and
    // so revoking) the key of a harness a previous daemon spawned.
    static RUN: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    let run = RUN.get_or_init(|| uuid::Uuid::now_v7().simple().to_string());
    let key_id: String = format!("acpmux-route-{family}-{run}")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .take(64)
        .collect();
    let api = if is_anthropic_family(family) { "anthropic_messages" } else { "open_ai_responses" };
    let answer = ask(json!({
        "op": "mint",
        "key_id": key_id,
        "scope": {
            "harness": family,
            "session": "acpmux",
            "surfaces": [],
            "families": [api],
            "expires_at": 0,
        },
    }))?;
    let key = answer
        .get("key")
        .and_then(Value::as_str)
        .ok_or_else(|| unavailable("it minted no key".into()))?
        .to_owned();
    minted.insert((port, family.to_owned()), key.clone());
    Ok((url, key))
}

/// The env a route gives a spawn of `family`.
pub fn env_for(route: &Route, family: &str, home: &Path) -> Result<RouteEnv, RouteError> {
    if !route.serves(family) {
        return Err(RouteError::BadParams(format!(
            "route {} does not serve the {family} harness",
            route.id
        )));
    }
    let mut out = RouteEnv {
        set: BTreeMap::new(),
        unset: SCRUBBED.iter().map(|k| (*k).to_owned()).collect(),
    };
    let anthropic = is_anthropic_family(family);
    let (mut base, mut secret_value): (Option<String>, Option<String>) = (
        if anthropic {
            route.file.anthropic_base_url.clone()
        } else {
            route.file.openai_base_url.clone()
        },
        route.file.secret.as_deref().map(reference_value),
    );
    if route.uses_relay() {
        let cmux = route.file.kind == RouteKind::CmuxRouter;
        let (url, key) = local_router_with(home, family, cmux)?;
        let relay = if anthropic { url } else { format!("{url}/v1") };
        // The cmux model router is reached only through the relay: a URL in
        // the file would get the relay's key, which works nowhere else.
        if cmux || base.is_none() {
            base = Some(relay);
        }
        if cmux || secret_value.is_none() {
            secret_value = Some(key);
        }
    }
    let (url_key, key_key, bearer_key) = if anthropic {
        ("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
    } else {
        ("OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENAI_API_KEY")
    };
    if let Some(url) = base {
        out.set.insert(url_key.into(), url);
    }
    match route.auth() {
        Auth::Subscription | Auth::None => {}
        Auth::ApiKey => {
            if let Some(v) = secret_value {
                out.set.insert(key_key.into(), v);
            }
        }
        Auth::Bearer => {
            if let Some(v) = secret_value {
                out.set.insert(bearer_key.into(), v);
            }
        }
    }
    if anthropic && !route.file.headers.is_empty() {
        let lines: Vec<String> = route
            .file
            .headers
            .iter()
            .map(|(k, v)| {
                let v = if is_reference(v) { reference_value(v) } else { v.clone() };
                format!("{k}: {v}")
            })
            .collect();
        out.set.insert("ANTHROPIC_CUSTOM_HEADERS".into(), lines.join("\n"));
    }
    Ok(out)
}

/// Apply a route env to a profile env: drop every scrubbed key, set the
/// route's, and record what the spawn must also remove from its inherited env.
pub fn apply(env: &mut BTreeMap<String, String>, route_env: &RouteEnv) {
    for k in &route_env.unset {
        env.remove(k);
    }
    for (k, v) in &route_env.set {
        env.insert(k.clone(), v.clone());
    }
    let unset: Vec<&str> = route_env
        .unset
        .iter()
        .filter(|k| !route_env.set.contains_key(*k))
        .map(String::as_str)
        .collect();
    if !unset.is_empty() {
        env.insert(UNSET_KEY.into(), unset.join(","));
    }
}

// ------------------------------------------------------------------- probe

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

fn resolve_reference(value: &str) -> Result<String, String> {
    if let Some(var) = value.strip_prefix("env:") {
        return crate::login_env::var(var)
            .or_else(|| std::env::var(var).ok())
            .ok_or_else(|| format!("{var} is not set in the login environment"));
    }
    if let Some(item) = value.strip_prefix("keychain:") {
        let (service, account) = match item.split_once('/') {
            Some((s, a)) => (s, Some(a)),
            None => (item, None),
        };
        return crate::config::profiles::keychain_lookup(service, account);
    }
    Ok(value.to_owned())
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
