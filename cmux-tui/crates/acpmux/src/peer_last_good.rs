//! Each peer's last-known-good link, kept on disk (`peer-paths.json` in the acpmux home), so a
//! restarted daemon dials the path that worked first, even while a platform service is down:
//! the path that carried the session, each path's last round trip, and the endpoints it was
//! reached at.
//!
//! Format (mode 0600, replaced through a temp file and a rename):
//! `{"version":1,"peers":{"<name>":{"via":"link","carrier":"direct","at":<ms>,
//!   "rttMs":{"link":3.1,"ssh":41.0},"endpoints":{"url":"ssh://...","link":"inst_..."}}}}`.
//! A memory store keeps none.

use crate::peer_paths::{Paths, Via};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// The file name in the acpmux home.
pub const FILE_NAME: &str = "peer-paths.json";
const VERSION: u32 = 1;
/// The most bytes the file may hold; one peer's entry is under 300.
const MAX_BYTES: u64 = 1024 * 1024;

/// Where one peer was reached last.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Endpoints {
    /// The configured peer URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The paired install the cmux link dials.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
    /// acpmux's own WireGuard service address of the peer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wireguard: Option<String>,
}

/// One peer's last-known-good link.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// The path that carried the session last.
    pub via: Option<Via>,
    /// Its carrier, as clients name it (`direct`, `ssh`, `hub`, `cloud`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub carrier: Option<String>,
    /// When it was written, ms since the epoch.
    pub at: u64,
    /// Each path's last smoothed round trip, in ms.
    #[serde(default)]
    pub rtt_ms: BTreeMap<String, f64>,
    #[serde(default)]
    pub endpoints: Endpoints,
}

impl Entry {
    /// The entry for `paths` carried by `via` now.
    pub fn of(paths: &Paths, via: Via, endpoints: Endpoints, at: u64) -> Self {
        let rtt_ms = paths
            .vias()
            .filter_map(|v| {
                paths.rtt(v).map(|rtt| (v.as_str().to_owned(), rtt.as_micros() as f64 / 1000.0))
            })
            .collect();
        Self {
            via: Some(via),
            carrier: Some(via.carrier().as_str().to_owned()),
            at,
            rtt_ms,
            endpoints,
        }
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct File {
    version: u32,
    #[serde(default)]
    peers: BTreeMap<String, Entry>,
}

/// The file, loaded once and written on each change. Shared by every peer of one hub.
#[derive(Debug, Default)]
pub struct LastGood {
    path: Option<PathBuf>,
    peers: Mutex<BTreeMap<String, Entry>>,
    /// The remote tokens each `ssh://` peer read, in the same home (`peer_kept_tokens.rs`).
    pub tokens: crate::peer_kept_tokens::KeptTokens,
}

impl LastGood {
    /// Read `<home>/peer-paths.json` (none, unreadable or another version: empty). `None`
    /// keeps everything in memory only.
    pub fn open(home: Option<&Path>) -> Self {
        let path = home.map(|home| home.join(FILE_NAME));
        let peers = path.as_deref().and_then(read).unwrap_or_default();
        let tokens = crate::peer_kept_tokens::KeptTokens::open(home);
        Self { path, peers: Mutex::new(peers), tokens }
    }

    pub fn get(&self, name: &str) -> Option<Entry> {
        self.peers.lock().unwrap_or_else(|e| e.into_inner()).get(name).cloned()
    }

    /// Record `entry` for `name` and write the file when the path or the endpoints changed (a
    /// round trip alone is not worth a write; it goes along with the next one).
    pub fn record(&self, name: &str, entry: Entry) {
        let snapshot = {
            let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let changed = peers
                .get(name)
                .is_none_or(|old| old.via != entry.via || old.endpoints != entry.endpoints);
            peers.insert(name.to_owned(), entry);
            if !changed {
                return;
            }
            File { version: VERSION, peers: peers.clone() }
        };
        if let Some(path) = &self.path
            && let Err(e) = write_json(path, &snapshot)
        {
            tracing::warn!(peer = %name, "could not save the peer's last good path: {e}");
        }
    }

    /// Forget a removed peer.
    pub fn forget(&self, name: &str) {
        let snapshot = {
            let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            if peers.remove(name).is_none() {
                return;
            }
            File { version: VERSION, peers: peers.clone() }
        };
        if let Some(path) = &self.path {
            let _ = write_json(path, &snapshot);
        }
    }
}

fn read(path: &Path) -> Option<BTreeMap<String, Entry>> {
    let file: File = read_json(path)?;
    (file.version == VERSION).then_some(file.peers)
}

/// A JSON file of this home's peer state (none, too large or unreadable: None).
pub(crate) fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return None;
    }
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// Replace `path` with `value` as JSON, mode 0600, through a temp file and a rename.
pub(crate) fn write_json(path: &Path, value: &impl Serialize) -> std::io::Result<()> {
    let text = serde_json::to_vec(value).map_err(std::io::Error::other)?;
    let dir = path.parent().ok_or_else(|| std::io::Error::other("no parent"))?;
    let name = path.file_name().ok_or_else(|| std::io::Error::other("no file name"))?;
    let temp = dir.join(format!(".{}.{}.tmp", name.to_string_lossy(), std::process::id()));
    let written = write_private(&temp, &text).and_then(|()| crate::home_fs::rename(&temp, path));
    if written.is_err() {
        let _ = crate::home_fs::remove_file(&temp);
    }
    written
}

fn write_private(path: &Path, text: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    let mut options = crate::home_fs::OpenOptions::new();
    options.write(true).create(true).truncate(true).mode(0o600);
    let mut file = options.open(path)?;
    file.write_all(text)?;
    file.sync_all()
}

#[cfg(test)]
mod tests;
