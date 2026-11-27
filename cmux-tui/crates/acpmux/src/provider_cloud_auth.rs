//! Gemini's and Grok's sign-in mode on a cmux Cloud machine, for the launches acpmux makes itself
//! (hq#11225). Leo, 2026-11-15: "We're doing it through the gateway."
//!
//! A team in inference gateway mode serves these agents on the machine's edge origin, the same
//! origin Claude and Codex team mode use (`codex_cloud_auth::Inputs::team_origin`): Grok at
//! `<origin>/xai/v1/...`, Gemini at `<origin>/v1beta/models/...`. The guest sends the public
//! placeholder key; the edge adds the machine token, and the Worker answers with the team's key (or
//! the owner's own on a personal machine), else a 401 that says `agent.sign_in_required`
//! (`recovery::start_sign_in` and `claude_auth::is_sign_in_failure` type it as a sign-in).
//!
//! [`decide_launch`] is `codex_cloud_auth::own_reason`'s rule for these two, on an owner machine
//! with the image's own-or-team script:
//!   env       `CMUX_GEMINI_AUTH` / `CMUX_GROK_AUTH` = `own|team` pins the launch;
//!   chosen    `~/.config/cmux/agent-auth/<agent>` holds `own` or `team` (`cr use`);
//!   login     no choice; the agent has its own sign-in (`agent_login::signed_in_at`);
//!   key       a key of its own in the env the launch gets ([`LaunchEnv`]: the vault's and
//!             `machine.env`'s values too, as Claude's check reads them): anything but the
//!             placeholder or a `cmux-secret://` reference, except the vault's own placeholder
//!             for that name, which its egress proxy fills; or one the login shell sets that
//!             this daemon has not read yet (#43800);
//!   endpoint  the person points it somewhere themselves (a base URL, Gemini's Vertex or Google
//!             sign-in switches, a Gemini `selectedType` other than an API key or gateway);
//!   no-team-plane / probe-failed / not-served: no `https://` origin, or the origin's
//!             `GET /cmux/v1/providers` did not answer in time, or says false for this agent.
//! Otherwise team: [`Provider::team_env`] on the launch env only (never a login shell). A team
//! machine (vm-kind not `owner`) is left alone, as for Codex.
//!
//! Gemini CLI (0.67, `acpSessionManager.ts`): with no `selectedType`, a set
//! `GOOGLE_GEMINI_BASE_URL` picks its `gateway` auth for both `session/new` and `session/load`,
//! whose key is `GEMINI_API_KEY`, sent as `x-goog-api-key` to that base URL
//! (`contentGenerator.ts`). With `selectedType` `gemini-api-key` it uses the same two. Grok
//! (`11-custom-models.md`): `GROK_MODELS_BASE_URL` is its base URL for inference, `XAI_API_KEY`
//! sent as `Authorization: Bearer`. Grok CLI 1.0.77 in ACP mode offers its `xai.api_key` auth
//! method, and so starts `session/new` with no sign-in, only when its probe of that key
//! (`GET <xAI API base>/api-key`) does not call the key unusable. The default base is the public
//! API, which refuses the placeholder, so `session/new` answered "Authentication required"
//! (#43857). `GROK_XAI_API_BASE_URL` (its `--xai-api-base-url`) moves the probe, and the title
//! and turn calls (`/responses`, `/chat/completions`), to the gateway. The gateway answers the
//! probe's path with a 404 before it checks the machine token (cmux-platform `ProviderRoute.ts`
//! `providerTarget`), which the probe takes as unknown, so the key method is offered. A 400, 401
//! or 403 there would make the probe call the key unusable and bring the refusal back.
//!
//! Antigravity (`agy acp`, 1.5.17) is served as Gemini: the same base URL and key, which it reads
//! only once told to (`acp_key_auth.rs` sends its `authenticate` with `gemini-api-key` when the
//! launch has a key, so the team's placeholder too). Its own sign-in is its token files, not
//! Gemini CLI's (`harness_health/agent_files.rs`); its pin is `CMUX_ANTIGRAVITY_AUTH`, its choice
//! `agent-auth/antigravity`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::codex_cloud_auth::{Inputs, PLACEHOLDER_KEY};

