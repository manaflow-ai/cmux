//! Routes (ROUTES, recorded 2026-10-09; Lawrence: "fully user configurable,
//! including base url etc. profiles … switch from proxy A to proxy B without
//! quit/restarting"). A route is how a harness reaches its model provider:
//! data in `<cmux config>/routes/<id>.toml`, never code, secrets only as
//! references (`keychain:ITEM`, `env:VAR`, `file:/PATH`). acpmux owns the store; the daemon
//! RPC (`_acpmux/route/*`, server/routes.rs) reads and writes it. There is no
//! `cmux route` command (Leo, 2026-10-21: "literally nobody but us is using
//! cmux "route" so just removing it is fine").
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
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub use crate::route_probe::{
    ProbeStatus, auto_probe_allowed, classify, probe, probes_for, reads_keychain,
    recent as recent_probe,
};

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

/// The profile-env key that names the route a profile binds by default (the
/// `cmux` harness: the `cmux` route). A chat or workspace binding still wins;
/// it replaces a family or global binding. Internal: never reaches the harness.
pub const PROFILE_ROUTE_KEY: &str = "ACPMUX_PROFILE_ROUTE";

/// The profile-env key that carries the bound route's name to the spawn, for the `/status`
/// card (`session_status.rs`). Internal: never reaches the harness.
pub const NAME_KEY: &str = "ACPMUX_ROUTE_NAME";

/// The built-in route to the hosted cmux model router through the local relay.
/// A route file named `cmux` replaces it; `find` resolves it, `load` does not list it.
pub const CMUX_ROUTE_ID: &str = "cmux";

/// The built-in route to the Codex CLI's own signed-in login (`~/.codex/auth.json`, or the chat's
/// `CODEX_HOME`): no endpoint and no account home, so a chat on it runs on the login Settings shows
/// as "ChatGPT / Codex". A codex chat whose route fails, and names no fallback of its own, moves
/// onto it by itself (`hub/route_switch.rs`). A route file named `codex-login` replaces it; `find`
/// resolves it, `load` does not list it (the Account menu already shows the CLI login).
pub const CODEX_LOGIN_ROUTE_ID: &str = "codex-login";

/// Whether the Codex CLI is signed in in `home` (its `CODEX_HOME`), else in `~/.codex`: an
/// `auth.json` with tokens or an API key, never an empty or broken one.
pub fn codex_signed_in(home: Option<&Path>) -> bool {
    let dir = match home {
        Some(home) => home.to_path_buf(),
        None => match dirs::home_dir() {
            Some(home) => home.join(".codex"),
            None => return false,
        },
    };
    crate::agent_login::signed_in_at(crate::agent_login::Agent::Codex, &dir)
}

fn builtin_routes() -> Vec<Route> {
    let codex_login = Route {
        id: CODEX_LOGIN_ROUTE_ID.into(),
        file: RouteFile {
            credential_instance: None,
            name: Some("ChatGPT (Codex CLI login)".into()),
            kind: RouteKind::DirectSubscription,
            families: vec!["codex".into()],
            anthropic_base_url: None,
            openai_base_url: None,
            auth: None,
            secret: None,
            claude_token_expires_at: None,
            cloud_enabled: None,
            headers: BTreeMap::new(),
            health_url: None,
            fallback: vec![],
            auto_fallback: false,
            notes: Some("built in: the Codex CLI's own signed-in login".into()),
            account_home: None,
            shadow_of: None,
            disabled: false,
            provider: None,
        },
        path: PathBuf::new(),
    };
    vec![
        codex_login,
        Route {
            id: CMUX_ROUTE_ID.into(),
            file: RouteFile {
                credential_instance: None,
                name: Some("cmux model router".into()),
                kind: RouteKind::CmuxRouter,
                families: vec![],
                anthropic_base_url: None,
                openai_base_url: None,
                auth: None,
                secret: None,
                claude_token_expires_at: None,
                cloud_enabled: None,
                headers: BTreeMap::new(),
                health_url: None,
                fallback: vec![],
                auto_fallback: false,
                notes: Some("built in: open-source models through the cmux model router".into()),
                account_home: None,
                shadow_of: None,
                disabled: false,
                provider: None,
            },
            path: PathBuf::new(),
        },
    ]
}

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
    /// Sign in with ChatGPT (`crate::chatgpt`): a ChatGPT plan's OAuth login this daemon holds
    /// and refreshes in `<acpmux home>/chatgpt/<id>.json`.
    ChatgptPlan,
    /// Claude Code's long-lived token from `claude setup-token`, as a secret reference
    /// Added by `_acpmux/connections/claude_token.add` for Cloud credential delivery.
    ClaudeToken,
    /// xAI device sign-in managed by acpmux.
    GrokPlan,
    /// GitHub device sign-in managed by acpmux and consumed by OpenCode.
    CopilotPlan,
    /// Kimi Code device sign-in managed by acpmux and consumed by OpenCode.
    KimiPlan,
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
        Self::ChatgptPlan,
        Self::ClaudeToken,
        Self::GrokPlan,
        Self::CopilotPlan,
        Self::KimiPlan,
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
            Self::ChatgptPlan => "chatgpt-plan",
            Self::ClaudeToken => "claude-token",
            Self::GrokPlan => "grok-plan",
            Self::CopilotPlan => "copilot-plan",
            Self::KimiPlan => "kimi-plan",
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
            Self::DirectSubscription
            | Self::ChatgptPlan
            | Self::ClaudeToken
            | Self::GrokPlan
            | Self::CopilotPlan
            | Self::KimiPlan => Auth::Subscription,
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

const CLOUD_POLICY_PREFIX: &str = "# cmux-cloud-enabled: ";
const LEGACY_LOCAL_KEY_PREFIX: &str = "local-only:";
const LOCAL_KEY_NOTES_PREFIX: &str = "# cmux-local-key-reference: ";
// Older builds accept an absolute file reference when loading a route, but
// their resolver refuses directories. The real reference stays in the notes.
const LOCAL_KEY_PLACEHOLDER: &str = if cfg!(windows) { "file:C:/" } else { "file:/" };

