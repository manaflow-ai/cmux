//! What a pull does with the secret store, decided without I/O, and the
//! state file that remembers it (`<ACPMUX_HOME>/vault-state.json`, 0600).
//!
//! The state holds the hub, when the last pull ran and its result, and per
//! env entry its name, revision and a salted fingerprint. Never a value: the
//! values live only in the OS secret store and, in the daemon, in memory.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use zeroize::Zeroizing;

use super::wire::EnvItem;

pub const STATE_VERSION: u8 = 1;

/// What the machine remembers of one env entry it stored.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EnvRecord {
    pub revision: u64,
    /// sha256 hex of the state's salt, the name and the value: tells a changed
    /// value at the same revision, and a secret store item edited since.
    pub fingerprint: String,
    /// The salted fingerprint of the machine credential whose answer
    /// authorized this entry: it is given to agents only while that
    /// credential is still this machine's and not revoked.
    #[serde(default)]
    pub credential: String,
    /// How agents get it: `Some(allowed hosts)` is a placeholder the egress
    /// proxy fills only toward those hosts; `None` is the value itself in
    /// the env (the person's opt-out, or a hub that predates delivery). The
    /// hub can change it without a new revision, so every pull rewrites it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<Vec<String>>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    #[serde(default)]
    pub version: u8,
    #[serde(default)]
    pub hub: String,
    /// Milliseconds since the epoch of the last answered pull.
    #[serde(default)]
    pub pulled_at: Option<u64>,
    /// `ok`, `not_granted`, `revoked`, `off`, or an error code.
    #[serde(default)]
    pub last_result: Option<String>,
    /// Random per machine, so a fingerprint is never a plain hash of a value.
    #[serde(default)]
    pub salt: String,
    /// Entries this machine may give agents.
    #[serde(default)]
    pub env: BTreeMap<String, EnvRecord>,
    /// Entries revoked or removed whose secret store item could not be
    /// deleted yet: never given to an agent, deleted again on every pull.
    #[serde(default, skip_serializing_if = "std::collections::BTreeSet::is_empty")]
    pub pending_delete: std::collections::BTreeSet<String>,
    /// Where `env`'s values are kept: `os` (the OS store; empty in a state
    /// saved before this field, which only the OS store wrote) or `memory`
    /// (the daemon's, where the OS store takes no write).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub backend: String,
    /// Items still in the OS store from before this machine switched to
    /// memory: never given to an agent, deleted from the OS store on every
    /// pull and by `forget`, whichever store is active.
    #[serde(default, skip_serializing_if = "std::collections::BTreeSet::is_empty")]
    pub os_pending: std::collections::BTreeSet<String>,
}

/// The backend of a store kind: `memory` for the daemon's memory, else `os`.
pub fn backend_of(kind: &str) -> &'static str {
    if kind == "memory" { "memory" } else { "os" }
}

impl State {
    /// The saved state, or a fresh one when there is none or it does not parse.
    pub fn parse(text: Option<&[u8]>) -> State {
        let mut state: State =
            text.and_then(|t| serde_json::from_slice(t).ok()).unwrap_or_default();
        state.version = STATE_VERSION;
        state
    }

    /// The salt, made once.
    pub fn ensure_salt(&mut self, random: impl FnOnce() -> [u8; 16]) {
        if self.salt.len() != 32 {
            self.salt = random().iter().map(|b| format!("{b:02x}")).collect();
        }
    }

    pub fn fingerprint(&self, name: &str, value: &str) -> String {
        let mut h = Sha256::new();
        h.update(self.salt.as_bytes());
        h.update([0]);
        h.update(name.as_bytes());
        h.update([0]);
        h.update(value.as_bytes());
        h.finalize().iter().map(|b| format!("{b:02x}")).collect()
    }

    /// The salted fingerprint an entry records for `credential`.
    pub fn binding(&self, credential: &str) -> String {
        self.fingerprint("\0credential", credential)
    }

    /// The entries that may be given to agents under the machine's credential
    /// now (`current`: the stored credential and whether it is revoked): those
    /// whose authorizing answer came for that same live credential.
    pub fn delivered_names(&self, current: Option<(&str, bool)>) -> Vec<String> {
        let Some((credential, false)) = current else { return Vec::new() };
        let binding = self.binding(credential);
        self.env
            .iter()
            .filter(|(_, record)| !record.credential.is_empty() && record.credential == binding)
            .map(|(name, _)| name.clone())
            .collect()
    }

    /// Entries authorized under another credential (or none) are never
    /// rebound to `credential`: they become cleanup records. True when any moved.
    pub fn drop_foreign(&mut self, credential: &str) -> bool {
        let binding = self.binding(credential);
        let foreign: Vec<String> = self
            .env
            .iter()
            .filter(|(_, record)| record.credential != binding)
            .map(|(name, _)| name.clone())
            .collect();
        for name in &foreign {
            self.env.remove(name);
            self.pending_delete.insert(name.clone());
        }
        !foreign.is_empty()
    }

