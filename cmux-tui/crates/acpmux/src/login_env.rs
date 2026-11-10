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
//! the shell; a changed fingerprint refreshes it in the background. An edit
//! to a startup file is seen at once by a watcher (`watch.rs`, D26), and
//! checked again at most every 10 s when an agent spawns.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::Read;
use std::path::PathBuf;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

mod machine;
mod watch;
pub use watch::start as watch_startup_files;

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
// Older caches could contain machine declarations imported through a shell hook;
// version 3 caches lack the provider keys (`PROVIDER_KEYS`), so the shell runs once more.
const CACHE_VERSION: u32 = 4;

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
    /// Machine-env metadata from the last successful shell import.
    applied_machine_stamp: Option<String>,
}

static STATE: RwLock<State> = RwLock::new(State {
    imported: None,
    outcome: Outcome::None,
    fingerprint: None,
    secret_names: Vec::new(),
    last_check: None,
    applied_machine_stamp: None,
});

/// Names delivered in `~/.config/cmux/machine-secrets.env` at the last shell
/// import (`cmux cloud deliver-secrets`): the person sent them to this
/// machine for its shells and agents, so they pass the allow-list. Its own
/// lock, never `STATE`'s: the allow-list runs while `STATE` is held.
static DELIVERED: RwLock<Vec<String>> = RwLock::new(Vec::new());
static ENABLED: AtomicBool = AtomicBool::new(false);
static REFRESHING: AtomicBool = AtomicBool::new(false);
/// Coalesce concurrent agent starts awaiting a changed machine secret file.
static MACHINE_REFRESH: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

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
    /// Agent spawns wait for that run (bounded by `MAX_ROUNDS` x `TIMEOUT`) only when
    /// Claude has no sign-in without it (the daemon's environment, settings
    /// files, credentials file; never the keychain) and there is no matching cache or
    /// the cache names a secret whose value this process lacks.
    pub wait: bool,
}

/// Start resolution: apply a matching cache at once, and say whether the
/// shell must run. Fast: stats and one small file read (plus, only when
/// the cache lacks secret values, the Claude sign-in sources check, which
/// reads files and never the keychain).
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
    // Machine values belong only to local spawns, even if a shell profile
    // also sourced that file before this cache was written.
    let _ = machine::read();
    let machine_names = machine::names();
    let vars = cache
        .vars
        .into_iter()
        .filter(|(k, v)| !machine_names.contains(k) && storable(k, v))
        .collect();
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
    // unless Claude signs in without it (settings, credentials file, env).
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

/// One login shell read at a time: the startup read and a refresh never
/// overlap, so the last cache written is the newest read.
static IMPORT: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
/// Told when a login shell read ends, done or failed (`await_child_env`).
static READ_ENDED: tokio::sync::Notify = tokio::sync::Notify::const_new();
/// Login shell reads ended, done or failed: a command built before a read
/// ended and checked after it is built again (`build_ready`).
static READS: AtomicU64 = AtomicU64::new(0);
/// Reads in a row when the startup files change during a read: one more
/// read catches an edit made during the first.
const MAX_ROUNDS: usize = 2;

/// Run the login shell (each run bounded by `TIMEOUT`, so at most
/// `MAX_ROUNDS` x `TIMEOUT` in all) and remember its environment, one read
/// at a time. A startup file edited during a read is read again, so the
/// result never lags an edit. Returns true when the children's environment
/// changed.
pub async fn import() -> bool {
    let _one = IMPORT.lock().await;
    let mut changed = false;
    for round in 1..=MAX_ROUNDS {
        // The fingerprint of the files this read sees, taken before it.
        let read = fingerprint();
        STATE.write().unwrap_or_else(|e| e.into_inner()).fingerprint = Some(read.clone());
        changed |= import_once(&read).await;
        if outcome() == Outcome::Failed || fingerprint() == read {
            break;
        }
        if round == MAX_ROUNDS {
            // The shell itself rewrites a startup file (a tool appending to
            // ~/.zshrc): take the files as they are now, so only a later
            // edit reads them again, never a loop of login shells.
            tracing::info!(
                "shell startup files change on every read; reading them on the next edit"
            );
            STATE.write().unwrap_or_else(|e| e.into_inner()).fingerprint = Some(fingerprint());
        } else {
            tracing::info!("shell startup files changed during the read; reading them again");
        }
    }
    if outcome() == Outcome::Failed {
        // A read that failed (a shell slower than TIMEOUT, at the daemon's start too) settled
        // nothing: the next spawn's check reads again (`refresh`, at most every RECHECK), as it
        // would after an edit. Kept, the fingerprint made every later check see "no change", so
        // every agent of this daemon started without the login env until an edit or a restart.
        STATE.write().unwrap_or_else(|e| e.into_inner()).fingerprint = None;
    }
    READS.fetch_add(1, Ordering::SeqCst);
    READ_ENDED.notify_waiters();
    changed
}

/// A child's final env plan, as far as the login shell goes: what it takes
/// from the login env once its command is built (route set and unset, the
/// remote policy, profile resolution, scrubs). Every spawn path waits on it
/// (`await_child_env`; `agent::harness_command_ready` for harness commands),
/// so none waits, or refuses, over a name its child never receives.
pub(crate) struct ChildEnv<'a> {
    pub family: &'a str,
    /// The profile's env, unresolved: its `${env:X}` references and the
    /// Bedrock and Vertex switches of the allow-list (`allowed_with`).
    pub profile: Option<&'a BTreeMap<String, String>>,
    /// The child starts from a cleared env and takes no login value but PATH
    /// (`apply_remote_tokio`): a remote-origin launch.
    pub remote: bool,
    /// The command's explicit env changes as built: a name it sets (a
    /// profile value) is never the login env's. A name it removes may be: the
    /// nested-session scrub removes an inherited `ANTHROPIC_BASE_URL` that the
    /// login import puts back. Only `never` names one the child never gets.
    /// `None` until it is built.
    pub explicit: Option<Vec<(String, Option<String>)>>,
}

impl ChildEnv<'_> {
    /// The profile's `${env:X}` names: resolved from the login env whatever
    /// the plan, remote included (`reference_var`).
    fn refs(&self) -> Vec<String> {
        self.profile.map(crate::config::profiles::env_ref_names).unwrap_or_default()
    }

    /// Names the child receives from the login env whose values only the
    /// shell holds now (a cached start: `save_cache` keeps secrets by name
    /// only). A reference; or a name the plan neither sets nor removes, the
    /// family's allow-list takes (`allowed_with`), and that is a provider key
    /// of a multi-provider harness or a base URL. Claude's and Codex's own
    /// keys stay with `Plan::wait`.
    fn blocking(&self) -> Vec<String> {
        let refs = self.refs();
        missing_secret_names().into_iter().filter(|n| self.takes(n, &refs)).collect()
    }

    /// The child receives `name` from the login env, and it is one a start waits for (`blocking`).
    fn takes(&self, name: &str, refs: &[String]) -> bool {
        if refs.iter().any(|r| r == name) {
            return true;
        }
        let Some(explicit) = &self.explicit else { return false };
        !self.remote
            && !explicit.iter().any(|(k, v)| k == name && v.is_some())
            && !self.never(name)
            && PROVIDER_KEYS.contains(&name)
            && allowed_with(name, "", Some(self.family), self.profile)
            && (PROVIDER_FAMILIES.contains(&self.family) || endpoint(name))
    }

    /// The child never gets `name`, whatever the login env holds: a bound
    /// route unsets it (`routes::UNSET_KEY`), or an Anthropic endpoint
    /// harness clears it (`byo_endpoint::clears`). Unlike a scrub, which the
    /// login import undoes, this removal is the plan's.
    fn never(&self, name: &str) -> bool {
        let Some(env) = self.profile else { return false };
        env.get(crate::routes::UNSET_KEY).is_some_and(|l| l.split(',').any(|k| k == name))
            || crate::byo_endpoint::clears(name, env)
    }

    /// The blocking names a start cannot go without: a base URL (else the
    /// agent runs on its default endpoint) or a reference. A provider key it
    /// lacks, the harness names itself.
    fn refusing(&self) -> Vec<String> {
        let refs = self.refs();
        self.blocking().into_iter().filter(|n| endpoint(n) || refs.contains(n)).collect()
    }
}

