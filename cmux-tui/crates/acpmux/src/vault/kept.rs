//! Keys an agent keeps on this machine itself (`acpmux machine vault keep`),
//! with no sign-in, no cmux platform call and no click (Leo, 2026-11-15: "we
//! should be able to have some good ways for you guys to make and store keys
//! without me ever needing to click"; "it can be like... a cmux-next feature.
//! the safe key thing").
//!
//! An agent that made a key (a provider's token API, a CLI that mints one)
//! pipes it in: `mint | acpmux machine vault keep DEPLOY_TOKEN --host
//! api.example.com`. It shares nothing the agent did not already have, so it
//! asks no one; the value stays on this machine.
//!
//! - A placeholder is filled only where the key travels in a request (a
//!   bearer token, an API key header). A key that signs requests locally (an
//!   S3 SigV4 secret access key) never goes on the wire, so it needs `--env`.
//! - Never keep a provider's root or bootstrap token (one that mints other
//!   keys) here: every agent this daemon starts would get it, filled toward
//!   that provider's API. Keep only the scoped keys made from it.
//!
//! - The value comes on stdin (never argv) and goes into the OS secret store
//!   as the item `kept.NAME` (`store.rs`: account `env/<home-id>/kept.NAME`;
//!   an env name has no dot, so it never meets a pulled entry or a probe).
//!   There is no file or memory fallback: a machine whose OS store takes no
//!   write refuses (`vault.secret_store_unavailable`).
//! - `<ACPMUX_HOME>/vault-kept.json` (0600) keeps per name its allowed hosts
//!   (or none, for `--env`), when it was kept and a salted fingerprint, never
//!   a value. An item whose value no longer matches is not given out.
//! - Agents the daemon spawns from then on get it as they get a pulled proxy
//!   entry: `NAME=cmux-secret://NAME`, which the egress proxy fills only in
//!   HTTPS requests to its hosts (`egress.rs`). `--env` gives the value
//!   itself, the weaker opt-out. A pulled entry of the same name wins, and
//!   `keep` refuses a name the vault already pulled.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use super::store::SecretStore;
use super::wire::{MAX_ENV_STRING_BYTES, MAX_HOSTS, MAX_VAULT_ENV_BYTES, env_string_bytes};
use super::{Given, Stamp, stamp_of};

pub const FILE: &str = "vault-kept.json";
/// The most bytes one kept value may have: the pulled vault's own bound, one
/// value a spawn's env can carry (the platform's per-string exec limit).
pub use super::wire::MAX_VALUE_BYTES;

pub fn path(home: &Path) -> PathBuf {
    home.join(FILE)
}