/// One route file. Field names are the TOML keys.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouteFile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub kind: RouteKind,
    /// The durable identity of this saved connection.
    #[serde(skip)]
    pub credential_instance: Option<String>,
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
    /// `keychain:ITEM`, `env:VAR` or `file:/ABSOLUTE/PATH` (an owner-only
    /// file read at each spawn: a short-lived token another process rotates);
    /// never the secret itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secret: Option<String>,
    /// Unix seconds, recorded when this Mac captures a Claude setup token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_token_expires_at: Option<u64>,
    /// The explicit Cloud preference, if set. Read the old TOML field too.
    #[serde(default, skip_serializing)]
    pub cloud_enabled: Option<bool>,
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
    /// A direct-subscription route's account home: the CLI's own config
    /// folder for one login (route_account.rs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_home: Option<String>,
    /// A Codex account home that shares everything but its login with this
    /// folder, the CLI's own home (route_shadow.rs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow_of: Option<String>,
    /// Turned off: no chat moves onto it by itself, and the account list says
    /// so. A chat bound to it still runs on it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub disabled: bool,
    /// The provider an API-key route's key is for (`anthropic`, `openai`, `openrouter`,
    /// `google`, `xai`; [`PROVIDERS`]). Absent: its family's (claude: anthropic, else openai).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
}

/// The providers an API-key connection may name (`_acpmux/connections/key.add`).
pub const PROVIDERS: &[&str] =
    &["anthropic", "openai", "openrouter", "google", "vertex-express", "xai"];

impl RouteFile {
    /// The provider this route pays: its own `provider`, a ChatGPT plan's OpenAI, else its
    /// family's (claude: anthropic, else openai).
    pub fn provider(&self) -> &str {
        if let Some(p) = self.provider.as_deref() {
            return p;
        }
        match self.families.first().map(String::as_str) {
            Some(f) if is_anthropic_family(f) => "anthropic",
            _ => "openai",
        }
    }
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

    /// Native key route for a provider whose harness does not read OpenAI variables.
    pub(crate) fn native_key_provider(&self) -> Option<crate::provider_cloud_auth::Provider> {
        use crate::provider_cloud_auth::Provider;
        match (self.file.kind, self.file.provider()) {
            (RouteKind::DirectApiKey, "google" | "vertex-express") => Some(Provider::Gemini),
            (RouteKind::DirectApiKey, "xai") => Some(Provider::Grok),
            _ => None,
        }
    }

    pub(crate) fn is_openrouter(&self) -> bool {
        self.file.kind == RouteKind::DirectApiKey
            && self.file.provider() == "openrouter"
            && self.file.openai_base_url.as_deref() == Some("https://openrouter.ai/api/v1")
            && self.file.headers.is_empty()
            && self.file.secret.is_some()
    }

    /// Whether a launch on this machine can use the route directly.
    pub(crate) fn check_local_launch(&self) -> Result<(), RouteError> {
        if self.file.kind == RouteKind::ClaudeToken {
            return Err(RouteError::Unavailable(format!(
                "route {} is a Cloud connection: its credential goes to a Cloud machine's agent, not a chat on this Mac",
                self.id
            )));
        }
        Ok(())
    }

    pub(crate) fn check_local_harness(
        &self,
        profile: Option<&crate::config::HarnessProfile>,
    ) -> Result<(), RouteError> {
        if self.file.kind == RouteKind::ChatgptPlan
            && !profile.is_some_and(|p| crate::codex_app_server::is_profile_launch(&p.argv))
        {
            return Err(RouteError::ChatgptAppServerRequired);
        }
        Ok(())
    }

    /// Whether it serves `family`.
    pub fn serves(&self, family: &str) -> bool {
        // Existing xAI route files were written for Codex. They can also serve the native CLI
        // without rewriting the user's routes or their existing Codex bindings.
        if self.native_key_provider().is_some_and(|provider| provider.name() == family) {
            return true;
        }
        if family == "openrouter" {
            return self.is_openrouter();
        }
        if let Some(provider) = crate::subscriptions::Provider::for_kind(self.file.kind) {
            return provider.family() == family;
        }
        if self.file.kind == RouteKind::ChatgptPlan {
            return crate::agent_credentials::Family::of_harness(family)
                == Some(crate::agent_credentials::Family::Codex);
        }
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
            RouteKind::ChatgptPlan => !is_anthropic_family(family),
            RouteKind::ClaudeToken => is_anthropic_family(family),
            _ => {
                if is_anthropic_family(family) {
                    self.file.anthropic_base_url.is_some() || self.file.kind.relayed()
                } else {
                    self.file.openai_base_url.is_some() || self.file.kind.relayed()
                }
            }
        }
    }

    /// The JSON `_acpmux/route/list` and `show` answer. Never a secret: the
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
            "accountHome": self.file.account_home,
            "shadowOf": self.file.shadow_of,
            "enabled": !self.file.disabled,
            "provider": self.file.provider,
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

pub(crate) fn is_anthropic_family(family: &str) -> bool {
    family == "claude"
}

#[derive(Debug, PartialEq)]
pub enum RouteError {
    BadParams(String),
    Exists(String),
    NotFound(String),
    SecretInline(String),
    Unavailable(String),
    ChatgptAppServerRequired,
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
            Self::ChatgptAppServerRequired => {
                "ChatGPT connections require a codex app-server harness."
            }
        }
    }

    /// The `error.data.reason` the RPC carries.
    pub fn reason(&self) -> Option<&'static str> {
        match self {
            Self::Exists(_) => Some("route.exists"),
            Self::NotFound(_) => Some("route.not_found"),
            Self::SecretInline(_) => Some("route.secret_inline"),
            Self::Unavailable(_) => Some("route.unavailable"),
            Self::ChatgptAppServerRequired => Some("chatgpt.app_server_required"),
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
    // Beside cmux.json when there is one: a DEV build's user harness folder is
    // in its acpmux home (`profiles::build_harness_dir`), its routes are not.
    let sources = &cfg.profile_sources;
    let config_dir = sources.cmux_json.as_deref().and_then(Path::parent);
    let routes = config_dir.map(|d| d.join("routes"));
    (routes.or_else(|| routes_dir(sources.user_dir.as_deref())), state)
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
    value.starts_with("keychain:")
        || value.starts_with("env:")
        || value.strip_prefix("file:").is_some_and(|p| Path::new(p).is_absolute())
}

/// Whether `id` names a route (lowercase letters, digits and `-`, at most 64).
pub fn is_route_id(id: &str) -> bool {
    valid_id(id)
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
    if file.kind == RouteKind::ClaudeToken {
        return Err(RouteError::BadParams(
            "add Claude token connections with `cmux cloud connect claude`".into(),
        ));
    }
    validate_contents(file)
}

