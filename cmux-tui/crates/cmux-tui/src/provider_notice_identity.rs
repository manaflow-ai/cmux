use std::fmt;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use cmux_tui_machine_protocol::OpaqueId;
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

const IDENTITY_DIRECTORY: &str = "device";
const IDENTITY_FILE: &str = "provider-notice-consumer.json";
const LOCK_FILE: &str = "provider-notice-consumer.lock";
const STATE_VERSION: u16 = 1;
const MAX_STATE_BYTES: u64 = 4096;

#[derive(Debug)]
struct UnexpectedLinkCount(u64);

impl fmt::Display for UnexpectedLinkCount {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "private file must have exactly one link, found {}", self.0)
    }
}

impl std::error::Error for UnexpectedLinkCount {}

struct IdentityLeaseLock {
    file: File,
}

#[derive(Debug)]
pub(super) struct ProviderNoticeIdentityInUse;

impl fmt::Display for ProviderNoticeIdentityInUse {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("provider notice identity is already in use")
    }
}

impl std::error::Error for ProviderNoticeIdentityInUse {}

pub(super) struct ProviderNoticeIdentityLease {
    consumer_id: OpaqueId,
    _lock: IdentityLeaseLock,
}

impl ProviderNoticeIdentityLease {
    pub(super) fn consumer_id(&self) -> &OpaqueId {
        &self.consumer_id
    }
}

impl IdentityLeaseLock {
    fn acquire(identity_path: &Path) -> anyhow::Result<Self> {
        let lock_path = state_parent(identity_path)?.join(LOCK_FILE);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(lock_path)?;
        verify_private_file(&file, "provider notice identity lock")?;
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                return Err(ProviderNoticeIdentityInUse.into());
            }
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error.into());
            }
        }
        Ok(Self { file })
    }
}

impl Drop for IdentityLeaseLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredIdentity {
    version: u16,
    consumer_id: OpaqueId,
}

pub(super) fn acquire(state_root: &Path) -> anyhow::Result<ProviderNoticeIdentityLease> {
    let path = identity_path(state_root);
    ensure_private_parent(&path)?;
    let lock = IdentityLeaseLock::acquire(&path)?;
    let consumer_id = match fs::symlink_metadata(&path) {
        Ok(_) => {
            remove_orphaned_temporary_links(&path)?;
            load(&path)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => create(&path),
        Err(error) => Err(error.into()),
    }?;
    Ok(ProviderNoticeIdentityLease { consumer_id, _lock: lock })
}

fn identity_path(state_root: &Path) -> PathBuf {
    identity_parent(state_root).join(IDENTITY_FILE)
}

pub(super) fn identity_parent(state_root: &Path) -> PathBuf {
    state_root.join(IDENTITY_DIRECTORY)
}

fn remove_orphaned_temporary_links(path: &Path) -> anyhow::Result<()> {
    let target = fs::symlink_metadata(path)?;
    if !target.file_type().is_file()
        || target.uid() != unsafe { libc::geteuid() }
        || target.permissions().mode() & 0o777 != 0o600
    {
        return Ok(());
    }
    let parent = state_parent(path)?;
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow::anyhow!("provider notice identity path has no name"))?;
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

fn load(path: &Path) -> anyhow::Result<OpaqueId> {
    let mut file = open_no_follow(path)?;
    verify_private_file(&file, "provider notice identity")?;
    let mut encoded = Vec::new();
    if let Err(error) = Read::by_ref(&mut file).take(MAX_STATE_BYTES + 1).read_to_end(&mut encoded)
    {
        encoded.zeroize();
        return Err(error.into());
    }
    if encoded.len() as u64 > MAX_STATE_BYTES {
        encoded.zeroize();
        anyhow::bail!("provider notice identity file is too large");
    }
    let stored = serde_json::from_slice::<StoredIdentity>(&encoded);
    encoded.zeroize();
    let stored = stored?;
    if stored.version != STATE_VERSION {
        anyhow::bail!("unsupported provider notice identity version {}", stored.version);
    }
    Ok(stored.consumer_id)
}

fn create(path: &Path) -> anyhow::Result<OpaqueId> {
    let parent = state_parent(path)?;
    let consumer_id = OpaqueId::new(format!("cmux-tui-{}", random_hex(16)?))?;
    let stored = StoredIdentity { version: STATE_VERSION, consumer_id: consumer_id.clone() };
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
        verify_private_file(&file, "temporary provider notice identity")?;
        file.write_all(&encoded)?;
        file.sync_all()?;
        match fs::hard_link(&temporary, path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => return Ok(false),
            Err(error) => return Err(error.into()),
        }
        match fs::remove_file(&temporary) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        sync_directory(parent)?;
        Ok(true)
    })();
    encoded.zeroize();
    if !matches!(write_result, Ok(true)) {
        let _ = fs::remove_file(&temporary);
    }
    if write_result? {
        let loaded = load(path)?;
        if loaded != consumer_id {
            anyhow::bail!("provider notice identity changed while it was being created");
        }
        Ok(loaded)
    } else {
        load(path)
    }
}

fn open_no_follow(path: &Path) -> io::Result<File> {
    OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(path)
}

fn ensure_private_parent(path: &Path) -> anyhow::Result<()> {
    let parent = state_parent(path)?;
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
        anyhow::bail!("provider notice identity directory must be a real directory");
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        anyhow::bail!("provider notice identity directory must be owned by the current user");
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        anyhow::bail!(
            "provider notice identity directory must not be accessible by group or others"
        );
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
        return Err(UnexpectedLinkCount(metadata.nlink()).into());
    }
    Ok(())
}

