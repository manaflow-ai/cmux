//! The login shell's environment, the one a person's terminal has.
//!
//! A daemon started by launchd, the app, the Chief or a non-login ssh shell
//! has a bare environment: no `ANTHROPIC_*`, no tool PATH, none of the
//! exports in `.zshenv`/`.zprofile`/`.zshrc`. Agents then behave differently
//! from the same command in a terminal ("Not logged in"). Every daemon reads
//! the login shell's environment (`ACPMUX_LOGIN_ENV=0` turns it off) and
//! applies it to every process it spawns. The daemon's own process
//! environment is never changed: the runtime is multi-threaded by then.
//!
//! Rule (precedence, high to low): the profile's, preset's and session's
//! env; the daemon's own environment; the login shell's. Two exceptions:
//! PATH is the login PATH first, then the daemon's other entries; and a
//! daemon started inside a Claude Code session (`CLAUDECODE` set) drops that
//! session's `CLAUDE*`/`ANTHROPIC_*` keys from every child
//! (`config::scrub_nested_claude_env`), so for those keys the login shell's
//! value is the one the child gets.
//!
//! Cost: the shell runs at most once per daemon start, off the request path,
//! with a hard limit of `TIMEOUT`, then the daemon falls back to its cache
//! and logs. `<ACPMUX_HOME>/login-env.json` (0600) keeps the last result,
//! keyed by a fingerprint (path, size, mtime) of the shell's startup files
//! and tool-manager configs. It holds only non-secret variables and the
//! NAMES of secret ones; secret values live in this process's memory only.
//! A start whose fingerprint matches and needs no secret value never runs
//! the shell; a changed fingerprint (checked at most every 10 s when an
//! agent spawns) refreshes it in the background.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

/// The hard limit for one login shell run.
pub const TIMEOUT: Duration = Duration::from_secs(3);
/// How often an agent spawn may stat the startup files for a change.
const RECHECK: Duration = Duration::from_secs(10);
/// A cache older than this is refreshed in the background at start: the
/// fingerprint cannot see files the startup files source.
const MAX_AGE: Duration = Duration::from_secs(24 * 3600);
/// Printed before `env -0`, so rc-file chatter on stdout is skipped; one
/// random suffix per run, so no rc file can print it ahead of time.
const MARKER: &str = "__ACPMUX_LOGIN_ENV__";

fn run_marker() -> String {
    use sha2::{Digest, Sha256};
    let seed =
        format!("{}:{:?}:{:?}", std::process::id(), std::time::SystemTime::now(), Instant::now());
    let hex: String =
        Sha256::digest(seed.as_bytes()).iter().take(8).map(|b| format!("{b:02x}")).collect();
    format!("{MARKER}{hex}")
}
const CACHE_VERSION: u32 = 2;

#[derive(Debug, Default, Clone)]
struct Imported {
    /// Variables the children get (see the precedence rule above).
    vars: Vec<(String, String)>,
    /// Login PATH first, then the daemon's PATH entries it did not list.
    path: Option<String>,
}

/// How the last resolution went, for `_acpmux/status` logs and the sign-in
/// explanation (`claude_auth.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing resolved yet.
    None,
    /// The cache's non-secret part (its fingerprint matched).
    Cached,
    /// A login shell run finished in time.
    Shell,
    /// The shell failed or passed `TIMEOUT`; the cache (if any) stands in.
    Failed,
}

struct State {
    imported: Option<Imported>,
    outcome: Outcome,
    fingerprint: Option<String>,
    /// Names of secret variables the login shell sets (values not cached).
    secret_names: Vec<String>,
    last_check: Option<Instant>,
}

static STATE: RwLock<State> = RwLock::new(State {
    imported: None,
    outcome: Outcome::None,
    fingerprint: None,
    secret_names: Vec::new(),
    last_check: None,
});
static ENABLED: AtomicBool = AtomicBool::new(false);
static REFRESHING: AtomicBool = AtomicBool::new(false);

/// Whether this daemon reads the login environment: always, unless
/// `ACPMUX_LOGIN_ENV=0`.
pub fn requested() -> bool {
    std::env::var("ACPMUX_LOGIN_ENV").as_deref() != Ok("0")
}