fn validate_contents(file: &RouteFile) -> Result<(), RouteError> {
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
                "op:// references are not supported yet: add a model key with `cmux cloud connect api-key --provider anthropic|openai`, or store the secret in the Keychain and pass keychain:SERVICE/ACCOUNT".into(),
            ));
        }
        Some(s) if !is_reference(s) => {
            return Err(RouteError::SecretInline(
                "secret must be a reference (keychain:SERVICE/ACCOUNT, env:VAR or file:/ABSOLUTE/PATH), never the secret itself: add a model key with `cmux cloud connect api-key --provider anthropic|openai`, which stores it in the Keychain, or store it there yourself and pass keychain:SERVICE/ACCOUNT".into(),
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
                "header {name} looks secret: its value must be keychain:ITEM, env:VAR or file:/ABSOLUTE/PATH"
            )));
        }
    }
    let auth = file.auth.unwrap_or_else(|| file.kind.default_auth());
    if matches!(auth, Auth::ApiKey | Auth::Bearer) && file.secret.is_none() && !uses_relay(file) {
        return Err(RouteError::BadParams(format!(
            "auth {} needs secret (keychain:ITEM, env:VAR or file:/ABSOLUTE/PATH)",
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
    if let Some(p) = &file.provider
        && !PROVIDERS.contains(&p.as_str())
        && crate::subscriptions::Provider::for_kind(file.kind)
            .is_none_or(|provider| provider.name() != p.as_str())
    {
        return Err(RouteError::BadParams(format!(
            "unknown provider {p:?}: one of {}",
            PROVIDERS.join(", ")
        )));
    }
    if crate::subscriptions::Provider::for_kind(file.kind).is_some_and(|provider| {
        file.secret.is_some()
            || !file.headers.is_empty()
            || file.families.as_slice() != [provider.family()]
    }) {
        return Err(RouteError::BadParams(
            "a subscription route holds only the provider's harness family".into(),
        ));
    }
    if file.kind == RouteKind::ChatgptPlan && (file.secret.is_some() || !file.headers.is_empty()) {
        return Err(RouteError::BadParams(
            "a chatgpt-plan route holds no secret or header: its tokens are the daemon's own"
                .into(),
        ));
    }
    if file.kind == RouteKind::ClaudeToken
        && (file.secret.is_none() || file.families.as_slice() != ["claude"])
    {
        return Err(RouteError::BadParams(
            "a claude-token route serves claude and needs secret (keychain:ITEM)".into(),
        ));
    }
    crate::route_account::validate(file)
}

const CLAUDE_TOKEN_NOTES: &str = "claude setup-token: served to Cloud machines' Claude agents";

fn file_from_toml(text: &str) -> Result<RouteFile, RouteError> {
    let mut file: RouteFile =
        toml::from_str(text).map_err(|e| RouteError::Failed(e.to_string()))?;
    let mut opted_out = file.kind == RouteKind::DirectApiKey
        && file.secret.as_deref() == Some(LOCAL_KEY_PLACEHOLDER);
    if file.kind == RouteKind::DirectApiKey
        && let Some(reference) =
            file.secret.as_deref().and_then(|s| s.strip_prefix(LEGACY_LOCAL_KEY_PREFIX))
        && is_reference(reference)
    {
        file.secret = Some(reference.to_owned());
        opted_out = true;
    }
    validate_contents(&file)?;
    file.credential_instance = crate::agent_credentials::stored_instance(text);
    let mut header = text.lines();
    if file.credential_instance.is_some() {
        header.next();
    }
    if header.next().and_then(|line| line.strip_prefix(CLOUD_POLICY_PREFIX)) == Some("false") {
        file.cloud_enabled = Some(false);
    }
    if file.kind == RouteKind::DirectApiKey
        && let Some(notes) = &file.notes
        && let Some(instance) = crate::agent_credentials::stored_instance(notes)
        && let Some((_, policy)) = notes.split_once('\n')
        && let Some((policy, notes)) = policy.split_once('\n')
        && let Some((enabled, provider)) =
            policy.strip_prefix(CLOUD_POLICY_PREFIX).and_then(|policy| policy.split_once(' '))
        && let Ok(enabled) =
            if enabled == "default" { Ok(None) } else { enabled.parse::<bool>().map(Some) }
    {
        file.credential_instance = Some(instance);
        file.cloud_enabled = if provider == file.provider() { enabled } else { Some(false) };
        let mut notes = notes;
        if file.secret.as_deref() == Some(LOCAL_KEY_PLACEHOLDER)
            && let Some((encoded, remaining)) = notes.split_once('\n')
            && let Some(encoded) = encoded.strip_prefix(LOCAL_KEY_NOTES_PREFIX)
            && let Ok(reference) = serde_json::from_str::<String>(encoded)
            && is_reference(&reference)
        {
            file.secret = Some(reference);
            notes = remaining;
        }
        file.notes = (!notes.is_empty()).then(|| notes.to_owned());
    }
    if matches!(file.kind, RouteKind::ClaudeToken | RouteKind::ChatgptPlan)
        && let Some(notes) = &file.notes
        && let Some(instance) = crate::agent_credentials::stored_instance(notes)
        && let Some((_, notes)) = notes.split_once('\n')
    {
        file.credential_instance = Some(instance);
        file.notes = (!notes.is_empty()).then(|| notes.to_owned());
    }
    if opted_out {
        file.cloud_enabled = Some(false);
    }
    Ok(file)
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
            .and_then(|text| file_from_toml(&text).map_err(|e| e.to_string()));
        match parsed {
            Ok(file) => routes.push(Route { id, file, path }),
            Err(e) => problems.push(format!("{}: {e}", path.display())),
        }
    }
    (routes, problems)
}

pub fn find(dir: Option<&Path>, id: &str) -> Result<Route, RouteError> {
    // A route file wins; the built-in routes are found only by id (they are
    // not listed, so `route list` shows the user's own routes).
    load(dir)
        .0
        .into_iter()
        .find(|r| r.id == id)
        .or_else(|| builtin_routes().into_iter().find(|r| r.id == id))
        .ok_or_else(|| RouteError::NotFound(format!("no route {id:?}")))
}

/// The route file the RPC `add`/`edit` params (camelCase) describe.
pub fn file_from_json(params: &Value) -> Result<RouteFile, RouteError> {
    file_from_edit(params, false)
}

pub(crate) fn file_from_edit(
    params: &Value,
    keep_claude_token: bool,
) -> Result<RouteFile, RouteError> {
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
        credential_instance: None,
        name: text("name"),
        kind,
        families: strings("families"),
        anthropic_base_url: text("anthropicBaseUrl"),
        openai_base_url: text("openaiBaseUrl"),
        auth,
        secret: text("secret"),
        claude_token_expires_at: None,
        cloud_enabled: None,
        headers,
        health_url: text("healthUrl"),
        fallback: strings("fallback"),
        auto_fallback: params.get("autoFallback").and_then(Value::as_bool).unwrap_or(false),
        notes: text("notes"),
        account_home: crate::route_account::from_json(params)?,
        shadow_of: crate::route_account::shadow_from_json(params)?,
        disabled: match params.get("enabled").and_then(Value::as_bool) {
            Some(enabled) => !enabled,
            None => params.get("disabled").and_then(Value::as_bool).unwrap_or(false),
        },
        provider: text("provider"),
    };
    if keep_claude_token && file.kind == RouteKind::ClaudeToken {
        validate_contents(&file)?;
    } else {
        validate(&file)?;
    }
    Ok(file)
}

fn write_file(path: &Path, file: &RouteFile) -> Result<(), RouteError> {
    if keeps_instance_in_notes(file.kind)
        && let Some(instance) = &file.credential_instance
    {
        let mut disk = file.clone();
        disk.notes = Some(credential_notes(file, instance)?);
        if local_key_reference(file).is_some() {
            disk.secret = Some(LOCAL_KEY_PLACEHOLDER.into());
        }
        let text = toml::to_string_pretty(&disk).map_err(|e| RouteError::Failed(e.to_string()))?;
        return write_route_text(path, &text);
    }
    let text = toml::to_string_pretty(file).map_err(|e| RouteError::Failed(e.to_string()))?;
    let text = match &file.credential_instance {
        Some(instance) => crate::agent_credentials::with_stored_instance(&text, instance),
        None => text,
    };
    write_route_text(path, &text)
}

fn keeps_instance_in_notes(kind: RouteKind) -> bool {
    matches!(kind, RouteKind::DirectApiKey | RouteKind::ClaudeToken | RouteKind::ChatgptPlan)
}

fn local_key_reference(file: &RouteFile) -> Option<&str> {
    if file.kind == RouteKind::DirectApiKey
        && file.cloud_enabled == Some(false)
        && file.provider() != "openrouter"
    {
        return file.secret.as_deref().filter(|reference| *reference != LOCAL_KEY_PLACEHOLDER);
    }
    None
}

// Older writers preserve notes when they rewrite a route's name or enabled state.
fn credential_notes(file: &RouteFile, instance: &str) -> Result<String, RouteError> {
    let notes = file.notes.as_deref().unwrap_or("");
    if file.kind != RouteKind::DirectApiKey {
        return Ok(crate::agent_credentials::with_stored_instance(notes, instance));
    }
    let enabled = match file.cloud_enabled {
        Some(true) => "true",
        Some(false) => "false",
        None => "default",
    };
    let mut text = format!("{CLOUD_POLICY_PREFIX}{enabled} {}\n", file.provider());
    if let Some(reference) = local_key_reference(file) {
        let encoded = serde_json::to_string(reference)
            .map_err(|_| RouteError::Failed("could not write local key reference".into()))?;
        text.push_str(LOCAL_KEY_NOTES_PREFIX);
        text.push_str(&encoded);
        text.push('\n');
    }
    text.push_str(notes);
    Ok(crate::agent_credentials::with_stored_instance(&text, instance))
}

/// Backfill and restore keep the rest of the original TOML, including user comments.
fn write_credential_instance(
    path: &Path,
    text: &str,
    file: &RouteFile,
    instance: &str,
) -> Result<(), RouteError> {
    if !keeps_instance_in_notes(file.kind) {
        let text = crate::agent_credentials::with_stored_instance(text, instance);
        return write_route_text(path, &text);
    }
    let text = if crate::agent_credentials::stored_instance(text).is_some() {
        text.split_once('\n').map_or("", |(_, rest)| rest)
    } else {
        text
    };
    let mut doc: toml_edit::DocumentMut =
        text.parse().map_err(|_| RouteError::Failed("could not read route TOML".into()))?;
    if file.kind == RouteKind::DirectApiKey {
        doc.remove("cloud_enabled");
    }
    if local_key_reference(file).is_some() {
        let mut secret = toml_edit::Value::from(LOCAL_KEY_PLACEHOLDER);
        if let Some(previous) = doc.get("secret").and_then(toml_edit::Item::as_value) {
            *secret.decor_mut() = previous.decor().clone();
        }
        doc["secret"] = toml_edit::Item::Value(secret);
    }
    let mut notes = toml_edit::Value::from(credential_notes(file, instance)?);
    if let Some(previous) = doc.get("notes").and_then(toml_edit::Item::as_value) {
        *notes.decor_mut() = previous.decor().clone();
    }
    doc["notes"] = toml_edit::Item::Value(notes);
    write_route_text(path, &doc.to_string())
}

fn read_route_text(path: &Path) -> Result<String, RouteError> {
    use std::io::Read;
    let mut text = String::new();
    crate::home_fs::OpenOptions::new()
        .read(true)
        .open(path)
        .and_then(|mut file| file.read_to_string(&mut text))
        .map_err(|e| RouteError::Failed(e.to_string()))?;
    Ok(text)
}

fn write_route_text(path: &Path, text: &str) -> Result<(), RouteError> {
    if let Some(parent) = path.parent() {
        crate::home_fs::create_dirs(parent).map_err(|e| RouteError::Failed(e.to_string()))?;
    }
    let tmp = path.with_extension("toml.tmp");
    crate::home_fs::write(&tmp, text).map_err(|e| RouteError::Failed(e.to_string()))?;
    crate::router_socket::owner_only(&tmp);
    crate::home_fs::rename(&tmp, path).map_err(|e| RouteError::Failed(e.to_string()))
}

// Dev and release daemons can write the same route folder.
fn lock_route_files(dir: Option<&Path>) -> Result<cmux_file_lock::FileLock, RouteError> {
    let dir = dir.ok_or_else(|| RouteError::Failed("no cmux config folder".into()))?;
    let path = dir.join(".route-write.lock");
    let failed = |e: std::io::Error| RouteError::Failed(e.to_string());
    crate::config::refuse_lost_home(&path).map_err(|e| RouteError::Failed(e.to_string()))?;
    crate::home_fs::create_dirs(dir).map_err(failed)?;
    let file = crate::home_fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)
        .map_err(failed)?;
    cmux_file_lock::FileLock::take(file, cmux_file_lock::Kind::Exclusive).map_err(failed)
}

