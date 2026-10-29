//! This Mac's copy of the sync record (the [`Manifest`]) a push left on a
//! machine, kept in this Mac's state folder by local folder and machine
//! folder. A pull's three-way merge takes its base from this copy only: a
//! machine that claims the push sent a file it never sent would otherwise
//! choose which files here a pull overwrites or deletes. A pull with no copy
//! here, or whose machine's record differs from it, brings nothing back.
//!
//! The copy is `<state>/link-sync/<sha256 of folder NUL machine folder>.json`
//! (0600, its folder 0700), written to a temporary name and renamed.

use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use anyhow::{Context as _, bail};
use sha2::{Digest as _, Sha256};

use super::Manifest;

/// No copy of the record is kept here for this folder and machine folder.
#[derive(Debug)]
pub(super) struct NoBase;

impl std::fmt::Display for NoBase {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("no sync push from this Mac left this folder on the machine")
    }
}

impl std::error::Error for NoBase {}

/// The machine's record differs from the copy kept here.
#[derive(Debug)]
pub(super) struct Mismatch;

impl std::fmt::Display for Mismatch {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(
            "the machine's sync record differs from the one this Mac kept; nothing was brought back",
        )
    }
}

impl std::error::Error for Mismatch {}

fn path_of(local: &Path, remote_root: &str) -> anyhow::Result<PathBuf> {
    let Some(state) = cmux_tui_core::platform::workspace_state_dir() else {
        bail!("this Mac has no state folder to keep the sync record in");
    };
    let mut key = Sha256::new();
    key.update(local.as_os_str().as_encoded_bytes());
    key.update([0]);
    key.update(remote_root.as_bytes());
    let name: String = key.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(state.join("link-sync").join(format!("{name}.json")))
}

/// Keeps `manifest` as the base of `local` synced to `remote_root`.
pub(super) fn save(local: &Path, remote_root: &str, manifest: &Manifest) -> anyhow::Result<()> {
    let path = path_of(local, remote_root)?;
    let dir = path.parent().context("no state folder")?;
    crate::blocking::fs::create_dir_with(
        std::fs::DirBuilder::new().recursive(true).mode(0o700),
        dir,
    )
    .with_context(|| format!("cannot make {}", dir.display()))?;
    let part = path.with_extension(format!("{}.part", std::process::id()));
    let _ = cmux_blocking::fs::remove_file(&part);
    let mut file = crate::blocking::fs::open_with(
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW),
        &part,
    )
    .with_context(|| format!("cannot write {}", part.display()))?;
    file.write_all(&serde_json::to_vec(manifest)?)?;
    crate::blocking::fs::sync_all(&file)?;
    cmux_blocking::fs::rename(&part, &path)
        .with_context(|| format!("cannot write {}", path.display()))
}

/// The base of `local` synced to `remote_root`, checked against the
/// machine's own record (`machine`, None when it has none).
pub(super) fn trusted(
    local: &Path,
    remote_root: &str,
    machine: Option<&[u8]>,
) -> anyhow::Result<Manifest> {
    let path = path_of(local, remote_root)?;
    let kept = match cmux_blocking::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Err(NoBase.into()),
        Err(error) => return Err(error).with_context(|| format!("cannot read {}", path.display())),
    };
    let kept: Manifest = serde_json::from_slice(&kept)
        .with_context(|| format!("{} is not a sync record", path.display()))?;
    let machine: Option<Manifest> = machine.and_then(|bytes| serde_json::from_slice(bytes).ok());
    if machine.as_ref() != Some(&kept) {
        return Err(Mismatch.into());
    }
    Ok(kept)
}