/// `pending`, `imported`, or `not_requested` (for `_acpmux/status`).
pub fn state(requested: bool) -> &'static str {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    match (&st.imported, requested) {
        (Some(_), _) => "imported",
        (None, true) if st.outcome == Outcome::Failed => "imported",
        (None, true) => "pending",
        (None, false) => "not_requested",
    }
}

/// How the last resolution went.
pub fn outcome() -> Outcome {
    STATE.read().unwrap_or_else(|e| e.into_inner()).outcome
}

/// What `begin` found and what startup should do next.
pub struct Plan {
    /// Run the login shell (in the background or awaited, see `wait`).
    pub run_shell: bool,
    /// Agent spawns wait for that run (bounded by `TIMEOUT`) only when
    /// Claude has no sign-in without it (the daemon's environment, settings
    /// files, credentials file, keychain) and there is no matching cache or
    /// the cache names a secret whose value this process lacks.
    pub wait: bool,
}

/// Start resolution: apply a matching cache at once, and say whether the
/// shell must run. Fast: stats and one small file read (plus, only when
/// the cache lacks secret values, the Claude sign-in sources check).
pub fn begin() -> Plan {
    ENABLED.store(true, Ordering::SeqCst);
    let fingerprint = fingerprint();
    let cache = load_cache().filter(|c| c.fingerprint == fingerprint);
    let mut st = STATE.write().unwrap_or_else(|e| e.into_inner());
    st.fingerprint = Some(fingerprint);
    st.last_check = Some(Instant::now());
    let Some(cache) = cache else {
        // First start, or edited startup files: spawns wait for the shell.
        return Plan { run_shell: true, wait: true };
    };
    let stale = cache.saved_at.is_none_or(|t| now_secs().saturating_sub(t) > MAX_AGE.as_secs());
    // Only names the current rule keeps (an older cache may hold more).
    let vars = cache.vars.into_iter().filter(|(k, v)| storable(k, v)).collect();
    st.imported = Some(build(for_children(vars), cache.path));
    st.outcome = Outcome::Cached;
    st.secret_names = cache.secret_names.clone();
    drop(st);
    let missing = cache.secret_names.iter().any(|n| !daemon_has(n));
    if !missing {
        // A file the startup files source may have changed: past MAX_AGE,
        // refresh in the background (spawns use the cache meanwhile).
        return Plan { run_shell: stale, wait: false };
    }
    // Secret values are never cached: the shell runs; spawns wait for it
    // unless Claude signs in without it (keychain, settings, env).
    Plan { run_shell: true, wait: !crate::claude_auth::direct_sign_in() }
}

