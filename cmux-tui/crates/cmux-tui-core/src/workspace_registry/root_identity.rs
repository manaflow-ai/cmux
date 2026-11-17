//! Writes `machine-id` and `resource-effect-pepper` beside their place and
//! renames them in, so a full disk leaves each whole or absent. Earlier builds
//! wrote in place and ENOSPC left a short file that failed every later start;
//! such a file was never used (the value was returned only after its fsync),
//! so a cut one is replaced when nothing can depend on it.

use super::*;

/// Moves this process's SQLite temp files from `/var/tmp` to the first opened
/// registry's directory. On a Cloud machine that directory has reserved room,
/// while `/var/tmp` is on the root disk, where a spill on a full disk stops the
/// daemon. The setting is process-wide and read without a lock, so it is set once,
/// before the daemon's other connections exist. SQLite falls back to its default
/// when the directory is gone, and a failure here only keeps that default.
#[cfg(unix)]
pub(super) fn keep_sqlite_temp_files_beside(connection: &Connection, database: &Path) {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let Some(directory) = database.parent().and_then(Path::to_str) else {
            return;
        };
        let directory = directory.replace('\'', "''");
        if let Err(error) =
            connection.execute_batch(&format!("PRAGMA temp_store_directory='{directory}';"))
        {
            eprintln!("cmux-tui: SQLite temp files stay in their default directory: {error}");
        }
    });
}

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
/// edit) stays corrupt. A whole id is never matched, so one already handed
/// out is kept; only a file truncated by filesystem damage could be misread.
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
        // A registry from schema 7 on has receipts bound to the pepper: the
        // cut file stays, and the start fails closed. Before 7 it is replaced.
        for (schema, replaced) in
            [(None, true), (Some(6), true), (Some(7), false), (Some(14), false)]
        {
            let root = temp_root("pepper-cut");
            let session = root.join("session");
            fs::create_dir_all(&session).unwrap();
            if let Some(schema) = schema {
                Connection::open(session.join(WORKSPACE_REGISTRY_FILE))
                    .unwrap()
                    .execute_batch(&format!(
                        "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                         INSERT INTO meta VALUES('schema_version', '{schema}');"
                    ))
                    .unwrap();
            }
            fs::write(root.join(RESOURCE_EFFECT_PEPPER_FILE), b"cut").unwrap();
            let loaded = load_or_create_resource_effect_pepper(&root);
            let on_disk = fs::read(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
            if replaced {
                assert_eq!(on_disk, loaded.unwrap().0.as_ref(), "{schema:?}");
                assert!(!root.join("resource-effect-pepper.new").exists());
            } else {
                let error = format!("{:#}", loaded.err().expect("fails closed"));
                assert!(
                    error.contains("resource receipt pepper is corrupt"),
                    "{schema:?}: {error}"
                );
                assert_eq!(on_disk, b"cut", "{schema:?} keeps the file");
            }
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn sqlite_temp_files_leave_the_default_temp_directory_once_a_registry_opens() {
        // SQLite's default /var/tmp is on the root disk: a spill there on a full
        // root disk stopped the daemon with "database or disk is full".
        let root = temp_root("sqlite-temp");
        fs::create_dir_all(&root).unwrap();
        let connection = open_registry_database(&root.join("registry.sqlite3")).unwrap();
        let directory: String = connection
            .query_row("PRAGMA temp_store_directory", [], |row| row.get(0))
            .expect("SQLite reports no temp directory");
        assert!(!directory.is_empty(), "temp files still use SQLite's default directory");
        drop(connection);
        fs::remove_dir_all(root).unwrap();
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
}
