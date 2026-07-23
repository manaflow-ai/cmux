use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use cmux_tui_machine_agent_protocol::{MachineSecret, OpaqueId, SessionName};
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

const STATE_VERSION: u16 = 1;
const MAX_STATE_BYTES: u64 = 4096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MachineIdentity {
    pub machine_id: OpaqueId,
    pub secret: MachineSecret,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredIdentity {
    version: u16,
    machine_id: OpaqueId,
    secret: MachineSecret,
}

pub(super) fn load_or_create(path: &Path) -> anyhow::Result<MachineIdentity> {
    ensure_private_parent(path)?;
    match fs::symlink_metadata(path) {
        Ok(_) => {
            remove_orphaned_temporary_links(path)?;
            load(path)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => create(path),
        Err(error) => Err(error.into()),
    }
}

fn remove_orphaned_temporary_links(path: &Path) -> anyhow::Result<()> {
    let target = fs::symlink_metadata(path)?;
    if !target.file_type().is_file()
        || target.uid() != unsafe { libc::geteuid() }
        || target.permissions().mode() & 0o777 != 0o600
    {
        return Ok(());
    }
    let parent =
        path.parent().ok_or_else(|| anyhow::anyhow!("machine-agent state path has no parent"))?;
    let file_name =
        path.file_name().ok_or_else(|| anyhow::anyhow!("machine-agent state path has no name"))?;
    let prefix = format!(".{}.", file_name.to_string_lossy());
    let suffix = ".tmp";
    let mut removed = false;
    for entry in fs::read_dir(parent)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with(&prefix)
            || !name.ends_with(suffix)
            || name.len() <= prefix.len() + suffix.len()
        {
            continue;
        }
        let candidate = fs::symlink_metadata(entry.path())?;
        if candidate.file_type().is_file()
            && candidate.dev() == target.dev()
            && candidate.ino() == target.ino()
        {
            match fs::remove_file(entry.path()) {
                Ok(()) => removed = true,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
    }
    if removed {
        sync_directory(parent)?;
    }
    Ok(())
}

fn load(path: &Path) -> anyhow::Result<MachineIdentity> {
    let mut file = open_no_follow(path, false)?;
    verify_private_file(&file, "machine-agent state")?;
    let mut encoded = Vec::new();
    if let Err(error) = Read::by_ref(&mut file).take(MAX_STATE_BYTES + 1).read_to_end(&mut encoded)
    {
        encoded.zeroize();
        return Err(error.into());
    }
    if encoded.len() as u64 > MAX_STATE_BYTES {
        encoded.zeroize();
        anyhow::bail!("machine-agent state file is too large");
    }
    let stored = serde_json::from_slice::<StoredIdentity>(&encoded);
    encoded.zeroize();
    let stored = stored?;
    if stored.version != STATE_VERSION {
        anyhow::bail!("unsupported machine-agent state version {}", stored.version);
    }
    Ok(MachineIdentity { machine_id: stored.machine_id, secret: stored.secret })
}

fn create(path: &Path) -> anyhow::Result<MachineIdentity> {
    let parent =
        path.parent().ok_or_else(|| anyhow::anyhow!("machine-agent state path has no parent"))?;
    let identity = MachineIdentity {
        machine_id: OpaqueId::new(format!("machine-{}", random_hex(16)?))?,
        secret: MachineSecret::new(random_hex(32)?)?,
    };
    let stored = StoredIdentity {
        version: STATE_VERSION,
        machine_id: identity.machine_id.clone(),
        secret: identity.secret.clone(),
    };
    let mut encoded = serde_json::to_vec_pretty(&stored)?;
    encoded.push(b'\n');
    let temporary = temporary_path(path)?;
    let write_result = (|| -> anyhow::Result<bool> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary)?;
        verify_private_file(&file, "temporary machine-agent state")?;
        file.write_all(&encoded)?;
        file.sync_all()?;
        match fs::hard_link(&temporary, path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => return Ok(false),
            Err(error) => return Err(error.into()),
        }
        fs::remove_file(&temporary)?;
        sync_directory(parent)?;
        Ok(true)
    })();
    encoded.zeroize();
    if !matches!(write_result, Ok(true)) {
        let _ = fs::remove_file(&temporary);
    }
    if write_result? {
        let loaded = load(path)?;
        if loaded != identity {
            anyhow::bail!("machine-agent state changed while it was being created");
        }
        Ok(loaded)
    } else {
        load(path)
    }
}

fn open_no_follow(path: &Path, write: bool) -> io::Result<File> {
    OpenOptions::new()
        .read(!write)
        .write(write)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

fn ensure_private_parent(path: &Path) -> anyhow::Result<()> {
    let parent =
        path.parent().ok_or_else(|| anyhow::anyhow!("machine-agent state path has no parent"))?;
    match fs::symlink_metadata(parent) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let mut builder = DirBuilder::new();
            builder.recursive(true).mode(0o700);
            builder.create(parent)?;
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
        }
        Err(error) => return Err(error.into()),
    }
    let metadata = fs::symlink_metadata(parent)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        anyhow::bail!("machine-agent state directory must be a real directory");
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        anyhow::bail!("machine-agent state directory must be owned by the current user");
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        anyhow::bail!("machine-agent state directory must not be accessible by group or others");
    }
    Ok(())
}

fn verify_private_file(file: &File, label: &str) -> anyhow::Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        anyhow::bail!("{label} must be a regular file");
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        anyhow::bail!("{label} must be owned by the current user");
    }
    if metadata.permissions().mode() & 0o777 != 0o600 {
        anyhow::bail!("{label} file must have mode 0600");
    }
    if metadata.nlink() != 1 {
        anyhow::bail!("{label} file must have exactly one link");
    }
    Ok(())
}

