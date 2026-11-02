//! Agent CLI health (hq #1875): for each harness, the program's installed
//! version, how it was installed, the newest version that channel offers,
//! whether it is signed in, and the commands that update it or sign it in.
//! Served as `_acpmux/harness/health` (`hub/health_view.rs`); checked when the
//! daemon starts and every few hours, and on request after an update.
//!
//! Sign-in is reported only from evidence: a profile's `auth.check` command,
//! else the hub's probe error naming sign-in (it can be older than a login
//! since). Without either it is `unknown`, never a guess from missing
//! credential files.

pub mod auto;
pub mod channel;
mod codex_provider;
pub(crate) mod inventory;
pub(crate) mod inventory_feed;
mod inventory_refresh;
pub(crate) use inventory_refresh::INVENTORY_REFRESH_FEATURE;
mod update_plan;
pub(crate) use update_plan::UPDATE_PLAN_FEATURE;
mod update_prepare;
pub(crate) use update_prepare::UPDATE_PREPARE_FEATURE;
pub mod latest;
pub mod probe;

use channel::{Channel, UpdatePlan};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

/// How often the daemon checks again.
pub const REFRESH_EVERY: Duration = Duration::from_secs(6 * 3600);
/// A newest-version answer younger than this is reused: a little under
/// `REFRESH_EVERY`, so each periodic check asks again.
const LATEST_TTL_MS: u64 = (6 * 3600 - 600) * 1000;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Auth {
    SignedIn,
    SignedOut,
    Expired,
    Unknown,
}

/// One harness's health.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HarnessHealth {
    pub id: String,
    /// The program as configured (the profile's first word).
    pub program: String,
    /// Where it was found.
    pub path: Option<String>,
    pub channel: Channel,
    /// The npm package or Homebrew formula behind it.
    pub package: Option<String>,
    pub version: Option<String>,
    pub latest: Option<String>,
    /// When `latest` was read (ms since the epoch).
    pub latest_checked_at: Option<u64>,
    pub outdated: bool,
    pub auth: Auth,
    /// Why `auth` is what it is (the probe error, or the check that ran).
    pub auth_detail: Option<String>,
    /// The command that signs it in, for a terminal tab.
    pub login: Option<String>,
    /// The command that updates it; None when only the way it was installed can.
    pub update: Option<UpdatePlan>,
    /// Why a part of the check failed (not installed, `--version` failed).
    pub problem: Option<String>,
    pub checked_at: u64,
    /// The person turned auto-update on for it (`auto.rs`; off by default).
    #[serde(default)]
    pub auto_update: bool,
    /// The last update auto-update ran for it, since the daemon started.
    #[serde(default)]
    pub last_auto_update: Option<auto::AutoUpdateResult>,
}

/// A harness to check, as the hub's configuration describes it.
#[derive(Clone, Debug)]
pub struct Subject {
    pub id: String,
    pub program: String,
    pub family: String,
    /// The profile's `auth.check` command.
    pub check: Vec<String>,
    /// The profile's env for the check (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`);
    /// values naming a secret or a login variable are left out.
    pub env: BTreeMap<String, String>,
    /// The profile's `auth.login` command.
    pub login: Option<String>,
    /// Env keys the profile sets to a value acpmux does not resolve here
    /// (`${...}`), left out of `env`.
    pub unresolved: Vec<String>,
    /// The hub's probe error for it (`Hub::probe_errors`).
    pub probe_error: Option<String>,
}

impl Subject {
    /// The harness `id` as `profile` and its profile file's `[auth]` describe
    /// it, without a probe error. None for an empty command line.
    pub fn of(
        id: &str,
        profile: &crate::config::HarnessProfile,
        auth: Option<&crate::config::profiles::AuthNotes>,
    ) -> Option<Self> {
        let (resolved, unresolved): (Vec<_>, Vec<_>) =
            profile.env.iter().partition(|(_, v)| !v.contains("${"));
        Some(Self {
            id: id.to_owned(),
            program: profile.argv.first()?.clone(),
            family: crate::config::derive_family(id, profile),
            check: auth.map(|a| a.check.clone()).unwrap_or_default(),
            env: resolved.into_iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
            login: auth.and_then(|a| a.login.clone()),
            unresolved: unresolved.into_iter().map(|(k, _)| k.clone()).collect(),
            probe_error: None,
        })
    }
}

