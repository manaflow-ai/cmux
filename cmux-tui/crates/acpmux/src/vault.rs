//! The person's vault on a joined machine: the env vars and API keys they
//! keep once for all their machines, pulled with the machine credential
//! `acpmux machine join` stored (`cli/cloud_join.rs`), and given to every
//! agent this machine's daemon spawns.
//!
//! - `GET {hub}/v1/vault/machine` (bearer: the machine credential) answers
//!   `{ env: [{ name, revision, state, valueBase64? }] }`; 403
//!   `vault.not_granted` is a machine the person has not shared the vault
//!   with (not an error), 401 a revoked credential (`wire.rs`).
//! - Each value goes into the OS secret store (Keychain service `cmux-vault`,
//!   account `env/<NAME>`, or the Secret Service on Linux), never a plain
//!   file; a machine with neither refuses env storage (`store.rs`).
//! - `<ACPMUX_HOME>/vault-state.json` (0600) keeps the hub, the last pull and
//!   per entry its name, revision and a salted fingerprint, never a value
//!   (`plan.rs`). Revoked or removed entries are deleted from the store.
//! - The daemon pulls at start when the machine is joined, then every 15
//!   minutes (backoff on failure), logging codes only, and holds the values
//!   in memory, reloaded from the store when the state's revisions change.
//!   Every local agent gets them (`login_env::pairs_for`). Precedence, high
//!   to low: the profile's, preset's and session's env; this machine's
//!   delivered `machine.env`; the vault; the daemon's own environment; the
//!   login shell's. Remote-origin launches never get them.
//!
//! The vault never carries a Claude or ChatGPT/Codex subscription login:
//! `machine vault status` only says whether each harness is signed in here,
//! so the person runs that harness's own sign-in on this machine.

pub mod plan;
pub mod pull;
pub mod store;
pub mod wire;

#[cfg(test)]
mod tests;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use self::plan::State;
use self::store::SecretStore;

/// Advertised by `acpmux capabilities`: `machine vault pull|status|forget`.
pub const CAPABILITY: &str = "machine.vault.pull.v1";
/// How often the daemon pulls.
pub const EVERY: Duration = Duration::from_secs(15 * 60);
/// The first retry after a failed pull; doubled up to [`EVERY`].
const FIRST_RETRY: Duration = Duration::from_secs(30);

/// Env names the vault never sets, whatever the hub sends: a Claude
/// subscription token is the person's own login, signed in per machine.
pub const REFUSED_NAMES: &[&str] = &["CLAUDE_CODE_OAUTH_TOKEN"];

/// Set by the daemon's worker: only a daemon gives agents the vault.
static ACTIVE: AtomicBool = AtomicBool::new(false);

struct Loaded {
    /// The state file's identity when last read: `None` never read,
    /// `Some(None)` read while there was no file.
    seen: Option<Option<Stamp>>,
    signature: String,
    /// The state the values came from, for its credential binding.
    state: Option<State>,
    vars: Vec<(String, Zeroizing<String>)>,
    /// Some entries could not be read (a locked Keychain): when, so they are
    /// read again after [`RETRY_INCOMPLETE`] without a state change.
    incomplete_at: Option<std::time::Instant>,
}

/// How long an incomplete load waits before it reads the store again.
pub const RETRY_INCOMPLETE: Duration = Duration::from_secs(30);

#[derive(Clone, PartialEq, Eq)]
struct Stamp {
    len: u64,
    modified: Option<std::time::SystemTime>,
    #[cfg(unix)]
    ino: u64,
}

static LOADED: RwLock<Loaded> = RwLock::new(Loaded {
    seen: None,
    signature: String::new(),
    state: None,
    vars: Vec::new(),
    incomplete_at: None,
});
static RELOAD: Mutex<()> = Mutex::new(());

fn stamp_of(path: &std::path::Path) -> Option<Stamp> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    Some(Stamp {
        len: meta.len(),
        modified: meta.modified().ok(),
        #[cfg(unix)]
        ino: std::os::unix::fs::MetadataExt::ino(&meta),
    })
}