/// The daemon's own environment holds `key` for its children: a daemon
/// inside a Claude Code session does not pass that session's keys on.
fn daemon_has(key: &str) -> bool {
    std::env::var_os(key).is_some()
        && !(std::env::var_os("CLAUDECODE").is_some() && crate::config::is_nested_claude_key(key))
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Run the login shell once (bounded by `TIMEOUT`) and remember its
/// environment. Returns true when the children's environment changed.
pub async fn import() -> bool {
    let shell =
        std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/zsh".into());
    let started = Instant::now();
    let before = pairs();
    let marker = run_marker();
    let output = run_shell(&shell, &marker).await;
    let elapsed = started.elapsed();
    let Some(text) = output else {
        let mut st = STATE.write().unwrap_or_else(|e| e.into_inner());
        st.outcome = Outcome::Failed;
        let cached = st.imported.is_some();
        tracing::warn!(
            shell = %shell,
            ms = elapsed.as_millis() as u64,
            cache = cached,
            "login shell env: no result within {}s; using {}",
            TIMEOUT.as_secs(),
            if cached { "the cached copy" } else { "the daemon's own environment" }
        );
        return false;
    };
    let (login, login_path) = parse_env0(&text, &marker);
    // Only what a child or the daemon itself may use is kept, in memory too.
    let login: Vec<(String, String)> = login.into_iter().filter(|(k, v)| storable(k, v)).collect();
    save_cache(&login, login_path.as_deref());
    let imported = build(for_children(login), login_path);
    let added = imported.vars.len();
    let mut st = STATE.write().unwrap_or_else(|e| e.into_inner());
    st.imported = Some(imported);
    st.outcome = Outcome::Shell;
    drop(st);
    tracing::info!(shell = %shell, added, ms = elapsed.as_millis() as u64, "imported login shell environment");
    pairs() != before
}

/// Called before each agent spawn: when the startup files changed since the
/// last resolution (checked at most every `RECHECK`), refresh in the
/// background. Never waits.
pub fn refresh_if_changed() {
    if !ENABLED.load(Ordering::SeqCst) {
        return;
    }
    {
        let mut st = STATE.write().unwrap_or_else(|e| e.into_inner());
        if st.last_check.is_some_and(|t| t.elapsed() < RECHECK) {
            return;
        }
        st.last_check = Some(Instant::now());
    }
    let now = fingerprint();
    let changed =
        STATE.read().unwrap_or_else(|e| e.into_inner()).fingerprint.as_deref() != Some(&now);
    if !changed || REFRESHING.swap(true, Ordering::SeqCst) {
        return;
    }
    let Ok(rt) = tokio::runtime::Handle::try_current() else {
        REFRESHING.store(false, Ordering::SeqCst);
        return;
    };
    STATE.write().unwrap_or_else(|e| e.into_inner()).fingerprint = Some(now);
    rt.spawn(async {
        tracing::info!("shell startup files changed; reading the login environment again");
        import().await;
        if outcome() == Outcome::Failed {
            // Try again at a later spawn.
            STATE.write().unwrap_or_else(|e| e.into_inner()).fingerprint = None;
        }
        REFRESHING.store(false, Ordering::SeqCst);
    });
}

/// `$SHELL -l -i -c` printing the marker and `env -0`: no terminal, stdin
/// from /dev/null, in its own process group (killed with everything it
/// started when `TIMEOUT` passes). The parent Claude session's own keys are
/// not passed in, so what comes back is the person's setup.
async fn run_shell(shell: &str, marker: &str) -> Option<String> {
    let mut cmd = tokio::process::Command::new(shell);
    cmd.args(["-l", "-i", "-c", &format!("printf '\\n{marker}\\n'; command env -0")])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    // Only the identity a login shell starts from, as a terminal gives it:
    // nothing of the daemon's own environment (a sandboxed starter's proxy,
    // PATH or endpoints) can come back as "the login environment".
    cmd.env_clear();
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
        if let Some(v) = std::env::var_os(key) {
            cmd.env(key, v);
        }
    }
    for (key, v) in std::env::vars_os() {
        if key.to_str().is_some_and(|k| k.starts_with("LC_")) {
            cmd.env(key, v);
        }
    }
    cmd.env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("SHELL", shell)
        .env("ACPMUX_LOGIN_ENV", "0");
    // Its own session: no controlling terminal (an interactive shell cannot
    // take the terminal a foreground daemon runs in), and its process group
    // id is its pid (killed as a group on timeout).
    #[cfg(unix)]
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("login shell env: {shell}: {e}");
            return None;
        }
    };
    let pid = child.id();
    match tokio::time::timeout(TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(out)) => Some(String::from_utf8_lossy(&out.stdout).into_owned()),
        Ok(Err(e)) => {
            tracing::warn!("login shell env: {shell}: {e}");
            None
        }
        Err(_) => {
            // The future (and the shell) is dropped; its group goes too.
            #[cfg(unix)]
            if let Some(pid) = pid {
                unsafe {
                    libc::killpg(pid as i32, libc::SIGKILL);
                }
            }
            None
        }
    }
}

/// The login variables children get: those the daemon's environment lacks,
/// and inside a Claude Code session the keys the nested scrub removes.
fn for_children(login: Vec<(String, String)>) -> Vec<(String, String)> {
    let nested = std::env::var_os("CLAUDECODE").is_some();
    login
        .into_iter()
        .filter(|(k, _)| {
            std::env::var_os(k).is_none() || (nested && crate::config::is_nested_claude_key(k))
        })
        .collect()
}