fn temporary_path(path: &Path) -> anyhow::Result<PathBuf> {
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow::anyhow!("provider notice identity path has no name"))?;
    for _ in 0..16 {
        let candidate =
            path.with_file_name(format!(".{}.{}.tmp", file_name.to_string_lossy(), random_hex(8)?));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    anyhow::bail!("could not allocate a private provider notice identity path")
}

fn state_parent(path: &Path) -> anyhow::Result<&Path> {
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => Ok(parent),
        Some(_) => Ok(Path::new(".")),
        None => anyhow::bail!("provider notice identity path has no parent"),
    }
}

fn random_hex(length: usize) -> anyhow::Result<String> {
    let mut bytes = vec![0_u8; length];
    getrandom::fill(&mut bytes)
        .map_err(|_| anyhow::anyhow!("could not generate provider notice identity"))?;
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
    use std::os::unix::fs::{PermissionsExt, symlink};

    use super::*;

    struct TestStateRoot {
        path: PathBuf,
    }

    impl TestStateRoot {
        fn create(label: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "cmux-provider-notice-identity-{label}-{}-{}",
                std::process::id(),
                random_hex(8).unwrap()
            ));
            let mut builder = DirBuilder::new();
            builder.mode(0o700).create(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TestStateRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn load_once(state_root: &Path) -> anyhow::Result<OpaqueId> {
        let lease = acquire(state_root)?;
        Ok(lease.consumer_id().clone())
    }

    #[test]
    fn identity_is_stable_and_private() {
        let state = TestStateRoot::create("private");
        let first = load_once(&state.path).unwrap();
        let second = load_once(&state.path).unwrap();
        let path = identity_path(&state.path);
        let parent = path.parent().unwrap();
        let lock = parent.join(LOCK_FILE);

        assert_eq!(second, first);
        assert_eq!(fs::metadata(parent).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(&path).unwrap().nlink(), 1);
        assert_eq!(fs::metadata(&lock).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(&lock).unwrap().nlink(), 1);
    }

    #[test]
    fn identity_rejects_permissive_hardlinked_or_symlinked_state() {
        let state = TestStateRoot::create("file-safety");
        load_once(&state.path).unwrap();
        let path = identity_path(&state.path);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(load_once(&state.path).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();

        let second_link = path.with_file_name("second-link.json");
        fs::hard_link(&path, &second_link).unwrap();
        assert!(load_once(&state.path).is_err());
        fs::remove_file(second_link).unwrap();

        let target = path.with_file_name("target.json");
        fs::rename(&path, &target).unwrap();
        symlink(&target, &path).unwrap();
        assert!(load_once(&state.path).is_err());
    }

    #[test]
    fn identity_rejects_permissive_or_symlinked_parent() {
        let state = TestStateRoot::create("parent-safety");
        let path = identity_path(&state.path);
        let parent = path.parent().unwrap();
        DirBuilder::new().mode(0o755).create(parent).unwrap();
        assert!(load_once(&state.path).is_err());
        fs::remove_dir(parent).unwrap();

        let real = state.path.join("real");
        DirBuilder::new().mode(0o700).create(&real).unwrap();
        symlink(&real, parent).unwrap();
        assert!(load_once(&state.path).is_err());
    }

    #[test]
    fn identity_rejects_permissive_hardlinked_or_symlinked_lock() {
        let state = TestStateRoot::create("lock-safety");
        load_once(&state.path).unwrap();
        let lock = identity_path(&state.path).parent().unwrap().join(LOCK_FILE);

        fs::set_permissions(&lock, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(load_once(&state.path).is_err());
        fs::set_permissions(&lock, fs::Permissions::from_mode(0o600)).unwrap();

        let second_link = lock.with_file_name("second-lock");
        fs::hard_link(&lock, &second_link).unwrap();
        assert!(load_once(&state.path).is_err());
        fs::remove_file(second_link).unwrap();

        let target = lock.with_file_name("target-lock");
        fs::rename(&lock, &target).unwrap();
        symlink(&target, &lock).unwrap();
        assert!(load_once(&state.path).is_err());
    }

    #[test]
    fn identity_parser_is_bounded() {
        let state = TestStateRoot::create("bounded");
        load_once(&state.path).unwrap();
        let path = identity_path(&state.path);
        fs::write(&path, vec![b'x'; MAX_STATE_BYTES as usize + 1]).unwrap();
        let error = load_once(&state.path).unwrap_err();
        assert!(error.to_string().contains("too large"));
    }

    #[test]
    fn identity_rejects_unsupported_version() {
        let state = TestStateRoot::create("unsupported-version");
        let consumer_id = load_once(&state.path).unwrap();
        let path = identity_path(&state.path);
        let future = StoredIdentity { version: STATE_VERSION + 1, consumer_id };
        fs::write(&path, serde_json::to_vec(&future).unwrap()).unwrap();

        let error = load_once(&state.path).unwrap_err();
        assert!(error.to_string().contains("unsupported provider notice identity version"));
    }

    #[test]
    fn identity_lease_is_exclusive_and_reuses_the_cursor_after_release() {
        let state = TestStateRoot::create("exclusive");
        let first = acquire(&state.path).unwrap();
        let first_id = first.consumer_id().clone();
        let error = acquire(&state.path).err().unwrap();
        assert!(error.downcast_ref::<ProviderNoticeIdentityInUse>().is_some());

        drop(first);
        let restarted = acquire(&state.path).unwrap();
        assert_eq!(restarted.consumer_id(), &first_id);

        let path = identity_path(&state.path);
        assert_eq!(fs::metadata(&path).unwrap().nlink(), 1);
        let temporary_prefix = format!(".{IDENTITY_FILE}.");
        assert!(
            fs::read_dir(path.parent().unwrap())
                .unwrap()
                .filter_map(Result::ok)
                .all(|entry| !entry.file_name().to_string_lossy().starts_with(&temporary_prefix))
        );
    }
}
