//! Loads or creates this state root's `resource-effect-pepper` and `machine-id`, each under its
//! own lock file beside it (moved out of `workspace_registry.rs` unchanged).

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
    pepper_under_lock(&root, lock, &lock_path)
}

/// [`load_or_create_resource_effect_pepper`] once the lock file `lock` is open: takes its lock,
/// loads or creates the pepper and lets the lock go.
fn pepper_under_lock(
    root: &Path,
    lock: File,
    lock_path: &Path,
) -> anyhow::Result<ResourceEffectPepper> {
    FileExt::lock(&lock)
        .with_context(|| format!("lock resource receipt pepper {}", lock_path.display()))?;

    let path = platform::normalize_filesystem_path(root.join(RESOURCE_EFFECT_PEPPER_FILE));
    let result = match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            anyhow::ensure!(
                metadata.file_type().is_file(),
                "resource receipt pepper is corrupt: {}",
                path.display()
            );
            platform::restrict_file(&path)?;
            let bytes = fs::read(&path)
                .with_context(|| format!("read resource receipt pepper {}", path.display()))?;
            if bytes.len() < RESOURCE_EFFECT_PEPPER_BYTES {
                root_identity::replace_cut_pepper(root, &path, bytes)
            } else {
                ResourceEffectPepper::from_bytes(bytes, &path)
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            ensure_missing_pepper_can_migrate(root, &path)?;
            root_identity::create_pepper(root, &path, false)
        }
        Err(error) => {
            Err(error).with_context(|| format!("read resource receipt pepper {}", path.display()))
        }
    };
    let _ = FileExt::unlock(&lock);
    result
}

fn ensure_missing_pepper_can_migrate(root: &Path, pepper_path: &Path) -> anyhow::Result<()> {
    ensure_no_registry_at(root, pepper_path, SCHEMA_VERSION)
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
    machine_id_under_lock(&root, lock, &lock_path)
}

/// [`load_or_create_machine_id`] once the lock file `lock` is open: takes its lock, loads or
/// creates the id and lets the lock go.
fn machine_id_under_lock(
    root: &Path,
    lock: File,
    lock_path: &Path,
) -> anyhow::Result<MachinePublicId> {
    FileExt::lock(&lock)
        .with_context(|| format!("lock machine identity {}", lock_path.display()))?;

    let path = platform::normalize_filesystem_path(root.join(MACHINE_ID_FILE));
    let result = match fs::read(&path) {
        // Cut by a full disk in an earlier build's in-place write: never
        // handed out (returned only after its fsync), so a new id replaces it.
        Ok(bytes) if root_identity::is_cut_machine_id(&bytes) => {
            root_identity::create_machine_id(root, &path, true)
                .and_then(|id| host_identity::machine_id_for_this_host(root, &path, id))
        }
        Ok(bytes) => {
            platform::restrict_file(&path)?;
            parse_machine_id_file(&path, &bytes)
                .and_then(|id| host_identity::machine_id_for_this_host(root, &path, id))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            root_identity::create_machine_id(root, &path, false)
                .and_then(|id| host_identity::machine_id_for_this_host(root, &path, id))
        }
        Err(error) => {
            Err(error).with_context(|| format!("read machine identity {}", path.display()))
        }
    };
    let _ = FileExt::unlock(&lock);
    result
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

#[cfg(all(test, unix))]
mod lock_tests {
    use super::*;

    fn opened(path: &Path) -> File {
        OpenOptions::new().create(true).truncate(false).read(true).write(true).open(path).unwrap()
    }

    /// A pepper load that fails after it took the pepper lock (the pepper path is a folder) lets
    /// the lock go, also while a child the server forked meanwhile keeps its descriptor: else
    /// the next registry open waits for that child.
    #[test]
    fn a_failed_pepper_load_leaves_its_lock_free_while_a_forked_child_keeps_its_descriptor() {
        let dir = crate::fork_tests::Scratch::new("pepper_lock");
        fs::create_dir(dir.path().join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
        let lock_path = dir.path().join(RESOURCE_EFFECT_PEPPER_LOCK_FILE);
        let lock = opened(&lock_path);
        let keeper = crate::fork_tests::Keeper::fork();
        let loaded = pepper_under_lock(dir.path(), lock, &lock_path);
        let free = crate::fork_tests::free(&lock_path);
        drop(keeper);
        assert!(loaded.is_err(), "a folder at the pepper path is no pepper");
        assert!(free, "a failed pepper load left its lock held");
    }

    /// A machine-id load that fails after it took the id lock (the id file cannot be made
    /// private: a link to a file of another owner) lets the lock go, also while a child the
    /// server forked meanwhile keeps its descriptor.
    #[test]
    fn a_failed_machine_id_load_leaves_its_lock_free_while_a_forked_child_keeps_its_descriptor() {
        let dir = crate::fork_tests::Scratch::new("machine_id_lock");
        std::os::unix::fs::symlink("/etc/hosts", dir.path().join(MACHINE_ID_FILE)).unwrap();
        let lock_path = dir.path().join(MACHINE_ID_LOCK_FILE);
        let lock = opened(&lock_path);
        let keeper = crate::fork_tests::Keeper::fork();
        let loaded = machine_id_under_lock(dir.path(), lock, &lock_path);
        let free = crate::fork_tests::free(&lock_path);
        drop(keeper);
        assert!(loaded.is_err(), "a file of another owner cannot be made private");
        assert!(free, "a failed machine-id load left its lock held");
    }
}