fn build(vars: Vec<(String, String)>, login_path: Option<String>) -> Imported {
    let path = login_path.map(|lp| {
        let current = std::env::var("PATH").unwrap_or_default();
        let mut merged: Vec<String> =
            lp.split(':').filter(|p| !p.is_empty()).map(str::to_owned).collect();
        for p in current.split(':') {
            if !p.is_empty() && !merged.iter().any(|m| m == p) {
                merged.push(p.to_owned());
            }
        }
        merged.join(":")
    });
    let vars = vars.into_iter().filter(|(k, _)| k != "PATH").collect();
    Imported { vars, path }
}

/// The PATH spawned processes see.
pub fn path() -> Option<OsString> {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    if let Some(p) = st.imported.as_ref().and_then(|i| i.path.clone()) {
        return Some(p.into());
    }
    std::env::var_os("PATH")
}

/// The PATH an agent sees: [`path`] with the directory of the app's bundled
/// CLI (`CMUX_BUNDLED_CLI_PATH`, set by the app that started this daemon)
/// first, so `cmux` in an agent chat is that app's CLI and not one the login
/// PATH lists earlier (cx-c6xdh). Plain [`path`] without that variable.
pub fn agent_path() -> Option<OsString> {
    let path = path();
    let Some(bin) = std::env::var_os(BUNDLED_CLI_ENV)
        .map(std::path::PathBuf::from)
        .and_then(|cli| cli.parent().map(std::path::Path::to_path_buf))
        .filter(|bin| bin.is_absolute())
    else {
        return path;
    };
    let rest = path.iter().flat_map(std::env::split_paths).filter(|entry| *entry != bin);
    let joined = std::env::join_paths(std::iter::once(bin.clone()).chain(rest)).ok();
    joined.or(path)
}

/// The app's bundled `cmux` (BundledCLIEnvironment.swift).
pub const BUNDLED_CLI_ENV: &str = "CMUX_BUNDLED_CLI_PATH";

/// A variable the import added, by name.
pub fn var(key: &str) -> Option<String> {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    st.imported.as_ref()?.vars.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
}

/// Keys the import adds on top of the daemon's environment.
pub fn imported_keys() -> Vec<String> {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    st.imported
        .as_ref()
        .map(|i| i.vars.iter().map(|(k, _)| k.clone()).collect())
        .unwrap_or_default()
}

/// Secret variable names the login shell sets whose values this process
/// does not hold (the shell has not answered since a cached start).
pub fn missing_secret_names() -> Vec<String> {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    let have = |n: &str| {
        daemon_has(n) || st.imported.as_ref().is_some_and(|i| i.vars.iter().any(|(k, _)| k == n))
    };
    st.secret_names.iter().filter(|n| !have(n)).cloned().collect()
}

fn pairs() -> Vec<(String, String)> {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    let Some(i) = &st.imported else { return Vec::new() };
    let mut out = i.vars.clone();
    if let Some(p) = &i.path {
        out.push(("PATH".into(), p.clone()));
    }
    out
}

static EXTRA_ALLOW: RwLock<Vec<String>> = RwLock::new(Vec::new());

/// Names the person added to the allow-list (`loginEnvAllow` in
/// config.json; default empty). Exact names, or a prefix ending in `*`.
pub fn set_extra_allow(names: Vec<String>) {
    *EXTRA_ALLOW.write().unwrap_or_else(|e| e.into_inner()) = names;
}

fn is_on(v: Option<String>) -> bool {
    v.is_some_and(|v| !v.is_empty() && v != "0" && !v.eq_ignore_ascii_case("false"))
}

/// The person's own switch: the daemon's environment (not a parent Claude
/// Code session's) or the login shell. Only this one unlocks secrets.
fn person_switch(key: &str) -> bool {
    is_on(std::env::var(key).ok().filter(|_| daemon_has(key)).or_else(|| var(key)))
}

/// A harness profile's own switch. Any local client can add a profile (an
/// agent too, through ACPMUX_SOCKET), so it unlocks only non-secret names.
fn profile_switch(key: &str, profile: Option<&BTreeMap<String, String>>) -> bool {
    is_on(profile.and_then(|p| p.get(key).cloned()))
}

