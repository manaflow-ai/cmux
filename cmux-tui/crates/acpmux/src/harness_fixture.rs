//! A capture fixture for the harness catalog and its health
//! (`ACPMUX_HARNESS_FIXTURE`): a JSON file the daemon reads once at start
//! when the variable names it, so a screenshot rig's before and after builds
//! show the same harnesses with the same health on any host.
//!
//! ```json
//! {"harnesses": {"codex": {"argv": ["codex-acp"], "description": "found on PATH"}},
//!  "health": [{"id": "codex", "program": "codex-acp", "channel": "npm", ...}]}
//! ```
//!
//! The variable may name a first-run state instead of a file,
//! `matrix:CELL` (`matrix.rs`): which agent CLIs the Mac has and their sign-in.
//!
//! `harnesses` are `HarnessProfile`s that stand in for what PATH, `~/.acpx`
//! and the ACP Registry would add (profile files still join); `health` are
//! `HarnessHealth` rows served as the daemon's check. While a fixture is
//! set nothing about a fixture harness is read from this machine: no
//! version, sign-in or newest-version check, no model probe of it, no
//! saved health copy, and every update (auto, requested or prepared) is
//! refused, since its commands describe no real install. Nor does the daemon
//! verify launchers (`config/launchers.rs`), probe live model lists, read
//! the ACP Registry or add a harness while a fixture is set.
//!
//! Unset (every normal run), nothing here is read and every path is the
//! one it always was. A signed app never passes the variable to its daemon
//! (`AcpmuxDaemonLauncher.signedInheritedKeys`). A set variable whose file
//! cannot be read stops the daemon at start (`check`), so a capture never
//! silently shows the host's harnesses instead.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

use serde::Deserialize;

use crate::config::HarnessProfile;
use crate::harness_health::HarnessHealth;

pub mod matrix;

/// The variable that names the fixture file.
pub const ENV: &str = "ACPMUX_HARNESS_FIXTURE";

/// The largest fixture file read (a real one is a few KiB).
pub const MAX_BYTES: u64 = 1 << 20;

/// Why a requested update of a fixture harness is refused.
pub const REFUSAL: &str = "a capture fixture's harness: nothing is installed to update";

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Fixture {
    /// The harnesses PATH, `~/.acpx` and the ACP Registry would add.
    #[serde(default)]
    pub harnesses: BTreeMap<String, HarnessProfile>,
    /// The health rows `_acpmux/harness/health` serves.
    #[serde(default)]
    pub health: Vec<HarnessHealth>,
}

impl Fixture {
    /// Reads and parses a fixture file.
    /// The file itself, never a link (a capture app can write the folder
    /// that holds it).
    pub fn read(path: &Path) -> Result<Self, String> {
        let text = open_no_follow(path)
            .and_then(|file| {
                // A regular file only (never a FIFO or a device that never ends), read bounded.
                if !file.metadata()?.is_file() {
                    return Err(std::io::Error::other("not a regular file"));
                }
                let mut text = Vec::new();
                std::io::Read::read_to_end(
                    &mut std::io::Read::take(file, MAX_BYTES + 1),
                    &mut text,
                )?;
                if text.len() as u64 > MAX_BYTES {
                    return Err(std::io::Error::other(format!("over {MAX_BYTES} bytes")));
                }
                Ok(text)
            })
            .map_err(|e| format!("{ENV}: cannot read {}: {e}", path.display()))?;
        serde_json::from_slice(&text)
            .map_err(|e| format!("{ENV}: {} is not a harness fixture: {e}", path.display()))
    }

    /// Whether `id` is one of the fixture's harnesses (never started or probed).
    pub fn names(&self, id: &str) -> bool {
        self.harnesses.contains_key(id) || self.health.iter().any(|row| row.id == id)
    }
}

#[cfg(unix)]
fn open_no_follow(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
}

#[cfg(not(unix))]
fn open_no_follow(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::File::open(path)
}

/// The fixture file's outcome, read once per process: None when the
/// variable is unset or empty.
fn loaded() -> &'static Option<Result<Fixture, String>> {
    static LOADED: OnceLock<Option<Result<Fixture, String>>> = OnceLock::new();
    LOADED.get_or_init(|| {
        // Set but empty is a mistake, never "unset": the capture would show
        // this host's harnesses.
        let path = std::env::var_os(ENV)?;
        if path.is_empty() {
            return Some(Err(format!("{ENV} is set but empty")));
        }
        // `matrix:CELL` names a first-run state instead of a file (`matrix.rs`).
        if let Some(cell) = path.to_str().and_then(|p| p.strip_prefix(matrix::PREFIX)) {
            return Some(matrix::fixture(cell).map_err(|e| format!("{ENV}: {e}")));
        }
        Some(Fixture::read(Path::new(&path)))
    })
}

/// The fixture this process runs with, or None (the variable is unset).
/// It is per process: the daemon and the acpmux processes it starts read it
/// (the app passes it only to its daemon); a CLI run without the variable
/// sees the host as always. A
/// fixture that could not be read is an empty one here, so a client
/// process still reads nothing live; the daemon refuses to start (`check`).
pub fn active() -> Option<&'static Fixture> {
    static EMPTY: OnceLock<Fixture> = OnceLock::new();
    match loaded() {
        None => None,
        Some(Ok(fixture)) => Some(fixture),
        Some(Err(_)) => Some(EMPTY.get_or_init(Fixture::default)),
    }
}

/// The daemon's start check: an error when the variable is set and its file
/// cannot be read or parsed.
pub fn check() -> Result<(), String> {
    match loaded() {
        Some(Err(why)) => Err(why.clone()),
        Some(Ok(fixture)) => {
            tracing::warn!(
                harnesses = fixture.harnesses.len(),
                health = fixture.health.len(),
                "{ENV}: serving a capture fixture's harnesses; nothing about them is read from this machine"
            );
            Ok(())
        }
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests;
