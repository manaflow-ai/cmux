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

/// Present while a removal is not yet saved: the daemon gives agents no vault
/// value while it exists, so a state file that could not be written (a full
/// disk) never leaves revoked values deliverable. Removed once the state is saved.
pub const HOLD_FILE: &str = "vault-hold";

pub fn hold_path(home: &Path) -> PathBuf {
    home.join(HOLD_FILE)
}

/// Whether a removal is waiting to be saved (or the hold cannot be checked).
pub fn held(home: &Path) -> bool {
    match std::fs::symlink_metadata(hold_path(home)) {
        Ok(_) => true,
        Err(e) => e.kind() != std::io::ErrorKind::NotFound,
    }
}

/// Put the hold down before a removal. An empty file: it needs no free blocks.
pub(super) fn hold(home: &Path) -> Result<(), &'static str> {
    crate::config::private_state_dir(home).map_err(|_| "vault.state_write_failed")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(hold_path(home))
            .map(drop)
            .map_err(|_| "vault.state_write_failed")
    }
    #[cfg(not(unix))]
    std::fs::write(hold_path(home), b"").map_err(|_| "vault.state_write_failed")
}

pub(super) fn release(home: &Path) {
    let _ = std::fs::remove_file(hold_path(home));
}

/// Save `state`. The one rule for the hold: it is lifted only by a durable
/// state that delivers nothing, or whose entries a grant answered just now
/// (`fresh_grant`). A save after a failed request or a hub without a vault
/// carries entries no answer re-authorized (perhaps ones a withdrawal whose
/// save failed had removed), so it leaves the hold down.
fn save(home: &Path, state: &State, fresh_grant: bool) -> Result<(), &'static str> {
    write_state(home, state)?;
    if fresh_grant || state.env.is_empty() {
        release(home);
    }
    Ok(())
}

/// A `Keep` trusts the state; check the item itself. One that is missing or
/// holds another value (removed or edited by hand, or a load that failed) is
/// stored again at the same revision. A store that cannot be read now (a
/// locked keychain) keeps it as it is.
pub fn verify_kept(steps: Vec<Step>, store: &dyn SecretStore) -> Vec<Step> {
    steps
        .into_iter()
        .map(|step| match step {
            Step::Keep { name, revision, value, proxy } => match store.get(&name) {
                Ok(Some(have)) if have.as_str() == value.as_str() => {
                    Step::Keep { name, revision, value, proxy }
                }
                Err(_) => Step::Keep { name, revision, value, proxy },
                Ok(_) => Step::Store { name, revision, value, proxy },
            },
            other => other,
        })
        .collect()
}

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

