//! The client's local Unix socket: its path (with a private fallback directory when the state
//! path is too long), the owner lock that serializes startup, stale-socket replacement, and the
//! bound lease that unlinks only its own socket.

use super::*;

/// An exclusive `flock` on an owner-only lock file, released on drop.
#[cfg(unix)]
#[derive(Debug)]
struct OwnerFileLock {
    file: fs::File,
}

#[cfg(unix)]
impl Drop for OwnerFileLock {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;

        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[cfg(unix)]
#[derive(Debug)]
pub(super) struct ClientSocketPreparation {
    path: PathBuf,
    _lock: OwnerFileLock,
}

#[cfg(unix)]
impl ClientSocketPreparation {
    pub(super) fn bind(self) -> anyhow::Result<ClientSocketLease> {
        use std::os::unix::fs::PermissionsExt;

        let lease = ClientSocketLease::bind_locked(self.path.clone())?;
        fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600))?;
        Ok(lease)
    }
}

#[cfg(unix)]
pub(super) struct ClientSocketLease {
    listener: tokio::net::UnixListener,
    path: PathBuf,
    device: u64,
    inode: u64,
    linked: bool,
}

#[cfg(unix)]
impl ClientSocketLease {
    fn bind_locked(path: PathBuf) -> std::io::Result<Self> {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};

        let listener = tokio::net::UnixListener::bind(&path)?;
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) => {
                let _ = fs::remove_file(&path);
                return Err(error);
            }
        };
        if !metadata.file_type().is_socket() {
            let _ = fs::remove_file(&path);
            return Err(std::io::Error::other("bound client path is not a Unix socket"));
        }
        Ok(Self { listener, path, device: metadata.dev(), inode: metadata.ino(), linked: true })
    }

    pub(super) fn listener(&self) -> &tokio::net::UnixListener {
        &self.listener
    }

    pub(super) fn unlink(&mut self) -> std::io::Result<()> {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};

        if !self.linked {
            return Ok(());
        }
        let metadata = match fs::symlink_metadata(&self.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                self.linked = false;
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        if !metadata.file_type().is_socket()
            || metadata.dev() != self.device
            || metadata.ino() != self.inode
        {
            self.linked = false;
            return Ok(());
        }
        fs::remove_file(&self.path)?;
        self.linked = false;
        Ok(())
    }
}

#[cfg(unix)]
impl Drop for ClientSocketLease {
    fn drop(&mut self) {
        let _ = self.unlink();
    }
}

#[cfg(test)]
pub(super) async fn prepare_client_socket(path: &Path) -> anyhow::Result<ClientSocketPreparation> {
    prepare_client_socket_with_shutdown(path, None).await
}

pub(super) async fn prepare_client_socket_with_shutdown(
    path: &Path,
    mut shutdown: Option<watch::Receiver<bool>>,
) -> anyhow::Result<ClientSocketPreparation> {
    if !unix_socket_path_fits(path) {
        return Err(anyhow!(
            "client socket path is too long for this platform: {}",
            path.display()
        ));
    }
    let parent = path.parent().ok_or_else(|| anyhow!("client socket path has no parent"))?;
    prepare_client_socket_directory(parent)?;
    let lock_path = client_socket_lock_path(path)?;
    let path_lock = acquire_client_socket_lock(&lock_path, shutdown.as_mut()).await?;

    use std::os::unix::fs::FileTypeExt;

    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error)
                .with_context(|| format!("could not inspect client socket {}", path.display()));
        }
        Ok(metadata) => {
            if !metadata.file_type().is_socket() {
                return Err(anyhow!(
                    "refusing to replace non-socket client path {}",
                    path.display()
                ));
            }
            match tokio::time::timeout(
                UNIX_SOCKET_PROBE_TIMEOUT,
                tokio::net::UnixStream::connect(path),
            )
            .await
            {
                Ok(Ok(_)) => return Err(anyhow!("another client owns {}", path.display())),
                Ok(Err(error)) if error.kind() == std::io::ErrorKind::ConnectionRefused => {
                    remove_stale_client_socket(path, &metadata)?;
                }
                Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => {}
                Ok(Err(error)) => {
                    return Err(error).with_context(|| {
                        format!("could not verify ownership of client socket {}", path.display())
                    });
                }
                Err(_) => {
                    return Err(anyhow!(
                        "timed out checking whether another client owns {}",
                        path.display()
                    ));
                }
            }
        }
    }
    Ok(ClientSocketPreparation { path: path.to_path_buf(), _lock: path_lock })
}

