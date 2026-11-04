//! What this machine measured, so a restore runs only when it beats a cold
//! install here: per lockfile key the last cold install and the last restore
//! (download, unpack and the install after it), the archive's size, and the
//! machine's download speed from the cache. Kept in `~/.acpmux/deps-stats.json`
//! (owner-only); numbers and keys only, never a path or a credential.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Assumed download speed before this machine has measured one: high, so a
/// first restore is tried unless the cold install is very fast.
pub const DEFAULT_DOWNLOAD_BPS: f64 = 100.0 * 1024.0 * 1024.0;
/// Unpack speed (archive bytes per second) before one is measured.
pub const DEFAULT_UNPACK_BPS: f64 = 300.0 * 1024.0 * 1024.0;
/// At most this many keys are kept; the oldest are dropped.
const MAX_KEYS: usize = 256;

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct KeyStats {
    /// The last cold install of this key here (no restore before it).
    pub cold_ms: Option<u64>,
    /// The last restore of this key here: download, unpack and the install after it.
    pub warm_ms: Option<u64>,
    /// The archive's size, from a download or an upload.
    pub archive_bytes: Option<u64>,
    /// When this record last changed (seconds since the epoch), for trimming.
    pub updated: u64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Stats {
    pub keys: BTreeMap<String, KeyStats>,
    /// Bytes per second of the last download from the cache.
    pub download_bps: Option<f64>,
    /// Archive bytes per second of the last unpack.
    pub unpack_bps: Option<f64>,
}

/// Why a restore is skipped, or None to try one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Choice {
    Restore,
    /// The last cold install here was faster than a restore is expected to be.
    Cold {
        cold_ms: u64,
        expected_ms: u64,
    },
}