    /// No entry may be delivered: every one becomes a cleanup record.
    pub fn unbind_all(&mut self) {
        let names: Vec<String> = self.env.keys().cloned().collect();
        self.pending_delete.extend(names);
        self.env.clear();
    }

    /// Make `kind`'s backend the active one. Entries kept in the other one are
    /// no longer this machine's: OS store items become `os_pending` (deleted
    /// from the OS store whatever is active), and values in another process's
    /// memory went with it. Back on the OS store, `os_pending` joins the
    /// ordinary cleanup records.
    pub fn switch_backend(&mut self, kind: &str) {
        let to = backend_of(kind);
        let from = if self.backend.is_empty() { "os" } else { self.backend.as_str() };
        if from != to {
            let names: Vec<String> =
                self.env.keys().cloned().chain(self.pending_delete.iter().cloned()).collect();
            self.env.clear();
            self.pending_delete.clear();
            if from == "os" {
                self.os_pending.extend(names);
            }
        }
        if to == "os" {
            let left = std::mem::take(&mut self.os_pending);
            self.pending_delete.extend(left);
        }
        self.backend = to.to_owned();
    }

    /// Names and revisions, in order: the daemon reloads its values when this
    /// changes.
    pub fn signature(&self) -> String {
        self.env
            .iter()
            .map(|(name, r)| {
                let delivery = r
                    .proxy
                    .as_ref()
                    .map_or("env".to_owned(), |h| format!("proxy[{}]", h.join(" ")));
                format!("{name}={}:{}:{}:{delivery}", r.revision, r.fingerprint, r.credential)
            })
            .collect::<Vec<_>>()
            .join(",")
    }
}

/// One step of a pull.
pub enum Step {
    /// Put this value in the secret store (new, newer or changed).
    Store { name: String, revision: u64, value: Zeroizing<String>, proxy: Option<Vec<String>> },
    /// Remove this entry: revoked, gone from the vault, or the vault is no
    /// longer shared with this machine.
    Delete { name: String },
    /// Already stored at this revision with this value, as far as the state
    /// says; the pull checks the item and stores it again when it is missing
    /// or differs (`pull::verify_kept`).
    /// Its delivery is recorded again: the hub changes it without a revision.
    Keep { name: String, revision: u64, value: Zeroizing<String>, proxy: Option<Vec<String>> },
}

impl std::fmt::Debug for Step {
    /// Never the value.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Step::Store { name, revision, .. } => write!(f, "Store({name} r{revision})"),
            Step::Delete { name } => write!(f, "Delete({name})"),
            Step::Keep { name, .. } => write!(f, "Keep({name})"),
        }
    }
}

/// The steps for a granted answer: store each active entry the state does not
/// already hold at that revision and value; delete each stored entry the
/// answer revokes or no longer lists.
pub fn plan(state: &State, env: Vec<EnvItem>) -> Vec<Step> {
    let mut steps = Vec::new();
    let mut listed = std::collections::BTreeSet::new();
    for item in env {
        listed.insert(item.name.clone());
        match item.value {
            Some(value) => {
                let same = state.env.get(&item.name).is_some_and(|r| {
                    r.revision == item.revision
                        && r.fingerprint == state.fingerprint(&item.name, &value)
                });
                let (name, revision, proxy) = (item.name, item.revision, item.proxy);
                if same {
                    steps.push(Step::Keep { name, revision, value, proxy });
                } else {
                    steps.push(Step::Store { name, revision, value, proxy });
                }
            }
            None if state.env.contains_key(&item.name) => {
                steps.push(Step::Delete { name: item.name })
            }
            None => {}
        }
    }
    for name in state.env.keys() {
        if !listed.contains(name) {
            steps.push(Step::Delete { name: name.clone() });
        }
    }
    // A delete that failed earlier is tried again, unless the entry is
    // active again (its Store above replaces the item).
    for name in &state.pending_delete {
        let stored_again =
            steps.iter().any(|s| matches!(s, Step::Store { name: n, .. } if n == name));
        let deleting = steps.iter().any(|s| matches!(s, Step::Delete { name: n } if n == name));
        if !stored_again && !deleting {
            steps.push(Step::Delete { name: name.clone() });
        }
    }
    steps
}

/// The steps when the machine may no longer hold the vault (not granted, or
/// its credential revoked, or `vault forget`): every stored entry goes.
pub fn wipe(state: &State) -> Vec<Step> {
    state
        .env
        .keys()
        .chain(state.pending_delete.iter().filter(|n| !state.env.contains_key(*n)))
        .map(|name| Step::Delete { name: name.clone() })
        .collect()
}

/// The deletes of the cleanup records alone.
pub fn cleanup(state: &State) -> Vec<Step> {
    state.pending_delete.iter().map(|name| Step::Delete { name: name.clone() }).collect()
}
