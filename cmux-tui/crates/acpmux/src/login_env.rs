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
/// Printed before `env -0`, so rc-file chatter on stdout is skipped.
const MARKER: &str = "__ACPMUX_LOGIN_ENV__";
const CACHE_VERSION: u32 = 1;

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
        drop(st);
        // First start (or edited startup files): spawns wait for the shell
        // unless Claude already signs in without it (keychain, settings).
        return Plan { run_shell: true, wait: !crate::claude_auth::direct_sign_in() };
    };
    st.imported = Some(build(for_children(cache.vars.into_iter().collect()), cache.path));
    st.outcome = Outcome::Cached;
    st.secret_names = cache.secret_names.clone();
    drop(st);
    let missing: Vec<&String> =
        cache.secret_names.iter().filter(|n| std::env::var_os(n).is_none()).collect();
    if missing.is_empty() {
        return Plan { run_shell: false, wait: false };
    }
    let wait = !crate::claude_auth::direct_sign_in();
    Plan { run_shell: true, wait }
}

/// Run the login shell once (bounded by `TIMEOUT`) and remember its
/// environment. Returns true when the children's environment changed.
pub async fn import() -> bool {
    let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/zsh".into());
    let started = Instant::now();
    let before = pairs();
    let output = run_shell(&shell).await;
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
    let (login, login_path) = parse_env0(&text);
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
    let changed = STATE.read().unwrap_or_else(|e| e.into_inner()).fingerprint.as_deref() != Some(&now);
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
        REFRESHING.store(false, Ordering::SeqCst);
    });
}

/// `$SHELL -l -i -c` printing the marker and `env -0`: no terminal, stdin
/// from /dev/null, in its own process group (killed with everything it
/// started when `TIMEOUT` passes). The parent Claude session's own keys are
/// not passed in, so what comes back is the person's setup.
async fn run_shell(shell: &str) -> Option<String> {
    let mut cmd = tokio::process::Command::new(shell);
    cmd.args(["-l", "-i", "-c", &format!("printf '\\n{MARKER}\\n'; command env -0")])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .env("ACPMUX_LOGIN_ENV", "0")
        .kill_on_drop(true);
    for k in crate::config::nested_claude_keys() {
        cmd.env_remove(k);
    }
    #[cfg(unix)]
    cmd.process_group(0);
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

/// A variable the import added, by name.
pub fn var(key: &str) -> Option<String> {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    st.imported.as_ref()?.vars.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
}

/// Keys the import adds on top of the daemon's environment.
pub fn imported_keys() -> Vec<String> {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    st.imported.as_ref().map(|i| i.vars.iter().map(|(k, _)| k.clone()).collect()).unwrap_or_default()
}

/// Secret variable names the login shell sets whose values this process
/// does not hold (the shell has not answered since a cached start).
pub fn missing_secret_names() -> Vec<String> {
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    let have = |n: &str| {
        std::env::var_os(n).is_some()
            || st.imported.as_ref().is_some_and(|i| i.vars.iter().any(|(k, _)| k == n))
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

/// Login values of the keys `config::scrub_nested_claude_env` removes (a
/// daemon inside a Claude Code session): the scrub puts these back.
pub(crate) fn nested_overrides() -> Vec<(String, String)> {
    if std::env::var_os("CLAUDECODE").is_none() {
        return Vec::new();
    }
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    let Some(i) = &st.imported else { return Vec::new() };
    i.vars.iter().filter(|(k, _)| crate::config::is_nested_claude_key(k)).cloned().collect()
}

/// Apply the imported environment to a command.
pub fn apply_std(cmd: &mut std::process::Command) {
    cmd.envs(pairs());
}

/// Same, for tokio's process builder.
pub fn apply_tokio(cmd: &mut tokio::process::Command) {
    cmd.envs(pairs());
}

/// Parse `env -0` output: (variables worth importing, the login PATH).
/// Output before the marker line is rc-file chatter; without a marker,
/// anything an rc file printed before `env` ran is discarded up to the
/// last newline. Shell-private and per-process variables are dropped.
pub(crate) fn parse_env0(text: &str) -> (Vec<(String, String)>, Option<String>) {
    let marker = format!("\n{MARKER}\n");
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
    const PARTS: [&str; 15] = [
        "PASSWORD",
        "PASSWD",
        "PASS",
        "TOKEN",
        "SECRET",
        "CREDENTIAL",
        "CREDENTIALS",
        "APIKEY",
        "PRIVATE",
        "AUTH",
        "KEY",
        "COOKIE",
        "HEADERS",
        "SIGNATURE",
        "SESSION",
    ];
    let upper = key.to_ascii_uppercase();
    if upper.split('_').any(|p| PARTS.contains(&p)) {
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
    };
    let Ok(bytes) = serde_json::to_vec_pretty(&cache) else { return };
    let path = cache_path();
    let tmp = path.with_extension("json.tmp");
    #[cfg(unix)]
    let written = {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .and_then(|mut f| f.write_all(&bytes))
    };
    #[cfg(not(unix))]
    let written = std::fs::write(&tmp, &bytes);
    if written.is_ok() && std::fs::rename(&tmp, &path).is_ok() {
        return;
    }
    let _ = std::fs::remove_file(&tmp);
}

/// The startup files and tool-manager configs a login shell reads: path,
/// size and mtime of each (absent ones count too), plus the shell itself.
fn fingerprint() -> String {
    use sha2::{Digest, Sha256};
    let home = std::env::var_os("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
    let zdot = std::env::var_os("ZDOTDIR").map(PathBuf::from).unwrap_or_else(|| home.clone());
    let shell = std::env::var("SHELL").unwrap_or_default();
    let mut files: Vec<PathBuf> = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
        .iter()
        .map(|f| zdot.join(f))
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
    for f in ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/profile", "/etc/bashrc", "/etc/paths"] {
        files.push(PathBuf::from(f));
    }
    files.push(PathBuf::from(&shell));
    let mut hash = Sha256::new();
    hash.update(shell.as_bytes());
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