/// The secret store item of a kept `name`.
pub fn item(name: &str) -> String {
    format!("kept.{name}")
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Kept {
    /// Random per machine, so a fingerprint is never a plain hash of a value.
    #[serde(default)]
    pub salt: String,
    #[serde(default)]
    pub env: BTreeMap<String, KeptRecord>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeptRecord {
    pub fingerprint: String,
    /// `Some(allowed hosts)`: agents get the placeholder; `None`: the value (`--env`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<Vec<String>>,
    /// Milliseconds since the epoch.
    #[serde(default)]
    pub kept_at: u64,
}

impl Kept {
    fn fingerprint(&self, name: &str, value: &str) -> String {
        let mut h = Sha256::new();
        h.update(self.salt.as_bytes());
        h.update([0]);
        h.update(name.as_bytes());
        h.update([0]);
        h.update(value.as_bytes());
        h.finalize().iter().map(|b| format!("{b:02x}")).collect()
    }
}

/// The saved kept entries (none when there is no file or it does not parse).
pub fn read(home: &Path) -> Kept {
    let path = path(home);
    match std::fs::symlink_metadata(&path) {
        Ok(meta) if meta.is_file() => {}
        _ => return Kept::default(),
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
    serde_json::from_slice(&bytes).unwrap_or_default()
}

fn write(home: &Path, kept: &Kept) -> Result<(), &'static str> {
    crate::config::private_state_dir(home).map_err(|_| "vault.state_write_failed")?;
    let bytes = serde_json::to_vec_pretty(kept).map_err(|_| "vault.state_write_failed")?;
    crate::config::write_atomic(&path(home), &bytes).map_err(|_| "vault.state_write_failed")
}

/// The endings a kept name must have. Any agent can keep a value with no
/// person in the loop, so only names shaped like a credential are taken:
/// never one that steers other agents (`HTTPS_PROXY`, `SSL_CERT_FILE`,
/// `NODE_OPTIONS`, `GIT_ASKPASS`, `EDITOR`).
pub const SECRET_SUFFIXES: &[&str] =
    &["_TOKEN", "_KEY", "_KEY_ID", "_SECRET", "_PASSWORD", "_PAT", "_CREDENTIALS"];

/// Model provider keys: one kept by an agent would move every later agent's
/// model traffic onto that key.
pub const PROVIDER_KEYS: &[&str] = &["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY"];

/// A name agents may get: an env name a machine may set, ending like a
/// credential ([`SECRET_SUFFIXES`]), not a model provider key, not a
/// subscription login and not a base URL that would reroute agents.
pub fn check_name(name: &str) -> Result<(), &'static str> {
    let upper = name.to_ascii_uppercase();
    let ok = crate::login_env::machine_env_name_allowed(name)
        && SECRET_SUFFIXES.iter().any(|s| upper.ends_with(s) && upper.len() > s.len())
        && !PROVIDER_KEYS.iter().any(|k| k.eq_ignore_ascii_case(name))
        && !super::REFUSED_NAMES.iter().any(|k| k.eq_ignore_ascii_case(name))
        && !super::rerouting(name);
    if ok { Ok(()) } else { Err("vault.bad_name") }
}

/// The distinct host patterns of `--host`, in order: each must parse
/// (`vault.bad_host`), at most [`MAX_HOSTS`] (`vault.too_many_hosts`).
pub fn check_hosts(hosts: &[String]) -> Result<Vec<String>, &'static str> {
    let mut out: Vec<String> = Vec::new();
    for host in hosts {
        let pattern = cmux_vault_egress::HostPattern::parse(host).ok_or("vault.bad_host")?;
        let text = pattern.to_string();
        if !out.contains(&text) {
            out.push(text);
        }
    }
    if out.len() > MAX_HOSTS {
        return Err("vault.too_many_hosts");
    }
    Ok(out)
}

/// A value one spawn can carry: not empty, no NUL, at most [`MAX_VALUE_BYTES`].
pub fn check_value(name: &str, value: &str) -> Result<(), &'static str> {
    if value.is_empty() {
        return Err("vault.empty_value");
    }
    if value.contains('\0')
        || value.len() > MAX_VALUE_BYTES
        || env_string_bytes(name, value) > MAX_ENV_STRING_BYTES
    {
        return Err("vault.bad_value");
    }
    Ok(())
}

/// Keep `value` as `name`: the store item first, then the record, so a
/// record never names a value that is not there. `pulled` is the vault
/// state's names: a pulled entry of that name would win (`vault.name_taken`).
pub fn keep(
    home: &Path,
    store: &dyn SecretStore,
    name: &str,
    value: &str,
    proxy: Option<Vec<String>>,
    pulled: &[String],
    now_ms: u64,
) -> Result<(), &'static str> {
    check_name(name)?;
    check_value(name, value)?;
    if pulled.iter().any(|p| p == name) {
        return Err("vault.name_taken");
    }
    if !store.available() {
        return Err(super::store::UNAVAILABLE);
    }
    let _lock = super::pull::lock(home, true)?;
    let mut kept = read(home);
    if kept.salt.len() != 32 {
        let mut salt = [0u8; 16];
        getrandom::fill(&mut salt).map_err(|_| "vault.internal")?;
        kept.salt = salt.iter().map(|b| format!("{b:02x}")).collect();
    }
    store.put(&item(name), value)?;
    let fingerprint = kept.fingerprint(name, value);
    kept.env.insert(name.to_owned(), KeptRecord { fingerprint, proxy, kept_at: now_ms });
    write(home, &kept)
}