/// Before a child starts on `plan`: while it takes a login value only the
/// shell holds and the shell has not answered since a cached start, wait
/// for that read until `deadline` (`TIMEOUT` from the first build). True
/// when the plan took such a value, so the caller builds the command again
/// with the read's values. A base URL or reference still missing then (the
/// read failed or is slower) refuses the start, naming it, never its value.
pub(crate) async fn await_child_env(
    plan: &ChildEnv<'_>,
    deadline: tokio::time::Instant,
) -> Result<bool, String> {
    if !ENABLED.load(Ordering::SeqCst) || plan.blocking().is_empty() {
        return Ok(false);
    }
    wait_until(|| outcome() == Outcome::Cached && !plan.blocking().is_empty(), deadline).await;
    let missing = plan.refusing();
    if missing.is_empty() {
        return Ok(true);
    }
    Err(format!(
        "{} from the login shell is not available yet: the shell did not answer within {} s. \
         Retry in a moment, or set it in the agent's profile",
        missing.join(", "),
        TIMEOUT.as_secs()
    ))
}

/// Build a spawn's command on `plan`, ready to start: `build` it, take its
/// env changes (`explicit`) into the plan and `await_child_env`. Built again
/// when the plan waited for the shell, or when a read ended while it was
/// built (it took the values from before the read). A refusal is `refuse`d.
pub(crate) async fn build_ready<T, E>(
    plan: &mut ChildEnv<'_>,
    mut build: impl FnMut() -> Result<T, E>,
    explicit: impl Fn(&T) -> Vec<(String, Option<String>)>,
    refuse: impl Fn(String) -> E,
) -> Result<T, E> {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    // Twice at most: a build that failed on a missing reference has no plan
    // until the reference is here.
    for _ in 0..2 {
        let reads = READS.load(Ordering::SeqCst);
        let built = build();
        plan.explicit = built.as_ref().ok().map(&explicit);
        let waited = await_child_env(plan, deadline).await.map_err(&refuse)?;
        if !waited && READS.load(Ordering::SeqCst) == reads {
            return built;
        }
    }
    build()
}

/// `build_ready` from synchronous code (a sign-in check on a blocking
/// thread, or outside any runtime), waiting at most `TIMEOUT`. Free when the
/// first build's plan takes nothing only the shell holds and no read ended
/// meanwhile; otherwise the wait runs on a thread of its own, so it never
/// blocks a runtime's worker.
pub(crate) fn build_ready_blocking<T: Send, E: Send>(
    plan: &mut ChildEnv<'_>,
    mut build: impl FnMut() -> Result<T, E> + Send,
    explicit: impl Fn(&T) -> Vec<(String, Option<String>)> + Send,
    refuse: impl Fn(String) -> E + Sync,
) -> Result<T, E> {
    let reads = READS.load(Ordering::SeqCst);
    let built = build();
    plan.explicit = built.as_ref().ok().map(&explicit);
    if !ENABLED.load(Ordering::SeqCst)
        || (plan.blocking().is_empty() && READS.load(Ordering::SeqCst) == reads)
    {
        return built;
    }
    let refuse = &refuse;
    std::thread::scope(|scope| {
        scope
            .spawn(move || {
                let runtime =
                    tokio::runtime::Builder::new_current_thread()
                        .enable_time()
                        .build()
                        .map_err(|e| refuse(format!("cannot wait for the login shell: {e}")))?;
                runtime.block_on(build_ready(plan, build, explicit, refuse))
            })
            .join()
            .unwrap_or_else(|_| Err(refuse("the login shell wait stopped".to_owned())))
    })
}

/// A provider base URL (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`): the
/// `PROVIDER_KEYS` names that are not secret by name.
fn endpoint(name: &str) -> bool {
    PROVIDER_KEYS.contains(&name) && !is_secret(name, "")
}

/// Wait while `pending`, each time until a login shell read ends, at most `limit` in all.
#[cfg(test)]
async fn wait_while(pending: impl Fn() -> bool, limit: Duration) {
    wait_until(pending, tokio::time::Instant::now() + limit).await;
}

/// Wait while `pending`, each time until a login shell read ends, until `deadline`.
async fn wait_until(pending: impl Fn() -> bool, deadline: tokio::time::Instant) {
    loop {
        let ended = READ_ENDED.notified();
        tokio::pin!(ended);
        // Registered before the check, so a read that ends between them still wakes it.
        ended.as_mut().enable();
        if !pending() || tokio::time::timeout_at(deadline, ended).await.is_err() {
            return;
        }
    }
}

/// One login shell run; its cache is labelled `read`, the fingerprint
/// taken before the run.
async fn import_once(read: &str) -> bool {
    let shell =
        std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/zsh".into());
    let started = Instant::now();
    let before = pairs();
    let marker = run_marker();
    // Capture before reading the shell. import() retries when files change mid-read.
    let machine_stamp = machine_files_stamp();
    // Keep declarations seen before and after the shell read out of generic
    // imports, including a file revoked or renamed while the shell was running.
    let _ = machine::read();
    // Names only, read with the stamp: the values still come from the shell.
    let delivered = delivered_names();
    *DELIVERED.write().unwrap_or_else(|e| e.into_inner()) = delivered;
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
    // Literal machine declarations are local-spawn authority. A profile may
    // also source them, but they must not enter generic login APIs or the cache.
    let _ = machine::read();
    let machine_names = machine::names();
    let login: Vec<(String, String)> =
        login.into_iter().filter(|(k, v)| !machine_names.contains(k) && storable(k, v)).collect();
    save_cache(read, &login, login_path.as_deref());
    let imported = build(for_children(login), login_path);
    let added = imported.vars.len();
    let mut st = STATE.write().unwrap_or_else(|e| e.into_inner());
    st.imported = Some(imported);
    st.applied_machine_stamp = machine_stamp;
    st.outcome = Outcome::Shell;
    drop(st);
    tracing::info!(shell = %shell, added, ms = elapsed.as_millis() as u64, "imported login shell environment");
    pairs() != before
}

/// A delivered cloud secret file may have changed after acpmux cached the
/// shell environment. A new harness must use the new values, or refuse to
/// start rather than inheriting a stale, possibly revoked secret.
/// This reads only file metadata; secret values remain shell-owned.
pub async fn machine_env_fresh_before_spawn() -> bool {
    if !ENABLED.load(Ordering::SeqCst) {
        return true;
    }
    let applied = || STATE.read().unwrap_or_else(|e| e.into_inner()).applied_machine_stamp.clone();
    if machine_files_stamp() == applied() {
        return true;
    }
    let _one = MACHINE_REFRESH.lock().await;
    // The watcher or an earlier spawn may already have completed this import.
    if machine_files_stamp() == applied() {
        return true;
    }
    import().await;
    let current = machine_files_stamp();
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    st.outcome == Outcome::Shell && st.applied_machine_stamp == current
}

/// Called before each agent spawn: when the startup files changed since the
/// last resolution (checked at most every `RECHECK`), refresh in the
/// background. Never waits. The startup-file watcher (`watch.rs`) refreshes
/// at once on an edit; this check covers what it cannot watch.
pub fn refresh_if_changed() {
    refresh(true);
}

