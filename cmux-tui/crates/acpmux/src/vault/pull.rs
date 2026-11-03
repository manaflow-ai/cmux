//! One pull: ask the hub with the joined machine credential, plan, apply the
//! plan to the secret store, save the state. The CLI (`acpmux machine vault
//! pull`) and the daemon's worker share it, under one lock.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::plan::{self, State, Step};
use super::store::{SecretStore, UNAVAILABLE};
use super::wire::{self, Answer};

pub const STATE_FILE: &str = "vault-state.json";
const LOCK_FILE: &str = "vault.lock";
const MAX_BODY_BYTES: usize = 8 << 20;

/// What a pull did. Names and codes only.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Outcome {
    /// `ok`, `not_granted` or `off`.
    pub state: &'static str,
    pub hub: String,
    /// The env names present on this machine after the pull.
    pub env: Vec<String>,
    pub stored: Vec<String>,
    pub deleted: Vec<String>,
    /// Entries whose store or delete failed: name and code.
    pub failed: Vec<(String, &'static str)>,
    /// Entries of the answer this machine refused (malformed, or a name it never sets).
    pub refused: usize,
}

/// A failed pull. `code` is stable and holds no value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub code: String,
    /// The local entries a revoked credential removed (names only).
    pub deleted: Vec<String>,
    /// A pull that applied only part of its changes (`vault.partial`): what it did.
    pub outcome: Option<Outcome>,
}

impl Failure {
    fn code(code: impl Into<String>) -> Failure {
        Failure { code: code.into(), deleted: Vec::new(), outcome: None }
    }
}

/// The code of a pull whose store writes or deletes did not all succeed.
pub const PARTIAL: &str = "vault.partial";

pub fn state_path(home: &Path) -> PathBuf {
    home.join(STATE_FILE)
}

/// The saved state (fresh when none). Never holds a value.
pub fn read_state(home: &Path) -> State {
    let path = state_path(home);
    match std::fs::symlink_metadata(&path) {
        Ok(meta) if meta.is_file() => {}
        _ => return State::parse(None),
    }
    #[cfg(unix)]
    let file = crate::config::private_state_file(&path).ok();
    #[cfg(not(unix))]
    let file = std::fs::File::open(&path).ok();
    let mut bytes = Vec::new();
    if let Some(file) = file {
        use std::io::Read as _;
        let _ = file.take(4 << 20).read_to_end(&mut bytes);
    }
    State::parse(Some(&bytes))
}

pub fn write_state(home: &Path, state: &State) -> Result<(), &'static str> {
    crate::config::private_state_dir(home).map_err(|_| "vault.state_write_failed")?;
    let bytes = serde_json::to_vec_pretty(state).map_err(|_| "vault.state_write_failed")?;
    crate::config::write_atomic(&state_path(home), &bytes).map_err(|_| "vault.state_write_failed")
}

/// Held while a pull or forget reads and writes the state and the store.
pub struct Lock(#[allow(dead_code)] std::fs::File);

#[cfg(unix)]
impl Drop for Lock {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        // SAFETY: this process owns the descriptor.
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

/// `wait`: block until a running pull finishes (the CLI). Otherwise give up at
/// once (the daemon's worker skips that round).
#[cfg(unix)]
pub fn lock(home: &Path, wait: bool) -> Result<Lock, &'static str> {
    use std::os::fd::AsRawFd;
    crate::config::private_state_dir(home).map_err(|_| "vault.state_unavailable")?;
    let file = crate::config::private_state_rw(&home.join(LOCK_FILE))
        .map_err(|_| "vault.state_unavailable")?;
    let flags = if wait { libc::LOCK_EX } else { libc::LOCK_EX | libc::LOCK_NB };
    // SAFETY: this process owns the opened regular-file descriptor.
    if unsafe { libc::flock(file.as_raw_fd(), flags) } != 0 {
        return Err("vault.busy");
    }
    Ok(Lock(file))
}

#[cfg(not(unix))]
pub fn lock(_home: &Path, _wait: bool) -> Result<Lock, &'static str> {
    Err("vault.unsupported")
}

