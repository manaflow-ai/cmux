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
    #[serde(default)]
    pub env: BTreeMap<String, EnvRecord>,
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

    /// Names and revisions, in order: the daemon reloads its values when this
    /// changes.
    pub fn signature(&self) -> String {
        self.env
            .iter()
            .map(|(name, r)| format!("{name}={}:{}", r.revision, r.fingerprint))
            .collect::<Vec<_>>()
            .join(",")
    }
}

/// One step of a pull.
pub enum Step {
    /// Put this value in the secret store (new, newer or changed).
    Store { name: String, revision: u64, value: Zeroizing<String> },
    /// Remove this entry: revoked, gone from the vault, or the vault is no
    /// longer shared with this machine.
    Delete { name: String },
    /// Already stored at this revision with this value.
    Keep { name: String },
}

impl std::fmt::Debug for Step {
    /// Never the value.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Step::Store { name, revision, .. } => write!(f, "Store({name} r{revision})"),
            Step::Delete { name } => write!(f, "Delete({name})"),
            Step::Keep { name } => write!(f, "Keep({name})"),
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
                if same {
                    steps.push(Step::Keep { name: item.name });
                } else {
                    steps.push(Step::Store { name: item.name, revision: item.revision, value });
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
    steps
}

/// The steps when the machine may no longer hold the vault (not granted, or
/// its credential revoked, or `vault forget`): every stored entry goes.
pub fn wipe(state: &State) -> Vec<Step> {
    state.env.keys().map(|name| Step::Delete { name: name.clone() }).collect()
}
