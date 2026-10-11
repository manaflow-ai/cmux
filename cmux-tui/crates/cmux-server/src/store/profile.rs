//! Profiles: `profiles/<generation>/` with `bin/` (a symlink farm into the
//! store), `pkgs/<name>` (one link per package root), `packages.json`, the
//! manifest, its signature and its SHA-256. Links are relative, so a store
//! root can move.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{Error, IoContext, Result};
use crate::fsx;

/// One package in a profile.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub name: String,
    pub version: String,
    pub sha256: String,
}

/// What a profile records besides its links.
pub struct ProfileInput<'a> {
    pub generation: u64,
    pub entries: &'a [Entry],
    pub manifest: &'a [u8],
    pub signature: &'a [u8],
    /// Lowercase hex SHA-256 of `manifest`.
    pub manifest_sha256: &'a str,
}

pub fn profile_dir(profiles: &Path, generation: u64) -> PathBuf {
    profiles.join(generation.to_string())
}

/// Generations present under `profiles`, ascending.
pub fn generations(profiles: &Path) -> Vec<u64> {
    let mut out: Vec<u64> = fs::read_dir(profiles)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str().and_then(|n| n.parse().ok()))
        .filter(|g: &u64| profiles.join(g.to_string()).join("packages.json").is_file())
        .collect();
    out.sort_unstable();
    out
}

/// The generation `current` points at (`profiles/<g>`), if any.
pub fn current_generation(current: &Path) -> Option<u64> {
    let target = fs::read_link(current).ok()?;
    let mut parts = target.components();
    match (parts.next(), parts.next(), parts.next()) {
        (Some(a), Some(b), None) if a.as_os_str() == "profiles" => {
            b.as_os_str().to_str()?.parse().ok()
        }
        _ => None,
    }
}

pub fn read_entries(profile: &Path) -> Result<Vec<Entry>> {
    let path = profile.join("packages.json");
    let bytes = fs::read(&path).ctx(path.display())?;
    serde_json::from_slice(&bytes).map_err(|e| Error::internal(format!("{}: {e}", path.display())))
}

/// Builds the profile unless it exists with the same manifest. Returns
/// whether it was built. A profile with this generation but other manifest
/// bytes is refused (CI never signs two manifests with one sequence).
pub fn build(store: &Path, profiles: &Path, input: &ProfileInput<'_>) -> Result<bool> {
    let dir = profile_dir(profiles, input.generation);
    if fsx::exists_no_follow(&dir) {
        let recorded = fs::read_to_string(dir.join("manifest.sha256")).unwrap_or_default();
        if recorded.trim() == input.manifest_sha256 {
            return Ok(false);
        }
        return Err(Error::verification(format!(
            "profile {} exists with a different manifest; refusing",
            input.generation
        )));
    }
    fsx::ensure_dir(profiles, 0o755)?;
    let staging = fsx::temp_sibling(&dir, "staging");
    let result = fill(store, &staging, input).and_then(|()| {
        fs::rename(&staging, &dir).ctx(dir.display())?;
        crate::sys::fsync_dir(profiles).ctx(profiles.display())
    });
    if result.is_err() {
        let _ = fsx::remove_tree(&staging);
    }
    result.map(|()| true)
}

fn fill(store: &Path, staging: &Path, input: &ProfileInput<'_>) -> Result<()> {
    let bin = staging.join("bin");
    let pkgs = staging.join("pkgs");
    fsx::ensure_dir(&bin, 0o755)?;
    fsx::ensure_dir(&pkgs, 0o755)?;
    // From profiles/<g>/bin and profiles/<g>/pkgs, the store is ../../../store.
    let up = Path::new("../../../store");
    for entry in input.entries {
        let package = store.join(&entry.sha256);
        link(&up.join(&entry.sha256), &pkgs.join(&entry.name))?;
        let package_bin = package.join("bin");
        let Ok(files) = fs::read_dir(&package_bin) else { continue };
        let mut names: Vec<_> = files.flatten().map(|f| f.file_name()).collect();
        names.sort();
        for name in names {
            let at = bin.join(&name);
            if fsx::exists_no_follow(&at) {
                return Err(Error::rejected(format!(
                    "two packages provide bin/{}; refusing",
                    name.to_string_lossy()
                )));
            }
            link(&up.join(&entry.sha256).join("bin").join(&name), &at)?;
        }
    }
    crate::sys::fsync_dir(&bin).ctx(bin.display())?;
    crate::sys::fsync_dir(&pkgs).ctx(pkgs.display())?;
    let json =
        serde_json::to_vec_pretty(input.entries).map_err(|e| Error::internal(e.to_string()))?;
    fsx::atomic_write(&staging.join("packages.json"), &json, 0o644)?;
    fsx::atomic_write(&staging.join("manifest.json"), input.manifest, 0o644)?;
    fsx::atomic_write(&staging.join("manifest.json.sig"), input.signature, 0o644)?;
    let sha = format!("{}\n", input.manifest_sha256);
    fsx::atomic_write(&staging.join("manifest.sha256"), sha.as_bytes(), 0o644)
}

fn link(target: &Path, at: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, at).ctx(at.display())
    }
    #[cfg(not(unix))]
    {
        let _ = target;
        Err(Error::internal(format!("{}: profiles need a Unix platform", at.display())))
    }
}