/// Recheck the saved connection under the same lock that Settings uses to turn Cloud use off.
/// The move pump drops the lock as soon as it writes the finish request.
pub fn lock_cloud_move_connection(
    path: &Path,
    id: &str,
    instance: Option<&str>,
) -> Result<cmux_file_lock::FileLock, RouteError> {
    let unavailable =
        || RouteError::Unavailable("the model connection is unavailable for Cloud".into());
    let dir = path.parent().filter(|_| path.is_absolute()).ok_or_else(unavailable)?;
    let guard = lock_route_files(Some(dir))?;
    let route = find(Some(dir), id)?;
    let file = route.file;
    let supported = match file.kind {
        RouteKind::DirectApiKey => {
            matches!(file.provider(), "anthropic" | "openai")
                && crate::server::connections::standard_key_endpoint(&file).is_some()
        }
        RouteKind::ClaudeToken | RouteKind::ChatgptPlan => true,
        _ => false,
    };
    if route.path == path
        && supported
        && !file.disabled
        && file.cloud_enabled.unwrap_or(true)
        && file.credential_instance.as_deref() == instance
    {
        Ok(guard)
    } else {
        Err(unavailable())
    }
}

/// Apply an edit to the latest file. An edit of a removed route fails at the read.
pub(crate) fn edit<R>(
    dir: Option<&Path>,
    id: &str,
    change: impl FnOnce(&mut RouteFile) -> Result<R, RouteError>,
) -> Result<(Route, R), RouteError> {
    let _guard = lock_route_files(dir)?;
    let mut file = find(dir, id)?.file;
    let kind = file.kind;
    let provider = file.provider().to_owned();
    let instance = file.credential_instance.clone();
    let key_ref = file.secret.clone().filter(|_| kind == RouteKind::DirectApiKey);
    let token_ref = file.secret.clone().filter(|_| kind == RouteKind::ClaudeToken);
    let result = change(&mut file)?;
    // A key with a different saved reference may belong to a different account.
    // Never let an edit choose its own identity.
    let changed_key = kind == RouteKind::DirectApiKey && key_ref != file.secret;
    let same_connection = kind == file.kind && provider == file.provider() && !changed_key;
    file.credential_instance = if same_connection { instance } else { None };
    if changed_key && file.kind == RouteKind::DirectApiKey {
        file.cloud_enabled = Some(false);
    }
    let keep_token =
        token_ref.is_some() && token_ref == file.secret && file.kind == RouteKind::ClaudeToken;
    let route = write_route(dir, id, file, true, keep_token)?;
    Ok((route, result))
}