/// The values the state lists, read from `store`. An entry whose stored value
/// no longer matches its fingerprint (edited or removed since) is left out,
/// with its code.
pub fn load_values(
    state: &State,
    store: &dyn SecretStore,
) -> (Vec<(String, Zeroizing<String>)>, Vec<(String, &'static str)>) {
    let (mut vars, mut skipped) = (Vec::new(), Vec::new());
    for (name, record) in &state.env {
        match store.get(name) {
            Ok(Some(value)) if state.fingerprint(name, &value) == record.fingerprint => {
                vars.push((name.clone(), value));
            }
            Ok(Some(_)) => skipped.push((name.clone(), "vault.env_changed")),
            Ok(None) => skipped.push((name.clone(), "vault.env_missing")),
            Err(code) => skipped.push((name.clone(), code)),
        }
    }
    (vars, skipped)
}

/// Whether the loaded values still stand for the state file seen now.
fn current(loaded: &Loaded, now: &Option<Stamp>, at: std::time::Instant) -> bool {
    loaded.seen.as_ref() == Some(now)
        && loaded.incomplete_at.is_none_or(|t| at.duration_since(t) < RETRY_INCOMPLETE)
}

/// Reload the in-memory values when the state file changed since the last
/// read (a pull here or by `machine vault pull`), or when the last load could
/// not read every entry and [`RETRY_INCOMPLETE`] has passed. An entry the
/// state no longer lists (revoked, removed, or waiting for its store delete)
/// is dropped from memory on the reload that sees it gone.
fn refresh(store: &dyn SecretStore) {
    refresh_at(&pull::state_path(&crate::config::home()), store, std::time::Instant::now());
}

fn refresh_at(path: &std::path::Path, store: &dyn SecretStore, at: std::time::Instant) {
    let now = stamp_of(path);
    if current(&LOADED.read().unwrap_or_else(|e| e.into_inner()), &now, at) {
        return;
    }
    let _one = RELOAD.lock().unwrap_or_else(|e| e.into_inner());
    let (seen_before, complete_before) = {
        let loaded = LOADED.read().unwrap_or_else(|e| e.into_inner());
        if current(&loaded, &now, at) {
            return;
        }
        (loaded.seen.is_some(), loaded.incomplete_at.is_none())
    };
    let home = path.parent().map(std::path::Path::to_path_buf).unwrap_or_default();
    let state = pull::read_state(&home);
    let signature = state.signature();
    {
        let mut loaded = LOADED.write().unwrap_or_else(|e| e.into_inner());
        if seen_before && complete_before && loaded.signature == signature {
            loaded.seen = Some(now);
            return;
        }
    }
    let (vars, skipped) = load_values(&state, store);
    for (name, code) in &skipped {
        tracing::warn!(name = %name, code = %code, "vault env entry not loaded");
    }
    let mut loaded = LOADED.write().unwrap_or_else(|e| e.into_inner());
    loaded.seen = Some(now);
    loaded.signature = signature;
    loaded.state = Some(state);
    loaded.vars = vars;
    loaded.incomplete_at = (!skipped.is_empty()).then_some(at);
}

/// Forget the values held in memory, so the next spawn loads (tests).
#[cfg(test)]
fn reset_loaded() {
    let mut loaded = LOADED.write().unwrap_or_else(|e| e.into_inner());
    loaded.seen = None;
    loaded.signature.clear();
    loaded.state = None;
    loaded.vars.clear();
    loaded.incomplete_at = None;
}

/// The values held in memory now (tests).
#[cfg(test)]
fn loaded_names() -> Vec<String> {
    LOADED.read().unwrap_or_else(|e| e.into_inner()).vars.iter().map(|(k, _)| k.clone()).collect()
}

/// The vault env every local agent of this daemon gets (`login_env`). Empty
/// outside a daemon. Values are read from the store only when the state
/// changed; otherwise this is a `stat`.
pub fn env_for_children() -> Vec<(String, String)> {
    if !ACTIVE.load(Ordering::SeqCst) {
        return Vec::new();
    }
    deliver_at(&crate::config::home(), &store::OsStore, &pull::current_credential, Instant::now())
}

/// What a spawn gets, checked against a withdrawal racing the load: nothing
/// while a removal is held, and nothing when the state file changed or a
/// hold was placed while the values were read (a pull or `forget` that ran
/// during `load_values` may have saved a state without them), or when the
/// machine credential was replaced or revoked meanwhile (`machine join
/// --replace` changes neither file). The credential is read after the load
/// and again after the values are taken. The next spawn reloads.
fn deliver_at(
    home: &std::path::Path,
    store: &dyn SecretStore,
    current: pull::CurrentCredential,
    at: Instant,
) -> Vec<(String, String)> {
    if pull::held(home) {
        return Vec::new();
    }
    let path = pull::state_path(home);
    refresh_at(&path, store, at);
    let credential = current();
    let (seen, values) = {
        let loaded = LOADED.read().unwrap_or_else(|e| e.into_inner());
        (loaded.seen.clone(), given(&loaded, credential.clone()))
    };
    // Checked after the values were taken: a save, a hold or a credential
    // change since then (or during the load) means they may include a
    // withdrawn entry.
    if seen != Some(stamp_of(&path)) || pull::held(home) || current() != credential {
        return Vec::new();
    }
    values
}

/// The loaded values agents get: none while a removal is held (`held`, the
/// state not yet saved after one), else each entry whose authorizing answer
/// came for the machine's credential now, while it is not revoked (`current`).
#[cfg(test)]
fn delivered(current: Option<(String, bool)>, held: bool) -> Vec<(String, String)> {
    if held {
        return Vec::new();
    }
    given(&LOADED.read().unwrap_or_else(|e| e.into_inner()), current)
}

fn given(loaded: &Loaded, current: Option<(String, bool)>) -> Vec<(String, String)> {
    let Some(state) = loaded.state.as_ref() else { return Vec::new() };
    let names = state.delivered_names(current.as_ref().map(|(c, revoked)| (c.as_str(), *revoked)));
    loaded
        .vars
        .iter()
        .filter(|(k, _)| names.contains(k))
        .map(|(k, v)| (k.clone(), v.as_str().to_owned()))
        .collect()
}

/// What the vault env a spawn gets depends on, as metadata (never a value):
/// the state file's identity, the hold, and a digest of the machine
/// credential and its revoked flag. `None` outside a daemon. The agent pool
/// keys on it (`login_env::machine_stamp`).
pub fn stamp() -> Option<String> {
    if !ACTIVE.load(Ordering::SeqCst) {
        return None;
    }
    Some(stamp_in(&crate::config::home(), pull::current_credential()))
}

pub(crate) fn stamp_in(home: &std::path::Path, credential: Option<(String, bool)>) -> String {
    use sha2::{Digest, Sha256};
    let file = stamp_of(&pull::state_path(home));
    let mut h = Sha256::new();
    if let Some((credential, revoked)) = &credential {
        h.update(credential.as_bytes());
        h.update([u8::from(*revoked)]);
    }
    let credential: String = h.finalize().iter().take(8).map(|b| format!("{b:02x}")).collect();
    let file = match file {
        None => "none".to_owned(),
        Some(s) => {
            #[cfg(unix)]
            let ino = s.ino;
            #[cfg(not(unix))]
            let ino = 0u64;
            let at = s
                .modified
                .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_nanos());
            format!("{}:{at}:{ino}", s.len)
        }
    };
    format!("{file};held={};cred={credential}", pull::held(home))
}