#[cfg(test)]
thread_local! {
    /// Tests: the next state writes fail, as on a full disk.
    pub static FAIL_STATE_WRITE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

pub fn write_state(home: &Path, state: &State) -> Result<(), &'static str> {
    #[cfg(test)]
    if FAIL_STATE_WRITE.with(std::cell::Cell::get) {
        return Err("vault.state_write_failed");
    }
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
        .get(format!("{hub}{}?{}", wire::MACHINE_PATH, wire::DELIVERY_QUERY))
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
/// `binding` is what a stored entry records as its authorizing credential
/// ([`State::binding`]; empty when nothing is stored).
pub fn apply(
    state: &mut State,
    steps: Vec<Step>,
    store: &dyn SecretStore,
    binding: &str,
) -> (Vec<String>, Vec<String>, Vec<(String, &'static str)>) {
    let (mut stored, mut deleted, mut failed) = (Vec::new(), Vec::new(), Vec::new());
    for step in steps {
        match step {
            // A policy change (proxy hosts, or env and proxy swapped) comes
            // without a new revision: the record takes it.
            Step::Keep { name, proxy, .. } => {
                if let Some(record) = state.env.get_mut(&name) {
                    record.proxy = proxy;
                }
            }
            Step::Store { name, revision, value, proxy } => match store.put(&name, &value) {
                Ok(()) => {
                    state.pending_delete.remove(&name);
                    let fingerprint = state.fingerprint(&name, &value);
                    let credential = binding.to_owned();
                    state.env.insert(
                        name.clone(),
                        plan::EnvRecord { revision, fingerprint, credential, proxy },
                    );
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

/// Delete from the OS store the items a switch to the daemon's memory left
/// there (`State::os_pending`): what is deleted leaves the list, what fails
/// stays for the next pull or `forget`. Nothing to do with the OS store active.
fn clean_os_leftovers(
    state: &mut State,
    store: &dyn SecretStore,
) -> (Vec<String>, Vec<(String, &'static str)>) {
    let (mut deleted, mut failed) = (Vec::new(), Vec::new());
    let Some(os) = store.os_leftovers() else { return (deleted, failed) };
    for name in state.os_pending.clone() {
        match os.delete(&name) {
            Ok(()) => {
                state.os_pending.remove(&name);
                deleted.push(name);
            }
            Err(code) => failed.push((name, code)),
        }
    }
    (deleted, failed)
}

fn random_salt() -> [u8; 16] {
    let mut salt = [0u8; 16];
    let _ = getrandom::fill(&mut salt);
    salt
}

/// The machine credential now: the stored bearer and whether it is revoked.
pub type CurrentCredential<'a> = &'a (dyn Fn() -> Option<(String, bool)> + Sync);

/// The machine's credential as the join store has it now.
pub fn current_credential() -> Option<(String, bool)> {
    crate::cli::cloud_join::machine_credential()
        .ok()
        .flatten()
        .map(|record| (record.credential, record.revoked))
}

fn is_current(used: &str, current: CurrentCredential) -> bool {
    let now = current();
    still_current(used, now.as_ref().map(|(c, revoked)| (c.as_str(), *revoked)))
}

/// Plan and apply one answer, asked with `credential`, under the lock.
/// Blocking (the store runs commands). `current` reads the machine credential
/// as it is now: an answer for a credential replaced or revoked before the
/// state is saved is not published, and the state it saves is bound to
/// `credential`, so a change after the save stops delivery too.
pub fn settle(
    home: &Path,
    hub: &str,
    credential: &str,
    answer: Answer,
    store: &dyn SecretStore,
    current: CurrentCredential,
    now_ms: u64,
) -> Result<Outcome, Failure> {
    let mut state = read_state(home);
    state.ensure_salt(random_salt);
    let granted = matches!(answer, Answer::Granted { .. });
    if granted && !is_current(credential, current) {
        return Err(Failure::code(CREDENTIAL_CHANGED));
    }
    // The active store holds this machine's entries; what the other one
    // still holds is cleaned up from it (never delivered).
    state.switch_backend(store.kind());
    let _ = clean_os_leftovers(&mut state, store);
    let binding = state.binding(credential);
    let before: std::collections::BTreeSet<String> = state.env.keys().cloned().collect();
    // Entries another credential's answer authorized are never rebound to this one.
    if !matches!(answer, Answer::Revoked) {
        state.drop_foreign(credential);
    }
    // Hold before saving a state that no longer delivers an entry it did.
    let hold_if_removing = |state: &State| -> Result<(), Failure> {
        if !before.iter().all(|n| state.env.contains_key(n)) {
            hold(home).map_err(Failure::code)?;
        }
        Ok(())
    };
    let mut unavailable = false;
    let (steps, result, refused) = match answer {
        Answer::Granted { env, refused } => {
            let mut steps = plan::plan(&state, env);
            if store.available() {
                steps = verify_kept(steps, store);
            }
            if !store.available() && steps.iter().any(|s| matches!(s, Step::Store { .. })) {
                // No file fallback: nothing is stored. Removals still leave the
                // delivered set now, kept as cleanup records.
                steps.retain(|s| !matches!(s, Step::Store { .. }));
                unavailable = true;
            }
            (steps, "ok", refused)
        }
        // The person no longer shares the vault with this machine: its entries go.
        Answer::NotGranted => (plan::wipe(&state), "not_granted", 0),
        Answer::Revoked => {
            state.unbind_all();
            hold_if_removing(&state)?;
            let steps = plan::wipe(&state);
            let (_, deleted, _) = apply(&mut state, steps, store, "");
            state.last_result = Some("vault.revoked".to_owned());
            state.hub = hub.to_owned();
            save(home, &state, true).map_err(Failure::code)?;
            return Err(Failure { code: "vault.revoked".to_owned(), deleted, outcome: None });
        }
        // No vault on this hub: only the cleanup records are worked off.
        Answer::Off => (plan::cleanup(&state), "off", 0),
        Answer::Retry(code) | Answer::Refused(code) => {
            hold_if_removing(&state)?;
            state.last_result = Some(code.clone());
            save(home, &state, false).map_err(Failure::code)?;
            // A hold from an earlier removal stays: this answer authorizes nothing.
            return Err(Failure::code(code));
        }
    };
    // Every removal (revoked, gone, foreign, not granted) is held before the
    // store deletes run, so it takes effect even if the state cannot be saved.
    if steps.iter().any(|s| matches!(s, Step::Delete { .. })) {
        hold(home).map_err(Failure::code)?;
    }
    hold_if_removing(&state)?;
    let (stored, deleted, failed) = apply(&mut state, steps, store, &binding);
    // The store writes can take seconds: a credential replaced or revoked
    // meanwhile gets nothing of this answer. What it stored is cleaned up.
    if !is_current(credential, current) {
        hold(home).map_err(Failure::code)?;
        state.unbind_all();
        state.last_result = Some(CREDENTIAL_CHANGED.to_owned());
        save(home, &state, true).map_err(Failure::code)?;
        return Err(Failure::code(CREDENTIAL_CHANGED));
    }
    state.hub = hub.to_owned();
    if unavailable {
        state.last_result = Some(UNAVAILABLE.to_owned());
        save(home, &state, true).map_err(Failure::code)?;
        return Err(Failure { code: UNAVAILABLE.to_owned(), deleted, outcome: None });
    }
    // A pull that could not store or delete everything fails, keeping what it did.
    let result = if !failed.is_empty() && result == "ok" { "partial" } else { result };
    state.pulled_at = Some(now_ms);
    state.last_result =
        Some(if failed.is_empty() { result.to_owned() } else { PARTIAL.to_owned() });
    // A hub without a vault (`off`) re-authorizes nothing kept here.
    save(home, &state, matches!(result, "ok" | "partial")).map_err(Failure::code)?;
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

/// The code of an answer dropped because the machine credential changed.
pub const CREDENTIAL_CHANGED: &str = "vault.credential_changed";

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
    let used = record.credential.clone();
    tokio::task::spawn_blocking(move || {
        let _held = held;
        settle(
            &home,
            &hub,
            &used,
            answer,
            store.as_ref(),
            &current_credential,
            crate::store::now_ms(),
        )
    })
    .await
    .map_err(|_| Failure::code("vault.internal"))?
}

/// Remove every stored entry and the state file (`vault forget`).
pub fn forget(home: &Path, store: &dyn SecretStore) -> Result<Outcome, Failure> {
    let _lock = lock(home, true).map_err(Failure::code)?;
    let mut state = read_state(home);
    let hub = state.hub.clone();
    if !state.env.is_empty() {
        hold(home).map_err(Failure::code)?;
    }
    state.switch_backend(store.kind());
    let (mut deleted, mut failed) = clean_os_leftovers(&mut state, store);
    let steps = plan::wipe(&state);
    let (_, wiped, wipe_failed) = apply(&mut state, steps, store, "");
    deleted.extend(wiped);
    failed.extend(wipe_failed);
    let mut outcome = Outcome {
        state: "forgotten",
        hub,
        env: state.env.keys().cloned().collect(),
        stored: Vec::new(),
        deleted,
        failed,
        refused: 0,
    };
    // The state file goes only once no item is left in any store.
    if outcome.failed.is_empty() && state.os_pending.is_empty() {
        match std::fs::remove_file(state_path(home)) {
            Ok(()) => {
                release(home);
                Ok(outcome)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                release(home);
                Ok(outcome)
            }
            Err(_) => Err(Failure {
                code: "vault.state_write_failed".into(),
                deleted: outcome.deleted,
                outcome: None,
            }),
        }
    } else {
        // Keep the cleanup records of items still in the store, so a retry finds them.
        save(home, &state, true).map_err(Failure::code)?;
        outcome.state = "partial";
        Err(Failure { code: PARTIAL.to_owned(), deleted: Vec::new(), outcome: Some(outcome) })
    }
}