/// `refresh_if_changed`; `throttled` false (a watched file changed) skips
/// the `RECHECK` limit.
fn refresh(throttled: bool) {
    if !ENABLED.load(Ordering::SeqCst) {
        return;
    }
    {
        let mut st = STATE.write().unwrap_or_else(|e| e.into_inner());
        if throttled && st.last_check.is_some_and(|t| t.elapsed() < RECHECK) {
            return;
        }
        st.last_check = Some(Instant::now());
    }
    let now = fingerprint();
    let changed =
        STATE.read().unwrap_or_else(|e| e.into_inner()).fingerprint.as_deref() != Some(&now);
    // A refresh already running reads again when the files changed under
    // it (`import`), and checks once more after it ends.
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
        // A failed read clears the fingerprint itself (`import`): a later spawn or edit tries again.
        import().await;
        let failed = outcome() == Outcome::Failed;
        REFRESHING.store(false, Ordering::SeqCst);
        if !failed {
            // An edit after the read's last check found REFRESHING set.
            refresh(false);
        }
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

/// A profile's, preset's or session's own PATH `own`, then every
/// [`agent_path`] directory it does not list, each directory once. A PATH a
/// preset saved (the Chief's built-in subagent preset takes the daemon's PATH
/// when it is installed, which can be before the login import, or a launchd
/// start's bare `/usr/bin:/bin:/usr/sbin:/sbin`) must not hide the login
/// PATH's tools: the harness is looked up on this PATH (`claude`), and so is
/// every tool it runs.
pub fn with_agent_path(own: &str) -> String {
    let login = agent_path();
    let login =
        login.iter().flat_map(std::env::split_paths).map(|p| p.to_string_lossy().into_owned());
    merge_paths(own.split(':').map(str::to_owned).chain(login))
}

/// The non-empty entries of `dirs`, first occurrence kept, joined with `:`.
fn merge_paths(dirs: impl Iterator<Item = String>) -> String {
    let mut merged: Vec<String> = Vec::new();
    for dir in dirs {
        if !dir.is_empty() && !merged.contains(&dir) {
            merged.push(dir);
        }
    }
    merged.join(":")
}

/// The app's bundled `cmux` (BundledCLIEnvironment.swift).
pub const BUNDLED_CLI_ENV: &str = "CMUX_BUNDLED_CLI_PATH";

/// A variable the import added, by name.
pub fn var(key: &str) -> Option<String> {
    if machine::names().contains(key) {
        return None;
    }
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
/// (`claude`, `codex`, `gemini`, `muse`, a `PROVIDER_FAMILIES` one, else none) gets. Every other variable stays in the
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
/// - Gemini: GEMINI_* and GOOGLE_* (the CLI/API and Vertex credentials).
/// - Muse: MUSE_* and META_* (the official CLI and API credentials).
/// - OpenCode, OpenCode v2, pi, omp, Prime, cmux Harness (pi's loop) and Hermes: the fixed
///   provider-key names in `PROVIDER_KEYS`, never a prefix.
/// - Not here: a name delivered in `~/.config/cmux/machine-secrets.env`
///   passes only on the local spawn paths (`pairs_for`), never through this
///   rule, so nested-session restoration (`nested_overrides`), `${env:VAR}`
///   references and remote-origin launches never gain it.
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
    // An exact name the person added always comes in (another harness's login
    // still never reaches an agent: `agent/foreign_login.rs`); a prefix they added,
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
    // A provider key's own family (`foreign_login::provider_key_owner`): Codex's
    // AZURE_OPENAI_API_KEY, Grok's XAI_API_KEY, DeepSeek's DEEPSEEK_API_KEY.
    if family.is_some()
        && PROVIDER_KEYS.contains(&key)
        && crate::agent::foreign_login::provider_key_owner(key) == family
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
        Some("gemini") => key.starts_with("GEMINI_") || key.starts_with("GOOGLE_"),
        Some("muse") => key.starts_with("MUSE_") || key.starts_with("META_"),
        Some(f) if PROVIDER_FAMILIES.contains(&f) => PROVIDER_KEYS.contains(&key),
        _ => false,
    }
}

/// The harnesses that sign in with any provider's API key: OpenCode and
/// OpenCode v2 (`opencode2`, which uses OpenCode's provider credentials), pi
/// and its forks omp and Prime Agent, cmux Harness (pi's model loop) and
/// Hermes. Not DeepSeek Harness (`dsh`): its key lives in
/// `~/.dsh/.credentials.yaml`.
pub(crate) const PROVIDER_FAMILIES: [&str; 7] =
    ["opencode", "opencode-v2", "pi", "omp", "prime", "cmux-harness", "hermes"];

/// The provider keys (and base URLs) those harnesses read from their
/// environment. Exact names, never a prefix: a prefix would bring in any
/// secret that shares it (`OPENAI_ORG_TOKEN`, `GROQ_SECRET`). Every key is a
/// secret by name, so only its name reaches the cache (`save_cache`); a base
/// URL is cached by value unless it carries a credential (`is_secret`).
/// Not here: cloud credentials (AWS_*, Vertex ADC), which only Claude's
/// Bedrock and Vertex switches unlock, and GitHub tokens. The same list keeps
/// these keys in the daemon's own env from other agents
/// (`agent/foreign_login.rs`).
pub(crate) const PROVIDER_KEYS: [&str; 26] = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_BASE_URL",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "AZURE_OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_GENERATIVE_AI_API_KEY",
    "OPENROUTER_API_KEY",
    "GROQ_API_KEY",
    "TOGETHER_API_KEY",
    "TOGETHER_AI_API_KEY",
    "FIREWORKS_API_KEY",
    "DEEPSEEK_API_KEY",
    "MISTRAL_API_KEY",
    "XAI_API_KEY",
    "CEREBRAS_API_KEY",
    "DEEPINFRA_API_KEY",
    "HF_TOKEN",
    "AI_GATEWAY_API_KEY",
    "ZAI_API_KEY",
    "MINIMAX_API_KEY",
    "KIMI_API_KEY",
    "MOONSHOT_API_KEY",
    "PERPLEXITY_API_KEY",
    "NOUS_API_KEY",
];

/// A name delivered to this machine's secrets file (`DELIVERED`).
fn delivered(key: &str) -> bool {
    DELIVERED.read().unwrap_or_else(|e| e.into_inner()).iter().any(|n| n == key)
}

fn extra_exact(key: &str) -> bool {
    EXTRA_ALLOW.read().unwrap_or_else(|e| e.into_inner()).iter().any(|n| n == key)
}

fn extra_prefix(key: &str) -> bool {
    EXTRA_ALLOW.read().unwrap_or_else(|e| e.into_inner()).iter().any(|n| {
        n.strip_suffix('*').is_some_and(|prefix| !prefix.is_empty() && key.starts_with(prefix))
    })
}

/// Login keys the daemon itself reads (routing and installation discovery), passed to a child only
/// when the allow-list passes them.
const INTERNAL: [&str; 5] = [
    "SUBROUTER_URL",
    "ACPMUX_CODEROUTER_CLAUDE_ROUTE",
    "BUN_INSTALL_GLOBAL_DIR",
    "BUN_INSTALL_BIN",
    "XDG_CONFIG_HOME",
];

/// Whether a login variable is kept at all (memory and cache): allowed for
/// some family (its Bedrock or Vertex condition aside), or read by the daemon.
fn storable(key: &str, value: &str) -> bool {
    INTERNAL.contains(&key)
        || delivered(key)
        || allowed(key, value, None)
        || allowed(key, value, Some("codex"))
        || PROVIDER_KEYS.contains(&key)
        || [
            "ANTHROPIC_",
            "CLAUDE_",
            "DISABLE_",
            "AWS_",
            "GOOGLE_",
            "CLOUDSDK_",
            "GCLOUD_",
            "GEMINI_",
            "MUSE_",
            "META_",
        ]
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
    (allowed(key, &v, None)
        || allowed(key, &v, Some("claude"))
        || allowed(key, &v, Some("codex"))
        || allowed(key, &v, Some("gemini"))
        || allowed(key, &v, Some("muse"))
        || PROVIDER_FAMILIES.iter().any(|f| allowed(key, &v, Some(f))))
    .then_some(v)
}