/// Where the service asks and keeps its copy.
#[derive(Clone, Debug, Default)]
pub struct Settings {
    /// None: no newest-version lookups (the default until the daemon attaches;
    /// tests attach a loopback server).
    pub sources: Option<latest::Sources>,
    /// The saved copy (`<acpmux home>/harness-health.json`).
    pub cache: Option<PathBuf>,
    /// The user's home, where bun and the native installers live.
    pub home: PathBuf,
    /// The harnesses with auto-update on (`<acpmux home>/harness-auto-update.json`); None: none.
    pub auto_update: Option<PathBuf>,
    /// A capture fixture's rows (`harness_fixture.rs`): served as every
    /// check, with nothing read from this machine and no update run.
    pub fixture: Option<Vec<HarnessHealth>>,
}

#[derive(Default)]
pub struct HealthService {
    settings: Mutex<Settings>,
    rows: Mutex<Vec<HarnessHealth>>,
    inventory: inventory_feed::InventoryFeed,
    /// One check at a time.
    checking: tokio::sync::Mutex<()>,
    /// What auto-update ran, by harness id.
    ran: Mutex<HashMap<String, auto::AutoUpdateResult>>,
    /// One auto-update run at a time.
    updating: tokio::sync::Mutex<()>,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Login commands for the harnesses acpmux finds on PATH, which carry no
/// profile (`config/discover.rs`). A profile's `auth.login` comes first.
pub(crate) fn builtin_login(family: &str) -> Option<&'static str> {
    Some(match family {
        "codex" => "codex login",
        "claude" => "claude auth login",
        "gemini" => "gemini",
        "opencode" => "opencode auth login",
        "unii" => "unii login",
        "hermes" => "hermes model",
        _ => return None,
    })
}

