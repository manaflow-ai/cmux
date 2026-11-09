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
}

impl LastGood {
    /// Read `<home>/peer-paths.json` (none, unreadable or another version: empty). `None`
    /// keeps everything in memory only.
    pub fn open(home: Option<&Path>) -> Self {
        let path = home.map(|home| home.join(FILE_NAME));
        let peers = path.as_deref().and_then(read).unwrap_or_default();
        Self { path, peers: Mutex::new(peers) }
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
            && let Err(e) = write(path, &snapshot)
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
            let _ = write(path, &snapshot);
        }
    }
}

fn read(path: &Path) -> Option<BTreeMap<String, Entry>> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return None;
    }
    let file: File = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (file.version == VERSION).then_some(file.peers)
}

fn write(path: &Path, file: &File) -> std::io::Result<()> {
    let text = serde_json::to_vec(file).map_err(std::io::Error::other)?;
    let dir = path.parent().ok_or_else(|| std::io::Error::other("no parent"))?;
    let temp = dir.join(format!(".{FILE_NAME}.{}.tmp", std::process::id()));
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
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(path)?;
    file.write_all(text)?;
    file.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn the_last_good_path_is_read_again_after_a_restart_and_dialed_first() {
        let dir = tempfile::tempdir().unwrap();
        let book = LastGood::open(Some(dir.path()));
        let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
        paths.pong(Via::Ssh, Duration::from_millis(40), 0);
        paths.pong(Via::Ssh, Duration::from_millis(40), 3_000);
        let endpoints = Endpoints {
            url: Some("ssh://mini".into()),
            link: Some("inst_b".into()),
            wireguard: None,
        };
        book.record("mini", Entry::of(&paths, Via::Ssh, endpoints.clone(), 3_000));
        drop(book);

        // A new daemon run.
        let book = LastGood::open(Some(dir.path()));
        let entry = book.get("mini").expect("kept across the restart");
        assert_eq!(entry.via, Some(Via::Ssh));
        assert_eq!(entry.carrier.as_deref(), Some("ssh"));
        assert_eq!(entry.endpoints, endpoints);
        assert_eq!(entry.rtt_ms.get("ssh"), Some(&40.0));
        let mut fresh = Paths::new(&[Via::Ssh, Via::Link]);
        assert_eq!(fresh.dial_order(0), vec![Via::Link, Via::Ssh]);
        fresh.remember(entry.via);
        assert_eq!(fresh.dial_order(0), vec![Via::Ssh, Via::Link], "the remembered path first");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(dir.path().join(FILE_NAME)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        book.forget("mini");
        assert!(LastGood::open(Some(dir.path())).get("mini").is_none());
    }

    #[test]
    fn a_file_of_another_version_or_garbage_reads_as_empty() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(FILE_NAME), br#"{"version":2,"peers":{"a":{}}}"#).unwrap();
        assert!(LastGood::open(Some(dir.path())).get("a").is_none());
        std::fs::write(dir.path().join(FILE_NAME), b"not json").unwrap();
        assert!(LastGood::open(Some(dir.path())).get("a").is_none());
        let memory = LastGood::open(None);
        memory.record("a", Entry { via: Some(Via::Link), ..Entry::default() });
        assert_eq!(memory.get("a").and_then(|e| e.via), Some(Via::Link));
    }
}