/// Profile and route references must not recover a machine value from the
/// daemon's inherited environment after the local-only overlay refuses it.
pub(crate) fn reference_var(key: &str) -> Option<String> {
    let _ = machine::read();
    if machine::names().contains(key) {
        return None;
    }
    allowed_var(key).or_else(|| std::env::var(key).ok())
}

/// A nested Claude scrub runs after login env is applied. Restore only the
/// current local machine declarations it removed; never restore an inherited
/// value or expose this overlay to remote-origin launches.
pub(crate) fn restore_machine_tokio(cmd: &mut tokio::process::Command) {
    cmd.envs(nested_local(crate::vault::env_for_children(), machine::read()));
}

/// The nested-Claude keys of the local overlay a scrub removed, in the order
/// a launch puts them back: the vault's, then `machine.env`'s.
pub(crate) fn nested_local(
    vault: Vec<(String, String)>,
    machine: BTreeMap<String, String>,
) -> Vec<(String, String)> {
    vault
        .into_iter()
        .chain(machine)
        .filter(|(key, _)| crate::config::is_nested_claude_key(key))
        .collect()
}

/// The login, vault and machine values every local child gets whatever its family (the
/// allow-list's common part and `loginEnvAllow`), with the profile `profile` deciding the
/// Bedrock and Vertex conditions. A family's own keys and the daemon's own env are not here.
pub(crate) fn every_child_pairs(
    profile: Option<&BTreeMap<String, String>>,
) -> Vec<(String, String)> {
    pairs_for(None, profile)
}

fn pairs_for(
    family: Option<&str>,
    profile: Option<&BTreeMap<String, String>>,
) -> Vec<(String, String)> {
    pairs_with(family, profile, crate::vault::env_for_children(), machine::read())
}

fn pairs_with(
    family: Option<&str>,
    profile: Option<&BTreeMap<String, String>>,
    vault: Vec<(String, String)>,
    machine: BTreeMap<String, String>,
) -> Vec<(String, String)> {
    // A name delivered to this machine (`cmux cloud deliver-secrets`) goes to
    // every local child: the person sent it for this machine's shells and
    // agents, except another harness's login (`agent/foreign_login.rs`).
    // Remote-origin launches never call this (`apply_remote_tokio`).
    let names = machine::names();
    let values: BTreeMap<_, _> = pairs()
        .into_iter()
        .filter(|(k, v)| {
            !names.contains(k) && (allowed_with(k, v, family, profile) || delivered(k))
        })
        .collect();
    // Read literals at the local spawn boundary; never expose them through
    // var/allowed_var/nested_overrides or persist them in login-env.json.
    // Explicit profile/preset/session env is applied after this overlay.
    overlay(values, vault, machine)
}

/// The local overlay over the allow-listed login values: the person's vault
/// (`crate::vault`), then this machine's delivered `machine.env`, which is
/// specific to it. Profile, preset and session env go on after it.
pub(crate) fn overlay(
    login: BTreeMap<String, String>,
    vault: Vec<(String, String)>,
    machine: BTreeMap<String, String>,
) -> Vec<(String, String)> {
    let mut values = login;
    values.extend(vault);
    values.extend(machine);
    values.into_iter().collect()
}

/// Whether an env name may come from a person's or machine's declarations:
/// never a loader, shell bootstrap, PATH/HOME or `CMUX_`/`ACPMUX_` name.
pub(crate) fn machine_env_name_allowed(name: &str) -> bool {
    machine::allowed_name(name)
}

/// Login values of the keys `config::scrub_nested_claude_env` removes (a
/// daemon inside a Claude Code session), within the allow-list of
/// `family`: the scrub puts these back.
pub(crate) fn nested_overrides(family: Option<&str>) -> Vec<(String, String)> {
    if std::env::var_os("CLAUDECODE").is_none() {
        return Vec::new();
    }
    let names = machine::names();
    let st = STATE.read().unwrap_or_else(|e| e.into_inner());
    let Some(i) = &st.imported else { return Vec::new() };
    let nested: Vec<(String, String)> = i
        .vars
        .iter()
        .filter(|(k, _)| !names.contains(k) && crate::config::is_nested_claude_key(k))
        .cloned()
        .collect();
    drop(st);
    nested.into_iter().filter(|(k, v)| allowed(k, v, family)).collect()
}

/// The environment a harness of `family` with the profile env `profile`
/// starts with, as `harness_health::probe::run_for` prepares it: the
/// daemon's own (less a nested Claude Code session's keys), the
/// allow-listed login values over it, then `profile`. For sign-in checks
/// that read the environment instead of spawning; the values stay in this
/// process's memory.
pub fn effective_for(
    family: Option<&str>,
    profile: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let nested = std::env::var_os("CLAUDECODE").is_some();
    let (vault, machine) = (crate::vault::env_for_children(), machine::read());
    // A launch's scrub removes the nested keys, then puts back the login
    // values, the vault's and `machine.env`'s (`restore_machine_tokio`).
    let mut restored = nested_overrides(family);
    restored.extend(nested_local(vault.clone(), machine.clone()));
    let local = pairs_with(family, Some(profile), vault, machine);
    let names = machine::names();
    layered(
        std::env::vars().filter(|(key, _)| !names.contains(key)),
        nested,
        local,
        restored,
        profile,
    )
}

/// `effective_for`'s layering, pure: `daemon` (its nested Claude keys
/// dropped when `nested`), then `login`, then `restored`, then `profile`.
pub(crate) fn layered(
    daemon: impl IntoIterator<Item = (String, String)>,
    nested: bool,
    login: Vec<(String, String)>,
    restored: Vec<(String, String)>,
    profile: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut env: BTreeMap<String, String> = daemon.into_iter().collect();
    env.extend(login);
    if nested {
        env.retain(|k, _| !crate::config::is_nested_claude_key(k));
    }
    env.extend(restored);
    env.extend(profile.iter().map(|(k, v)| (k.clone(), v.clone())));
    env
}

/// Apply the allow-listed login environment every child gets (PATH,
/// version managers, proxies, CA) to a command.
pub fn apply_std(cmd: &mut std::process::Command) {
    let values = pairs_for(None, None);
    for key in machine::names() {
        cmd.env_remove(key);
    }
    cmd.envs(values);
}

/// Same, for tokio's process builder.
pub fn apply_tokio(cmd: &mut tokio::process::Command) {
    let values = pairs_for(None, None);
    for key in machine::names() {
        cmd.env_remove(key);
    }
    cmd.envs(values);
}

/// The allow-listed login environment for a harness of `family`, with
/// [`agent_path`] as its PATH. `profile` is the harness profile's own env
/// (its Bedrock/Vertex switch).
pub fn apply_tokio_for(
    cmd: &mut tokio::process::Command,
    family: Option<&str>,
    profile: Option<&BTreeMap<String, String>>,
) {
    let values = pairs_for(family, profile);
    for key in machine::names() {
        cmd.env_remove(key);
    }
    cmd.envs(values);
    if let Some(path) = agent_path() {
        cmd.env("PATH", path);
    }
    if let Some((layer, user)) = agent_shell_env() {
        cmd.env("ZDOTDIR", layer);
        match user {
            Some(user) => cmd.env(AGENT_USER_ZDOTDIR_ENV, user),
            None => cmd.env_remove(AGENT_USER_ZDOTDIR_ENV),
        };
    }
    if let Some(browser) = agent_browser_env() {
        cmd.env("BROWSER", browser);
    }
}

