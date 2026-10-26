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

        // A registry from schema 7 on has receipts bound to the pepper: the
        // cut file stays, and the start fails closed. Before 7 it is replaced.
        for (schema, replaced) in [(6, true), (7, false), (9, false), (14, false)] {
            let root = temp_root("pepper-cut-registry");
            let session = root.join("session");
            fs::create_dir_all(&session).unwrap();
            let registry = Connection::open(session.join(WORKSPACE_REGISTRY_FILE)).unwrap();
            registry
                .execute_batch(&format!(
                    "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                     INSERT INTO meta VALUES('schema_version', '{schema}');"
                ))
                .unwrap();
            drop(registry);
            fs::write(root.join(RESOURCE_EFFECT_PEPPER_FILE), b"cut").unwrap();
            let loaded = load_or_create_resource_effect_pepper(&root);
            let on_disk = fs::read(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
            if replaced {
                assert_eq!(on_disk, loaded.unwrap().0.as_ref(), "schema {schema}");
            } else {
                let error = format!("{:#}", loaded.err().expect("fails closed"));
                assert!(error.contains("resource receipt pepper is corrupt"), "{schema}: {error}");
                assert_eq!(on_disk, b"cut", "schema {schema} keeps the file");
            }
            fs::remove_dir_all(root).unwrap();
        }
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