/// The AWS names a profile's Bedrock switch may unlock.
const AWS_PUBLIC: [&str; 5] = [
    "AWS_PROFILE",
    "AWS_REGION",
    "AWS_DEFAULT_REGION",
    "AWS_CONFIG_FILE",
    "AWS_SHARED_CREDENTIALS_FILE",
];

fn aws_allowed(key: &str, profile: Option<&BTreeMap<String, String>>) -> bool {
    key.starts_with("AWS_")
        && (person_switch("CLAUDE_CODE_USE_BEDROCK")
            || (AWS_PUBLIC.contains(&key) && profile_switch("CLAUDE_CODE_USE_BEDROCK", profile)))
}

fn vertex_allowed(key: &str, value: &str, profile: Option<&BTreeMap<String, String>>) -> bool {
    // Region names: CLOUD_ML_REGION exactly, VERTEX_REGION_* when not secret.
    let region =
        key == "CLOUD_ML_REGION" || (key.starts_with("VERTEX_REGION_") && !is_secret(key, value));
    let google =
        key.starts_with("GOOGLE_") || key.starts_with("CLOUDSDK_") || key.starts_with("GCLOUD_");
    if !region && !google {
        return false;
    }
    person_switch("CLAUDE_CODE_USE_VERTEX")
        || (profile_switch("CLAUDE_CODE_USE_VERTEX", profile) && !is_secret(key, value))
}

/// The allow-list: which login-shell variables a child of `family`
/// (`claude`, `codex`, else none) gets. Every other variable stays in the
/// daemon (GITHUB_TOKEN, GH_TOKEN, NPM_TOKEN, ...), unless the person adds
/// its name to `loginEnvAllow`.
///
/// - Every child: PATH (login PATH first); version-manager variables that
///   find the binary (MISE_*, ASDF_*, NVM_*, VOLTA_*, never a secret under
///   them; BUN_INSTALL); proxies (HTTPS_PROXY, HTTP_PROXY, ALL_PROXY,
///   NO_PROXY, both cases); custom CA (NODE_EXTRA_CA_CERTS, SSL_CERT_FILE,
///   SSL_CERT_DIR).
/// - Claude: ANTHROPIC_*, CLAUDE_* (CLAUDE_CODE_* included), DISABLE_* and
///   *_TELEMETRY. With the person's own CLAUDE_CODE_USE_BEDROCK (daemon env
///   or login shell): AWS_*; with only a profile's switch: AWS_PROFILE,
///   AWS_REGION, AWS_DEFAULT_REGION, AWS_CONFIG_FILE,
///   AWS_SHARED_CREDENTIALS_FILE. With the person's own
///   CLAUDE_CODE_USE_VERTEX: GOOGLE_*, CLOUDSDK_*, GCLOUD_*, CLOUD_ML_REGION,
///   VERTEX_REGION_* (not secret); with only a profile's switch, the
///   non-secret ones of those.
/// - Codex: OPENAI_*, CODEX_*.
///
/// Known limit: the family comes from the profile (`config::derive_family`),
/// and any local client can add a profile (an agent through ACPMUX_SOCKET).
/// A profile whose id or argv names `claude` gets the Claude list
/// (ANTHROPIC_*, CLAUDE_CODE_OAUTH_TOKEN): the same reach an agent has by
/// running `zsh -lic env` itself.
pub fn allowed(key: &str, value: &str, family: Option<&str>) -> bool {
    allowed_with(key, value, family, None)
}