#[cfg(unix)]
fn remove_stale_client_socket(path: &Path, expected: &fs::Metadata) -> anyhow::Result<()> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};

    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error)
            .with_context(|| format!("could not recheck stale client socket {}", path.display())),
        Ok(current)
            if current.file_type().is_socket()
                && current.dev() == expected.dev()
                && current.ino() == expected.ino() =>
        {
            fs::remove_file(path)?;
            Ok(())
        }
        Ok(_) => {
            Err(anyhow!("client socket {} changed during stale-owner detection", path.display()))
        }
    }
}

#[cfg(unix)]
pub(super) fn client_socket_lock_path(path: &Path) -> anyhow::Result<PathBuf> {
    let file_name =
        path.file_name().ok_or_else(|| anyhow!("client socket path has no file name"))?;
    let mut lock_name = file_name.to_os_string();
    lock_name.push(".lock");
    Ok(path.with_file_name(lock_name))
}

/// Opens (creating if needed) the owner-only lock file at `path` and checks
/// that nobody else can own, open or alias it. `what` names it in errors.
#[cfg(unix)]
fn open_owner_lock_file(path: &Path, what: &str) -> anyhow::Result<fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .with_context(|| format!("could not open {what} {}", path.display()))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(anyhow!("{what} {} is not a regular file", path.display()));
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(anyhow!("{what} {} is not owned by the effective user", path.display()));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(anyhow!("{what} {} is accessible by another user", path.display()));
    }
    if metadata.nlink() != 1 {
        return Err(anyhow!("{what} {} has unexpected hard links", path.display()));
    }
    Ok(file)
}

#[cfg(unix)]
async fn acquire_client_socket_lock(
    path: &Path,
    mut shutdown: Option<&mut watch::Receiver<bool>>,
) -> anyhow::Result<OwnerFileLock> {
    use std::os::fd::AsRawFd;

    let file = open_owner_lock_file(path, "client socket lock")?;

    loop {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(OwnerFileLock { file });
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if error.kind() != std::io::ErrorKind::WouldBlock {
            return Err(error)
                .with_context(|| format!("could not lock client socket path {}", path.display()));
        }
        match shutdown.as_deref_mut() {
            Some(shutdown) => {
                tokio::select! {
                    _ = tokio::time::sleep(CLIENT_SOCKET_LOCK_RETRY) => {}
                    _ = wait_for_shutdown(shutdown) => {
                        return Err(anyhow!("remote client startup was cancelled"));
                    }
                }
            }
            None => tokio::time::sleep(CLIENT_SOCKET_LOCK_RETRY).await,
        }
    }
}

#[cfg(unix)]
fn prepare_client_socket_directory(path: &Path) -> anyhow::Result<()> {
    ensure_secure_directory(path, DirectoryAccess::OwnerControlled)?;
    let metadata = fs::symlink_metadata(path)?;
    validate_client_socket_directory(path, &metadata, unsafe { libc::geteuid() })
}

#[cfg(unix)]
pub(super) fn validate_client_socket_directory(
    path: &Path,
    metadata: &fs::Metadata,
    effective_uid: u32,
) -> anyhow::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    if metadata.file_type().is_symlink() {
        return Err(anyhow!("client socket directory {} must not be a symlink", path.display()));
    }
    if !metadata.is_dir() {
        return Err(anyhow!("client socket directory {} is not a directory", path.display()));
    }
    if metadata.uid() != effective_uid {
        return Err(anyhow!(
            "client socket directory {} is not owned by the effective user",
            path.display()
        ));
    }
    if metadata.permissions().mode() & 0o022 != 0 {
        return Err(anyhow!(
            "client socket directory {} is writable by another user",
            path.display()
        ));
    }
    Ok(())
}