/// Allocate and write the next Claude token route under the same lock.
pub(crate) fn add_claude_token(
    dir: Option<&Path>,
    secret: &str,
    label: Option<&str>,
) -> Result<Route, RouteError> {
    let _guard = lock_route_files(dir)?;
    let dir = dir.ok_or_else(|| RouteError::Failed("no cmux config folder".into()))?;
    let file = RouteFile {
        credential_instance: None,
        name: Some(
            label.map(str::trim).filter(|l| !l.is_empty()).unwrap_or("Claude Code token").into(),
        ),
        kind: RouteKind::ClaudeToken,
        families: vec!["claude".into()],
        anthropic_base_url: None,
        openai_base_url: None,
        auth: None,
        secret: Some(secret.into()),
        claude_token_expires_at: None,
        cloud_enabled: None,
        headers: Default::default(),
        health_url: None,
        fallback: vec![],
        auto_fallback: false,
        notes: Some(CLAUDE_TOKEN_NOTES.into()),
        account_home: None,
        shadow_of: None,
        disabled: false,
        provider: Some("anthropic".into()),
    };
    let id = std::iter::once("claude-token".to_owned())
        .chain((2..1000).map(|n| format!("claude-token-{n}")))
        .find(|id| !dir.join(format!("{id}.toml")).exists())
        .ok_or_else(|| RouteError::BadParams("too many Claude tokens".into()))?;
    write_route(Some(dir), &id, file, false, true)
}

/// Write a new route (`replace`: over an existing one).
pub fn add(
    dir: Option<&Path>,
    id: &str,
    file: &RouteFile,
    replace: bool,
) -> Result<Route, RouteError> {
    let _guard = lock_route_files(dir)?;
    let mut file = file.clone();
    file.credential_instance = None;
    if replace
        && let Ok(previous) = find(dir, id)
        && previous.file.kind == file.kind
    {
        let same_provider = previous.file.provider() == file.provider();
        let changed_key =
            file.kind == RouteKind::DirectApiKey && previous.file.secret != file.secret;
        if same_provider && !changed_key {
            file.credential_instance = previous.file.credential_instance;
        }
        if changed_key {
            file.cloud_enabled = Some(false);
        } else if file.kind == RouteKind::DirectApiKey
            && file.cloud_enabled.is_none()
            && (same_provider || previous.file.cloud_enabled == Some(false))
        {
            file.cloud_enabled = previous.file.cloud_enabled;
        }
    }
    write_route(dir, id, file, replace, false)
}

fn write_route(
    dir: Option<&Path>,
    id: &str,
    mut file: RouteFile,
    replace: bool,
    managed_claude_token: bool,
) -> Result<Route, RouteError> {
    if !valid_id(id) {
        return Err(RouteError::BadParams(format!(
            "{id:?} is not a route id (lowercase letters, digits and -)"
        )));
    }
    if managed_claude_token {
        validate_contents(&file)?;
    } else {
        validate(&file)?;
    }
    let dir = dir.ok_or_else(|| RouteError::Failed("no cmux config folder".into()))?;
    let path = dir.join(format!("{id}.toml"));
    if path.exists() && !replace {
        return Err(RouteError::Exists(format!("a route {id:?} exists (pass replace)")));
    }
    crate::route_account::prepare(&file)?;
    assign_credential_instance(&mut file);
    write_file(&path, &file)?;
    Ok(Route { id: id.to_owned(), file, path })
}

fn has_credential_instance(kind: RouteKind) -> bool {
    matches!(
        kind,
        RouteKind::DirectApiKey
            | RouteKind::DirectSubscription
            | RouteKind::ClaudeToken
            | RouteKind::ChatgptPlan
    ) || crate::subscriptions::Provider::for_kind(kind).is_some()
}

fn assign_credential_instance(file: &mut RouteFile) -> bool {
    if has_credential_instance(file.kind) && file.credential_instance.is_none() {
        file.credential_instance = Some(uuid::Uuid::new_v4().to_string());
        return true;
    }
    false
}

/// Read the route for delivery, assigning an identity to pre-existing files under the edit lock.
pub(crate) fn for_credential(dir: Option<&Path>, id: &str) -> Result<Route, RouteError> {
    let mut route = find(dir, id)?;
    ensure_credential_instance(dir, &mut route)?;
    Ok(route)
}

fn needs_credential_migration(file: &RouteFile, text: &str) -> bool {
    if crate::agent_credentials::stored_instance(text).is_some() {
        return true;
    }
    local_key_reference(file).is_some()
        && toml::from_str::<RouteFile>(text)
            .is_ok_and(|disk| disk.secret.as_deref() != Some(LOCAL_KEY_PLACEHOLDER))
}