/// The fixed login-derived subset a remote-origin harness may receive.
///
/// Only the resolved executable search path crosses this boundary. The
/// person's `loginEnvAllow`, provider variables, proxy variables and shell
/// startup layer are local authority and are never inherited by a remote
/// process. A remote profile may still name an explicit `${env:...}` value;
/// resolving that reference is the profile owner's authorization.
pub fn apply_remote_tokio(cmd: &mut tokio::process::Command) {
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
    let values = pairs_for(family, profile);
    for key in machine::names() {
        cmd.env_remove(key);
    }
    cmd.envs(values);
    if let Some(path) = agent_path() {
        cmd.env("PATH", path);
    }
    if let Some((layer, user)) = agent_shell_env() {
        cmd.env("ZDOTDIR", layer);
        match user {
            Some(user) => cmd.env(AGENT_USER_ZDOTDIR_ENV, user),
            None => cmd.env_remove(AGENT_USER_ZDOTDIR_ENV),
        };
    }
    if let Some(browser) = agent_browser_env() {
        cmd.env("BROWSER", browser);
    }
}

/// The app's URL opener next to its bundled CLI (`<Resources>/bin/cmux-open-url`,
/// scripts/cmux-next/url-open), by the bare name an agent finds first on [`agent_path`].
const URL_OPENER: &str = "cmux-open-url";

/// The `BROWSER` an agent gets: the app's URL opener, as the app's terminals get
/// (BundledCLIEnvironment.swift), so a sign-in or device-code page a tool opens
/// (`gh auth login`, `aws sso login`, Python's webbrowser, `open <url>`) lands in a
/// cmux browser tab and not in the default browser. Set before the agent's shells
/// run the user's files, so a `.zprofile` that sets `BROWSER=open` only when it is
/// unset (prezto's stock one) keeps it. `None` when this daemon already has a
/// `BROWSER` or the person added `BROWSER` to `loginEnvAllow` (theirs wins), or
/// without a bundled CLI whose bin dir holds an executable opener (an older app).
pub fn agent_browser_env() -> Option<&'static str> {
    if std::env::var_os("BROWSER").is_some_and(|v| !v.is_empty()) || extra_exact("BROWSER") {
        return None;
    }
    let bin = std::env::var_os(BUNDLED_CLI_ENV)
        .map(PathBuf::from)
        .filter(|cli| cli.is_absolute())
        .and_then(|cli| cli.parent().map(std::path::Path::to_path_buf))?;
    is_executable(&bin.join(URL_OPENER)).then_some(URL_OPENER)
}

#[cfg(unix)]
fn is_executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(path: &std::path::Path) -> bool {
    path.is_file()
}

/// The app's agent zsh layer, `<Resources>/cmux-cli-path/zsh-agent`, next to
/// the bundled CLI (`<Resources>/bin/cmux`).
const AGENT_ZSH_LAYER: &str = "cmux-cli-path/zsh-agent";
/// The user's ZDOTDIR while the agent layer stands in for it.
pub const AGENT_USER_ZDOTDIR_ENV: &str = "CMUX_CLI_AGENT_ZDOTDIR";

/// The variables that keep the app's `cmux` first in the shells an agent
/// starts for its commands. [`agent_path`] puts it first in the agent's own
/// PATH, but Codex and Claude Code run each command in a fresh `zsh -lc`,
/// which reads the user's `.zprofile` again; that often prepends
/// `~/.local/bin`, where an old PyPI `cmux` lives (0.13.4 lacks this app's
/// verbs). `ZDOTDIR` names the app's agent layer
/// (Resources/cmux-cli-path/zsh-agent/.zshenv), which runs the user's files
/// from the user's ZDOTDIR, saved in [`AGENT_USER_ZDOTDIR_ENV`], and moves the
/// bundled CLI back to the front after each. Returns (the layer for
/// `ZDOTDIR`, the user's ZDOTDIR or none); `None` without a bundled CLI or
/// without the layer next to it (an older app). Other shells ignore ZDOTDIR.
pub fn agent_shell_env() -> Option<(OsString, Option<OsString>)> {
    let resources = std::env::var_os(BUNDLED_CLI_ENV)
        .map(PathBuf::from)
        .filter(|cli| cli.is_absolute())
        .and_then(|cli| cli.parent()?.parent().map(std::path::Path::to_path_buf))?;
    let layer = resources.join(AGENT_ZSH_LAYER);
    if !layer.join(".zshenv").is_file() {
        return None;
    }
    // The user's ZDOTDIR: the daemon's, else the login shell's. A daemon
    // started from an agent's shell already has the layer: keep its saved one.
    let current = std::env::var_os("ZDOTDIR").or_else(|| var("ZDOTDIR").map(OsString::from));
    let user = match current {
        Some(dir) if std::path::Path::new(&dir) == layer => {
            std::env::var_os(AGENT_USER_ZDOTDIR_ENV)
        }
        other => other,
    }
    .filter(|dir| !dir.is_empty());
    Some((layer.into_os_string(), user))
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
    let mut file = crate::config::private_state_file(&cache_path()).ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let cache: Cache = serde_json::from_slice(&bytes).ok()?;
    (cache.version == CACHE_VERSION).then_some(cache)
}

