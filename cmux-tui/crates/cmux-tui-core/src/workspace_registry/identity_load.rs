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
    // Unlocked when `_held` drops, on every return: a child another daemon thread forked
    // meanwhile shares the open file until it execs, and a close alone leaves the lock held.
    let _held = cmux_file_lock::FileLock::take(lock, cmux_file_lock::Kind::Exclusive)
        .with_context(|| format!("lock resource receipt pepper {}", lock_path.display()))?;

    let path = platform::normalize_filesystem_path(root.join(RESOURCE_EFFECT_PEPPER_FILE));
    match fs::symlink_metadata(&path) {
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
    }
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
    // Unlocked when `_held` drops, on every return (as in `pepper_under_lock`).
    let _held = cmux_file_lock::FileLock::take(lock, cmux_file_lock::Kind::Exclusive)
        .with_context(|| format!("lock machine identity {}", lock_path.display()))?;

    let path = platform::normalize_filesystem_path(root.join(MACHINE_ID_FILE));
    match fs::read(&path) {
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
    }
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
mod lock_tests;