#[cfg(unix)]
pub(crate) fn unix_socket_path_fits(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;

    let capacity = unsafe { std::mem::zeroed::<libc::sockaddr_un>() }.sun_path.len();
    path.as_os_str().as_bytes().len() < capacity
}

pub(super) fn default_client_socket(
    state_dir: &Path,
    session: SessionId,
) -> anyhow::Result<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);
    client_socket_path_in(state_dir, session, runtime.as_deref(), Path::new("/tmp"))
}

/// Resolves the client socket for `session`. `runtime` is `XDG_RUNTIME_DIR`
/// and `shared_tmp` is the world-writable directory used when the state path
/// is too long for a Unix socket.
pub(super) fn client_socket_path_in(
    state_dir: &Path,
    session: SessionId,
    runtime: Option<&Path>,
    shared_tmp: &Path,
) -> anyhow::Result<PathBuf> {
    let candidate = state_dir.join("connections").join(format!("{session:?}")).join("mux.sock");
    if unix_socket_path_fits(&candidate) {
        return Ok(candidate);
    }
    let prefix = format!("cmux-r-{}", unsafe { libc::geteuid() });
    let name =
        format!("{}.sock", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(session.0));
    let preferred_base = runtime.unwrap_or(shared_tmp);
    let base = if unix_socket_path_fits(&preferred_base.join(&prefix).join(&name)) {
        preferred_base
    } else {
        shared_tmp
    };
    let record = candidate.with_file_name(SOCKET_DIRECTORY_RECORD);
    let directory =
        private_socket_directory(base, &prefix, &record, prepare_client_socket_directory)?;
    let socket = directory.join(name);
    if !unix_socket_path_fits(&socket) {
        return Err(anyhow!(
            "client socket path is too long for this platform: {}",
            socket.display()
        ));
    }
    Ok(socket)
}

/// File in a private state directory that records the socket directory chosen
/// after the fixed shared one was unusable.
#[cfg(unix)]
pub(super) const SOCKET_DIRECTORY_RECORD: &str = "socket-dir";

/// Chooses a private directory for Unix sockets under the world-writable
/// `base`. `<base>/<prefix>` is preferred, but any local user can create that
/// name first; `validate` rejects such a directory and a fresh random `0700`
/// sibling is used instead, like the Go daemon's fallback. The fallback is
/// recorded in `record`, inside the caller's private state, so every later
/// process for the same session resolves the same sockets.
#[cfg(unix)]
pub(super) fn private_socket_directory(
    base: &Path,
    prefix: &str,
    record: &Path,
    validate: impl Fn(&Path) -> anyhow::Result<()>,
) -> anyhow::Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;

    let preferred = base.join(prefix);
    let mut preferred_error = None;
    for _ in 0..8 {
        if let Some(recorded) = recorded_socket_directory(record, base, prefix)
            && validate(&recorded).is_ok()
        {
            return Ok(recorded);
        }
        match validate(&preferred) {
            Ok(()) => return Ok(preferred),
            Err(error) => preferred_error = Some(error),
        }
        let parent = record.parent().ok_or_else(|| anyhow!("socket record has no parent"))?;
        ensure_secure_directory(parent, DirectoryAccess::OwnerControlled)
            .with_context(|| format!("could not prepare {}", parent.display()))?;
        let suffix = uuid::Uuid::new_v4().simple().to_string();
        // Keep the name short: socket paths must fit in sun_path.
        let candidate = base.join(format!("{prefix}-{}", &suffix[..8]));
        match fs::DirBuilder::new().mode(0o700).create(&candidate) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("could not create {}", candidate.display()));
            }
        }
        if let Err(error) = validate(&candidate) {
            let _ = fs::remove_dir(&candidate);
            return Err(error);
        }
        match publish_socket_directory_record(record, &candidate) {
            Ok(()) => return Ok(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                // Another process for this session recorded its directory
                // first. Use it if it is still private, otherwise replace
                // the stale record on the next attempt.
                let _ = fs::remove_dir(&candidate);
                if let Some(recorded) = recorded_socket_directory(record, base, prefix)
                    && validate(&recorded).is_ok()
                {
                    return Ok(recorded);
                }
                before_socket_directory_record_replace();
                // Only a lock holder removes the record, and a publisher
                // cannot link over one that exists. So what this reads under
                // the lock is what it removes, never a record another
                // process published since the check above.
                let _lock = lock_socket_directory_record(record)?;
                if let Some(recorded) = recorded_socket_directory(record, base, prefix)
                    && validate(&recorded).is_ok()
                {
                    return Ok(recorded);
                }
                let _ = fs::remove_file(record);
            }
            Err(error) => {
                let _ = fs::remove_dir(&candidate);
                return Err(error)
                    .with_context(|| format!("could not record {}", candidate.display()));
            }
        }
    }
    Err(preferred_error.unwrap_or_else(|| anyhow!("no private socket directory was available")))
        .with_context(|| {
            format!("could not create a private socket directory under {}", base.display())
        })
}