/// Preserve delivered identities across older rewrites and protect older Cloud reads of local keys.
pub(crate) fn ensure_credential_instance(
    dir: Option<&Path>,
    route: &mut Route,
) -> Result<(), RouteError> {
    if route.path.as_os_str().is_empty() || !has_credential_instance(route.file.kind) {
        return Ok(());
    }
    if route.file.credential_instance.is_some()
        && (!keeps_instance_in_notes(route.file.kind)
            || !needs_credential_migration(&route.file, &read_route_text(&route.path)?))
    {
        return Ok(());
    }
    let Ok(_guard) = lock_route_files(dir) else { return Ok(()) };
    let text = read_route_text(&route.path)?;
    route.file = file_from_toml(&text)?;
    let assigned = assign_credential_instance(&mut route.file);
    if let Some(instance) = &route.file.credential_instance
        && (assigned
            || (keeps_instance_in_notes(route.file.kind)
                && needs_credential_migration(&route.file, &text)))
    {
        let written = write_credential_instance(&route.path, &text, &route.file, instance);
        if written.is_err() && assigned {
            // Read-only legacy routes can still start an agent with an unbound credential.
            route.file.credential_instance = None;
        }
    }
    Ok(())
}

/// Move a route to the backup folder; the backup's name restores it.
pub fn remove(dir: Option<&Path>, home: &Path, id: &str) -> Result<String, RouteError> {
    remove_with(dir, home, id, None, |_| Ok(()), |error| error).map(|(backup, ())| backup)
}

/// Validate the captured connection and clean up its credentials under the route write lock.
pub(crate) fn remove_with<T, E>(
    dir: Option<&Path>,
    home: &Path,
    id: &str,
    instance: Option<&str>,
    cleanup: impl FnOnce(&Route) -> Result<T, E>,
    route_error: impl Fn(RouteError) -> E,
) -> Result<(String, T), E> {
    let _guard = lock_route_files(dir).map_err(&route_error)?;
    let route = find(dir, id).map_err(&route_error)?;
    if route.path.as_os_str().is_empty() {
        return Err(route_error(RouteError::BadParams("built-in routes cannot be removed".into())));
    }
    if instance.is_some_and(|expected| route.file.credential_instance.as_deref() != Some(expected))
    {
        return Err(route_error(RouteError::BadParams(
            "the connection changed while it was open".into(),
        )));
    }
    let result = cleanup(&route)?;
    let backup = backup_removed_route(home, route).map_err(route_error)?;
    Ok((backup, result))
}

fn backup_removed_route(home: &Path, route: Route) -> Result<String, RouteError> {
    let id = route.id.as_str();
    let backups = prepare_backups(home)?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let name = format!("{id}.{stamp}.toml");
    if id.starts_with(ONE_RUN_PREFIX) {
        // A one-run chat keeps its binding so it cannot fall back to the owner's provider.
        crate::home_fs::remove_file(&route.path).map_err(route_storage_error)?;
        return Ok(name);
    }

    let _guard = BINDINGS_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let token_route = route.file.kind == RouteKind::ClaudeToken;
    // Keep the original text only in memory for token routes, which leave no backup.
    let token_text = token_route.then(|| read_route_text(&route.path)).transpose()?;
    // Record the withdrawal before removing the route. The connection list hides the marker
    // while this instance exists, including if the daemon stops before the move.
    let marker = route
        .file
        .credential_instance
        .as_deref()
        .map(|instance| write_disconnect(&backups, id, instance))
        .transpose()?;
    let discard_marker = || {
        if let Some(marker) = &marker
            && let Err(error) = crate::home_fs::remove_file(marker)
        {
            tracing::warn!(%error, "could not remove an uncommitted route withdrawal");
        }
    };
    let backup = backups.join(&name);
    let removed = if token_route {
        crate::home_fs::remove_file(&route.path)
    } else {
        crate::home_fs::rename(&route.path, &backup)
    };
    if let Err(error) = removed {
        discard_marker();
        return Err(route_storage_error(error));
    }

    // Chats bound to it fall back to their inherited route, and a workspace,
    // family or global default that named it is cleared, so new chats fall
    // back too instead of failing on a route that is gone.
    let mut b = bindings(home);
    b.chats.retain(|_, r| r != id);
    b.workspaces.retain(|_, r| r != id);
    b.families.retain(|_, r| r != id);
    b.connection_order.retain(|r| r != id);
    if b.global.as_deref() == Some(id) {
        b.global = None;
    }
    if let Err(error) = write_bindings(home, &b) {
        let restored = match token_text {
            Some(text) => write_route_text(&route.path, &text),
            None => crate::home_fs::rename(&backup, &route.path).map_err(route_storage_error),
        };
        match restored {
            Ok(()) => discard_marker(),
            Err(restore) => {
                tracing::warn!(%restore, "could not restore route after bindings write failed")
            }
        }
        return Err(error);
    }
    Ok(name)
}

fn route_storage_error(error: std::io::Error) -> RouteError {
    RouteError::Failed(error.to_string())
}

fn prepare_backups(home: &Path) -> Result<PathBuf, RouteError> {
    let backups = backups_dir(home);
    // The backup goes through the folder this daemon holds, even if the home is replaced.
    crate::config::refuse_lost_home(&backups).map_err(|e| RouteError::Failed(e.to_string()))?;
    crate::home_fs::create_dir_all(&backups, 0o777).map_err(route_storage_error)?;
    Ok(backups)
}

pub(crate) fn record_disconnect(
    home: &Path,
    id: &str,
    instance: &str,
) -> Result<PathBuf, RouteError> {
    write_disconnect(&prepare_backups(home)?, id, instance)
}

fn write_disconnect(backups: &Path, id: &str, instance: &str) -> Result<PathBuf, RouteError> {
    let path = backups.join(format!("{}.disconnect.json", uuid::Uuid::new_v4()));
    let tmp = path.with_extension("tmp");
    let bytes =
        serde_json::to_vec(&(id, instance)).map_err(|e| RouteError::Failed(e.to_string()))?;
    crate::home_fs::write_synced(&tmp, &bytes).map_err(route_storage_error)?;
    crate::home_fs::rename(&tmp, &path).map_err(route_storage_error)?;
    Ok(path)
}

/// Read the settings snapshot after any in-process Disconnect commits or rolls back.
pub(crate) fn bindings_with_disconnects(home: &Path) -> Bindings {
    let _guard = BINDINGS_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut b = bindings(home);
    // Keep legacy markers so a guest can still receive withdrawals saved by the prior build.
    if let Ok(entries) = std::fs::read_dir(backups_dir(home)) {
        for path in entries.flatten().map(|entry| entry.path()).filter(|path| {
            path.file_name()
                .and_then(std::ffi::OsStr::to_str)
                .is_some_and(|name| name.ends_with(".disconnect.json"))
        }) {
            if let Ok(bytes) = std::fs::read(path)
                && let Ok((id, instance)) = serde_json::from_slice::<(String, String)>(&bytes)
            {
                b.disconnected_credentials.entry(id).or_default().insert(instance);
            }
        }
    }
    b
}