/// `fingerprint` is the one taken before the shell read these variables.
fn save_cache(fingerprint: &str, login: &[(String, String)], login_path: Option<&str>) {
    let mut vars = BTreeMap::new();
    let mut secret_names = Vec::new();
    for (k, v) in login {
        // A delivered value is a secret whatever its name (`DEMO`, `STRIPE`). A base URL is
        // one only when it carries a credential (userinfo, `key=` or `token=` in its query:
        // `is_secret`); a plain endpoint is cached by value, so a restart has it at once.
        if is_secret(k, v) || delivered(k) {
            secret_names.push(k.clone());
        } else {
            vars.insert(k.clone(), v.clone());
        }
    }
    STATE.write().unwrap_or_else(|e| e.into_inner()).secret_names = secret_names.clone();
    let cache = Cache {
        version: CACHE_VERSION,
        fingerprint: fingerprint.to_owned(),
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

/// Files created by cloud apply-machine-config and deliver-secrets. Their
/// metadata is enough to detect delivery, rotation and deletion; never read
/// or hash a credential value on the spawn decision path.
fn machine_files_stamp_in(home: &std::path::Path) -> Option<String> {
    let mut any = false;
    let mut stamp = String::new();
    for name in ["machine.env", "machine-secrets.env"] {
        let path = home.join(".config/cmux").join(name);
        match std::fs::symlink_metadata(path) {
            Ok(meta) => {
                any = true;
                let kind = if meta.is_file() {
                    'f'
                } else if meta.file_type().is_symlink() {
                    'l'
                } else {
                    'o'
                };
                let modified = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                // A delivery uses atomic replacement: preserve the identity change
                // even for a same-length secret written within one mtime tick.
                #[cfg(unix)]
                let identity = {
                    use std::os::unix::fs::MetadataExt as _;
                    format!("{}:{}:{}:{}", meta.dev(), meta.ino(), meta.ctime(), meta.ctime_nsec())
                };
                #[cfg(not(unix))]
                let identity = String::new();
                stamp.push_str(&format!("{name}:{kind}:{}:{modified}:{identity};", meta.len()));
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                stamp.push_str(&format!("{name}:absent;"));
            }
            Err(e) => {
                any = true;
                stamp.push_str(&format!("{name}:error:{:?};", e.kind()));
            }
        }
    }
    any.then_some(stamp)
}

/// The largest secrets file read for its names, the applier's limit too.
const MAX_SECRETS_FILE: u64 = 4 << 20;

/// The names `export NAME=` in `<home>/.config/cmux/machine-secrets.env`,
/// the receiver's format. Only a regular file of this user, opened without
/// following a link or blocking on a FIFO, as the applier reads it. The
/// buffer holding the values is zeroed when dropped; no value is kept.
fn delivered_names_in(home: &std::path::Path) -> Vec<String> {
    use std::io::Read as _;
    let path = home.join(".config/cmux/machine-secrets.env");
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let Ok(file) = options.open(&path) else { return Vec::new() };
    let Ok(meta) = file.metadata() else { return Vec::new() };
    if !meta.is_file() || meta.len() > MAX_SECRETS_FILE {
        return Vec::new();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if meta.uid() != unsafe { libc::getuid() } {
            return Vec::new();
        }
    }
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    if file.take(MAX_SECRETS_FILE).read_to_end(&mut bytes).is_err() {
        return Vec::new();
    }
    let mut names: Vec<String> = bytes
        .split(|b| *b == b'\n')
        .filter_map(|line| line.strip_prefix(b"export "))
        .filter_map(|rest| {
            let end = rest.iter().position(|b| *b == b'=')?;
            let name = &rest[..end];
            let valid = name.first().is_some_and(|b| b.is_ascii_alphabetic() || *b == b'_')
                && name.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_');
            valid.then(|| String::from_utf8_lossy(name).into_owned())
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

fn delivered_names() -> Vec<String> {
    let home =
        std::env::var_os("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
    delivered_names_in(&home)
}

/// The machine files' metadata stamp (never a value), for keys that must
/// change when a delivery or revocation does (the agent pool's). It covers
/// the vault too (`vault::stamp`): a pooled agent started before a vault pull,
/// a hold or a credential change is discarded at its claim.
pub fn machine_stamp() -> Option<String> {
    let vault = crate::vault::stamp();
    match (machine_files_stamp(), vault) {
        (None, None) => None,
        (files, vault) => {
            Some(format!("{}|vault:{}", files.unwrap_or_default(), vault.unwrap_or_default()))
        }
    }
}

fn machine_files_stamp() -> Option<String> {
    let home =
        std::env::var_os("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
    machine_files_stamp_in(&home)
}

/// The startup files and tool-manager configs a login shell reads: path,
/// size and mtime of each (absent ones count too), plus the shell itself.
fn fingerprint() -> String {
    use sha2::{Digest, Sha256};
    let shell = std::env::var("SHELL").unwrap_or_default();
    let mut hash = Sha256::new();
    hash.update(shell.as_bytes());
    // A changed loginEnvAllow is a changed rule: read the shell again.
    let mut extra = EXTRA_ALLOW.read().unwrap_or_else(|e| e.into_inner()).clone();
    extra.sort();
    hash.update(format!("allow:{};", extra.join(",")).as_bytes());
    for f in startup_files() {
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

/// The files `fingerprint` reads and `watch.rs` watches: the login shell's
/// startup files, tool-manager configs and the shell itself.
fn startup_files() -> Vec<PathBuf> {
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
        // Both machine configuration and delivered secrets can change after daemon startup.
        ".config/cmux/machine.env",
        ".config/cmux/machine-secrets.env",
    ] {
        files.push(home.join(f));
    }
    for f in
        ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/profile", "/etc/bashrc", "/etc/paths"]
    {
        files.push(PathBuf::from(f));
    }
    files.push(PathBuf::from(&shell));
    files
}

#[cfg(test)]
mod machine_file_tests {
    use super::{
        DELIVERED, allowed, delivered_names_in, is_secret, machine_files_stamp_in, startup_files,
        storable,
    };

    /// A delivered name is not on the allow-list itself: only the local
    /// spawn paths (`pairs_for`) add it, so nested-session restoration and
    /// remote-origin launches, which go through `allowed`, never get it.
    #[test]
    fn delivered_names_stay_off_the_allow_list() {
        let before = std::mem::replace(
            &mut *DELIVERED.write().unwrap(),
            vec!["CLAUDE_CODE_OAUTH_TOKEN".into(), "DEMO_KEY".into()],
        );
        assert!(!allowed("DEMO_KEY", "dummy", None));
        assert!(!allowed("DEMO_KEY", "dummy", Some("codex")));
        assert!(!allowed("CLAUDE_CODE_OAUTH_TOKEN", "dummy", None));
        *DELIVERED.write().unwrap() = before;
    }

    /// Gemini and Muse credentials follow their ACP harness across the
    /// daemon-to-agent boundary, while staying scoped away from other agents.
    /// A provider key with one owning family besides the multi-provider
    /// harnesses (`foreign_login::provider_key_owner`) comes from the login
    /// shell for that family, as it stays in the daemon's env for it, and for
    /// no other single-agent family.
    #[test]
    fn a_provider_key_reaches_its_own_family_from_the_login_shell() {
        for (key, own) in [
            ("AZURE_OPENAI_API_KEY", "codex"),
            ("XAI_API_KEY", "grok"),
            ("DEEPSEEK_API_KEY", "deepseek"),
            ("OPENAI_BASE_URL", "codex"),
            ("ANTHROPIC_BASE_URL", "claude"),
            ("GOOGLE_API_KEY", "gemini"),
        ] {
            assert!(allowed(key, "dummy", Some(own)), "{own} gets {key}");
            for other in ["claude", "codex", "gemini", "grok", "deepseek", "muse"] {
                if other != own && !(other == "gemini" && key.starts_with("GOOGLE_")) {
                    assert!(!allowed(key, "dummy", Some(other)), "{other} never gets {key}");
                }
            }
        }
        // Every owned key, by the one table both sides read.
        for key in super::PROVIDER_KEYS {
            if let Some(own) = crate::agent::foreign_login::provider_key_owner(key) {
                assert!(allowed(key, "dummy", Some(own)), "{own} gets {key}");
            }
        }
    }

    #[test]
    fn provider_credentials_are_scoped_to_gemini_and_muse() {
        assert!(allowed("GEMINI_API_KEY", "secret", Some("gemini")));
        assert!(allowed("GOOGLE_API_KEY", "secret", Some("gemini")));
        assert!(allowed("MUSE_API_KEY", "secret", Some("muse")));
        assert!(allowed("META_API_KEY", "secret", Some("muse")));
        assert!(!allowed("MUSE_API_KEY", "secret", Some("gemini")));
        assert!(!allowed("META_API_KEY", "secret", Some("claude")));
    }

    /// A multi-provider harness waits for the shell read that fetches its
    /// keys, at most `TIMEOUT`, and goes on as soon as a read ends; another
    /// family never waits.
    #[tokio::test(start_paused = true)]
    async fn a_provider_harness_waits_for_the_read_that_fetches_its_keys() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};
        let start = tokio::time::Instant::now();
        super::wait_while(|| true, super::TIMEOUT).await;
        assert_eq!(start.elapsed(), super::TIMEOUT, "the wait is bounded");
        let pending = Arc::new(AtomicBool::new(true));
        let read = pending.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            read.store(false, Ordering::SeqCst);
            super::READ_ENDED.notify_waiters();
        });
        let start = tokio::time::Instant::now();
        let waiting = pending.clone();
        super::wait_while(move || waiting.load(Ordering::SeqCst), super::TIMEOUT).await;
        let waited = start.elapsed();
        assert_eq!(waited, std::time::Duration::from_millis(200), "it goes on when the read ends");
    }

    /// Which names a spawn waits for after a cached start, from its final env
    /// plan: a multi-provider harness any provider key or base URL; Claude and
    /// Codex the base URL they read, never a key (their own wait is
    /// `Plan::wait`); a reference always; never a name the plan sets or
    /// removes (a route's unset), nor anything on a remote-origin plan.
    #[test]
    fn a_spawn_waits_only_for_values_its_plan_takes_from_the_shell() {
        use super::ChildEnv;
        use std::collections::BTreeMap;
        let plan = |family, profile, remote, explicit: &[(&str, Option<&str>)]| ChildEnv {
            family,
            profile,
            remote,
            explicit: Some(
                explicit.iter().map(|(k, v)| (k.to_string(), v.map(str::to_owned))).collect(),
            ),
        };
        let takes = |p: &ChildEnv, name: &str| p.takes(name, &p.refs());
        for family in ["opencode", "opencode-v2", "pi", "prime", "cmux-harness", "hermes"] {
            for key in ["OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_BASE_URL"] {
                assert!(takes(&plan(family, None, false, &[]), key), "{family} waits for {key}");
            }
        }
        assert!(takes(&plan("claude", None, false, &[]), "ANTHROPIC_BASE_URL"));
        assert!(takes(&plan("codex", None, false, &[]), "OPENAI_BASE_URL"));
        for (family, key) in [
            ("claude", "OPENAI_BASE_URL"),
            ("claude", "ANTHROPIC_API_KEY"),
            ("claude", "ANTHROPIC_AUTH_TOKEN"),
            ("claude", "OPENROUTER_API_KEY"),
            ("codex", "ANTHROPIC_BASE_URL"),
            ("codex", "OPENAI_API_KEY"),
            ("gemini", "OPENAI_BASE_URL"),
            ("gemini", "GOOGLE_API_KEY"),
            ("deepseek", "OPENAI_BASE_URL"),
            ("opencode", "GITHUB_TOKEN"),
        ] {
            assert!(!takes(&plan(family, None, false, &[]), key), "{family} never waits for {key}");
        }
        // A route that unsets it (codex-login), or a profile that sets it: never.
        let route: BTreeMap<String, String> =
            [(crate::routes::UNSET_KEY.to_owned(), "OPENAI_API_KEY,OPENAI_BASE_URL".to_owned())]
                .into();
        let unset = plan("codex", Some(&route), false, &[("OPENAI_BASE_URL", None)]);
        assert!(!takes(&unset, "OPENAI_BASE_URL"));
        // An Anthropic endpoint harness clears the Claude provider env it does not set.
        let own: BTreeMap<String, String> =
            [(crate::byo_endpoint::OWN_ENDPOINT_KEY.to_owned(), "anthropic".to_owned())].into();
        let cleared = plan("claude", Some(&own), false, &[("ANTHROPIC_BASE_URL", None)]);
        assert!(!takes(&cleared, "ANTHROPIC_BASE_URL"));
        // A scrub is not an unset: the nested-session scrub (a daemon started
        // inside a Claude Code turn) removes the inherited ANTHROPIC_BASE_URL,
        // and the login import puts the person's own back, so a cached start
        // still waits for it.
        let scrubbed = plan("claude", None, false, &[("ANTHROPIC_BASE_URL", None)]);
        assert!(takes(&scrubbed, "ANTHROPIC_BASE_URL"));
        let scrubbed = plan("pi", None, false, &[("OPENROUTER_API_KEY", None)]);
        assert!(takes(&scrubbed, "OPENROUTER_API_KEY"));
        let set = plan("claude", None, false, &[("ANTHROPIC_BASE_URL", Some("https://r.invalid"))]);
        assert!(!takes(&set, "ANTHROPIC_BASE_URL"));
        // A remote-origin plan takes no login value.
        assert!(!takes(&plan("codex", None, true, &[]), "OPENAI_BASE_URL"));
        assert!(!takes(&plan("pi", None, true, &[]), "OPENROUTER_API_KEY"));
        // A `${env:X}` reference needs X, whatever the family, name or plan.
        let refs: BTreeMap<String, String> = [
            ("ANTHROPIC_BASE_URL".to_owned(), "${env:ANTHROPIC_BASE_URL}".to_owned()),
            ("TEAM_HEADER".to_owned(), "Bearer ${env:TEAM_GATEWAY_TOKEN}".to_owned()),
        ]
        .into();
        let by_ref = plan("claude", Some(&refs), true, &[("ANTHROPIC_BASE_URL", Some("x"))]);
        assert!(takes(&by_ref, "ANTHROPIC_BASE_URL"));
        assert!(takes(&by_ref, "TEAM_GATEWAY_TOKEN"));
        assert!(!takes(&by_ref, "OTHER_TOKEN"));
        // Not built yet (a reference missing): only references.
        let unbuilt = ChildEnv { explicit: None, ..plan("claude", Some(&refs), false, &[]) };
        assert!(takes(&unbuilt, "TEAM_GATEWAY_TOKEN"));
        assert!(!takes(&plan("pi", None, false, &[]), "GITHUB_TOKEN"));
    }

    /// A read that ends between building a command and checking its plan
    /// left the command with the values from before it: it is built again.
    #[tokio::test]
    async fn a_command_built_while_a_read_ended_is_built_again() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let builds = AtomicUsize::new(0);
        let mut plan =
            super::ChildEnv { family: "pi", profile: None, remote: false, explicit: None };
        let built = super::build_ready(
            &mut plan,
            || {
                let n = builds.fetch_add(1, Ordering::SeqCst);
                if n == 0 {
                    // The shell read ends after this build took its values.
                    super::READS.fetch_add(1, Ordering::SeqCst);
                    super::READ_ENDED.notify_waiters();
                }
                Ok::<_, String>(n)
            },
            |_| Vec::new(),
            |e| e,
        )
        .await
        .unwrap();
        assert_ne!(built, 0, "the command built before the read ended is not the one started");
    }

    /// A plain base URL is cached by value; one with a credential in its
    /// userinfo or query is a secret, kept by name only.
    #[test]
    fn only_a_base_url_with_a_credential_is_a_secret() {
        for url in
            ["https://gateway.example/v1", "http://127.0.0.1:11434/v1", "https://api.example"]
        {
            assert!(!is_secret("ANTHROPIC_BASE_URL", url), "{url}");
            assert!(!is_secret("OPENAI_BASE_URL", url), "{url}");
        }
        for url in [
            "https://user:pass@gateway.example/v1",
            "https://gateway.example/v1?api_key=s3cret",
            "https://gateway.example/v1?token=s3cret",
        ] {
            assert!(is_secret("ANTHROPIC_BASE_URL", url), "{url}");
        }
    }

    /// A provider key exported in the login shell reaches the harnesses that
    /// sign in with any provider's key (OpenCode, pi and its forks, cmux
    /// Harness, Hermes) and no other family; it is kept as a secret, and no
    /// other token comes in with it.
    #[test]
    fn provider_keys_reach_multi_provider_harnesses_only() {
        const KEYS: [&str; 14] = [
            "OPENROUTER_API_KEY",
            "GROQ_API_KEY",
            "TOGETHER_API_KEY",
            "FIREWORKS_API_KEY",
            "DEEPSEEK_API_KEY",
            "MISTRAL_API_KEY",
            "XAI_API_KEY",
            "CEREBRAS_API_KEY",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "GOOGLE_GENERATIVE_AI_API_KEY",
            "HF_TOKEN",
        ];
        for family in ["opencode", "opencode-v2", "pi", "omp", "prime", "cmux-harness", "hermes"] {
            for key in KEYS {
                assert!(allowed(key, "dummy", Some(family)), "{family} gets {key}");
            }
            assert!(allowed("OPENAI_BASE_URL", "http://127.0.0.1:11434/v1", Some(family)));
            assert!(allowed("ANTHROPIC_BASE_URL", "https://gateway.example", Some(family)));
            // Explicit names only: no prefix, and no other token.
            for key in [
                "OPENROUTER_REFERER_TOKEN",
                "GROQ_SECRET",
                "OPENAI_ORG_TOKEN",
                "ANTHROPIC_AUTH_TOKEN",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CODEX_API_KEY",
                "GITHUB_TOKEN",
                "GH_TOKEN",
                "NPM_TOKEN",
                "AWS_SECRET_ACCESS_KEY",
                "STRIPE_API_KEY",
            ] {
                assert!(!allowed(key, "dummy", Some(family)), "{family} never gets {key}");
            }
        }
        // Every other family keeps its own list.
        for key in ["OPENROUTER_API_KEY", "GROQ_API_KEY", "DEEPSEEK_API_KEY", "HF_TOKEN"] {
            for family in [None, Some("claude"), Some("codex"), Some("gemini"), Some("muse")] {
                assert!(!allowed(key, "dummy", family), "{family:?} never gets {key}");
            }
            for family in ["chief", "unii", "cursor", "deepseek", "fake"] {
                // DeepSeek Harness gets only its own key (`foreign_login::provider_key_owner`).
                if family == "deepseek" && key == "DEEPSEEK_API_KEY" {
                    continue;
                }
                assert!(!allowed(key, "dummy", Some(family)), "{family} never gets {key}");
            }
        }
        assert!(!allowed("OPENAI_API_KEY", "dummy", Some("claude")));
        assert!(!allowed("ANTHROPIC_API_KEY", "dummy", Some("codex")));
        // Kept in memory as secrets: their names, never their values, reach the cache.
        for key in KEYS {
            assert!(storable(key, "dummy"), "{key} is kept");
            assert!(is_secret(key, "dummy"), "{key} is a secret");
        }
        assert!(storable("OPENAI_BASE_URL", "http://127.0.0.1:11434/v1"));
        assert!(!storable("GITHUB_TOKEN", "dummy"));
        assert!(!storable("STRIPE_API_KEY", "dummy"));
    }

    /// Only the names of a delivered file, in the receiver's format; a link
    /// or a missing file names nothing.
    #[test]
    fn delivered_names_reads_only_export_names() {
        let dir = tempfile::tempdir().expect("temp home");
        let conf = dir.path().join(".config/cmux");
        std::fs::create_dir_all(&conf).expect("config dir");
        assert!(delivered_names_in(dir.path()).is_empty());
        let secrets = conf.join("machine-secrets.env");
        std::fs::write(
            &secrets,
            b"export DEMO_KEY='dummy-1'\nexport _OTHER2='a=b'\nexport 9BAD='x'\n# export NOTE='x'\nexport DEMO_KEY='dummy-2'\n",
        )
        .expect("deliver");
        assert_eq!(delivered_names_in(dir.path()), vec!["DEMO_KEY", "_OTHER2"]);
        #[cfg(unix)]
        {
            let real = dir.path().join("elsewhere.env");
            std::fs::rename(&secrets, &real).expect("move");
            std::os::unix::fs::symlink(&real, &secrets).expect("link");
            assert!(delivered_names_in(dir.path()).is_empty());
        }
    }

    #[test]
    fn login_watch_includes_delivered_machine_files() {
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .or_else(dirs::home_dir)
            .unwrap_or_default();
        let watched = startup_files();
        for name in ["machine.env", "machine-secrets.env"] {
            assert!(watched.contains(&home.join(".config/cmux").join(name)));
        }
    }

    #[test]
    fn stamp_changes_for_delivery_rotation_and_revocation() {
        let dir = tempfile::tempdir().expect("temp home");
        let conf = dir.path().join(".config/cmux");
        std::fs::create_dir_all(&conf).expect("config dir");
        let env = conf.join("machine.env");
        let secrets = conf.join("machine-secrets.env");
        assert_eq!(machine_files_stamp_in(dir.path()), None);
        std::fs::write(&env, b"export RUN_MODE='dev'\n").expect("write machine env");
        let applied = machine_files_stamp_in(dir.path());
        assert!(applied.is_some());
        std::fs::write(&secrets, b"export SESSION_KEY='dummy-secret-1'\n").expect("deliver");
        let delivered = machine_files_stamp_in(dir.path());
        assert_ne!(delivered, applied);
        std::fs::write(&secrets, b"export SESSION_KEY='different-dummy-secret'\n").expect("rotate");
        let rotated = machine_files_stamp_in(dir.path());
        assert_ne!(rotated, delivered);
        #[cfg(unix)]
        {
            // Atomic replace with the same size changes the file identity.
            let next = conf.join("replacement");
            std::fs::write(&next, b"export SESSION_KEY='same-length-secret-001'\n")
                .expect("prepare replacement");
            let before = machine_files_stamp_in(dir.path());
            assert_eq!(
                std::fs::metadata(&next).expect("replacement").len(),
                std::fs::metadata(&secrets).expect("old value").len(),
            );
            std::fs::rename(&next, &secrets).expect("atomic replace");
            assert_ne!(machine_files_stamp_in(dir.path()), before);
        }
        std::fs::remove_file(&secrets).expect("revoke");
        assert_eq!(machine_files_stamp_in(dir.path()), applied);
        std::fs::remove_file(&env).expect("remove machine env");
        assert_eq!(machine_files_stamp_in(dir.path()), None);
    }
}

#[cfg(test)]
mod effective_tests {
    use super::layered;
    use std::collections::BTreeMap;

    fn pairs(list: &[(&str, &str)]) -> Vec<(String, String)> {
        list.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    /// A sign-in check reads what the agent would get (hq#2569 #2): a token or
    /// a `CODEX_HOME` exported only in the login shell counts, the profile's
    /// env wins, and a nested Claude Code session's keys do not leak in.
    #[test]
    fn layers_daemon_login_and_profile_like_a_spawn() {
        let profile = BTreeMap::from([("CODEX_HOME".to_owned(), "/profile/codex".to_owned())]);
        let env = layered(
            pairs(&[("HOME", "/u"), ("CODEX_HOME", "/daemon/codex"), ("OPENAI_BASE_URL", "d")]),
            false,
            pairs(&[("CLAUDE_CODE_OAUTH_TOKEN", "login"), ("OPENAI_BASE_URL", "login")]),
            Vec::new(),
            &profile,
        );
        assert_eq!(env["HOME"], "/u");
        assert_eq!(env["CODEX_HOME"], "/profile/codex");
        assert_eq!(env["OPENAI_BASE_URL"], "login");
        assert_eq!(env["CLAUDE_CODE_OAUTH_TOKEN"], "login");

        let nested = layered(
            pairs(&[("CLAUDECODE", "1"), ("ANTHROPIC_API_KEY", "session"), ("HOME", "/u")]),
            true,
            Vec::new(),
            pairs(&[("CLAUDE_CODE_OAUTH_TOKEN", "login")]),
            &BTreeMap::new(),
        );
        assert!(!nested.contains_key("ANTHROPIC_API_KEY"));
        assert_eq!(nested["CLAUDE_CODE_OAUTH_TOKEN"], "login");
        assert_eq!(nested["HOME"], "/u");
    }

    /// Under a nested Claude Code session the scrub drops the vault's and
    /// `machine.env`'s Claude keys too; a launch puts them back
    /// (`restore_machine_tokio`) and a sign-in check must see the same:
    /// session over machine over vault over login over the daemon.
    #[test]
    fn a_nested_check_restores_the_vault_and_machine_like_a_launch() {
        let vault = pairs(&[("ANTHROPIC_BASE_URL", "vault"), ("ANTHROPIC_MODEL", "vault")]);
        let machine = BTreeMap::from([("ANTHROPIC_MODEL".to_owned(), "machine".to_owned())]);
        let login = BTreeMap::from([
            ("ANTHROPIC_BASE_URL".to_owned(), "login".to_owned()),
            ("ANTHROPIC_SMALL_FAST_MODEL".to_owned(), "login".to_owned()),
        ]);
        let mut restored = pairs(&[("ANTHROPIC_SMALL_FAST_MODEL", "login")]);
        restored.extend(super::nested_local(vault.clone(), machine.clone()));
        let profile = BTreeMap::from([("ANTHROPIC_MODEL".to_owned(), "session".to_owned())]);
        let env = layered(
            pairs(&[("CLAUDECODE", "1"), ("ANTHROPIC_BASE_URL", "daemon"), ("HOME", "/u")]),
            true,
            super::overlay(login, vault, machine.clone()),
            restored,
            &profile,
        );
        assert_eq!(env["ANTHROPIC_BASE_URL"], "vault");
        assert_eq!(env["ANTHROPIC_SMALL_FAST_MODEL"], "login");
        assert_eq!(env["ANTHROPIC_MODEL"], "session");
        let env = layered(
            pairs(&[("CLAUDECODE", "1")]),
            true,
            Vec::new(),
            super::nested_local(pairs(&[("ANTHROPIC_MODEL", "vault")]), machine),
            &BTreeMap::new(),
        );
        assert_eq!(env["ANTHROPIC_MODEL"], "machine");
    }
}
