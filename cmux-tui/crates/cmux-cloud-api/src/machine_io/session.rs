//! The client-session cache: one entry per (cmux API, team, machine, person), so
//! per-call `cloud machine-io` runs mint about once per session lifetime instead
//! of once per call. The entry is a file when the caller names a folder, else it
//! lives in this process's memory (the daemon, which keeps no session on disk).
//!
//! A file holds either the session (the provider token, the VM, the user, the
//! provider API and when to stop using it) or a "proxy until" time after a mint
//! the cmux API refused (a teammate's machine, a provider without client
//! sessions, the rate limit), so a refused machine costs no mint per call. Files
//! are 0600 in a 0700 folder, written whole then renamed. A token lives at most
//! [`TTL_SECONDS`]; it is never printed, logged or put in an argument list.

use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::direct::Grant;

/// What a mint asks for: the cmux API's longest session (15 minutes).
pub(super) const TTL_SECONDS: u64 = 900;
/// A session closer than this to its end is renewed before use, so no call starts on a token
/// that could lapse mid-call (a 1 MB write is seconds; a five-minute exec is the longest call).
pub(super) const RENEW_MARGIN_MS: u64 = 330_000;
const HOLD_LONG_MS: u64 = 10 * 60 * 1000;
const HOLD_SHORT_MS: u64 = 60 * 1000;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(super) enum Entry {
    Session { grant: Grant, use_until_ms: u64 },
    ProxyUntil { until_ms: u64 },
}

/// What the cache says to do now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Use {
    Direct(Grant),
    Proxy,
    Mint,
}

pub(super) fn decide(entry: Option<&Entry>, now_ms: u64) -> Use {
    match entry {
        Some(Entry::Session { grant, use_until_ms })
            if *use_until_ms > now_ms.saturating_add(RENEW_MARGIN_MS) =>
        {
            Use::Direct(grant.clone())
        }
        Some(Entry::ProxyUntil { until_ms }) if *until_ms > now_ms => Use::Proxy,
        _ => Use::Mint,
    }
}

/// When to stop using a session the cmux API says expires at `expires_at_ms`: that time, but no
/// later than the asked lifetime from now by this machine's clock (a clock behind the server's
/// would otherwise keep a token past its end).
pub(super) fn use_until(expires_at_ms: u64, now_ms: u64) -> u64 {
    expires_at_ms.min(now_ms.saturating_add(TTL_SECONDS.saturating_mul(1000)))
}

/// How long to take the proxy after the cmux API refused a mint with `status`. Refusals that hold
/// for the machine (not this person's, no client sessions, gone) wait ten minutes; the rate limit,
/// a server error or no answer wait one; a paused machine or a bad credential is not remembered
/// (the proxy answers those alike, and the next call should mint once the machine runs).
pub(super) fn hold_ms(status: u16) -> u64 {
    match status {
        403 | 404 | 501 => HOLD_LONG_MS,
        401 | 409 | 400 => 0,
        _ => HOLD_SHORT_MS,
    }
}

/// The person the credential speaks for: a JWT's `sub` (a Stack access token keeps it across its
/// refreshes), else a digest of the credential itself.
pub(super) fn subject(credential: &str) -> String {
    let sub = credential
        .split('.')
        .nth(1)
        .and_then(|payload| URL_SAFE_NO_PAD.decode(payload.trim_end_matches('=')).ok())
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|claims| claims.get("sub").and_then(|s| s.as_str()).map(str::to_owned));
    match sub {
        Some(sub) if !sub.is_empty() => format!("sub:{sub}"),
        _ => format!("credential:{}", hex(&Sha256::digest(credential.as_bytes()))),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub(super) struct Cache {
    place: Place,
}

/// Where an entry lives: a file in the folder the caller named, else this process's memory. The
/// daemon names no folder (it keeps no session on disk), but it lives long, so its memory still
/// turns a mint per exec into a mint per session lifetime.
enum Place {
    File(PathBuf),
    Memory(String),
}

/// The in-memory entries, by the digest a file would be named by. At most [`MEMORY_ENTRIES`]: a
/// store first drops every entry past its end, then, when still full, the one nearest its end.
static MEMORY: LazyLock<Mutex<HashMap<String, Entry>>> = LazyLock::new(Default::default);
const MEMORY_ENTRIES: usize = 256;

impl Entry {
    fn ends_at_ms(&self) -> u64 {
        match self {
            Entry::Session { use_until_ms, .. } => *use_until_ms,
            Entry::ProxyUntil { until_ms } => *until_ms,
        }
    }
}

impl Cache {
    /// The cache entry for this API, team, machine and person: a file in `dir`, or with no dir
    /// an entry in this process's memory.
    pub(super) fn new(
        dir: Option<&Path>,
        api: &str,
        team: Option<&str>,
        machine: &str,
        credential: &str,
    ) -> Self {
        let key = [api, team.unwrap_or_default(), machine, &subject(credential)].join("\0");
        let name = hex(&Sha256::digest(key.as_bytes()));
        let place = match dir {
            Some(d) => Place::File(d.join(format!("{name}.json"))),
            None => Place::Memory(name),
        };
        Cache { place }
    }

    pub(super) fn load(&self) -> Option<Entry> {
        match &self.place {
            Place::File(file) => {
                let bytes = std::fs::read(file).ok()?;
                serde_json::from_slice(&bytes).ok()
            }
            Place::Memory(name) => memory().get(name).cloned(),
        }
    }

    /// Best effort: a cache that cannot be written only costs a mint on the next call.
    pub(super) fn store(&self, entry: &Entry, now_ms: u64) {
        match &self.place {
            Place::File(file) => {
                let _ = write_private(file, &serde_json::to_vec(entry).unwrap_or_default());
            }
            Place::Memory(name) => {
                let mut map = memory();
                map.retain(|_, e| e.ends_at_ms() > now_ms);
                if map.len() >= MEMORY_ENTRIES && !map.contains_key(name) {
                    let nearest =
                        map.iter().min_by_key(|(_, e)| e.ends_at_ms()).map(|(k, _)| k.clone());
                    if let Some(nearest) = nearest {
                        map.remove(&nearest);
                    }
                }
                map.insert(name.clone(), entry.clone());
            }
        }
    }

    pub(super) fn clear(&self) {
        match &self.place {
            Place::File(file) => {
                let _ = std::fs::remove_file(file);
            }
            Place::Memory(name) => {
                memory().remove(name);
            }
        }
    }
}

/// A poisoned lock means only that a store panicked; every entry left is still a whole one.
fn memory() -> MutexGuard<'static, HashMap<String, Entry>> {
    MEMORY.lock().unwrap_or_else(PoisonError::into_inner)
}

fn write_private(file: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    let dir = file.parent().ok_or_else(|| std::io::Error::other("no folder"))?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    let temp = dir.join(format!(
        ".{}.{}",
        std::process::id(),
        file.file_name().and_then(|n| n.to_str()).unwrap_or("entry")
    ));
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temp)?;
    let written = out.write_all(bytes).and_then(|()| out.sync_all());
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
        return written;
    }
    std::fs::rename(&temp, file)
}