/// The longest the first agent spawn waits for the first pull of a joined
/// machine that has no vault state yet.
pub const INITIAL_WAIT: Duration = Duration::from_secs(5);

/// Whether the daemon pulls before letting agents spawn: a joined machine
/// with no saved vault state (its first start after `machine join`).
pub fn needs_initial_pull(state_saved: bool, joined: bool) -> bool {
    joined && !state_saved
}

/// `first`, bounded by `wait`: `None` when it did not finish in time.
pub async fn bounded<T>(wait: Duration, first: impl std::future::Future<Output = T>) -> Option<T> {
    tokio::time::timeout(wait, first).await.ok()
}

/// Start the daemon's pull loop once. A joined machine with no vault state
/// pulls first, for at most [`INITIAL_WAIT`], before this returns (agent
/// spawns wait for startup); then every [`EVERY`], with backoff after a failure.
pub async fn start_worker() {
    if ACTIVE.swap(true, Ordering::SeqCst) {
        return;
    }
    let saved = pull::state_path(&crate::config::home()).exists();
    let joined = matches!(crate::cli::cloud_join::machine_credential(), Ok(Some(_)));
    let mut failures = 0u32;
    let mut first_delay = Duration::ZERO;
    if needs_initial_pull(saved, joined) {
        match bounded(INITIAL_WAIT, run_once()).await {
            Some(Ok(result)) => {
                tracing::info!(result, "vault pull");
                first_delay = EVERY;
            }
            Some(Err(code)) => {
                failures = 1;
                tracing::warn!(code = %code, failures, "vault pull failed");
                first_delay = backoff(failures);
            }
            // Timed out: the pull was dropped; the loop's first round runs it again now.
            None => tracing::warn!(code = "vault.initial_timeout", "vault pull failed"),
        }
    }
    tokio::spawn(async move {
        tokio::time::sleep(first_delay).await;
        loop {
            let delay = match run_once().await {
                Ok(result) => {
                    failures = 0;
                    if result != "not_joined" {
                        tracing::info!(result, "vault pull");
                    }
                    EVERY
                }
                Err(code) => {
                    failures = failures.saturating_add(1);
                    tracing::warn!(code = %code, failures, "vault pull failed");
                    backoff(failures)
                }
            };
            tokio::time::sleep(delay).await;
        }
    });
}

/// 30 s, 60 s, 2 min ... up to [`EVERY`].
pub fn backoff(failures: u32) -> Duration {
    let shift = failures.saturating_sub(1).min(16);
    FIRST_RETRY.saturating_mul(1u32 << shift).min(EVERY)
}

async fn run_once() -> Result<&'static str, String> {
    match crate::cli::cloud_join::machine_credential() {
        Ok(Some(_)) => {}
        Ok(None) => return Ok("not_joined"),
        Err(_) => return Err("vault.credential_unreadable".to_owned()),
    }
    let store: Arc<dyn SecretStore> = Arc::new(store::OsStore);
    let result = match pull::pull(crate::config::home(), store, false).await {
        Ok(outcome) => {
            for (name, code) in &outcome.failed {
                tracing::warn!(name = %name, code = %code, "vault env entry not stored");
            }
            Ok(outcome.state)
        }
        // A pull by `machine vault pull` holds the lock: it does this round's work.
        Err(failure) if failure.code == "vault.busy" => Ok("busy"),
        Err(failure) => Err(failure.code),
    };
    // Load what the pull stored before the next spawn needs it.
    let _ = tokio::task::spawn_blocking(|| refresh(&store::OsStore)).await;
    result
}
