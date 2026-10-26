//! The state root's identity files: `machine-id` (this machine's public id)
//! and `resource-effect-pepper` (the secret behind resource receipt HMACs).
//!
//! Each is created once and never rewritten. A new file is written beside
//! its place (`<name>.new`), synced, and renamed in, so a full disk leaves
//! the file whole or absent, never cut. Earlier builds wrote it in place: a
//! write cut by ENOSPC left a short file, and every later start failed on
//! it as corrupt. Such a file was never used (those builds returned the
//! value only after the write and its fsync succeeded), so a cut one is
//! replaced when nothing can depend on it (see each loader).

use super::*;

pub(super) fn load_or_create_resource_effect_pepper(
    root: &Path,
) -> anyhow::Result<ResourceEffectPepper> {
    let root = platform::normalize_filesystem_path(root.to_path_buf());
    fs::create_dir_all(&root).with_context(|| format!("create state root {}", root.display()))?;
    platform::restrict_directory(&root)?;
    let lock_path =
        platform::normalize_filesystem_path(root.join(RESOURCE_EFFECT_PEPPER_LOCK_FILE));
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("open resource receipt pepper lock {}", lock_path.display()))?;
    platform::restrict_file(&lock_path)?;
    FileExt::lock(&lock)
        .with_context(|| format!("lock resource receipt pepper {}", lock_path.display()))?;

    let path = platform::normalize_filesystem_path(root.join(RESOURCE_EFFECT_PEPPER_FILE));
    let create = |replace: bool| -> anyhow::Result<ResourceEffectPepper> {
        let pepper = ResourceEffectPepper::random()?;
        write_identity_file(&root, &path, pepper.0.as_ref(), replace)
            .with_context(|| format!("create resource receipt pepper {}", path.display()))?;
        Ok(pepper)
    };
    let result = match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            anyhow::ensure!(
                metadata.file_type().is_file(),
                "resource receipt pepper is corrupt: {}",
                path.display()
            );
            platform::restrict_file(&path)?;
            let mut bytes = fs::read(&path)
                .with_context(|| format!("read resource receipt pepper {}", path.display()))?;
            if bytes.len() < RESOURCE_EFFECT_PEPPER_BYTES {
                // Cut by a full disk in an earlier build's in-place write.
                // A registry at the current schema binds its receipts to
                // the pepper, so with one present this stays corrupt.
                bytes.zeroize();
                match ensure_missing_pepper_can_migrate(&root, &path) {
                    Ok(()) => create(true),
                    Err(error) => Err(error).with_context(|| {
                        format!("resource receipt pepper is corrupt: {}", path.display())
                    }),
                }
            } else {
                ResourceEffectPepper::from_bytes(bytes, &path)
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            ensure_missing_pepper_can_migrate(&root, &path)?;
            create(false)
        }
        Err(error) => {
            Err(error).with_context(|| format!("read resource receipt pepper {}", path.display()))
        }
    };
    let _ = FileExt::unlock(&lock);
    result
}

pub(super) fn load_or_create_machine_id(root: &Path) -> anyhow::Result<MachinePublicId> {
    let root = platform::normalize_filesystem_path(root.to_path_buf());
    fs::create_dir_all(&root).with_context(|| format!("create state root {}", root.display()))?;
    platform::restrict_directory(&root)?;
    let lock_path = platform::normalize_filesystem_path(root.join(MACHINE_ID_LOCK_FILE));
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("open machine identity lock {}", lock_path.display()))?;
    platform::restrict_file(&lock_path)?;
    FileExt::lock(&lock)
        .with_context(|| format!("lock machine identity {}", lock_path.display()))?;

    let path = platform::normalize_filesystem_path(root.join(MACHINE_ID_FILE));
    let create = |replace: bool| -> anyhow::Result<MachinePublicId> {
        let id = MachinePublicId::random()?;
        write_identity_file(&root, &path, format!("{}\n", id.as_str()).as_bytes(), replace)
            .with_context(|| format!("create machine identity {}", path.display()))?;
        Ok(id)
    };
    let result = match fs::read(&path) {
        // The id is public and no registry row holds it; a cut one was
        // never handed to a client, so a new one replaces it.
        Ok(bytes) if is_cut_machine_id(&bytes) => create(true),
        Ok(bytes) => {
            platform::restrict_file(&path)?;
            parse_machine_id_file(&path, &bytes)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => create(false),
        Err(error) => {
            Err(error).with_context(|| format!("read machine identity {}", path.display()))
        }
    };
    let _ = FileExt::unlock(&lock);
    result
}

/// True for an empty file or a strict prefix of `machine_<32 hex>`: what an
/// in-place write cut by a full disk leaves. Any other bad text (a foreign
/// edit) stays corrupt.
fn is_cut_machine_id(bytes: &[u8]) -> bool {
    let prefix = format!("{}_", MachinePublicId::PREFIX);
    let prefix = prefix.as_bytes();
    bytes.len() < prefix.len() + 32
        && bytes.iter().enumerate().all(|(index, byte)| match prefix.get(index) {
            Some(expected) => byte == expected,
            None => byte.is_ascii_digit() || (b'a'..=b'f').contains(byte),
        })
}