/// Sign-in evidence for a harness with no `auth.check` (one acpmux found on
/// PATH), when its program is the agent itself (not a wrapper that runs it
/// elsewhere) and its home is the one named here. Read in the environment
/// the agent gets (`login_env::effective_for`: the login shell's
/// `CODEX_HOME`, `CLAUDE_CONFIG_DIR` and tokens count, hq#2569 #2).
///
/// Codex: a model provider that does not use the OpenAI sign-in (sr, a
/// router with `env_key`, a local server; `codex_provider`) decides by its
/// own credential, since `codex login status` says "Not logged in" there
/// while Codex works. Otherwise `codex login status` answers (also behind
/// codex-acp) when Codex keeps its login in a file. Claude's sign-in
/// sources (`claude_auth`) normally prove presence only. A sole, expired file login without
/// a refresh token is Expired off macOS only with complete project context; otherwise unknown.
///
/// Never the login keychain (cx-hh0vu): this check runs on its own (daemon
/// start, every few hours), and acpmux never asks the keychain on its own.
/// Claude's keychain item is not read (so `claude auth status` does not run
/// here), and `codex login status` does not run when Codex keeps its login
/// in the keychain (`cli_auth_credentials_store` `keyring` or `auto`): the
/// sign-in stays unknown. Nothing here writes a credential or starts a login.
fn builtin_auth(s: &Subject, cwd: Option<&Path>) -> Option<(Auth, Option<String>)> {
    // No credential read (Keychain, `codex login status`) while agent
    // launches are off (cx-9ettq): the sign-in stays unknown.
    if crate::launch_policy::agent_launch_disabled() {
        return None;
    }
    let program = Path::new(&s.program).file_name()?.to_string_lossy().to_lowercase();
    let home_named = |key: &str| !s.unresolved.iter().any(|k| k == key);
    match s.family.as_str() {
        "codex" if program.contains("codex") && home_named("CODEX_HOME") => {
            let env = crate::login_env::effective_for(Some("codex"), &s.env);
            match codex_provider::provider_auth(&env) {
                codex_provider::ProviderAuth::Configured(detail) => {
                    return Some((Auth::SignedIn, Some(detail)));
                }
                codex_provider::ProviderAuth::Missing(detail) => {
                    return Some((Auth::Unknown, Some(detail)));
                }
                codex_provider::ProviderAuth::OpenAiLogin => {}
            }
            if !codex_login_in_file(&env) {
                return None;
            }
            match probe::codex_login_status(&s.env)? {
                true => Some((Auth::SignedIn, Some("`codex login status` passed".into()))),
                false => {
                    Some((Auth::SignedOut, Some("`codex login status`: not logged in".into())))
                }
            }
        }
        "claude" if program.contains("claude") && home_named("CLAUDE_CONFIG_DIR") => {
            let env = crate::login_env::effective_for(Some("claude"), &s.env);
            let found = match cwd.filter(|_| s.unresolved.is_empty()) {
                Some(cwd) => crate::claude_auth::find_in(&env, cwd),
                None => crate::claude_auth::find(&env),
            };
            if found.expired_file_login {
                if !found.credential_sources_complete {
                    return Some((
                        Auth::Unknown,
                        Some("Claude file login expired; project credentials not verified".into()),
                    ));
                }
                return Some((
                    Auth::Expired,
                    Some("Claude file login expired; sign in again".into()),
                ));
            }
            found.signed_in().then(|| (Auth::SignedIn, Some(found.sources.join(", "))))
        }
        // UniiChat (the bundled `uniichat-agent`): the token `unii login`
        // keeps for the server the harness env names (UNII_URL, UNII_HOME).
        "unii" => {
            use crate::cli::uniichat_agent::{Endpoint, Options};
            let env = |key: &str| s.env.get(key).filter(|v| !v.is_empty()).cloned();
            let endpoint = Endpoint::resolve(
                &Options::default(),
                env("UNII_URL"),
                env("UNII_HOME"),
                env("HOME").map(PathBuf::from).or_else(dirs::home_dir),
            )
            .ok()?;
            Some(match endpoint.token() {
                Ok(_) => (
                    Auth::SignedIn,
                    Some(format!("{} holds a sign-in", endpoint.token_file.display())),
                ),
                Err(why) => (Auth::SignedOut, Some(why)),
            })
        }
        _ => None,
    }
}

/// Whether Codex keeps its login in `<CODEX_HOME>/auth.json`, so `codex
/// login status` reads a file and never the keychain: its config's
/// `cli_auth_credentials_store` is unset or `file` (Codex's default). A
/// config that does not parse, `keyring`, `auto` or another value: false.
fn codex_login_in_file(env: &BTreeMap<String, String>) -> bool {
    let Some(home) = codex_provider::codex_home(env) else { return false };
    let text = match std::fs::read_to_string(home.join("config.toml")) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return true,
        Err(_) => return false,
    };
    let Ok(config) = text.parse::<toml::Table>() else { return false };
    match config.get("cli_auth_credentials_store") {
        None => true,
        Some(value) => value.as_str() == Some("file"),
    }
}

/// Why starting harness `id` may read the login keychain, or None. A
/// caller that starts a harness to ask its sign-in (`cmux setup harness`)
/// skips it then, as this check does (cx-hh0vu): its profile env names a
/// Keychain item, it is Claude Code (whose login may be its keychain item;
/// `claude_auth` reads every other source), or it is Codex and Codex may
/// keep its login there (not `codex_login_in_file`, or a Codex home set by
/// a reference).
pub fn keychain_sign_in(id: &str, profile: &crate::config::HarnessProfile) -> Option<&'static str> {
    if crate::config::profiles::has_keychain_refs(&profile.env) {
        return Some("its profile's env names a Keychain item");
    }
    let s = Subject::of(id, profile, None)?;
    match s.family.as_str() {
        family if family.starts_with("claude") => {
            return Some("Claude Code may keep its login in its keychain item");
        }
        "codex" => {}
        _ => return None,
    }
    if s.unresolved.iter().any(|k| k == "CODEX_HOME") {
        return Some("its Codex home is not known until it starts");
    }
    let env = crate::login_env::effective_for(Some("codex"), &s.env);
    (!codex_login_in_file(&env))
        .then_some("Codex's `cli_auth_credentials_store` does not keep its login in a file")
}