/// `allowed`, with the harness profile's env deciding the Bedrock and
/// Vertex conditions too.
pub fn allowed_with(
    key: &str,
    value: &str,
    family: Option<&str>,
    profile: Option<&BTreeMap<String, String>>,
) -> bool {
    // No DIRENV_: DIRENV_DIFF and DIRENV_WATCHES encode .envrc diffs, which can hold secrets.
    const COMMON_PREFIXES: [&str; 4] = ["MISE_", "ASDF_", "NVM_", "VOLTA_"];
    const COMMON: [&str; 12] = [
        "PATH",
        "BUN_INSTALL",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "https_proxy",
        "http_proxy",
        "all_proxy",
        "no_proxy",
        "NODE_EXTRA_CA_CERTS",
        "SSL_CERT_FILE",
    ];
    // An exact name the person added always comes in; a prefix they added,
    // like the version-manager prefixes, never brings in a secret
    // (MISE_GITHUB_TOKEN, NVM_AUTH_HEADER).
    if extra_exact(key) || COMMON.contains(&key) || key == "SSL_CERT_DIR" {
        return true;
    }
    if (COMMON_PREFIXES.iter().any(|p| key.starts_with(p)) || extra_prefix(key))
        && !is_secret(key, value)
    {
        return true;
    }
    match family {
        Some("claude") => {
            key.starts_with("ANTHROPIC_")
                || key.starts_with("CLAUDE_")
                || key.starts_with("DISABLE_")
                || key.ends_with("_TELEMETRY")
                || aws_allowed(key, profile)
                || vertex_allowed(key, value, profile)
        }
        Some("codex") => key.starts_with("OPENAI_") || key.starts_with("CODEX_"),
        _ => false,
    }
}

fn extra_exact(key: &str) -> bool {
    EXTRA_ALLOW.read().unwrap_or_else(|e| e.into_inner()).iter().any(|n| n == key)
}

fn extra_prefix(key: &str) -> bool {
    EXTRA_ALLOW.read().unwrap_or_else(|e| e.into_inner()).iter().any(|n| {
        n.strip_suffix('*').is_some_and(|prefix| !prefix.is_empty() && key.starts_with(prefix))
    })
}

/// Login keys the daemon itself reads (routing), passed to a child only
/// when the allow-list passes them.
const INTERNAL: [&str; 2] = ["SUBROUTER_URL", "ACPMUX_CODEROUTER_CLAUDE_ROUTE"];

/// Whether a login variable is kept at all (memory and cache): allowed for
/// some family (its Bedrock or Vertex condition aside), or read by the daemon.
fn storable(key: &str, value: &str) -> bool {
    INTERNAL.contains(&key)
        || allowed(key, value, None)
        || allowed(key, value, Some("codex"))
        || ["ANTHROPIC_", "CLAUDE_", "DISABLE_", "AWS_", "GOOGLE_", "CLOUDSDK_", "GCLOUD_"]
            .iter()
            .any(|p| key.starts_with(p))
        || key.ends_with("_TELEMETRY")
        || key == "CLOUD_ML_REGION"
        || (key.starts_with("VERTEX_REGION_") && !is_secret(key, value))
}

/// A login variable a profile or route may name as `${env:VAR}`: only one
/// some harness may get (the allow-list or `loginEnvAllow`).
pub fn allowed_var(key: &str) -> Option<String> {
    let v = var(key)?;
    (allowed(key, &v, None) || allowed(key, &v, Some("claude")) || allowed(key, &v, Some("codex")))
        .then_some(v)
}

fn pairs_for(
    family: Option<&str>,
    profile: Option<&BTreeMap<String, String>>,
) -> Vec<(String, String)> {
    pairs().into_iter().filter(|(k, v)| allowed_with(k, v, family, profile)).collect()
}

/// Login values of the keys `config::scrub_nested_claude_env` removes (a
/// daemon inside a Claude Code session), within the allow-list of
/// `family`: the scrub puts these back.
pub(crate) fn nested_overrides(family: Option<&str>) -> Vec<(String, String)> {
    if std::env::var_os("CLAUDECODE").is_none() {
        return Vec::new();
    }
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    let Some(i) = &st.imported else { return Vec::new() };
    let nested: Vec<(String, String)> =
        i.vars.iter().filter(|(k, _)| crate::config::is_nested_claude_key(k)).cloned().collect();
    drop(st);
    nested.into_iter().filter(|(k, v)| allowed(k, v, family)).collect()
}

/// Apply the allow-listed login environment every child gets (PATH,
/// version managers, proxies, CA) to a command.
pub fn apply_std(cmd: &mut std::process::Command) {
    cmd.envs(pairs_for(None, None));
}

/// Same, for tokio's process builder.
pub fn apply_tokio(cmd: &mut tokio::process::Command) {
    cmd.envs(pairs_for(None, None));
}

