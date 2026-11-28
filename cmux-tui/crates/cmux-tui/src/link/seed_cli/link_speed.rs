//! The link-speed choice between a carry and the machine's own clone: this Mac keeps what each
//! seed upload to a machine measured (bytes per second, both halves averaged), and the carry
//! pack goes up only when its upload at that rate takes at most `CMUX_SEED_CARRY_BUDGET_S`
//! (default [`DEFAULT_BUDGET_S`]), the time a blobless clone of a large repository takes on a
//! cloud machine. A fast link carries a pack the old fixed cap refused (cmux's 690 MB pack is
//! about 7 s at 100 MB/s, its clone minutes); a slow one clones instead of a pack it would
//! take longer to send.
//!
//! Until a machine has a measured upload, and whenever `CMUX_SEED_CARRY_MAX_MB` is set, the cap
//! is today's (`seed::carry`), so nothing changes for a first seed or a pinned cap. A machine's
//! warm mirror (`CMUX_SEED_MIRRORS` there) wins over both: it borrows the mirror's objects and
//! drops the pack.
//!
//! The record is `<state>/link-seed/links/<sha256 of the machine's store id>.json` (0600, its
//! folder 0700), written to a temporary name and renamed.

use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::PathBuf;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

/// The longest a carry upload may take by default, in seconds.
pub(super) const DEFAULT_BUDGET_S: u64 = 60;

/// An upload smaller than this measures latency more than the link; it is not kept.
const MIN_SAMPLE_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Link {
    /// The measured upload rate, bytes per second.
    bytes_per_sec: u64,
}

fn path_of(machine: &str) -> Option<PathBuf> {
    let state = cmux_tui_core::platform::workspace_state_dir()?;
    let name: String =
        Sha256::digest(machine.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect();
    Some(state.join("link-seed").join("links").join(format!("{name}.json")))
}

/// The measured upload rate to `machine`, bytes per second, when there is one.
pub(super) fn rate(machine: &str) -> Option<u64> {
    let bytes = std::fs::read(path_of(machine)?).ok()?;
    let link: Link = serde_json::from_slice(&bytes).ok()?;
    (link.bytes_per_sec > 0).then_some(link.bytes_per_sec)
}

/// The rate after a sample of `bytes` in `elapsed` over a kept `old` one: the mean of the two,
/// so one slow or fast upload moves it halfway. None when the sample is too small to count.
pub(super) fn next_rate(old: Option<u64>, bytes: u64, elapsed: Duration) -> Option<u64> {
    if bytes < MIN_SAMPLE_BYTES {
        return old;
    }
    let micros = u64::try_from(elapsed.as_micros()).unwrap_or(u64::MAX).max(1);
    let sample = u64::try_from(u128::from(bytes) * 1_000_000 / u128::from(micros))
        .unwrap_or(u64::MAX)
        .max(1);
    Some(old.map_or(sample, |old| old / 2 + sample / 2))
}

/// Keeps an upload of `bytes` in `elapsed` to `machine`. Best effort: a record that cannot be
/// written only leaves the next seed on today's cap.
pub(super) fn note(machine: &str, bytes: u64, elapsed: Duration) {
    let Some(rate) = next_rate(rate(machine), bytes, elapsed) else { return };
    let Some(path) = path_of(machine) else { return };
    let Some(dir) = path.parent() else { return };
    if std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).is_err() {
        return;
    }
    let part = path.with_extension(format!("{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let wrote = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)
        .and_then(|mut file| {
            file.write_all(&serde_json::to_vec(&Link { bytes_per_sec: rate }).unwrap_or_default())
        });
    if wrote.is_err() || std::fs::rename(&part, &path).is_err() {
        let _ = std::fs::remove_file(&part);
    }
}

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok().and_then(|value| value.parse::<u64>().ok())
}

/// The largest carry pack for a machine at `rate` (bytes per second, when measured).
pub(super) fn carry_cap(rate: Option<u64>) -> u64 {
    cap_for(
        rate,
        env_u64("CMUX_SEED_CARRY_MAX_MB"),
        env_u64("CMUX_SEED_CARRY_BUDGET_S").unwrap_or(DEFAULT_BUDGET_S),
    )
}

/// [`carry_cap`] over its inputs: a pinned `max_mb` wins, then `budget_s` at the measured rate,
/// then today's default cap.
pub(super) fn cap_for(rate: Option<u64>, max_mb: Option<u64>, budget_s: u64) -> u64 {
    const MIB: u64 = 1024 * 1024;
    match (max_mb, rate) {
        (Some(max_mb), _) => max_mb.saturating_mul(MIB),
        (None, Some(rate)) => rate.saturating_mul(budget_s),
        (None, None) => super::super::seed::carry::DEFAULT_MAX_MB.saturating_mul(MIB),
    }
}

#[cfg(test)]
#[path = "link_speed_tests.rs"]
mod tests;
