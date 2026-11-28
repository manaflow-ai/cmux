//! The cmux vault's machine side (cmuxterm-hq docs/design/e2e-vault.md, "Who seals to a machine"): pull
//! `GET /v1/cloud/vault/machine` as this machine's `vm` install, open each value with the session host's
//! X25519 private key (the pair of the `daemon_noise_key` the bind sent), and write the names the vault owns
//! into the session user's `~/.config/cmux/machine-secrets.env`, keeping every line it does not own (names
//! `cmux cloud deliver-secrets` wrote). The crypto, the rollback rule and the file's text are
//! `cmux_vault_e2e::machine`'s; this module is the order of the steps, over a [`Store`] for the state and an
//! [`EnvFile`] for the secrets file, so tests run it with fakes. `vault_thread.rs` runs it.
//!
//! Sans I/O apart from those two. Nothing here logs or returns a value or a ciphertext: [`note`] names
//! names and codes only.

use std::collections::BTreeSet;

use cmux_vault_e2e::machine::{self, State};
use zeroize::Zeroizing;

use super::client::Store;
use super::sender::Answer;

/// The route (cmux-platform `src/server/vault/SealedVaultRoute.ts`, forwarded by cmux-api).
pub const MACHINE_PATH: &str = "/v1/cloud/vault/machine";
/// Per name the highest revision opened and the names the vault owns in the file (names only, root's).
pub const STATE_FILE: &str = "/var/lib/cmux/vault-delivered.json";
/// The secrets file under the session user's home.
pub const SECRETS_FILE: &str = ".config/cmux/machine-secrets.env";

/// The session user's secrets file: read whole, replaced whole.
pub trait EnvFile {
    /// The file's text, empty when there is none. `Err` (a code) when it is there but is not one this
    /// writer may replace (a symlink, another user's, too large): nothing is written then.
    fn read(&mut self) -> Result<Zeroizing<String>, &'static str>;
    fn write(&mut self, text: &str) -> Result<(), &'static str>;
}

/// One pull's result.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The answer was opened and the file holds it. `changed`: the file was rewritten.
    Applied { applied: machine::Applied, changed: bool, kept: Vec<String> },
    /// The vault is off where this machine lives (404 `vault.not_found` from the platform).
    Off,
    /// Nothing changed; the code says why.
    Failed(&'static str),
}

/// One pull: `get` is the route's GET as this machine; `key` the session host's private key (`None` before its
/// identity file is there). The file and the state change only on a whole, opened answer for this machine.
pub fn pull_once(
    get: impl FnOnce(&str) -> Answer,
    machine_id: &str,
    key: Option<&[u8; 32]>,
    store: &mut dyn Store,
    env: &mut dyn EnvFile,
) -> Outcome {
    let body = match get(MACHINE_PATH) {
        Answer::Http { status: 200, body } => body,
        // Off only when the platform says so: a 404 without its code is a cmux-api that does not forward the route
        // yet (a deploy behind), which backs off and looks again instead of waiting the hour.
        Answer::Http { status: 404, body }
            if body.pointer("/error/code").and_then(serde_json::Value::as_str)
                == Some("vault.not_found") =>
        {
            return Outcome::Off;
        }
        Answer::Http { status: 404, .. } => return Outcome::Failed("vault.no_route"),
        Answer::Http { status, .. } => return Outcome::Failed(refusal(status)),
        Answer::Transport => return Outcome::Failed("vault.unreachable"),
    };
    let Some((answered, items, _malformed)) = machine::parse_answer(&body) else {
        return Outcome::Failed("vault.malformed");
    };
    // Another machine's answer is refused whole: the file keeps what it has.
    if answered != machine_id {
        return Outcome::Failed("vault.other_machine");
    }
    let Some(key) = key else { return Outcome::Failed("vault.no_daemon_key") };
    let state: State = store
        .read(STATE_FILE)
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default();
    let existing = match env.read() {
        Ok(text) => text,
        Err(code) => return Outcome::Failed(code),
    };
    let (values, mut next, applied) = machine::open_all(key, machine_id, &answered, &items, &state);
    // A name the vault still sends but whose new item was refused (a rollback, a value that does not open)
    // keeps the value it holds: a refusal never deletes a secret.
    let sent: BTreeSet<&str> = items.iter().map(|i| i.name.as_str()).collect();
    let kept: Vec<String> = state
        .owned
        .iter()
        .filter(|n| sent.contains(n.as_str()) && !values.contains_key(*n))
        .cloned()
        .collect();
    let mut replaced = state.owned.clone();
    for name in &kept {
        replaced.remove(name);
        next.owned.insert(name.clone());
    }
    let text = machine::render_env(&existing, &replaced, &values);
    let changed = *text != *existing;
    if changed && let Err(code) = env.write(&text) {
        return Outcome::Failed(code);
    }
    let Ok(saved) = serde_json::to_string(&next) else { return Outcome::Failed("vault.state") };
    if next != state && store.write(STATE_FILE, &format!("{saved}\n"), 0o600).is_err() {
        return Outcome::Failed("vault.state");
    }
    let mut applied = applied;
    // The kept names are still the vault's, not removed.
    applied.removed.retain(|n| !kept.contains(n));
    Outcome::Applied { applied, changed, kept }
}

/// A non-200 answer's code, by status class (the route's message is never copied).
fn refusal(status: u16) -> &'static str {
    match status {
        401 | 403 => "vault.forbidden",
        429 => "vault.rate_limited",
        s if s >= 500 => "vault.unavailable",
        _ => "vault.refused",
    }
}

/// The journal line: names and codes, never a value.
pub fn note(outcome: &Outcome) -> String {
    match outcome {
        Outcome::Applied { applied, changed, kept } => {
            let mut line = format!(
                "vault: {} names delivered{}",
                applied.written.len(),
                if *changed { ", machine-secrets.env written" } else { ", unchanged" }
            );
            if !applied.written.is_empty() {
                line.push_str(&format!(" ({})", applied.written.join(" ")));
            }
            if !applied.removed.is_empty() {
                line.push_str(&format!("; removed {}", applied.removed.join(" ")));
            }
            if !applied.refused.is_empty() {
                let refused: Vec<String> =
                    applied.refused.iter().map(|(n, c)| format!("{n} {c}")).collect();
                line.push_str(&format!("; refused {}", refused.join(", ")));
            }
            if !kept.is_empty() {
                line.push_str(&format!("; kept the held value of {}", kept.join(" ")));
            }
            line
        }
        Outcome::Off => "vault: off for this machine; looking again hourly".to_owned(),
        Outcome::Failed(code) => format!("vault: not delivered ({code})"),
    }
}

/// The next pull's delay class: `Off` hourly, a failure backs off, else the minute.
pub fn quiet(outcome: &Outcome) -> bool {
    matches!(outcome, Outcome::Applied { changed: false, applied, kept } if applied.refused.is_empty() && applied.removed.is_empty() && kept.is_empty())
}

#[cfg(all(test, unix))]
#[path = "vault_tests.rs"]
mod tests;