/// An agent the gateway serves besides Claude and Codex.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    Gemini,
    Grok,
    /// Google Antigravity's `agy`, on Gemini's gateway route (module docs).
    Antigravity,
}

impl Provider {
    /// The provider of a launch's family (`config::derive_family`).
    pub fn for_family(family: &str) -> Option<Provider> {
        match family {
            "gemini" => Some(Provider::Gemini),
            "grok" => Some(Provider::Grok),
            "antigravity" => Some(Provider::Antigravity),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Provider::Gemini => "gemini",
            Provider::Grok => "grok",
            Provider::Antigravity => "antigravity",
        }
    }

    /// The program that is the agent itself (`launches_itself`).
    fn program(self) -> &'static str {
        match self {
            Provider::Antigravity => "agy",
            other => other.name(),
        }
    }

    /// The agent has its own sign-in in `store` ([`Provider::store`]).
    fn signed_in(self, inputs: &Inputs<'_>, store: &std::path::Path) -> bool {
        match self {
            Provider::Gemini => {
                crate::agent_login::signed_in_at(crate::agent_login::Agent::Gemini, store)
            }
            Provider::Grok => {
                crate::agent_login::signed_in_at(crate::agent_login::Agent::Grok, store)
            }
            // The ACP server's token, or the `agy` CLI's (`harness_health/agent_files.rs`).
            Provider::Antigravity => [
                store.join("antigravity-acp/acp_token.json"),
                inputs.home.join(".gemini/antigravity-cli/antigravity-oauth-token"),
            ]
            .iter()
            .any(|f| std::fs::metadata(f).is_ok_and(|m| m.is_file() && m.len() > 0)),
        }
    }

    fn pin_var(self) -> &'static str {
        match self {
            Provider::Gemini => "CMUX_GEMINI_AUTH",
            Provider::Grok => "CMUX_GROK_AUTH",
            Provider::Antigravity => "CMUX_ANTIGRAVITY_AUTH",
        }
    }

    /// The env names whose value is a key of the person's own.
    fn key_vars(self) -> &'static [&'static str] {
        match self {
            Provider::Gemini | Provider::Antigravity => &["GEMINI_API_KEY", "GOOGLE_API_KEY"],
            Provider::Grok => &["XAI_API_KEY", "GROK_CODE_XAI_API_KEY"],
        }
    }

    /// The env names that point the agent somewhere of the person's choosing.
    fn endpoint_vars(self) -> &'static [&'static str] {
        match self {
            Provider::Gemini | Provider::Antigravity => &["GOOGLE_GEMINI_BASE_URL"],
            Provider::Grok => {
                &["GROK_MODELS_BASE_URL", "GROK_MODELS_LIST_URL", "GROK_XAI_API_BASE_URL"]
            }
        }
    }

    /// Where the agent keeps its sign-in (`agent_login::Cli::store`).
    fn store(self, inputs: &Inputs<'_>) -> PathBuf {
        let own = |k: &str| (inputs.var)(k).filter(|v| !v.is_empty()).map(PathBuf::from);
        match self {
            Provider::Gemini => {
                own("GEMINI_CLI_HOME").unwrap_or_else(|| inputs.home.to_owned()).join(".gemini")
            }
            Provider::Grok => own("GROK_HOME").unwrap_or_else(|| inputs.home.join(".grok")),
            Provider::Antigravity => {
                own("GEMINI_HOME").unwrap_or_else(|| inputs.home.join(".gemini"))
            }
        }
    }

    /// The env a team-mode launch gains for `origin` (no trailing slash needed); every name is in
    /// `agent_login::MODEL_PLANE_ENV`, so a sign-in never sees one.
    pub fn team_env(self, origin: &str) -> Vec<(String, String)> {
        let origin = origin.trim_end_matches('/');
        let pair = |k: &str, v: String| (k.to_owned(), v);
        match self {
            Provider::Gemini | Provider::Antigravity => vec![
                pair("GOOGLE_GEMINI_BASE_URL", origin.to_owned()),
                pair("GEMINI_API_KEY", PLACEHOLDER_KEY.to_owned()),
            ],
            Provider::Grok => vec![
                pair("GROK_MODELS_BASE_URL", format!("{origin}/xai/v1")),
                pair("GROK_XAI_API_BASE_URL", format!("{origin}/xai/v1")),
                pair("XAI_API_KEY", PLACEHOLDER_KEY.to_owned()),
            ],
        }
    }
}