/// Route ids a hand makes for one agent run (crates/acpmux/src/hand/gateway.rs).
pub const ONE_RUN_PREFIX: &str = "cmux-gateway-";

pub fn restore(dir: Option<&Path>, home: &Path, backup: &str) -> Result<Route, RouteError> {
    let _guard = lock_route_files(dir)?;
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
    crate::home_fs::create_dirs(dir).map_err(|e| RouteError::Failed(e.to_string()))?;
    let text = read_route_text(&from)?;
    let file = file_from_toml(&text)?;
    if file.credential_instance.is_some() || local_key_reference(&file).is_some() {
        write_credential_instance(&from, &text, &file, &uuid::Uuid::new_v4().to_string())?;
    }
    crate::home_fs::rename(&from, &to).map_err(|e| RouteError::Failed(e.to_string()))?;
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
    /// The person's connection order (`_acpmux/connections/order.set`); empty: the default
    /// order (`server/connections.rs`).
    #[serde(default, rename = "connection_order", skip_serializing_if = "Vec::is_empty")]
    pub connection_order: Vec<String>,
    /// Spread usage across my subscriptions (`_acpmux/connections/spread.set`); absent: off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spread: Option<bool>,
    /// Connections with no route file of their own that are turned off (`claude-login`;
    /// `_acpmux/account/set`). A route's own switch is its file's `disabled`.
    #[serde(default, rename = "disabled_connections", skip_serializing_if = "BTreeSet::is_empty")]
    pub disabled_connections: BTreeSet<String>,
    /// Explicit removals of delivered credentials, keyed by route id and saved instance.
    #[serde(
        default,
        rename = "disconnected_credentials",
        skip_serializing_if = "BTreeMap::is_empty"
    )]
    pub disconnected_credentials: BTreeMap<String, BTreeSet<String>>,
}

static BINDINGS_LOCK: Mutex<()> = Mutex::new(());

pub(crate) fn automatic_connection(
    dir: Option<&Path>,
    bindings: &Bindings,
    family: &str,
) -> Option<String> {
    load(dir)
        .0
        .into_iter()
        .filter(|route| !route.file.disabled && route.serves(family))
        .min_by_key(|route| {
            bindings.connection_order.iter().position(|id| id == &route.id).unwrap_or(usize::MAX)
        })
        .map(|route| route.id)
}

