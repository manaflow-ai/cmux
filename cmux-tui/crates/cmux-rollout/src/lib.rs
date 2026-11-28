//! Staged rollout of a channel build (hq RFD 0224, "One update system for every place cmux
//! runs", Channels, triggers, rollout and holds): a channel file names `rollout: {pct}`, and a
//! host takes the channel's build only when `hash(host id, build) mod 100 < pct`.
//!
//! Every channel reader calls the one [`Rollout::takes`], so a host lands in the same bucket for
//! a build on every surface and every run, and a different build reshuffles the buckets (the
//! same hosts are not always the canaries). A channel file from before the field names no
//! `rollout`: that reads as [`Rollout::FULL`], every host, as before.
//!
//! The gate only ever holds a host back from a *new* build. A reader still moves a host off a
//! revoked build at any `pct`: the kill switch is never staged.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Domain separation for the bucket hash: a rollout bucket is never another hash's value.
const DOMAIN: &[u8] = b"cmux rollout bucket v1\0";

/// A channel file's `rollout`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rollout {
    /// The share of hosts, 0..=100, that take the channel's build. Missing reads as 100.
    #[serde(default = "full")]
    pub pct: u8,
}

const fn full() -> u8 {
    Rollout::FULL.pct
}

impl Default for Rollout {
    fn default() -> Self {
        Rollout::FULL
    }
}

impl Rollout {
    /// Every host: what a channel file without the field means.
    pub const FULL: Rollout = Rollout { pct: 100 };

    /// The rollout when `pct` is a share (0..=100); else why not. A reader refuses a channel file
    /// whose rollout is out of range rather than guessing what it meant.
    pub fn checked(self) -> Result<Rollout, String> {
        if self.pct > 100 {
            return Err(format!("rollout.pct {} is not 0..=100", self.pct));
        }
        Ok(self)
    }

    /// Whether the host `host` takes the build `build` (its commit or sha256: the same string on
    /// every host). At 100 every host does, one with no id too. Below 100 a host with no id
    /// waits for 100: a host that cannot place itself is never a canary.
    pub fn takes(self, host: Option<&str>, build: &str) -> bool {
        if self.pct >= 100 {
            return true;
        }
        host.filter(|h| !h.is_empty()).is_some_and(|h| bucket(h, build) < self.pct)
    }

    /// Why this host waits, for the reader's status line, or `None` when it takes the build.
    pub fn held_back(self, host: Option<&str>, build: &str) -> Option<String> {
        if self.takes(host, build) {
            return None;
        }
        Some(match host.filter(|h| !h.is_empty()) {
            None => format!(
                "staged rollout at {}%: this host has no id, so it waits for 100%",
                self.pct
            ),
            Some(h) => format!(
                "staged rollout at {}%: this host's bucket for {build} is {}",
                self.pct,
                bucket(h, build)
            ),
        })
    }
}

/// The host's bucket, 0..100, for `build`: SHA-256 over the domain, the host id and the build,
/// its first eight bytes big-endian, mod 100.
pub fn bucket(host: &str, build: &str) -> u8 {
    let mut hash = Sha256::new();
    hash.update(DOMAIN);
    hash.update(host.as_bytes());
    hash.update([0]);
    hash.update(build.as_bytes());
    let digest = hash.finalize();
    let mut top = [0u8; 8];
    top.copy_from_slice(&digest[..8]);
    (u64::from_be_bytes(top) % 100) as u8
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
