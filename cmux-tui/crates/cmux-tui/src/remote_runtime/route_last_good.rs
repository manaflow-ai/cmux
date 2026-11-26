//! Each known daemon's last-known-good route, kept on disk (`route-last-good.json` in the
//! client state directory), so the next launch dials the route that connected last first
//! instead of waiting out a dead one ahead of it (a stale LAN address, a gone direct path)
//! for a whole attempt budget. The same shape as acpmux's `peer_last_good.rs`; a game client
//! dials its last good relay the same way (Steam Datagram Relay, QUIC's remembered path).
//!
//! Format (mode 0600, replaced through a temp file and a rename):
//! `{"version":1,"daemons":{"<daemon key, hex>":{"route":"<sha256 of the route URL, hex>",
//!   "at":<ms>}}}`. The route is kept as a hash: a route URL can carry a capability in its
//! path or query, and only "is this candidate the one that worked" is ever asked of it.
//!
//! A remembered route that is not among the candidates, or older than [`STALE_AFTER`], is
//! ignored. One that fails is forgotten at once, so a stale memory costs at most one attempt.
//! A connect with no pinned daemon key (an invitation, a carrier discovery) keeps none.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;

use super::ResolvedRouteCandidate;

/// The file name in the client state directory.
pub(super) const FILE_NAME: &str = "route-last-good.json";
const VERSION: u32 = 1;
/// The most bytes the file may hold; one daemon's entry is under 200.
const MAX_BYTES: u64 = 1024 * 1024;
/// How long a remembered route is trusted. Past it the candidates' own order rules again: a
/// machine not dialed for a month has likely moved networks.
pub(super) const STALE_AFTER: Duration = Duration::from_secs(30 * 24 * 60 * 60);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Entry {
    route: String,
    at: u64,
    /// How long the route's last connect took, in ms (the race's stagger follows it). Absent
    /// in files written before it.
    #[serde(default, rename = "connectMs", skip_serializing_if = "Option::is_none")]
    connect_ms: Option<u64>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct File {
    version: u32,
    #[serde(default)]
    daemons: BTreeMap<String, Entry>,
}

/// One daemon's remembered route, loaded once per first connect and written on each change.
#[derive(Debug)]
pub(super) struct LastGoodRoute {
    path: Option<PathBuf>,
    daemon: String,
    remembered: Mutex<Option<Entry>>,
}

impl LastGoodRoute {
    /// The memory of the daemon pinned to `daemon_key`, in `state_dir` (`None`: in memory
    /// only). No key: nothing names the daemon, so nothing is kept.
    pub(super) fn open(state_dir: Option<&Path>, daemon_key: Option<[u8; 32]>) -> Option<Self> {
        let daemon = to_hex(&daemon_key?);
        let path = state_dir.map(|dir| dir.join(FILE_NAME));
        let remembered =
            path.as_deref().and_then(read).and_then(|mut daemons| daemons.remove(&daemon)).filter(
                |entry| now_ms().saturating_sub(entry.at) <= STALE_AFTER.as_millis() as u64,
            );
        Some(Self { path, daemon, remembered: Mutex::new(remembered) })
    }

    /// The candidate to dial first: the remembered one, when it is still a candidate. `None`
    /// when `upgrade` is set (the SSH route at 0 must go first, it installs the daemon).
    pub(super) fn first(&self, routes: &[ResolvedRouteCandidate], upgrade: bool) -> Option<usize> {
        if upgrade {
            return None;
        }
        let remembered = self.remembered.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        // The attempts see each candidate as its connect request names it (normalized).
        routes.iter().position(|candidate| {
            super::normalize_carrier_endpoint(candidate.endpoint.clone())
                .is_ok_and(|endpoint| route_hash(&endpoint) == remembered.route)
        })
    }

    /// How long the remembered route's last connect took, when known.
    pub(super) fn connect_time(&self) -> Option<Duration> {
        let remembered = self.remembered.lock().unwrap_or_else(|e| e.into_inner());
        remembered.as_ref()?.connect_ms.map(Duration::from_millis)
    }

    /// `endpoint` connected: remember it.
    #[cfg(test)]
    pub(super) fn connected(&self, endpoint: &Url) {
        self.remember(endpoint, None);
    }

    /// `endpoint` connected in `took`: remember it and how long it took.
    pub(super) fn connected_in(&self, endpoint: &Url, took: Duration) {
        self.remember(endpoint, Some(took.as_millis().min(u128::from(u64::MAX)) as u64));
    }

    fn remember(&self, endpoint: &Url, connect_ms: Option<u64>) {
        let entry = Entry { route: route_hash(endpoint), at: now_ms(), connect_ms };
        {
            let mut remembered = self.remembered.lock().unwrap_or_else(|e| e.into_inner());
            if remembered.as_ref().is_some_and(|old| old.route == entry.route) {
                // The same route again: the stamp alone is not worth a write until it ages,
                // nor a connect time within a quarter of the one kept.
                let fresh = remembered.as_ref().is_some_and(|old| {
                    entry.at.saturating_sub(old.at) < STALE_AFTER.as_millis() as u64 / 2
                        && close_enough(old.connect_ms, entry.connect_ms)
                });
                if fresh {
                    return;
                }
            }
            *remembered = Some(entry.clone());
        }
        self.write(Some(entry));
    }

    /// `endpoint` failed: forget it when it is the remembered one.
    pub(super) fn failed(&self, endpoint: &Url) {
        {
            let mut remembered = self.remembered.lock().unwrap_or_else(|e| e.into_inner());
            if remembered.as_ref().is_none_or(|old| old.route != route_hash(endpoint)) {
                return;
            }
            *remembered = None;
        }
        self.write(None);
    }

    fn write(&self, entry: Option<Entry>) {
        let Some(path) = &self.path else { return };
        // Other daemons' entries are read again here, so two clients of two daemons keep both.
        let mut daemons = read(path).unwrap_or_default();
        match entry {
            Some(entry) => daemons.insert(self.daemon.clone(), entry),
            None => daemons.remove(&self.daemon),
        };
        // A memory that cannot be saved only costs the next launch the candidates' own order.
        let _ = write_json(path, &File { version: VERSION, daemons });
    }
}

/// Whether a new connect time `new` is within a quarter of the kept one `old` (no new one
/// keeps the old).
fn close_enough(old: Option<u64>, new: Option<u64>) -> bool {
    match (old, new) {
        (_, None) => true,
        (None, Some(_)) => false,
        (Some(old), Some(new)) => old.abs_diff(new) <= old / 4,
    }
}

fn route_hash(endpoint: &Url) -> String {
    to_hex(&Sha256::digest(endpoint.as_str().as_bytes()))
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis() as u64)
}

fn read(path: &Path) -> Option<BTreeMap<String, Entry>> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return None;
    }
    let file: File = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (file.version == VERSION).then_some(file.daemons)
}

/// Replace `path` with `value` as JSON, mode 0600, through a temp file and a rename.
fn write_json(path: &Path, value: &impl Serialize) -> std::io::Result<()> {
    let text = serde_json::to_vec(value).map_err(std::io::Error::other)?;
    let dir = path.parent().ok_or_else(|| std::io::Error::other("no parent"))?;
    std::fs::create_dir_all(dir)?;
    let name = path.file_name().ok_or_else(|| std::io::Error::other("no file name"))?;
    let temp = dir.join(format!(".{}.{}.tmp", name.to_string_lossy(), std::process::id()));
    let written = write_private(&temp, &text).and_then(|()| std::fs::rename(&temp, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

fn write_private(path: &Path, text: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(text)?;
    file.sync_all()
}