/// A failed auth check is expired only when its own output says a credential expired
/// (`claude_auth::is_expired_credential`, the matcher a failed turn uses too), and unknown
/// when it says the provider had no capacity or the connection dropped: a transport error is
/// never a sign-in state (`turn_errors::says_unreachable`, as `recovery::auth_kind`).
fn auth_failure(output: &str) -> Auth {
    if crate::hub::turn_errors::says_unreachable(output) {
        Auth::Unknown
    } else if crate::claude_auth::is_expired_credential(output) {
        Auth::Expired
    } else {
        Auth::SignedOut
    }
}

/// One harness's sign-in, asked now for `_acpmux/session/auth {refresh}` (`hub/session_auth.rs`),
/// never from the saved check: the profile's `auth.check` when starting it cannot read the login
/// keychain ([`keychain_sign_in`]), else the built-in evidence that reads only files and
/// `codex login status` with a file login ([`builtin_auth`]). `profile` carries the chat's own
/// account home. Err: nothing here could answer without the keychain, or the check failed to
/// run; a failure to run is never a sign-in state.
pub(crate) fn fresh_auth(
    id: &str,
    profile: &crate::config::HarnessProfile,
    notes: Option<&crate::config::profiles::AuthNotes>,
) -> Result<(Auth, String), String> {
    fresh_auth_in(id, profile, notes, None)
}

/// A known session directory lets the file check account for project credentials. A target
/// without a directory, or a profile supplying its own settings, remains inconclusive.
pub(crate) fn fresh_auth_in(
    id: &str,
    profile: &crate::config::HarnessProfile,
    notes: Option<&crate::config::profiles::AuthNotes>,
    cwd: Option<&Path>,
) -> Result<(Auth, String), String> {
    let s = Subject::of(id, profile, notes).ok_or("the harness has no command")?;
    let keychain = keychain_sign_in(id, profile);
    if !s.check.is_empty() && keychain.is_none() {
        let check = s.check.join(" ");
        return match probe::auth_check(&s.check, &s.env, &s.family)? {
            (true, _) => Ok((Auth::SignedIn, format!("`{check}` passed"))),
            (false, output) => Ok((auth_failure(&output), format!("`{check}` failed"))),
        };
    }
    let custom_settings = profile.argv.iter().any(|arg| {
        arg == "--settings"
            || arg.starts_with("--settings=")
            || arg == "--setting-sources"
            || arg.starts_with("--setting-sources=")
    });
    match builtin_auth(&s, cwd.filter(|_| !custom_settings)) {
        Some((auth, detail)) if auth != Auth::Unknown => Ok((auth, detail.unwrap_or_default())),
        _ => Err(match keychain {
            Some(why) => format!("no check ran: {why}, which acpmux does not read"),
            None => "the harness has no sign-in check acpmux can run".to_owned(),
        }),
    }
}

static SIGN_IN: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
    regex::Regex::new(r"(?i)\b(not (logged|signed) in|log ?in|sign ?in|unauthenticated|authentication required|auth required|unauthorized)\b")
        .expect("sign-in pattern") // crash-allow: constant pattern
});

/// Whether a CLI's message names signing in (`_acpmux/complete` tells a
/// signed-out harness by it, as the health check does by a probe error).
pub fn names_sign_in(text: &str) -> bool {
    SIGN_IN.is_match(text)
}