pub fn bindings(home: &Path) -> Bindings {
    std::fs::read_to_string(bindings_path(home))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// Resolve a chat binding and check it after reading the route, so a spawn that
/// read bindings just before a key replacement cannot pick up the new key.
pub(crate) fn find_chat_route(
    dir: Option<&Path>,
    home: &Path,
    session: &str,
    binding: &str,
) -> Result<Route, RouteError> {
    let (id, instance) =
        binding.split_once(':').map_or((binding, None), |(id, instance)| (id, Some(instance)));
    let route = find(dir, id)?;
    if instance.is_some_and(|expected| route.file.credential_instance.as_deref() != Some(expected))
        || bindings(home).chats.get(session).map(String::as_str) != Some(binding)
    {
        return Err(RouteError::NotFound(format!("no route {id:?}")));
    }
    Ok(route)
}

/// Preserve an explicitly bound chat's account before replacing a route's key.
/// Older daemons keep these string values and refuse them as unknown route IDs.
pub(crate) fn pin_replaced_key_bindings(
    home: &Path,
    id: &str,
    instance: &str,
) -> Result<(), RouteError> {
    let _guard = BINDINGS_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut b = bindings(home);
    let mut affected = b.chats.values_mut().filter(|route| route.as_str() == id).peekable();
    if affected.peek().is_some() {
        let binding = format!("{id}:{instance}");
        for route in affected {
            route.clone_from(&binding);
        }
        write_bindings(home, &b)?;
    }
    Ok(())
}

/// Change the bindings under one lock and write them atomically.
pub fn update_bindings(
    home: &Path,
    change: impl FnOnce(&mut Bindings),
) -> Result<Bindings, RouteError> {
    let _guard = BINDINGS_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let mut b = bindings(home);
    change(&mut b);
    write_bindings(home, &b)?;
    Ok(b)
}

fn write_bindings(home: &Path, b: &Bindings) -> Result<(), RouteError> {
    let path = bindings_path(home);
    // Not under a lost home (`config::refuse_lost_home`), and through the folder this daemon
    // holds (`home_fs`): a home replaced after the check never gets the bindings.
    let failed = |e: std::io::Error| RouteError::Failed(e.to_string());
    crate::config::refuse_lost_home(&path).map_err(|e| RouteError::Failed(e.to_string()))?;
    if let Some(parent) = path.parent() {
        crate::home_fs::create_dir_all(parent, 0o777).map_err(failed)?;
    }
    let tmp = path.with_extension("json.tmp");
    crate::home_fs::write_synced(&tmp, &serde_json::to_vec_pretty(b).unwrap_or_default())
        .map_err(failed)?;
    crate::home_fs::rename(&tmp, &path).map_err(failed)
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

pub(crate) fn set_default_binding(
    config: &crate::config::Config,
    scope: &str,
    route: Option<&str>,
) -> Result<Bindings, RouteError> {
    let (dir, home) = places(config);
    if let Some(id) = route {
        let found = find(dir.as_deref(), id)?;
        found.check_local_launch()?;
        // These scopes are shared by every harness they cover that can use the route.
        if found.file.kind == RouteKind::ChatgptPlan {
            for (name, profile) in &config.harnesses {
                let family = crate::config::derive_family(name, profile);
                if scope.strip_prefix("family:").is_none_or(|target| target == family)
                    && found.serves(&family)
                {
                    found.check_local_harness(Some(profile))?;
                }
            }
        }
        if found.file.disabled {
            return Err(RouteError::BadParams(format!(
                "{id} is turned off: turn it on before making it a default"
            )));
        }
    }
    set_binding(&home, scope, route)
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

/// The route a spawn of `family` on a profile with env `profile_env` takes, and the scope that
/// chose it: a chat or workspace binding, else the profile's own route ([`PROFILE_ROUTE_KEY`]),
/// else none for your own endpoint (`byo_endpoint.rs` names its provider itself), else a
/// family or global binding. The route may be gone or not serve the family; the caller checks.
pub fn spawn_route(
    dir: Option<&Path>,
    b: &Bindings,
    session_id: &str,
    workspace: Option<&str>,
    family: &str,
    profile_env: &BTreeMap<String, String>,
) -> Option<(String, &'static str)> {
    // Older builds could write a Cloud-only setup token as a local default.
    let usable_default = |id: &&String| {
        family != "claude" || !find(dir, id).is_ok_and(|route| route.check_local_launch().is_err())
    };
    b.chats
        .get(session_id)
        .map(|id| (id, "chat"))
        .or_else(|| {
            workspace
                .and_then(|w| b.workspaces.get(w))
                .filter(usable_default)
                .map(|id| (id, "workspace"))
        })
        .or_else(|| profile_env.get(PROFILE_ROUTE_KEY).map(|id| (id, "profile")))
        .or_else(|| {
            if crate::byo_endpoint::Kind::of_env(profile_env).is_some() {
                return None;
            }
            b.families
                .get(family)
                .filter(usable_default)
                .map(|id| (id, "family"))
                .or_else(|| b.global.as_ref().filter(usable_default).map(|id| (id, "global")))
        })
        .map(|(id, scope)| (id.clone(), scope))
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
/// Read from the running router (crate cmux-coderouter: its admin socket at
/// `cmux_coderouter::admin_socket_path`), never from a settings copy. One key
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
    use crate::router_socket::UnixStream;
    use std::io::{BufRead, BufReader, Write};
    static MINTED: Mutex<BTreeMap<(u64, String), String>> = Mutex::new(BTreeMap::new());
    let socket = cmux_coderouter::admin_socket_path(home);
    let unavailable = |what: String| {
        RouteError::Unavailable(format!(
            "the local CodeRouter is not running ({what}); start it with `acpmux router serve`"
        ))
    };
    let stream = UnixStream::connect(&socket).map_err(|e| unavailable(e.to_string()))?;
    let _ = stream.set_read_timeout(Some(crate::rpc::ANSWER_WAIT));
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

/// The model router's path on a Cloud machine's model plane: the inference gateway hands
/// `<origin>/router/v1/messages` to the model router as the machine's team (cmux-platform
/// `RouterRoute.ts`).
pub const CLOUD_ROUTER_PATH: &str = "/router";

/// The `https://` origin of this machine's model plane when it is a cmux Cloud machine (its
/// records under `root/etc/cmux`, or `CMUX_VM_ID`): the launch's `CMUX_CODEROUTER_URL`, else the
/// model-plane env file the image writes (`codex_cloud_auth::Inputs::team_origin`). There the
/// cmux model router is reached through the team's inference gateway, not a local CodeRouter
/// (Leo, 2026-11-15: "We're doing it through the gateway."). None on a Mac.
pub fn cloud_gateway_origin(
    root: &Path,
    home: &Path,
    var: &(dyn Fn(&str) -> Option<String> + Sync),
) -> Option<String> {
    if !crate::cloud_host::detect(&root.join("etc/cmux"), var("CMUX_VM_ID").as_deref()) {
        return None;
    }
    let inputs = crate::codex_cloud_auth::Inputs { root, home, var, broker: false };
    let origin = inputs.team_origin()?;
    let origin = origin.trim_end_matches('/');
    (origin.len() > "https://".len()).then(|| origin.to_owned())
}

/// The env a route gives a spawn of `family`.
pub fn env_for(route: &Route, family: &str, home: &Path) -> Result<RouteEnv, RouteError> {
    env_for_on(route, family, home, None)
}

/// [`env_for`] on a machine whose model plane is at `gateway` ([`cloud_gateway_origin`]). With
/// no local CodeRouter to carry it, the cmux model router's Claude goes to the gateway's model
/// router path with the image's public placeholder key: the machine's edge adds its own
/// credential, so no token is ever on the machine. A local CodeRouter, when one runs, still wins.
pub fn env_for_on(
    route: &Route,
    family: &str,
    home: &Path,
    gateway: Option<&str>,
) -> Result<RouteEnv, RouteError> {
    route.check_local_launch()?;
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
    if matches!(
        route.file.kind,
        RouteKind::ChatgptPlan | RouteKind::GrokPlan | RouteKind::CopilotPlan | RouteKind::KimiPlan
    ) {
        out.unset.extend(crate::agent_credentials::UNSET.iter().map(|key| (*key).to_owned()));
        return Ok(out);
    }
    if family == "openrouter" {
        out.unset.extend(crate::agent_credentials::UNSET.iter().map(|key| (*key).to_owned()));
        if let Some(secret) = &route.file.secret {
            out.set.insert("OPENROUTER_API_KEY".into(), reference_value(secret));
            out.set.insert(
                crate::agent_credentials::LOCAL_REDACTION.into(),
                "OPENROUTER_API_KEY".into(),
            );
        }
        return Ok(out);
    }
    if let Some(provider) = route.native_key_provider().filter(|provider| provider.name() == family)
    {
        out.unset.extend(provider.direct_env().map(str::to_owned));
        if let Some(reference) = &route.file.secret {
            let vertex = route.file.provider() == "vertex-express";
            let key = if vertex {
                crate::agent_credentials::VERTEX_EXPRESS_KEY
            } else {
                provider.api_key()
            };
            out.set.insert(key.into(), reference_value(reference));
            out.set.insert(crate::agent_credentials::LOCAL_REDACTION.into(), key.into());
            if provider == crate::provider_cloud_auth::Provider::Gemini {
                out.set.extend(
                    crate::provider_cloud_auth::gemini_key_env(vertex)
                        .into_iter()
                        .map(|(key, value)| (key.to_owned(), value.to_owned())),
                );
            }
        }
        return Ok(out);
    }
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
        let (relay, key) = match (local_router_with(home, family, cmux), gateway) {
            (Ok((url, key)), _) => (if anthropic { url } else { format!("{url}/v1") }, key),
            // The gateway's model router speaks the Messages API only.
            (Err(RouteError::Unavailable(_)), Some(origin)) if cmux && anthropic => (
                format!("{origin}{CLOUD_ROUTER_PATH}"),
                crate::codex_cloud_auth::PLACEHOLDER_KEY.to_owned(),
            ),
            (Err(e), _) => return Err(e),
        };
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
    if !anthropic {
        for (header, variable) in
            [("OpenAI-Organization", "OPENAI_ORGANIZATION"), ("OpenAI-Project", "OPENAI_PROJECT")]
        {
            if let Some((_, value)) =
                route.file.headers.iter().find(|(name, _)| name.eq_ignore_ascii_case(header))
            {
                let value =
                    if is_reference(value) { reference_value(value) } else { value.clone() };
                out.set.insert(variable.into(), value);
            }
        }
    }
    crate::route_account::set_env(route, family, &mut out.set);
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

pub(crate) fn resolve_reference(value: &str) -> Result<String, String> {
    if let Some(var) = value.strip_prefix("env:") {
        return crate::login_env::reference_var(var)
            .ok_or_else(|| format!("{var} is not set in the login environment"));
    }
    if let Some(path) = value.strip_prefix("file:") {
        return crate::config::profiles::file_secret(path);
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

#[cfg(test)]
#[path = "routes_tests.rs"]
mod tests;