fn parse_machine_id_file(path: &Path, bytes: &[u8]) -> anyhow::Result<MachinePublicId> {
    let content = std::str::from_utf8(bytes)
        .with_context(|| format!("machine identity is not UTF-8: {}", path.display()))?;
    let value = content.strip_suffix('\n').unwrap_or(content);
    anyhow::ensure!(
        !value.is_empty()
            && !value.contains('\n')
            && !value.contains('\r')
            && value.trim() == value,
        "machine identity file is corrupt: {}",
        path.display()
    );
    MachinePublicId::parse(value)
        .with_context(|| format!("machine identity file is corrupt: {}", path.display()))
}

/// Writes `bytes` to `<path>.new`, owner-only, syncs it, and renames it to
/// `path`, then syncs `root`. Without `replace` an existing `path` is kept
/// and the write fails: the caller holds the file's lock and found it
/// absent, so only a writer that skips the lock gets here. The temporary
/// file is removed on any failure, and a stale one (a killed writer) is
/// replaced.
fn write_identity_file(
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
mod tests {
    use super::*;

    fn temp_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("cmux-root-identity-{label}-{}", new_uuid_v4()))
    }

    #[test]
    fn a_machine_id_cut_by_a_full_disk_is_replaced_and_a_foreign_one_is_not() {
        for cut in [&b""[..], b"mach", b"machine_", b"machine_0123abcd"] {
            let root = temp_root("machine-cut");
            fs::create_dir_all(&root).unwrap();
            fs::write(root.join(MACHINE_ID_FILE), cut).unwrap();
            let id = load_or_create_machine_id(&root).unwrap();
            let written = fs::read(root.join(MACHINE_ID_FILE)).unwrap();
            assert_eq!(written, format!("{}\n", id.as_str()).into_bytes());
            assert_eq!(load_or_create_machine_id(&root).unwrap(), id, "created once");
            assert!(!root.join("machine-id.new").exists());
            fs::remove_dir_all(root).unwrap();
        }
        assert!(!is_cut_machine_id(b"machine_not-an-id\n"));
        assert!(!is_cut_machine_id(b"machine_0123\n"));
        assert!(!is_cut_machine_id(b"xmachine_"));
        assert!(!is_cut_machine_id(format!("machine_{}", "a".repeat(32)).as_bytes()));
    }

    #[test]
    fn a_pepper_cut_by_a_full_disk_is_replaced_only_without_a_registry() {
        let root = temp_root("pepper-cut");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join(RESOURCE_EFFECT_PEPPER_FILE), b"").unwrap();
        let pepper = load_or_create_resource_effect_pepper(&root).unwrap();
        let written = fs::read(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
        assert_eq!(written, pepper.0.as_ref());
        let again = load_or_create_resource_effect_pepper(&root).unwrap();
        assert_eq!(again.0.as_ref(), pepper.0.as_ref(), "created once");
        assert!(!root.join("resource-effect-pepper.new").exists());
        fs::remove_dir_all(root).unwrap();
        // With a registry at the current schema it stays corrupt
        // (`resource_effect_pepper_missing_corrupt_and_mismatch_fail_closed`).
    }

    #[test]
    fn an_identity_write_never_replaces_a_file_and_leaves_no_temporary() {
        let root = temp_root("identity-write");
        fs::create_dir_all(&root).unwrap();
        let path = root.join(MACHINE_ID_FILE);
        // A stale temporary file from a killed writer does not block one.
        fs::write(root.join("machine-id.new"), b"stale").unwrap();
        write_identity_file(&root, &path, b"first\n", false).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"first\n");
        let error = write_identity_file(&root, &path, b"second\n", false).unwrap_err();
        assert!(error.to_string().contains("appeared while it was written"), "{error:#}");
        assert_eq!(fs::read(&path).unwrap(), b"first\n");
        assert!(!root.join("machine-id.new").exists());
        write_identity_file(&root, &path, b"third\n", true).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"third\n");
        // A failed write (here the target is a directory) leaves nothing beside it.
        let blocked = root.join("blocked");
        fs::create_dir_all(blocked.join("child")).unwrap();
        assert!(write_identity_file(&root, &blocked, b"x", true).is_err());
        assert!(!root.join("blocked.new").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn identity_files_are_written_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let root = temp_root("identity-mode");
        load_or_create_machine_id(&root).unwrap();
        load_or_create_resource_effect_pepper(&root).unwrap();
        for name in [MACHINE_ID_FILE, RESOURCE_EFFECT_PEPPER_FILE] {
            let mode = fs::metadata(root.join(name)).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "{name}");
        }
        fs::remove_dir_all(root).unwrap();
    }
}
