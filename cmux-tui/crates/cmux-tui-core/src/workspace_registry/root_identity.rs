//! Writes `machine-id` and `resource-effect-pepper` beside their place and
//! renames them in, so a full disk leaves each whole or absent. Earlier builds
//! wrote in place and ENOSPC left a short file that failed every later start;
//! such a file was never used (the value was returned only after its fsync),
//! so a cut one is replaced when nothing can depend on it.

use super::*;

/// Creates the pepper (see [`write_identity_file`] for `replace`).
pub(super) fn create_pepper(
    root: &Path,
    path: &Path,
    replace: bool,
) -> anyhow::Result<ResourceEffectPepper> {
    let pepper = ResourceEffectPepper::random()?;
    write_identity_file(root, path, pepper.0.as_ref(), replace)
        .with_context(|| format!("create resource receipt pepper {}", path.display()))?;
    Ok(pepper)
}

/// A pepper shorter than its 32 bytes: cut by a full disk in an earlier
/// build's in-place write. A registry from schema 7 on binds receipts to the
/// pepper (and 9-14 carry them through migration), so with one present it
/// stays corrupt; without one a new pepper replaces it.
pub(super) fn replace_cut_pepper(
    root: &Path,
    path: &Path,
    mut bytes: Vec<u8>,
) -> anyhow::Result<ResourceEffectPepper> {
    bytes.zeroize();
    ensure_no_registry_at(root, path, RESOURCE_EFFECT_PEPPER_SCHEMA_VERSION)
        .with_context(|| format!("resource receipt pepper is corrupt: {}", path.display()))?;
    create_pepper(root, path, true)
}

/// Creates the machine id (see [`write_identity_file`] for `replace`).
pub(super) fn create_machine_id(
    root: &Path,
    path: &Path,
    replace: bool,
) -> anyhow::Result<MachinePublicId> {
    let id = MachinePublicId::random()?;
    write_identity_file(root, path, format!("{}\n", id.as_str()).as_bytes(), replace)
        .with_context(|| format!("create machine identity {}", path.display()))?;
    Ok(id)
}

/// True for an empty file or a strict prefix of `machine_<32 hex>`: what an
/// in-place write cut by a full disk leaves. Any other bad text (a foreign
/// edit) stays corrupt.
pub(super) fn is_cut_machine_id(bytes: &[u8]) -> bool {
    let prefix = format!("{}_", MachinePublicId::PREFIX);
    let prefix = prefix.as_bytes();
    bytes.len() < prefix.len() + 32
        && bytes.iter().enumerate().all(|(index, byte)| match prefix.get(index) {
            Some(expected) => byte == expected,
            None => byte.is_ascii_digit() || (b'a'..=b'f').contains(byte),
        })
}

/// Writes `bytes` to `<path>.new`, owner-only, syncs it, and renames it to
/// `path`, then syncs `root`. Without `replace` an existing `path` is kept
/// and the write fails: the caller holds the file's lock and found it
/// absent, so only a writer that skips the lock gets here. The temporary
/// file is removed on any failure, and a stale one (a killed writer) is
/// replaced.
pub(super) fn write_identity_file(
    root: &Path,
    path: &Path,
    bytes: &[u8],
    replace: bool,
) -> anyhow::Result<()> {
    let mut name = path.file_name().context("identity path has no file name")?.to_os_string();
    name.push(".new");
    let temporary = path.with_file_name(name);
    let result = (|| -> anyhow::Result<()> {
        match fs::remove_file(&temporary) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        platform::restrict_file(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        if !replace {
            match fs::symlink_metadata(path) {
                Ok(_) => anyhow::bail!("{} appeared while it was written", path.display()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        fs::rename(&temporary, path)?;
        platform::sync_directory(root).with_context(|| format!("sync {}", root.display()))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests;
