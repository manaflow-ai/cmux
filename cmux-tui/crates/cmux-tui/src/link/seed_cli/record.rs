//! This Mac's record of the last `cmux link seed push` of a folder to a
//! machine folder: whether it seeded or copied, the machine it went to, and
//! for a seed the commits the machine now has, so `--since-last` sends only
//! what changed since ([`super::super::seed::plan::plan_since`]).
//!
//! The record is `<state>/link-seed/<sha256 of folder NUL machine folder>.json`
//! (0600, its folder 0700), beside `cmux link sync`'s own record
//! (`<state>/link-sync`), written to a temporary name and renamed.

use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

/// How the last push put the folder on the machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Kept {
    /// A `git-seed-v1` seed (full or delta): the machine has its commits.
    Seed,
    /// The streamed copy (`cmux link sync push`), whose own record makes a
    /// re-push incremental.
    Copy,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Record {
    pub(super) mode: Kept,
    /// The machine daemon's store id (`identify`'s `session_id`), when it
    /// answered one.
    #[serde(default)]
    pub(super) machine: Option<String>,
    /// For a seed: the GitHub URL and the commits the machine has.
    #[serde(default)]
    pub(super) url: Option<String>,
    #[serde(default)]
    pub(super) head: Option<String>,
    #[serde(default)]
    pub(super) index: Option<String>,
    #[serde(default)]
    pub(super) work: Option<String>,
}

fn path_of(local: &Path, remote_root: &str) -> anyhow::Result<PathBuf> {
    let Some(state) = cmux_tui_core::platform::workspace_state_dir() else {
        bail!("this Mac has no state folder to keep the seed record in");
    };
    let mut key = Sha256::new();
    key.update(local.as_os_str().as_encoded_bytes());
    key.update([0]);
    key.update(remote_root.as_bytes());
    let name: String = key.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(state.join("link-seed").join(format!("{name}.json")))
}

/// The record of `local` pushed to `remote_root`; None when there is none.
pub(super) fn load(local: &Path, remote_root: &str) -> anyhow::Result<Option<Record>> {
    let path = path_of(local, remote_root)?;
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .with_context(|| format!("{} is not a seed record", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("cannot read {}", path.display())),
    }
}

/// Keeps `record` for `local` pushed to `remote_root`.
pub(super) fn save(local: &Path, remote_root: &str, record: &Record) -> anyhow::Result<()> {
    let path = path_of(local, remote_root)?;
    let dir = path.parent().context("no state folder")?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .with_context(|| format!("cannot make {}", dir.display()))?;
    let part = path.with_extension(format!("{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)
        .with_context(|| format!("cannot write {}", part.display()))?;
    file.write_all(&serde_json::to_vec(record)?)?;
    file.sync_all()?;
    std::fs::rename(&part, &path).with_context(|| format!("cannot write {}", path.display()))
}