impl HealthService {
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets where to ask and keep the copy, and reads the saved copy.
    pub fn attach(&self, settings: Settings) {
        if let Some(rows) = &settings.fixture {
            self.replace_rows(rows.clone());
            *self.settings.lock().unwrap_or_else(PoisonError::into_inner) = settings;
            return;
        }
        let saved = settings
            .cache
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice::<Vec<HarnessHealth>>(&b).ok());
        if let Some(mut rows) = saved {
            // A saved plan predates this binary's target binding. Keep its
            // observations, but do not expose an unbound npm command to any
            // consumer (including Settings' visible-terminal update path).
            for row in &mut rows {
                if row.channel == channel::Channel::Npm
                    && row.update.as_ref().is_some_and(|plan| {
                        !channel::npm_update_matches(plan, row.package.as_deref())
                    })
                {
                    row.update = None;
                }
                if row.channel == channel::Channel::Bun
                    && row.update.as_ref().is_some_and(|plan| {
                        !channel::bun::matches(plan, row.package.as_deref(), row.path.as_deref())
                    })
                {
                    row.update = None;
                }
            }
            self.replace_rows(rows);
        }
        *self.settings.lock().unwrap_or_else(PoisonError::into_inner) = settings;
    }

    /// Whether a capture fixture's rows stand in for this machine's.
    pub(crate) fn fixed(&self) -> bool {
        self.settings.lock().unwrap_or_else(PoisonError::into_inner).fixture.is_some()
    }

    /// The last check's rows (the saved copy until the first check).
    pub fn rows(&self) -> Vec<HarnessHealth> {
        self.rows.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// The first check: callers that ask before any check ended share one (the
    /// daemon's own, or the first caller's) instead of each running a full check.
    pub async fn first_check(&self, subjects: Vec<Subject>) -> Vec<HarnessHealth> {
        drop(self.checking.lock().await);
        let rows = self.rows_for_subjects(&subjects);
        if rows.is_empty() { self.check(subjects, false).await } else { rows }
    }

    /// Cached observations with login commands from the current profiles. Never write
    /// this projection back: a check may publish newer observations concurrently.
    pub(crate) fn rows_for_subjects(&self, subjects: &[Subject]) -> Vec<HarnessHealth> {
        let mut rows = self.rows();
        if !self.fixed() {
            rebind_cached_logins(&mut rows, subjects);
        }
        rows
    }

    /// Checks every subject on this machine, and asks each channel for its
    /// newest version unless a fresh answer is kept (always with `check_latest`).
    pub async fn check(&self, subjects: Vec<Subject>, check_latest: bool) -> Vec<HarnessHealth> {
        let _one = self.checking.lock().await;
        let settings = self.settings.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if settings.fixture.is_some() {
            return self.rows();
        }
        let previous = self.rows();
        let probes = subjects.into_iter().map(|s| {
            let home = settings.home.clone();
            tokio::task::spawn_blocking(move || local(s, &home))
        });
        let mut rows: Vec<HarnessHealth> =
            futures::future::join_all(probes).await.into_iter().filter_map(Result::ok).collect();
        let now = now_ms();
        let mut asked: HashMap<String, Option<String>> = HashMap::new();
        for row in &mut rows {
            let kept = previous.iter().find(|p| {
                p.id == row.id
                    && p.channel == row.channel
                    && p.package == row.package
                    && p.latest.is_some()
            });
            let fresh = kept.filter(|p| {
                p.latest_checked_at.is_some_and(|t| now.saturating_sub(t) < LATEST_TTL_MS)
            });
            let install = channel::Install {
                channel: row.channel,
                package: row.package.clone(),
                writes: None,
            };
            let url = settings.sources.as_ref().and_then(|s| latest::url(&install, s));
            match (fresh, url) {
                (Some(p), _) if !check_latest => {
                    row.latest = p.latest.clone();
                    row.latest_checked_at = p.latest_checked_at;
                }
                (_, Some(url)) => {
                    if !asked.contains_key(&url) {
                        let answer = match latest::fetch_json(&url).await {
                            Ok(body) => latest::parse(row.channel, &body),
                            Err(e) => {
                                tracing::info!(harness = %row.id, error = %e, "newest version not read");
                                None
                            }
                        };
                        asked.insert(url.clone(), answer);
                    }
                    match asked[&url].clone() {
                        Some(v) => (row.latest, row.latest_checked_at) = (Some(v), Some(now)),
                        None => {
                            row.latest = kept.and_then(|p| p.latest.clone());
                            row.latest_checked_at = kept.and_then(|p| p.latest_checked_at);
                        }
                    }
                }
                _ => {}
            }
            row.outdated =
                matches!((&row.latest, &row.version), (Some(l), Some(v)) if probe::is_newer(l, v));
        }
        self.mark_auto(&mut rows, &settings);
        if let Some(path) = settings.cache.as_deref() {
            save(path, &rows);
        }
        self.replace_rows(rows.clone());
        rows
    }
}