/// A key of the person's own: set, not the placeholder every guest sends, not a vault reference.
fn own_key(value: &str) -> bool {
    let v = value.trim();
    !v.is_empty() && v != PLACEHOLDER_KEY && !v.starts_with("cmux-secret://")
}

/// Gemini's recorded auth choice (`settings.json` `security.auth.selectedType`, or the older
/// top-level `selectedAuthType`) when it is one team mode cannot use: anything but an API key or
/// the gateway. A file that does not read as JSON says nothing.
fn gemini_selects_another(store: &std::path::Path) -> bool {
    let Ok(text) = std::fs::read_to_string(store.join("settings.json")) else { return false };
    let Ok(settings) = serde_json::from_str::<serde_json::Value>(&text) else { return false };
    let selected = settings
        .pointer("/security/auth/selectedType")
        .or_else(|| settings.get("selectedAuthType"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    !matches!(selected, "" | "gemini-api-key" | "gateway")
}

/// What a launch does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    /// Not an owner cmux Cloud image: nothing here applies.
    LeftAlone,
    /// The agent keeps its own sign-in; the reason (module docs).
    Own(&'static str),
    /// The env to add to the launch.
    Team(Vec<(String, String)>),
}

/// What the probe found the gateway serves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Providers {
    pub gemini: bool,
    pub xai: bool,
}

impl Providers {
    fn serves(self, provider: Provider) -> bool {
        match provider {
            Provider::Gemini | Provider::Antigravity => self.gemini,
            Provider::Grok => self.xai,
        }
    }
}

/// The mode of one launch (module docs). `probe` asks the origin what it serves; it runs only
/// when nothing else decides, and None (no answer in time, any error) keeps own. A launch goes
/// through [`decide_launch`], which also knows the keys its env shows only as a reference.
#[cfg(test)]
async fn decide<F, Fut>(provider: Provider, inputs: &Inputs<'_>, probe: F) -> Mode
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = Option<Providers>>,
{
    decide_holding(provider, inputs, &|_| false, probe).await
}

/// [`decide`], where `held` names the keys the launch gets a value of the person's own for
/// that its env shows only as a reference ([`LaunchEnv::holds`]).
async fn decide_holding<F, Fut>(
    provider: Provider,
    inputs: &Inputs<'_>,
    held: &(dyn Fn(&str) -> bool + Sync),
    probe: F,
) -> Mode
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = Option<Providers>>,
{
    if !inputs.owner_cloud_image() {
        return Mode::LeftAlone;
    }
    let var = |k: &str| (inputs.var)(k).filter(|v| !v.is_empty());
    let pinned = match var(provider.pin_var()).as_deref().map(str::trim) {
        Some("own") => return Mode::Own("env"),
        Some("team") => true,
        _ => false,
    };
    let chosen = !pinned
        && match inputs.choice_for(provider.name()) {
            Some("own") => return Mode::Own("chosen"),
            Some(_) => true,
            None => false,
        };
    if !pinned && !chosen {
        let store = provider.store(inputs);
        if provider.signed_in(inputs, &store) {
            return Mode::Own("login");
        }
        let own = |k: &str| match var(k) {
            Some(v) => own_key(&v) || (held(k) && v.trim() == cmux_vault_egress::placeholder(k)),
            None => held(k),
        };
        if provider.key_vars().iter().any(|k| own(k)) {
            return Mode::Own("key");
        }
        let google_switch = || {
            ["GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA"]
                .iter()
                .any(|k| var(k).is_some_and(|v| v.trim().eq_ignore_ascii_case("true")))
        };
        let switched = match provider {
            Provider::Gemini => google_switch() || gemini_selects_another(&store),
            Provider::Antigravity => google_switch(),
            Provider::Grok => false,
        };
        if switched || provider.endpoint_vars().iter().any(|k| var(k).is_some()) {
            return Mode::Own("endpoint");
        }
    }
    let Some(origin) = inputs.team_origin() else { return Mode::Own("no-team-plane") };
    let origin = origin.trim_end_matches('/').to_owned();
    match probe(origin.clone()).await {
        None => Mode::Own("probe-failed"),
        Some(p) if !p.serves(provider) => Mode::Own("not-served"),
        Some(_) => Mode::Team(provider.team_env(&origin)),
    }
}

/// What the own-key check reads for one Cloud machine launch (`hub/spawn.rs`: Gemini and Grok
/// here, Claude through `claude_cloud_auth::launch_env`): the env the child gets
/// (`login_env::effective_with`: the daemon's env, the allow-listed login values, the vault's
/// entries, `machine.env`'s values, then the profile; for a remote-origin launch only the host
/// base and the profile), and the key names it gets a value of the person's own for that this env
/// shows only as a reference (#43800, #43821).
#[derive(Debug, Clone, Default)]
pub struct LaunchEnv {
    env: BTreeMap<String, String>,
    held: BTreeSet<String>,
}

impl LaunchEnv {
    /// The view of a launch of `family` with the (resolved) profile env `profile`, over the
    /// daemon's own env `daemon` (less `machine.env`'s names), the vault's entries `vault`
    /// (`vault::env_for_children`: a proxy entry as its `cmux-secret://NAME` placeholder, which
    /// the egress proxy fills), `machine.env`'s values `machine`, and `pending`, the secret names
    /// the login shell sets that this daemon does not hold yet (`login_env::missing_secret_names`).
    /// A `remote` (remote-origin) launch starts from the fixed host base `daemon`
    /// (`agent::host_environment`) and its profile only: no login value, vault entry or
    /// `machine.env` value reaches it (`agent/command.rs`), so none counts as its key.
    pub fn new(
        family: &str,
        profile: BTreeMap<String, String>,
        daemon: BTreeMap<String, String>,
        vault: Vec<(String, String)>,
        machine: BTreeMap<String, String>,
        pending: Vec<String>,
        remote: bool,
    ) -> LaunchEnv {
        if remote {
            let mut env = daemon;
            env.extend(profile);
            return LaunchEnv { env, held: BTreeSet::new() };
        }
        let held = vault
            .iter()
            .filter(|(k, v)| *v == cmux_vault_egress::placeholder(k))
            .map(|(k, _)| k.clone())
            .chain(pending)
            .collect();
        let env = crate::login_env::effective_with(
            Some(family),
            &profile,
            daemon.into_iter().collect(),
            vault,
            machine,
        );
        LaunchEnv { env, held }
    }

    /// [`LaunchEnv::new`] with this daemon's vault, `machine.env`, own env and pending secrets now;
    /// for a `remote` launch, the host base it starts from instead.
    pub fn now(family: &str, profile: BTreeMap<String, String>, remote: bool) -> LaunchEnv {
        if remote {
            let base = crate::agent::host_environment()
                .into_iter()
                .map(|(k, v)| (k.to_string_lossy().into_owned(), v.to_string_lossy().into_owned()))
                .collect();
            return LaunchEnv::new(
                family,
                profile,
                base,
                Vec::new(),
                BTreeMap::new(),
                Vec::new(),
                true,
            );
        }
        let vault = crate::login_env::vault_env();
        let machine = crate::login_env::machine_values();
        let daemon = crate::login_env::daemon_values().into_iter().collect();
        LaunchEnv::new(
            family,
            profile,
            daemon,
            vault,
            machine,
            crate::login_env::missing_secret_names(),
            false,
        )
    }

    /// The env the launch gets, for a check that reads it whole (Claude's, `claude_auth::find_in`).
    pub fn into_env(self) -> BTreeMap<String, String> {
        self.env
    }

    /// The launch's value of `k`; None when unset or empty.
    pub fn var(&self, k: &str) -> Option<String> {
        self.env.get(k).cloned().filter(|v| !v.is_empty())
    }

    /// Whether the launch gets a value of the person's own for `k` though its env shows none, or
    /// only `k`'s vault placeholder: a vault proxy entry, or a login-shell secret not read yet.
    /// Any other `cmux-secret://` reference, or the gateway placeholder, is still no key.
    pub fn holds(&self, k: &str) -> bool {
        self.held.contains(k)
    }
}

/// [`decide`] for one launch: its `HOME` (else this user's), the machine root `root`.
pub async fn decide_launch<F, Fut>(
    provider: Provider,
    launch: &LaunchEnv,
    root: &std::path::Path,
    probe: F,
) -> Mode
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = Option<Providers>>,
{
    let var = |k: &str| launch.var(k);
    let home = var("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
    let inputs = Inputs { root, home: &home, var: &var, broker: false };
    decide_holding(provider, &inputs, &|k| launch.holds(k), probe).await
}

/// Put team mode in a launch's profile env: [`Provider::team_env`] over whatever it had.
pub fn apply_team(env: &mut BTreeMap<String, String>, team: Vec<(String, String)>) {
    env.extend(team);
}

/// The longest a start waits for the probe, DNS included.
// timeout: a Gemini or Grok start waits at most this for the gateway probe, then starts without it
pub const PROBE_DEADLINE: Duration = Duration::from_secs(1);
/// How long an answer is reused, and a failure.
const PROBE_TTL: Duration = Duration::from_secs(60);
// timeout: not a wait; a failed probe is retried after this cache age
const PROBE_FAILED_TTL: Duration = Duration::from_secs(10);

type ProbeCache = Mutex<HashMap<String, (Instant, Option<Providers>)>>;
static PROBES: std::sync::LazyLock<ProbeCache> = std::sync::LazyLock::new(Default::default);

/// `GET <origin>/cmux/v1/providers` through the machine's edge, at most [`PROBE_DEADLINE`],
/// reused for a minute (a failure for 10 s). None on any failure.
pub async fn probe_providers(origin: String) -> Option<Providers> {
    let now = Instant::now();
    if let Some((at, answer)) = PROBES.lock().unwrap_or_else(|e| e.into_inner()).get(&origin) {
        let ttl = if answer.is_some() { PROBE_TTL } else { PROBE_FAILED_TTL };
        if now.duration_since(*at) < ttl {
            return *answer;
        }
    }
    let answer =
        tokio::time::timeout(PROBE_DEADLINE, fetch_providers(&origin)).await.ok().flatten();
    PROBES.lock().unwrap_or_else(|e| e.into_inner()).insert(origin, (Instant::now(), answer));
    answer
}

async fn fetch_providers(origin: &str) -> Option<Providers> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = crate::happy_dial::http_client()
        // timeout: the Cloud gateway's provider probe, before a Gemini or Grok start
        .timeout(PROBE_DEADLINE)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .ok()?;
    let response = client
        .get(format!("{origin}/cmux/v1/providers"))
        .bearer_auth(PLACEHOLDER_KEY)
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: serde_json::Value = response.json().await.ok()?;
    parse_providers(&body)
}

/// The probe's answer, `{gemini: bool, xai: bool}`; None for any other shape.
fn parse_providers(body: &serde_json::Value) -> Option<Providers> {
    Some(Providers { gemini: body.get("gemini")?.as_bool()?, xai: body.get("xai")?.as_bool()? })
}

/// Whether `argv` starts the agent itself (`gemini`, `grok`, `agy`), not a launcher that picks its
/// provider on its own.
pub fn launches_itself(provider: Provider, argv: &[String]) -> bool {
    argv.first()
        .and_then(|program| std::path::Path::new(program).file_name())
        .is_some_and(|name| name == provider.program())
}

#[cfg(test)]
#[path = "provider_cloud_auth_tests.rs"]
mod tests;