/// Ask the hub. Network errors are a retry code.
pub async fn fetch(hub: &str, credential: &str) -> Answer {
    let Ok(client) = crate::cli::cloud_join::http_client() else {
        return Answer::Retry("vault.client".to_owned());
    };
    let response = match client
        .get(format!("{hub}{}", wire::MACHINE_PATH))
        .bearer_auth(credential)
        .send()
        .await
    {
        Ok(response) => response,
        Err(_) => return Answer::Retry("vault.hub_unreachable".to_owned()),
    };
    let status = response.status().as_u16();
    if response.content_length().is_some_and(|n| n > MAX_BODY_BYTES as u64) {
        return Answer::Refused("vault.too_large".to_owned());
    }
    match response.bytes().await {
        Ok(body) if body.len() <= MAX_BODY_BYTES => {
            let body = zeroize::Zeroizing::new(body.to_vec());
            wire::parse(status, &body)
        }
        Ok(_) => Answer::Refused("vault.too_large".to_owned()),
        Err(_) => Answer::Retry("vault.hub_unreachable".to_owned()),
    }
}

/// Run `steps` against the store and record each success in `state`. A failed
/// store keeps the old record; a failed delete keeps the record, so the next
/// pull deletes it again. Returns stored, deleted and failed names.
pub fn apply(
    state: &mut State,
    steps: Vec<Step>,
    store: &dyn SecretStore,
) -> (Vec<String>, Vec<String>, Vec<(String, &'static str)>) {
    let (mut stored, mut deleted, mut failed) = (Vec::new(), Vec::new(), Vec::new());
    for step in steps {
        match step {
            Step::Keep { .. } => {}
            Step::Store { name, revision, value } => match store.put(&name, &value) {
                Ok(()) => {
                    state.pending_delete.remove(&name);
                    let fingerprint = state.fingerprint(&name, &value);
                    state.env.insert(name.clone(), plan::EnvRecord { revision, fingerprint });
                    stored.push(name);
                }
                Err(code) => failed.push((name, code)),
            },
            // Either way the entry is no longer given to agents; a failed
            // delete keeps a cleanup record until the store confirms it.
            Step::Delete { name } => {
                state.env.remove(&name);
                match store.delete(&name) {
                    Ok(()) => {
                        state.pending_delete.remove(&name);
                        deleted.push(name);
                    }
                    Err(code) => {
                        state.pending_delete.insert(name.clone());
                        failed.push((name, code));
                    }
                }
            }
        }
    }
    (stored, deleted, failed)
}

fn random_salt() -> [u8; 16] {
    let mut salt = [0u8; 16];
    let _ = getrandom::fill(&mut salt);
    salt
}

/// Plan and apply one answer under the lock. Blocking (the store runs commands).
pub fn settle(
    home: &Path,
    hub: &str,
    answer: Answer,
    store: &dyn SecretStore,
    now_ms: u64,
) -> Result<Outcome, Failure> {
    let mut state = read_state(home);
    state.ensure_salt(random_salt);
    let (steps, result, refused) = match answer {
        Answer::Granted { env, refused } => {
            let steps = plan::plan(&state, env);
            if !store.available() && steps.iter().any(|s| matches!(s, Step::Store { .. })) {
                // No file fallback: nothing is written, and the state says why.
                state.last_result = Some(UNAVAILABLE.to_owned());
                let _ = write_state(home, &state);
                return Err(Failure::code(UNAVAILABLE));
            }
            (steps, "ok", refused)
        }
        // The person no longer shares the vault with this machine: its entries go.
        Answer::NotGranted => (plan::wipe(&state), "not_granted", 0),
        Answer::Revoked => {
            let steps = plan::wipe(&state);
            let (_, deleted, _) = apply(&mut state, steps, store);
            state.last_result = Some("vault.revoked".to_owned());
            state.hub = hub.to_owned();
            let _ = write_state(home, &state);
            return Err(Failure { code: "vault.revoked".to_owned(), deleted, outcome: None });
        }
        Answer::Off => (Vec::new(), "off", 0),
        Answer::Retry(code) | Answer::Refused(code) => {
            state.last_result = Some(code.clone());
            let _ = write_state(home, &state);
            return Err(Failure::code(code));
        }
    };
    let (stored, deleted, failed) = apply(&mut state, steps, store);
    // A pull that could not store or delete everything fails, keeping what it did.
    let result = if !failed.is_empty() && result == "ok" { "partial" } else { result };
    state.hub = hub.to_owned();
    state.pulled_at = Some(now_ms);
    state.last_result =
        Some(if failed.is_empty() { result.to_owned() } else { PARTIAL.to_owned() });
    write_state(home, &state).map_err(Failure::code)?;
    let outcome = Outcome {
        state: result,
        hub: hub.to_owned(),
        env: state.env.keys().cloned().collect(),
        stored,
        deleted,
        failed,
        refused,
    };
    if outcome.failed.is_empty() {
        Ok(outcome)
    } else {
        Err(Failure { code: PARTIAL.to_owned(), deleted: Vec::new(), outcome: Some(outcome) })
    }
}

/// Whether the credential an answer was asked with is still this machine's
/// live one (`now`: the stored credential and whether it is revoked).
pub fn still_current(used: &str, now: Option<(&str, bool)>) -> bool {
    now.is_some_and(|(credential, revoked)| credential == used && !revoked)
}

/// One full pull with the joined credential of `home`. The lock is held from
/// reading the credential to saving the state, so a slower answer can never
/// undo a newer one (a revocation), and an answer for a credential replaced in
/// the meantime is dropped.
pub async fn pull(
    home: PathBuf,
    store: Arc<dyn SecretStore>,
    wait_for_lock: bool,
) -> Result<Outcome, Failure> {
    let lock_home = home.clone();
    let held = tokio::task::spawn_blocking(move || lock(&lock_home, wait_for_lock))
        .await
        .map_err(|_| Failure::code("vault.internal"))?
        .map_err(Failure::code)?;
    let record = crate::cli::cloud_join::machine_credential()
        .map_err(|_| Failure::code("vault.credential_unreadable"))?
        .ok_or_else(|| Failure::code("vault.not_joined"))?;
    let hub = crate::cli::cloud_join::hub_origin(&record.hub_origin)
        .map_err(|_| Failure::code("vault.hub_malformed"))?;
    let answer = if record.revoked {
        Answer::Revoked
    } else {
        let answer = fetch(&hub, &record.credential).await;
        if matches!(answer, Answer::Revoked) {
            let _ = crate::cli::cloud_join::record_auth_result(&record.credential, true, false);
        }
        answer
    };
    // A `machine join --replace` while the request ran: this answer was for the old one.
    let current = crate::cli::cloud_join::machine_credential().ok().flatten();
    if !matches!(answer, Answer::Revoked)
        && !still_current(
            &record.credential,
            current.as_ref().map(|c| (c.credential.as_str(), c.revoked)),
        )
    {
        return Err(Failure::code("vault.credential_changed"));
    }
    tokio::task::spawn_blocking(move || {
        let _held = held;
        settle(&home, &hub, answer, store.as_ref(), crate::store::now_ms())
    })
    .await
    .map_err(|_| Failure::code("vault.internal"))?
}

/// Remove every stored entry and the state file (`vault forget`).
pub fn forget(home: &Path, store: &dyn SecretStore) -> Result<Outcome, Failure> {
    let _lock = lock(home, true).map_err(Failure::code)?;
    let mut state = read_state(home);
    let hub = state.hub.clone();
    let steps = plan::wipe(&state);
    let (_, deleted, failed) = apply(&mut state, steps, store);
    let mut outcome = Outcome {
        state: "forgotten",
        hub,
        env: state.env.keys().cloned().collect(),
        stored: Vec::new(),
        deleted,
        failed,
        refused: 0,
    };
    if outcome.failed.is_empty() {
        match std::fs::remove_file(state_path(home)) {
            Ok(()) => Ok(outcome),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(outcome),
            Err(_) => Err(Failure {
                code: "vault.state_write_failed".into(),
                deleted: outcome.deleted,
                outcome: None,
            }),
        }
    } else {
        // Keep the cleanup records of items still in the store, so a retry finds them.
        write_state(home, &state).map_err(Failure::code)?;
        outcome.state = "partial";
        Err(Failure { code: PARTIAL.to_owned(), deleted: Vec::new(), outcome: Some(outcome) })
    }
}