fn rebind_cached_logins(rows: &mut [HarnessHealth], subjects: &[Subject]) {
    for row in rows {
        let Some(subject) = subjects.iter().find(|subject| subject.id == row.id) else {
            row.login = None;
            continue;
        };
        row.login = crate::route_account::login_command(
            subject.login.clone().or_else(|| builtin_login(&subject.family).map(str::to_owned)),
            crate::route_account::home_var(&subject.family)
                .and_then(|var| subject.env.get(var).map(|home| (var, Path::new(home.as_str())))),
        );
    }
}

fn save(path: &Path, rows: &[HarnessHealth]) {
    let Ok(body) = serde_json::to_vec_pretty(rows) else { return };
    // Owner-only whatever the umask, through a new temporary file each time.
    if let Err(e) = crate::config::write_atomic(path, &body) {
        tracing::info!(error = %e, "harness health not saved");
    }
}

/// The part of a check that runs here: where the program is, how it was
/// installed, its version, its sign-in, and its update and login commands.
fn local(s: Subject, home: &Path) -> HarnessHealth {
    let mut found = if Path::new(&s.program).is_absolute() {
        Path::new(&s.program).is_file().then(|| s.program.clone())
    } else {
        crate::config::which(&s.program)
    };
    let real = found.as_deref().and_then(|p| std::fs::canonicalize(p).ok());
    let install = channel::detect(&s.program, real.as_deref(), home);
    let mut problem = None;
    let version = match (&found, install.channel) {
        (_, Channel::Launcher) => None,
        (None, _) => {
            problem = Some(format!("`{}` is not installed", s.program));
            None
        }
        (Some(path), _) => probe::installed_version(path).map_err(|e| problem = Some(e)).ok(),
    };
    let update =
        channel::update_plan(&install, found.as_deref().map(Path::new), real.as_deref(), home);
    if install.channel == Channel::Bun
        && let (Some(plan), Some(path)) = (&update, &found)
    {
        found = channel::bun::recorded_path(plan, Path::new(path))
            .and_then(|path| path.to_str().map(str::to_owned));
    }
    // Without a profile check, the agent's own answer; a sign-in it proves,
    // or a provider that `codex login` cannot fix, outranks an older probe's
    // sign-in error.
    let builtin = (s.check.is_empty() && found.is_some()).then(|| builtin_auth(&s, None)).flatten();
    let (auth, auth_detail) = match &s.probe_error {
        _ if !s.check.is_empty() && found.is_some() => {
            match probe::auth_check(&s.check, &s.env, &s.family) {
                Ok((true, _)) => (Auth::SignedIn, Some(format!("`{}` passed", s.check.join(" ")))),
                Ok((false, output)) => {
                    let auth = auth_failure(&output);
                    let detail = match auth {
                        Auth::Expired => "credential expired".to_owned(),
                        Auth::Unknown => {
                            format!("`{}` could not reach its provider", s.check.join(" "))
                        }
                        _ => format!("`{}` failed", s.check.join(" ")),
                    };
                    (auth, Some(detail))
                }
                Err(e) => (Auth::Unknown, Some(e)),
            }
        }
        _ if builtin.as_ref().is_some_and(|(auth, _)| *auth != Auth::SignedOut) => {
            builtin.unwrap_or((Auth::Unknown, None))
        }
        Some(e) if SIGN_IN.is_match(e) || auth_failure(e) == Auth::Expired => {
            (auth_failure(e), Some(e.clone()))
        }
        _ => builtin.unwrap_or((Auth::Unknown, None)),
    };
    HarnessHealth {
        id: s.id,
        // In the account home the check read (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`), so Log In
        // signs that login in, not the default one.
        login: crate::route_account::login_command(
            s.login.or_else(|| builtin_login(&s.family).map(str::to_owned)),
            crate::route_account::home_var(&s.family)
                .and_then(|var| s.env.get(var).map(|home| (var, Path::new(home.as_str())))),
        ),
        program: s.program,
        path: found,
        channel: install.channel,
        package: install.package,
        version,
        latest: None,
        latest_checked_at: None,
        outdated: false,
        auth,
        auth_detail,
        update,
        problem,
        checked_at: now_ms(),
        auto_update: false,
        last_auto_update: None,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Auth, Channel, HarnessHealth, HealthService, Subject, auth_failure, codex_login_in_file,
    };
    use serde_json::json;
    use std::collections::BTreeMap;

    /// Hermes keeps its provider and model in ~/.hermes: `hermes model` picks
    /// them (an API key or a provider sign-in), which is the sign-in a Chief on
    /// Hermes needs.
    #[test]
    fn hermes_signs_in_with_hermes_model() {
        assert_eq!(super::builtin_login("hermes"), Some("hermes model"));
    }

    #[test]
    fn expired_login_probe_is_not_just_signed_out() {
        assert_eq!(auth_failure("OAuth token has expired"), Auth::Expired);
        assert_eq!(auth_failure("Not logged in"), Auth::SignedOut);
        assert_eq!(auth_failure("check failed"), Auth::SignedOut);
        assert_eq!(auth_failure("HTTP 503"), Auth::Unknown);
        assert_eq!(auth_failure("HTTP 502: authentication_failed"), Auth::Unknown);
        assert_eq!(auth_failure("Not logged in? HTTP 503: authentication_failed"), Auth::Unknown);
        assert_eq!(auth_failure("token expired? connection refused"), Auth::Unknown);
        assert_eq!(auth_failure("Your refresh token has expired; run codex login"), Auth::Expired);
        assert_eq!(auth_failure("the MCP session expired"), Auth::SignedOut);
        assert_eq!(auth_failure("Provided authentication token is expired."), Auth::Expired);
        assert_eq!(auth_failure("credential expired"), Auth::Expired);
        // Only a statement that a credential expired: not its expiry field, not a future one.
        assert_eq!(auth_failure("HTTP 400: invalid token expiry value"), Auth::SignedOut);
        assert_eq!(
            auth_failure("Not logged in; the credential expires in 30 days"),
            Auth::SignedOut
        );
        assert_eq!(serde_json::to_value(Auth::Expired).unwrap(), json!("expired"));
    }

    /// A profile whose CLI keeps its login in an account home of its own (`CODEX_HOME`,
    /// `CLAUDE_CONFIG_DIR`) is checked there, so its Log In signs in there too, not the
    /// default home.
    #[test]
    fn log_in_signs_in_the_account_home_the_check_reads() {
        let subject =
            |id: &str, family: &str, env: &[(&str, &str)], login: Option<&str>| super::Subject {
                id: id.into(),
                program: format!("/nonexistent/{family}"),
                family: family.into(),
                check: vec![],
                env: env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
                login: login.map(str::to_owned),
                unresolved: vec![],
                probe_error: None,
            };
        let home = std::path::Path::new("/nonexistent-home");
        let login = |s| super::local(s, home).login;
        assert_eq!(
            login(subject("codex-work", "codex", &[("CODEX_HOME", "/Users/me/.codex-work")], None)),
            Some("CODEX_HOME=/Users/me/.codex-work codex login".into())
        );
        assert_eq!(
            login(subject(
                "claude-two",
                "claude",
                &[("CLAUDE_CONFIG_DIR", "/Users/me/claude two")],
                None
            )),
            Some("CLAUDE_CONFIG_DIR='/Users/me/claude two' claude auth login".into())
        );
        // A profile's own login, in the same home.
        assert_eq!(
            login(subject("codex-sr", "codex", &[("CODEX_HOME", "~/.codex-sr")], Some("sr login"))),
            Some("CODEX_HOME=~/.codex-sr sr login".into())
        );
        // No account home: unchanged.
        assert_eq!(login(subject("codex", "codex", &[], None)), Some("codex login".into()));
        assert_eq!(
            login(subject("gemini", "gemini", &[("CODEX_HOME", "/elsewhere")], None)),
            Some("gemini".into())
        );
    }

    #[tokio::test]
    async fn first_check_rebinds_a_cached_login_to_the_current_profile_home() {
        let service = HealthService::new();
        service.replace_rows(vec![HarnessHealth {
            id: "codex-sr".into(),
            program: "codex".into(),
            path: None,
            channel: Channel::Standalone,
            package: None,
            version: None,
            latest: None,
            latest_checked_at: None,
            outdated: false,
            auth: Auth::SignedOut,
            auth_detail: None,
            login: Some("codex login".into()),
            update: None,
            problem: None,
            checked_at: 1,
            auto_update: false,
            last_auto_update: None,
        }]);
        let subject = Subject {
            id: "codex-sr".into(),
            program: "codex".into(),
            family: "codex".into(),
            check: vec![],
            env: BTreeMap::from([(String::from("CODEX_HOME"), String::from("/tmp/codex-sr"))]),
            login: Some("codex login".into()),
            unresolved: vec![],
            probe_error: None,
        };
        let rows = service.first_check(vec![subject]).await;
        assert_eq!(rows[0].login.as_deref(), Some("CODEX_HOME=/tmp/codex-sr codex login"));
    }

    fn home_with(n: usize, config: Option<&str>) -> (std::path::PathBuf, BTreeMap<String, String>) {
        let dir = std::env::temp_dir().join(format!("amx-codex-store-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        if let Some(text) = config {
            std::fs::write(dir.join("config.toml"), text).unwrap();
        }
        let env = BTreeMap::from([("CODEX_HOME".to_owned(), dir.display().to_string())]);
        (dir, env)
    }

    /// `codex login status` runs only when Codex keeps its login in a file
    /// (cx-hh0vu): never when it may read the keychain.
    #[test]
    fn codex_login_status_runs_only_for_a_file_login() {
        for (n, (config, file)) in [
            (None, true),
            (Some("model = \"o3\"\n"), true),
            (Some("cli_auth_credentials_store = \"file\"\n"), true),
            (Some("cli_auth_credentials_store = \"keyring\"\n"), false),
            (Some("cli_auth_credentials_store = \"auto\"\n"), false),
            (Some("cli_auth_credentials_store = 1\n"), false),
            (Some("not toml ["), false),
        ]
        .into_iter()
        .enumerate()
        {
            let (dir, env) = home_with(n, config);
            assert_eq!(codex_login_in_file(&env), file, "{config:?}");
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    /// A harness whose start may read the keychain is named, so a caller
    /// that asks a harness its sign-in does not start it (cx-hh0vu).
    #[test]
    fn keychain_sign_in_names_keychain_references_and_a_codex_keychain_login() {
        let (keyring, keyring_env) =
            home_with(10, Some("cli_auth_credentials_store = \"keyring\"\n"));
        let (file, file_env) = home_with(11, None);
        for (argv, env, keychain) in [
            ("gemini", json!({"API_KEY": "${keychain:cmux-harness/gemini/API_KEY}"}), true),
            ("gemini", json!({"API_KEY": "${env:API_KEY}"}), false),
            ("claude-agent-acp", json!({}), true),
            ("codex-acp", json!({"CODEX_HOME": keyring_env["CODEX_HOME"]}), true),
            ("codex-acp", json!({"CODEX_HOME": file_env["CODEX_HOME"]}), false),
            ("codex-acp", json!({"CODEX_HOME": "${env:SOME_CODEX_HOME}"}), true),
        ] {
            let profile: crate::config::HarnessProfile =
                serde_json::from_value(json!({"argv": [argv], "env": env})).unwrap();
            let why = super::keychain_sign_in(argv, &profile);
            assert_eq!(why.is_some(), keychain, "{argv} {env}: {why:?}");
        }
        let _ = std::fs::remove_dir_all(keyring);
        let _ = std::fs::remove_dir_all(file);
    }
}