/// Remove `name`: the store item first (a record left by a failed write then
/// names a missing value, which no spawn gets), then the record, so an item
/// is never left with nothing tracking it. `Ok(false)` when there was no such
/// entry; a leftover item of a failed `keep` is still deleted when it can be.
pub fn remove(home: &Path, store: &dyn SecretStore, name: &str) -> Result<bool, &'static str> {
    let _lock = super::pull::lock(home, true)?;
    let mut kept = read(home);
    if !kept.env.contains_key(name) {
        let _ = store.delete(&item(name));
        return Ok(false);
    }
    store.delete(&item(name))?;
    kept.env.remove(name);
    write(home, &kept)?;
    Ok(true)
}

/// The entries as loaded for spawns, and what they came from.
struct Cache {
    seen: Option<Stamp>,
    loaded: Vec<(String, Zeroizing<String>, Option<Vec<String>>)>,
    /// Some item could not be read (a locked Keychain): when, so it is read
    /// again after [`super::RETRY_INCOMPLETE`].
    incomplete_at: Option<Instant>,
}

static CACHE: Mutex<Option<Cache>> = Mutex::new(None);

/// The kept entries a spawn gets, except names in `taken` (the pulled ones).
/// The store is read only when the file changed (else a `stat`), or after an
/// incomplete load; no item is read after `deadline`.
pub(super) fn given_at(
    home: &Path,
    store: &dyn SecretStore,
    taken: &[String],
    at: Instant,
    deadline: Instant,
) -> Vec<Given> {
    let now = stamp_of(&path(home));
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let fresh = cache.as_ref().is_some_and(|c| {
        c.seen == now
            && c.incomplete_at.is_none_or(|t| at.duration_since(t) < super::RETRY_INCOMPLETE)
    });
    if !fresh {
        *cache = Some(if now.is_none() {
            Cache { seen: None, loaded: Vec::new(), incomplete_at: None }
        } else {
            load(home, store, now, at, deadline)
        });
    }
    let Some(cache) = cache.as_ref() else { return Vec::new() };
    cache
        .loaded
        .iter()
        .filter(|(name, _, _)| !taken.contains(name))
        .map(|(name, value, proxy)| Given {
            name: name.clone(),
            value: value.clone(),
            proxy: proxy.clone(),
        })
        .collect()
}

fn load(
    home: &Path,
    store: &dyn SecretStore,
    seen: Option<Stamp>,
    at: Instant,
    deadline: Instant,
) -> Cache {
    let kept = read(home);
    let (mut loaded, mut incomplete, mut total) = (Vec::new(), false, 0usize);
    for (name, record) in &kept.env {
        if check_name(name).is_err() {
            continue;
        }
        let code = match store.get_by(&item(name), deadline) {
            Ok(Some(value)) if kept.fingerprint(name, &value) == record.fingerprint => {
                let bytes = env_string_bytes(name, &value);
                if total.saturating_add(bytes) > MAX_VAULT_ENV_BYTES {
                    "vault.env_too_large"
                } else {
                    total = total.saturating_add(bytes);
                    loaded.push((name.clone(), value, record.proxy.clone()));
                    continue;
                }
            }
            Ok(Some(_)) => "vault.env_changed",
            Ok(None) => "vault.env_missing",
            Err(code) => {
                incomplete = true;
                code
            }
        };
        tracing::warn!(name = %name, code, "kept vault entry not loaded");
    }
    Cache { seen, loaded, incomplete_at: incomplete.then_some(at) }
}

/// Forget the loaded entries, so the next spawn loads (tests).
#[cfg(test)]
pub(super) fn reset() {
    *CACHE.lock().unwrap_or_else(|e| e.into_inner()) = None;
}