/// Serializes replacing `record` across processes with an owner-only lock
/// file beside it. Blocks until the lock is free.
#[cfg(unix)]
fn lock_socket_directory_record(record: &Path) -> anyhow::Result<OwnerFileLock> {
    use std::os::fd::AsRawFd;

    let path = record.with_file_name(format!("{SOCKET_DIRECTORY_RECORD}.lock"));
    let file = open_owner_lock_file(&path, "socket directory record lock")?;
    loop {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
            return Ok(OwnerFileLock { file });
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error).with_context(|| format!("could not lock {}", path.display()));
        }
    }
}

#[cfg(all(unix, test))]
thread_local! {
    /// Test hook run on this thread when a publisher is about to replace a
    /// record it found unusable.
    pub(super) static BEFORE_SOCKET_DIRECTORY_RECORD_REPLACE: std::cell::RefCell<Option<Box<dyn FnMut()>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(unix)]
fn before_socket_directory_record_replace() {
    #[cfg(test)]
    BEFORE_SOCKET_DIRECTORY_RECORD_REPLACE.with(|hook| {
        if let Some(hook) = hook.borrow_mut().as_mut() {
            hook();
        }
    });
}

/// Reads a recorded fallback directory. Only a `<prefix>-*` child of `base`
/// is accepted, so a damaged record cannot point sockets anywhere else.
#[cfg(unix)]
fn recorded_socket_directory(record: &Path, base: &Path, prefix: &str) -> Option<PathBuf> {
    use std::os::unix::ffi::{OsStrExt, OsStringExt};

    let metadata = fs::symlink_metadata(record).ok()?;
    if !metadata.is_file() || metadata.len() > 4096 {
        return None;
    }
    let path = PathBuf::from(std::ffi::OsString::from_vec(fs::read(record).ok()?));
    let name = path.file_name()?.as_bytes();
    (path.parent() == Some(base) && name.starts_with(format!("{prefix}-").as_bytes()))
        .then_some(path)
}

/// Publishes `directory` as the session's socket directory without replacing
/// a record another process already published.
#[cfg(unix)]
fn publish_socket_directory_record(record: &Path, directory: &Path) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::OpenOptionsExt;

    let staged = record
        .with_file_name(format!(".{SOCKET_DIRECTORY_RECORD}.{}", uuid::Uuid::new_v4().simple()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&staged)?;
        file.write_all(directory.as_os_str().as_bytes())?;
        file.sync_all()?;
        fs::hard_link(&staged, record)
    })();
    let _ = fs::remove_file(&staged);
    result
}
