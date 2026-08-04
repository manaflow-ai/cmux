//! Hardened private-file persistence for identity and credential material.
//!
//! Mirrors the discipline of `cmux-tui/src/provider_notice_identity.rs`:
//! 0700 parent directories, 0600 files, `O_NOFOLLOW` opens, bounded reads,
//! and atomic replace via a same-directory temporary file.

use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};

pub const MAX_PRIVATE_FILE_BYTES: u64 = 64 * 1024;

#[cfg(unix)]
fn harden_open_options(options: &mut OpenOptions, create: bool) {
    use std::os::unix::fs::OpenOptionsExt;
    let mut flags = libc::O_NOFOLLOW | libc::O_CLOEXEC;
    if create {
        options.mode(0o600);
    } else {
        flags |= 0;
    }
    options.custom_flags(flags);
}

#[cfg(not(unix))]
fn harden_open_options(_options: &mut OpenOptions, _create: bool) {}

/// Creates `dir` (and parents) and enforces owner-only permissions on it.
pub fn ensure_private_dir(dir: &Path) -> anyhow::Result<()> {
    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let metadata = fs::symlink_metadata(dir)?;
        if !metadata.is_dir() {
            bail!("{} is not a directory", dir.display());
        }
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Reads a private file with a hard size bound. Returns `None` when absent.
pub fn read_private(path: &Path) -> anyhow::Result<Option<Vec<u8>>> {
    let mut options = OpenOptions::new();
    options.read(true);
    harden_open_options(&mut options, false);
    let mut file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).with_context(|| format!("opening {}", path.display())),
    };
    let metadata = file.metadata()?;
    if metadata.len() > MAX_PRIVATE_FILE_BYTES {
        bail!("{} exceeds the private-file size bound", path.display());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.nlink() != 1 {
            bail!("{} has unexpected hard links", path.display());
        }
    }
    let mut contents = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut contents)?;
    Ok(Some(contents))
}

/// Atomically replaces `path` with `contents`, owner-readable only.
pub fn write_private_atomic(path: &Path, contents: &[u8]) -> anyhow::Result<()> {
    let parent =
        path.parent().with_context(|| format!("{} has no parent directory", path.display()))?;
    ensure_private_dir(parent)?;
    let mut temp = temp_sibling(path)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    harden_open_options(&mut options, true);
    let mut attempts = 0;
    let mut file = loop {
        match options.open(&temp) {
            Ok(file) => break file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists && attempts < 8 => {
                attempts += 1;
                temp = temp_sibling(path)?;
            }
            Err(error) => {
                return Err(error).with_context(|| format!("creating {}", temp.display()));
            }
        }
    };
    let write_result = file
        .write_all(contents)
        .and_then(|()| file.sync_all())
        .with_context(|| format!("writing {}", temp.display()));
    if let Err(error) = write_result {
        drop(file);
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    drop(file);
    if let Err(error) = fs::rename(&temp, path) {
        let _ = fs::remove_file(&temp);
        return Err(error).with_context(|| format!("replacing {}", path.display()));
    }
    Ok(())
}

fn temp_sibling(path: &Path) -> anyhow::Result<PathBuf> {
    let mut random = [0u8; 8];
    getrandom::fill(&mut random).map_err(|error| anyhow::anyhow!("getrandom failed: {error}"))?;
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("private");
    let suffix: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(path.with_file_name(format!(".{name}.tmp-{suffix}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_then_read_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("device/identity.json");
        write_private_atomic(&path, b"{\"v\":1}").unwrap();
        assert_eq!(read_private(&path).unwrap().unwrap(), b"{\"v\":1}");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
            let dir_mode = fs::metadata(path.parent().unwrap()).unwrap().permissions().mode();
            assert_eq!(dir_mode & 0o777, 0o700);
        }
    }

    #[test]
    fn missing_file_reads_as_none() {
        let dir = tempfile::tempdir().unwrap();
        assert!(read_private(&dir.path().join("absent.json")).unwrap().is_none());
    }
}