fn path() -> PathBuf {
    crate::config::home().join("deps-stats.json")
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

impl Stats {
    /// This machine's record; empty when there is none or it does not parse.
    pub fn load() -> Stats {
        std::fs::read(path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    /// Written whole to a temporary file and renamed over the old one, owner-only.
    pub fn save(&self) -> std::io::Result<()> {
        let path = path();
        let Some(dir) = path.parent() else { return Ok(()) };
        std::fs::create_dir_all(dir)?;
        let mut tmp = tempfile::Builder::new().prefix(".deps-stats-").tempfile_in(dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tmp.as_file().set_permissions(std::fs::Permissions::from_mode(0o600))?;
        }
        tmp.write_all(&serde_json::to_vec(self).map_err(std::io::Error::other)?)?;
        tmp.persist(&path).map_err(|e| e.error)?;
        Ok(())
    }

    /// Applies `f` to the record on disk now (another process may have
    /// written since this one loaded) and saves it. Never fails a warm.
    pub fn update(f: impl FnOnce(&mut Stats)) {
        let mut stats = Stats::load();
        f(&mut stats);
        stats.trim();
        let _ = stats.save();
    }

    pub fn key_mut(&mut self, key: &str) -> &mut KeyStats {
        let entry = self.keys.entry(key.to_owned()).or_default();
        entry.updated = now();
        entry
    }

    fn trim(&mut self) {
        while self.keys.len() > MAX_KEYS {
            let Some(oldest) =
                self.keys.iter().min_by_key(|(_, v)| v.updated).map(|(k, _)| k.clone())
            else {
                break;
            };
            self.keys.remove(&oldest);
        }
    }

    /// How long a restore of `bytes` is expected to take here, in ms.
    pub fn expected_restore_ms(&self, bytes: u64) -> u64 {
        let down = self.download_bps.filter(|b| *b > 0.0).unwrap_or(DEFAULT_DOWNLOAD_BPS);
        let unpack = self.unpack_bps.filter(|b| *b > 0.0).unwrap_or(DEFAULT_UNPACK_BPS);
        ((bytes as f64 / down + bytes as f64 / unpack) * 1000.0) as u64
    }

    /// Restore, or install cold, for `key`: cold when the last cold install
    /// here beat the last restore here or, with no restore measured yet, the
    /// expected download and unpack of the archive.
    pub fn choose(&self, key: &str) -> Choice {
        let Some(record) = self.keys.get(key) else { return Choice::Restore };
        let Some(cold_ms) = record.cold_ms else { return Choice::Restore };
        let expected_ms = match (record.warm_ms, record.archive_bytes) {
            (Some(warm), _) => warm,
            (None, Some(bytes)) => self.expected_restore_ms(bytes),
            (None, None) => return Choice::Restore,
        };
        if expected_ms >= cold_ms { Choice::Cold { cold_ms, expected_ms } } else { Choice::Restore }
    }

    /// Whether a download that has read `got` of `size` bytes in
    /// `elapsed_ms` should be given up: what is left of it at this pace,
    /// and the unpack, would take longer than a cold install (`cold_ms`).
    /// The time already spent is spent either way.
    pub fn too_slow(&self, cold_ms: u64, got: u64, size: u64, elapsed_ms: u64) -> bool {
        if got == 0 || size <= got {
            return false;
        }
        let rate = got as f64 / (elapsed_ms.max(1) as f64 / 1000.0);
        let unpack = self.unpack_bps.filter(|b| *b > 0.0).unwrap_or(DEFAULT_UNPACK_BPS);
        let left = ((size - got) as f64 / rate + size as f64 / unpack) * 1000.0;
        left >= cold_ms as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MB: u64 = 1024 * 1024;

    fn with(key: &str, record: KeyStats) -> Stats {
        let mut stats = Stats::default();
        stats.keys.insert(key.into(), record);
        stats
    }

    #[test]
    fn restores_without_a_cold_record() {
        assert_eq!(Stats::default().choose("k"), Choice::Restore);
        let s = with("k", KeyStats { archive_bytes: Some(200 * MB), ..KeyStats::default() });
        assert_eq!(s.choose("k"), Choice::Restore);
    }

    #[test]
    fn a_fast_cold_install_beats_a_big_download() {
        // The bench VM: bun's 185 MB archive against a 0.7 s cold install.
        let s = with(
            "bun-x",
            KeyStats { cold_ms: Some(710), archive_bytes: Some(185 * MB), ..KeyStats::default() },
        );
        assert!(matches!(s.choose("bun-x"), Choice::Cold { cold_ms: 710, .. }));
    }

    #[test]
    fn a_slow_cold_install_restores() {
        let s = with(
            "cargo-x",
            KeyStats {
                cold_ms: Some(40_000),
                archive_bytes: Some(111 * MB),
                ..KeyStats::default()
            },
        );
        assert_eq!(s.choose("cargo-x"), Choice::Restore);
    }

    #[test]
    fn a_measured_restore_wins_over_the_estimate() {
        let s = with(
            "k",
            KeyStats {
                cold_ms: Some(2_000),
                warm_ms: Some(3_000),
                archive_bytes: Some(MB),
                ..KeyStats::default()
            },
        );
        assert!(matches!(s.choose("k"), Choice::Cold { expected_ms: 3_000, .. }));
        let s = with(
            "k",
            KeyStats {
                cold_ms: Some(2_000),
                warm_ms: Some(1_000),
                archive_bytes: Some(500 * MB),
                ..KeyStats::default()
            },
        );
        assert_eq!(s.choose("k"), Choice::Restore);
    }

    #[test]
    fn the_measured_speed_is_used() {
        let mut s = Stats { download_bps: Some(10.0 * MB as f64), ..Stats::default() };
        s.unpack_bps = Some(1_000.0 * MB as f64);
        // 100 MB at 10 MB/s plus 0.1 s unpack.
        assert_eq!(s.expected_restore_ms(100 * MB), 10_100);
    }

    #[test]
    fn a_slow_download_is_given_up() {
        let s = Stats::default();
        // 10 MB of 200 MB in 1 s: 20 s to go, against a 5 s cold install.
        assert!(s.too_slow(5_000, 10 * MB, 200 * MB, 1_000));
        // 100 MB of 200 MB in 1 s: 1 s more and 0.7 s to unpack.
        assert!(!s.too_slow(5_000, 100 * MB, 200 * MB, 1_000));
    }

    #[test]
    fn trims_to_the_newest_keys() {
        let mut s = Stats::default();
        for i in 0..(MAX_KEYS + 5) {
            s.keys.insert(format!("k{i}"), KeyStats { updated: i as u64, ..KeyStats::default() });
        }
        s.trim();
        assert_eq!(s.keys.len(), MAX_KEYS);
        assert!(!s.keys.contains_key("k0"));
        assert!(s.keys.contains_key(&format!("k{}", MAX_KEYS + 4)));
    }
}