/// The allow-listed login environment for a harness of `family`, with
/// [`agent_path`] as its PATH. `profile` is the harness profile's own env
/// (its Bedrock/Vertex switch).
pub fn apply_tokio_for(
    cmd: &mut tokio::process::Command,
    family: Option<&str>,
    profile: Option<&BTreeMap<String, String>>,
) {
    cmd.envs(pairs_for(family, profile));
    if let Some(path) = agent_path() {
        cmd.env("PATH", path);
    }
}

/// Same, for std's process builder.
pub fn apply_std_for(
    cmd: &mut std::process::Command,
    family: Option<&str>,
    profile: Option<&BTreeMap<String, String>>,
) {
    cmd.envs(pairs_for(family, profile));
    if let Some(path) = agent_path() {
        cmd.env("PATH", path);
    }
}

/// Parse `env -0` output: (variables worth importing, the login PATH).
/// Output before the marker line is rc-file chatter; without a marker,
/// anything an rc file printed before `env` ran is discarded up to the
/// last newline. Shell-private and per-process variables are dropped.
pub(crate) fn parse_env0(text: &str, marker: &str) -> (Vec<(String, String)>, Option<String>) {
    let marker = format!("\n{marker}\n");
    let text = match text.rfind(&marker) {
        Some(at) => &text[at + marker.len()..],
        None => text,
    };
    let skip = [
        "PWD",
        "OLDPWD",
        "SHLVL",
        "_",
        "TERM",
        "TERM_SESSION_ID",
        "TTY",
        "LOGNAME",
        "HOME",
        "USER",
        "SHELL",
        "TMPDIR",
        "SSH_AUTH_SOCK",
        "COLUMNS",
        "LINES",
        "ACPMUX_LOGIN_ENV",
        // A Claude Code session's own markers, never the person's setup.
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
    ];
    let mut vars = Vec::new();
    let mut login_path = None;
    for chunk in text.split('\0') {
        let Some(eq) = chunk.find('=') else { continue };
        let start = chunk[..eq].rfind('\n').map(|i| i + 1).unwrap_or(0);
        let key = &chunk[start..eq];
        let value = &chunk[eq + 1..];
        if key.is_empty()
            || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            || key.starts_with("XPC_")
            || key.starts_with("__CF")
            || skip.contains(&key)
        {
            continue;
        }
        if key == "PATH" {
            login_path = Some(value.to_owned());
        } else {
            vars.push((key.to_owned(), value.to_owned()));
        }
    }
    (vars, login_path)
}