pub(super) struct RegistrationLock {
    file: File,
}

impl Drop for RegistrationLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

pub(super) fn acquire_registration_lock(
    state_path: &Path,
    identity: &MachineIdentity,
    session: &SessionName,
) -> anyhow::Result<RegistrationLock> {
    ensure_private_parent(state_path)?;
    let parent = state_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("machine-agent state path has no parent"))?;
    let lock_path = parent.join(format!(
        "registration-{}-{}.lock",
        identity.machine_id.as_str(),
        session.as_str()
    ));
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&lock_path)?;
    verify_private_file(&file, "machine-agent registration lock")?;
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result != 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::WouldBlock {
            anyhow::bail!(
                "a machine agent is already running for session {:?}; stop it before starting another",
                session.as_str()
            );
        }
        return Err(error.into());
    }
    Ok(RegistrationLock { file })
}

fn temporary_path(path: &Path) -> anyhow::Result<PathBuf> {
    let file_name =
        path.file_name().ok_or_else(|| anyhow::anyhow!("machine-agent state path has no name"))?;
    for _ in 0..16 {
        let candidate =
            path.with_file_name(format!(".{}.{}.tmp", file_name.to_string_lossy(), random_hex(8)?));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    anyhow::bail!("could not allocate a private machine-agent state path")
}

fn random_hex(length: usize) -> anyhow::Result<String> {
    let mut bytes = vec![0u8; length];
    getrandom::fill(&mut bytes)
        .map_err(|_| anyhow::anyhow!("could not generate machine-agent identity"))?;
    let mut encoded = String::with_capacity(length * 2);
    use std::fmt::Write as _;
    for byte in &bytes {
        write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
    }
    bytes.zeroize();
    Ok(encoded)
}

fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::fs::symlink;

    use super::*;

    struct TestState {
        directory: PathBuf,
        path: PathBuf,
    }

    impl Drop for TestState {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }

    fn test_state(name: &str) -> TestState {
        let directory = std::env::temp_dir().join(format!(
            "cmux-machine-agent-{name}-{}-{}",
            std::process::id(),
            random_hex(8).unwrap()
        ));
        let mut builder = DirBuilder::new();
        builder.mode(0o700).create(&directory).unwrap();
        let path = directory.join("identity.json");
        TestState { directory, path }
    }

    #[test]
    fn identity_is_stable_private_and_contains_no_pairing_code() {
        let state = test_state("identity");
        let private_directory = state.directory.join("created");
        let path = private_directory.join("identity.json");
        let first = load_or_create(&path).unwrap();
        let second = load_or_create(&path).unwrap();
        assert_eq!(first, second);
        assert_eq!(fs::metadata(&private_directory).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(&path).unwrap().nlink(), 1);
        let contents = fs::read_to_string(&path).unwrap();
        assert!(!contents.contains("pairing"));
        assert!(!contents.contains("ABCD-EFGH"));
    }

    #[test]
    fn identity_rejects_permissive_hardlinked_or_symlinked_state() {
        let state = test_state("permissions");
        let identity = load_or_create(&state.path).unwrap();
        drop(identity);
        fs::set_permissions(&state.path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(load_or_create(&state.path).is_err());
        fs::set_permissions(&state.path, fs::Permissions::from_mode(0o600)).unwrap();

        let second_link = state.directory.join("second-link.json");
        fs::hard_link(&state.path, &second_link).unwrap();
        assert!(load_or_create(&state.path).is_err());
        fs::remove_file(second_link).unwrap();

        let target = state.directory.join("target.json");
        fs::rename(&state.path, &target).unwrap();
        symlink(&target, &state.path).unwrap();
        assert!(load_or_create(&state.path).is_err());
    }

    #[test]
    fn identity_recovers_only_its_orphaned_temporary_hardlinks() {
        let state = test_state("orphaned-temporary-link");
        let identity = load_or_create(&state.path).unwrap();
        let orphan = state.directory.join(".identity.json.crashed.tmp");
        fs::hard_link(&state.path, &orphan).unwrap();
        assert_eq!(fs::metadata(&state.path).unwrap().nlink(), 2);

        assert_eq!(load_or_create(&state.path).unwrap(), identity);
        assert!(!orphan.exists());
        assert_eq!(fs::metadata(&state.path).unwrap().nlink(), 1);

        let unrelated = state.directory.join(".identity.json.unrelated.tmp");
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(&unrelated).unwrap();
        assert_eq!(load_or_create(&state.path).unwrap(), identity);
        assert!(unrelated.exists());
    }

    #[test]
    fn identity_rejects_permissive_or_symlinked_parent() {
        let state = test_state("parent");
        fs::set_permissions(&state.directory, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(load_or_create(&state.path).is_err());
        fs::set_permissions(&state.directory, fs::Permissions::from_mode(0o700)).unwrap();

        let real = state.directory.join("real");
        let link = state.directory.join("link");
        DirBuilder::new().mode(0o700).create(&real).unwrap();
        symlink(&real, &link).unwrap();
        assert!(load_or_create(&link.join("identity.json")).is_err());
    }

    #[test]
    fn registration_lock_is_exclusive_per_identity_and_session() {
        let state = test_state("lock");
        let identity = load_or_create(&state.path).unwrap();
        let session = SessionName::new("agents").unwrap();
        let first = acquire_registration_lock(&state.path, &identity, &session).unwrap();
        let second = acquire_registration_lock(&state.path, &identity, &session);
        assert!(second.err().unwrap().to_string().contains("already running"));
        let other_session = SessionName::new("other").unwrap();
        let other = acquire_registration_lock(&state.path, &identity, &other_session).unwrap();
        drop(other);
        drop(first);
        acquire_registration_lock(&state.path, &identity, &session).unwrap();
    }
}
