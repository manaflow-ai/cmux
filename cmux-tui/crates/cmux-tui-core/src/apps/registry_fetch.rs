//! Fetches the registry's signed revocation list (DESIGN.md step 10) into
//! `<state>/apps/`[`REVOCATIONS_FILE`], where the catalog reads it on each
//! load ([`super::registry_trust::Revocations::load`]).
//!
//! The design names no URL for the list, so [`URL_ENV`] names it and
//! nothing defaults it: with no URL the task never starts. A fetched list
//! replaces the one on disk only when a registry key signed it and its
//! `sequence` is higher than the one on disk, so a replayed older list never
//! un-revokes a build. Each round makes at most [`ATTEMPTS`] requests of at
//! most `community::REQUEST_TIMEOUT` each, then waits [`INTERVAL`].

use std::path::Path;
use std::sync::{Arc, Weak};
use std::time::Duration;

use cmux_signed_envelope::Key;

use super::community::{HttpRegistryFetch, RegistryFetch};
use super::registry_trust::{
    MAX_BYTES, REVOCATIONS_FILE, open_revocations, read_signed, trusted_keys,
};
use super::supervisor::Supervisor;

/// The revocation list's URL (https only). Unset: no fetch, ever.
pub const URL_ENV: &str = "CMUX_EXTENSIONS_REVOCATIONS_URL";
/// Requests per round; a request that answers but does not open is not retried.
pub(super) const ATTEMPTS: u32 = 3;
/// The wait before the second request; each retry doubles it.
const BACKOFF: Duration = Duration::from_secs(2);
/// How often the task fetches again.
const INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);

/// What one round did.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Outcome {
    /// No URL is set: nothing fetched, nothing written.
    NoUrl,
    /// The list on disk is now this sequence.
    Updated(u64),
    /// The fetched list's sequence is not higher than the one on disk; kept.
    Kept { have: u64, fetched: u64 },
}

/// The URL [`URL_ENV`] names, if any.
fn configured_url() -> Option<String> {
    std::env::var(URL_ENV).ok().map(|s| s.trim().to_owned()).filter(|s| !s.is_empty())
}

/// The sequence of the list on disk that `keys` open; `None` when there is
/// none or it does not open (then any list that opens replaces it).
fn sequence_on_disk(apps_dir: &Path, keys: &[Key]) -> Option<u64> {
    let body = read_signed(&apps_dir.join(REVOCATIONS_FILE))?.ok()?;
    open_revocations(&body, keys).ok().map(|list| list.sequence)
}

/// One request with bounded retries: up to [`ATTEMPTS`], `pause` between.
fn fetch_bounded(
    fetch: &dyn RegistryFetch,
    url: &str,
    pause: &dyn Fn(Duration),
) -> Result<Vec<u8>, String> {
    let mut wait = BACKOFF;
    let mut last = String::new();
    for attempt in 0..ATTEMPTS {
        if attempt > 0 {
            pause(wait);
            wait *= 2;
        }
        match fetch.get(url) {
            Ok(body) => return Ok(body),
            Err(error) => last = error,
        }
    }
    Err(format!("{ATTEMPTS} requests failed; the last: {last}"))
}

/// Writes `body` to `<apps_dir>/`[`REVOCATIONS_FILE`] through a temporary
/// file and a rename, so a reader sees the old list or the new one.
fn write_atomic(apps_dir: &Path, body: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    std::fs::create_dir_all(apps_dir)?;
    let file = apps_dir.join(REVOCATIONS_FILE);
    let temp = apps_dir.join(format!("{REVOCATIONS_FILE}.tmp"));
    let mut out = std::fs::File::create(&temp)?;
    out.write_all(body)?;
    out.sync_all()?;
    drop(out);
    std::fs::rename(&temp, &file)
}

/// One round: fetch the list at `url`, open it with `keys`, and write it
/// when its sequence is higher than the one on disk.
pub(super) fn refresh(
    apps_dir: &Path,
    url: Option<&str>,
    keys: &[Key],
    fetch: &dyn RegistryFetch,
    pause: &dyn Fn(Duration),
) -> Result<Outcome, String> {
    let Some(url) = url else { return Ok(Outcome::NoUrl) };
    if !url.starts_with("https://") {
        return Err(format!("{URL_ENV} {url} is not an https URL"));
    }
    let body = fetch_bounded(fetch, url, pause)?;
    if body.len() as u64 > MAX_BYTES {
        return Err(format!("the revocation list is larger than {MAX_BYTES} bytes"));
    }
    let fetched = open_revocations(&body, keys)?.sequence;
    if let Some(have) = sequence_on_disk(apps_dir, keys)
        && fetched <= have
    {
        return Ok(Outcome::Kept { have, fetched });
    }
    write_atomic(apps_dir, &body).map_err(|e| format!("{}: {e}", apps_dir.display()))?;
    Ok(Outcome::Updated(fetched))
}

impl Supervisor {
    /// Starts the revocation fetch thread when [`URL_ENV`] names a URL; else
    /// does nothing. A round that writes a new list reloads the catalog so
    /// a newly revoked extension stops at once. In-crate tests start none.
    pub(crate) fn start_revocations_fetch(self: &Arc<Self>) {
        if cfg!(test) {
            return;
        }
        let Some(url) = configured_url() else { return };
        let Some(apps_dir) =
            self.config.sources.local.as_deref().and_then(Path::parent).map(Path::to_path_buf)
        else {
            return;
        };
        let me = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("apps-revocations-fetch".into())
            .spawn(move || fetch_loop(&me, &apps_dir, &url));
        if let Err(error) = spawned {
            eprintln!("cmux-tui: apps revocation fetch thread did not start: {error}");
        }
    }
}

fn fetch_loop(me: &Weak<Supervisor>, apps_dir: &Path, url: &str) {
    loop {
        if me.strong_count() == 0 {
            return;
        }
        let keys = trusted_keys();
        match refresh(apps_dir, Some(url), &keys, &HttpRegistryFetch, &std::thread::sleep) {
            Ok(Outcome::Updated(_)) => {
                let Some(supervisor) = me.upgrade() else { return };
                supervisor.reload_local_apps_now();
            }
            Ok(_) => {}
            Err(error) => eprintln!("cmux-tui: revocation list not updated: {error}"),
        }
        std::thread::sleep(INTERVAL);
    }
}

#[cfg(test)]
#[path = "registry_fetch_tests.rs"]
mod tests;