/// Whether a variable may hold a credential: a `_`-separated part of its
/// name is a credential word, or its value is a URL with a user part
/// (`https://user:pass@proxy`). Such values are never written to the cache.
pub fn is_secret(key: &str, value: &str) -> bool {
    /// Anywhere in the name (`PGPASSWORD`, `GITHUBTOKEN`).
    const WORDS: [&str; 12] = [
        "AUTHKEY",
        "PASSPHRASE",
        "PASSWORD",
        "PASSWD",
        "TOKEN",
        "SECRET",
        "CREDENTIAL",
        "APIKEY",
        "PRIVATE",
        "COOKIE",
        "WEBHOOK",
        "DSN",
    ];
    /// As a `_`-separated part (`AWS_ACCESS_KEY_ID`, `GH_PAT`, `MYSQL_PWD`).
    const PARTS: [&str; 9] =
        ["PASS", "PWD", "PAT", "KEY", "AUTH", "SESSION", "HEADERS", "SIGNATURE", "SIG"];
    let upper = key.to_ascii_uppercase();
    if WORDS.iter().any(|w| upper.contains(w)) || upper.split('_').any(|p| PARTS.contains(&p)) {
        return true;
    }
    const MORE_PARTS: [&str; 4] = ["CREDS", "KEYS", "SK", "BEARER"];
    if upper.split('_').any(|p| MORE_PARTS.contains(&p)) {
        return true;
    }
    const SHAPES: [&str; 8] =
        ["sk-ant-", "sk-", "ghp_", "gho_", "github_pat_", "xox", "tskey-", "AKIA"];
    if SHAPES.iter().any(|shape| value.starts_with(shape)) {
        return true;
    }
    let lower = value.to_ascii_lowercase();
    if ["token=", "key=", "secret=", "sig=", "password="].iter().any(|q| lower.contains(q)) {
        return true;
    }
    value.split_once("://").is_some_and(|(_, rest)| {
        rest.split(['/', '?', '#']).next().is_some_and(|authority| authority.contains('@'))
    })
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Cache {
    version: u32,
    fingerprint: String,
    vars: BTreeMap<String, String>,
    path: Option<String>,
    secret_names: Vec<String>,
    /// Seconds since the epoch.
    #[serde(default)]
    saved_at: Option<u64>,
}

fn cache_path() -> PathBuf {
    crate::config::home().join("login-env.json")
}

fn load_cache() -> Option<Cache> {
    let bytes = std::fs::read(cache_path()).ok()?;
    let cache: Cache = serde_json::from_slice(&bytes).ok()?;
    (cache.version == CACHE_VERSION).then_some(cache)
}

fn save_cache(login: &[(String, String)], login_path: Option<&str>) {
    let fingerprint = STATE.read().unwrap_or_else(|e| e.into_inner()).fingerprint.clone();
    let Some(fingerprint) = fingerprint else { return };
    let mut vars = BTreeMap::new();
    let mut secret_names = Vec::new();
    for (k, v) in login {
        if is_secret(k, v) {
            secret_names.push(k.clone());
        } else {
            vars.insert(k.clone(), v.clone());
        }
    }
    STATE.write().unwrap_or_else(|e| e.into_inner()).secret_names = secret_names.clone();
    let cache = Cache {
        version: CACHE_VERSION,
        fingerprint,
        vars,
        path: login_path.map(str::to_owned),
        secret_names,
        saved_at: Some(now_secs()),
    };
    let Ok(bytes) = serde_json::to_vec_pretty(&cache) else { return };
    if let Err(e) = crate::config::write_atomic(&cache_path(), &bytes) {
        tracing::warn!("login env cache: {e:#}");
    }
}

/// The startup files and tool-manager configs a login shell reads: path,
/// size and mtime of each (absent ones count too), plus the shell itself.
fn fingerprint() -> String {
    use sha2::{Digest, Sha256};
    let home =
        std::env::var_os("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
    let zdot = std::env::var_os("ZDOTDIR").map(PathBuf::from).unwrap_or_else(|| home.clone());
    let shell = std::env::var("SHELL").unwrap_or_default();
    // The shell starts without ZDOTDIR (run_shell), so zsh reads the files in
    // $HOME; a ZDOTDIR the rc files set is covered too.
    let mut files: Vec<PathBuf> = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
        .iter()
        .flat_map(|f| [home.join(f), zdot.join(f)])
        .collect();
    for f in [
        ".bash_profile",
        ".bash_login",
        ".bashrc",
        ".profile",
        ".config/fish/config.fish",
        ".tool-versions",
        ".asdfrc",
        ".config/mise/config.toml",
        ".mise.toml",
        ".envrc",
        ".direnvrc",
        ".config/direnv/direnvrc",
        ".nvmrc",
        ".config/claude/env",
    ] {
        files.push(home.join(f));
    }
    for f in
        ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/profile", "/etc/bashrc", "/etc/paths"]
    {
        files.push(PathBuf::from(f));
    }
    files.push(PathBuf::from(&shell));
    let mut hash = Sha256::new();
    hash.update(shell.as_bytes());
    // A changed loginEnvAllow is a changed rule: read the shell again.
    let mut extra = EXTRA_ALLOW.read().unwrap_or_else(|e| e.into_inner()).clone();
    extra.sort();
    hash.update(format!("allow:{};", extra.join(",")).as_bytes());
    for f in files {
        hash.update(f.as_os_str().as_encoded_bytes());
        match std::fs::metadata(&f) {
            Ok(m) => {
                let mtime = m
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                hash.update(format!(":{}:{mtime};", m.len()).as_bytes());
            }
            Err(_) => hash.update(b":-;"),
        }
    }
    hash.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
