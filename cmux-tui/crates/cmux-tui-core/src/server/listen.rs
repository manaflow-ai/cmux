//! Binding the local control socket: the private runtime socket directory,
//! the cross-process start lock that serializes probe, unlink and bind, the
//! paused server whose lifecycle endpoint is not ready yet, and `serve`.
//! Accepted connections go to `handle_connection_with_permit`; this module
//! owns no protocol handling.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

#[cfg(unix)]
use super::start_apps_when_ready;
use super::{
    ACCEPT_RETRY_INITIAL, ACCEPT_RETRY_MAX, RenderService, claim_connection, cleanup,
    handle_connection_with_permit, try_default_socket_path,
};
use crate::mux::Mux;
use crate::platform::{self, transport};

/// A bound local server whose lifecycle endpoint is not ready yet.
pub struct PendingServer {
    path: Option<PathBuf>,
    mux: Arc<Mux>,
    shutdown: Arc<AtomicBool>,
}

impl PendingServer {
    /// Publish lifecycle readiness and transfer socket cleanup to the caller.
    pub fn mark_ready(mut self) -> anyhow::Result<PathBuf> {
        self.mux.mark_server_lifecycle_ready();
        #[cfg(unix)]
        start_apps_when_ready(&self.mux);
        Ok(self.path.take().expect("pending server path is available"))
    }

    /// Transfer socket cleanup while another startup owner publishes readiness.
    pub fn into_bound_path(mut self) -> PathBuf {
        self.path.take().expect("pending server path is available")
    }
}

impl Drop for PendingServer {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            self.shutdown.store(true, Ordering::Release);
            let _ = transport::connect(&path);
            cleanup(&path);
        }
    }
}

/// Prepare the daemon-owned runtime directory without accepting a symlink or
/// an existing directory controlled by another user. The final metadata check
/// also confirms that tightening permissions did not change the object type.
/// Windows: an owner-only directory (protected DACL, our token user as
/// owner); a wider existing one is refused (cmux-sdk local_socket).
#[cfg(windows)]
pub(super) fn prepare_runtime_socket_directory(dir: &Path) -> anyhow::Result<()> {
    if let Some(parent) = dir.parent() {
        std::fs::create_dir_all(parent)?;
    }
    cmux::local_socket::private_directory(dir)?;
    Ok(())
}

#[cfg(not(windows))]
pub(super) fn prepare_runtime_socket_directory(dir: &Path) -> anyhow::Result<()> {
    match std::fs::symlink_metadata(dir) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                anyhow::bail!("runtime socket directory must not be a symlink: {}", dir.display());
            }
            if !metadata.is_dir() {
                anyhow::bail!("runtime socket path parent is not a directory: {}", dir.display());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(dir)?;
        }
        Err(error) => return Err(error.into()),
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let metadata = std::fs::symlink_metadata(dir)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            anyhow::bail!("runtime socket directory changed during creation: {}", dir.display());
        }
        // The effective user must own the directory before we chmod it. This
        // prevents an inherited path from being used to mutate another user's
        // runtime directory.
        if metadata.uid() != unsafe { libc::geteuid() } {
            anyhow::bail!(
                "runtime socket directory is not owned by the effective user: {}",
                dir.display()
            );
        }
        if metadata.permissions().mode() & 0o077 != 0 {
            platform::restrict_directory(dir)?;
        }
        verify_private_socket_directory(dir)?;
    }
    #[cfg(not(unix))]
    {
        platform::restrict_directory(dir)?;
    }
    Ok(())
}

/// Create missing parents for an explicitly selected socket path without
/// changing the permissions or ownership of an existing directory. Explicit
/// paths may point at a caller-managed location, but the final parent must
/// still be a real directory rather than a symlink or other file.
fn prepare_explicit_socket_directory(path: &Path) -> anyhow::Result<()> {
    let Some(dir) = path.parent() else { return Ok(()) };
    if dir.as_os_str().is_empty() {
        return Ok(());
    }

    match std::fs::symlink_metadata(dir) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                anyhow::bail!("explicit socket path parent is not a directory: {}", dir.display());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(dir)?;
            let metadata = std::fs::symlink_metadata(dir)?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                anyhow::bail!(
                    "explicit socket path parent changed to a non-directory: {}",
                    dir.display()
                );
            }
        }
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

/// Prepare the parent directory before any client creates coordination files.
/// Derived runtime paths receive the daemon-owned private-directory checks;
/// explicit paths keep their caller-managed permissions.
pub fn prepare_socket_parent(path: &Path, is_derived: bool) -> anyhow::Result<()> {
    if is_derived {
        if let Some(dir) = path.parent() {
            prepare_runtime_socket_directory(dir)?;
        }
    } else {
        prepare_explicit_socket_directory(path)?;
    }
    Ok(())
}

/// Connect a client to a session socket. A derived path must sit in the
/// private runtime directory a server prepared, and its listener must run as
/// this user, before the caller writes anything. Explicit paths keep their
/// caller-managed semantics.
pub fn connect_session_socket(
    path: &Path,
    is_derived: bool,
) -> std::io::Result<Box<dyn transport::Stream>> {
    if !is_derived {
        return transport::connect(path);
    }
    #[cfg(unix)]
    if let Some(dir) = path.parent() {
        verify_private_socket_directory(dir)?;
    }
    #[cfg(windows)]
    if let Some(dir) = path.parent() {
        let me = cmux::local_socket::win::current_identity()?;
        if !cmux::local_socket::win::directory_is_owner_only(dir, &me.user_sid)? {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!("runtime socket directory is not owner-only: {}", dir.display()),
            ));
        }
    }
    transport::connect_same_user(path)
}

/// Check, without changing anything, that a derived socket directory is still
/// the private one `prepare_runtime_socket_directory` leaves behind.
#[cfg(unix)]
fn verify_private_socket_directory(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let metadata = std::fs::symlink_metadata(dir)?;
    if metadata.file_type().is_symlink()
        || !metadata.is_dir()
        || metadata.uid() != platform::effective_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!("runtime socket directory is not private: {}", dir.display()),
        ));
    }
    Ok(())
}

/// Exclusive lock serializing every local server start for one socket path:
/// foreground `server start`, in-process TUI hosting, and detached-owner
/// spawns. The stale-socket recovery below (probe, unlink, bind) is not
/// atomic, so two unserialized starts can both classify a socket as stale,
/// and the second unlink disconnects the first starter's freshly bound
/// socket while its process keeps running unreachably. The lock file lives
/// next to the socket and is left in place: unlinking it would reopen the
/// very race it exists to close. The OS releases the lock when the holder
/// exits, so a crashed starter never wedges the session.
pub struct SocketStartLock {
    _file: std::fs::File,
}

const SOCKET_START_LOCK_RETRY_INTERVAL: Duration = Duration::from_millis(25);

/// Return the next retry wait without extending the caller's deadline.
/// `try_lock` remains non-blocking; only this retry delay is bounded.
pub(super) fn socket_start_lock_retry_delay(now: Instant, deadline: Instant) -> Option<Duration> {
    let remaining = deadline.checked_duration_since(now)?;
    (!remaining.is_zero()).then_some(SOCKET_START_LOCK_RETRY_INTERVAL.min(remaining))
}

fn socket_start_lock_timeout() -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::TimedOut,
        "timed out waiting for a concurrent session-server start",
    )
}

impl SocketStartLock {
    pub fn acquire(socket: &Path, deadline: Instant) -> std::io::Result<Self> {
        let mut name = socket.file_name().unwrap_or_default().to_os_string();
        name.push(".spawn-lock");
        let path = socket.with_file_name(name);
        let mut options = std::fs::OpenOptions::new();
        options.create(true);
        #[cfg(windows)]
        {
            // fs4 uses LockFileEx, which rejects Rust's append-only handle
            // because it has neither GENERIC_READ nor GENERIC_WRITE.
            options.truncate(false).read(true).write(true);
        }
        #[cfg(not(windows))]
        {
            // O_NONBLOCK plus write-only access rejects a FIFO before the
            // metadata check without waiting for another process to open it.
            options.append(true);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK).mode(0o600);
        }
        let file = options.open(&path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
            let metadata = file.metadata()?;
            if !metadata.is_file() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "session-server start lock is not a regular file",
                ));
            }
            if metadata.nlink() != 1 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "session-server start lock has unexpected hard links",
                ));
            }
            if metadata.uid() != unsafe { libc::geteuid() } {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "session-server start lock owner changed",
                ));
            }
            let mut permissions = metadata.permissions();
            permissions.set_mode(0o600);
            file.set_permissions(permissions)?;
            let mode = file.metadata()?.permissions().mode();
            if mode & 0o077 != 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "session-server start lock is not private",
                ));
            }
        }
        loop {
            match fs4::FileExt::try_lock(&file) {
                Ok(()) => return Ok(Self { _file: file }),
                Err(fs4::TryLockError::WouldBlock) => {}
                Err(fs4::TryLockError::Error(error)) => return Err(error),
            }
            let Some(retry_delay) = socket_start_lock_retry_delay(Instant::now(), deadline) else {
                return Err(socket_start_lock_timeout());
            };
            std::thread::sleep(retry_delay);
            if Instant::now() >= deadline {
                return Err(socket_start_lock_timeout());
            }
        }
    }
}

/// How long a server start may wait for a concurrent starter of the same
/// socket. Holders keep the lock only across probe, unlink, and bind, so a
/// healthy contender clears in milliseconds; the bound exists to surface a
/// wedged holder as an error instead of a hang.
const START_LOCK_DEADLINE: Duration = Duration::from_secs(10);

/// Bind the socket and accept protocol clients before lifecycle readiness.
pub fn serve_paused(mux: Arc<Mux>, path: Option<PathBuf>) -> anyhow::Result<PendingServer> {
    let (path, is_derived) = match path {
        Some(path) => (path, false),
        None => (try_default_socket_path(&mux.session)?, true),
    };
    // Refuse a path longer than sun_path before creating its parent or lock.
    cmux_unix_socket::check_path(&path)?;
    // Only harden directories selected by the daemon. An explicit socket path
    // is authoritative, so its parent may be a shared or pre-configured path
    // such as /tmp and must not be chmod'ed or ownership-checked.
    prepare_socket_parent(&path, is_derived)?;
    let start_lock = SocketStartLock::acquire(&path, Instant::now() + START_LOCK_DEADLINE)?;
    // Refuse to clobber a live socket; remove a stale one.
    if path.exists() {
        match transport::connect(&path) {
            Ok(_) => anyhow::bail!(
                "session socket {} is already in use (another instance running?)",
                path.display()
            ),
            Err(_) => std::fs::remove_file(&path)?,
        }
    }
    let listener = transport::listen(&path)?;
    drop(start_lock);
    if let Err(error) = platform::restrict_file(&path) {
        cleanup(&path);
        return Err(error.into());
    }
    let active_connections = mux.connection_stats().clone();
    let render_service = Arc::new(RenderService::new());
    let shutdown = Arc::new(AtomicBool::new(false));
    let server_shutdown = shutdown.clone();
    let server_mux = mux.clone();

    let server = std::thread::Builder::new().name("mux-server".into()).spawn(move || {
        // Resource exhaustion (EMFILE, ENFILE, ENOBUFS) persists across
        // accepts, and an immediate retry ran this thread at 100% CPU until
        // descriptors freed up. Space those retries; per-connection errors
        // need none because the next accept blocks.
        let mut backoff = crate::backoff::Backoff::new(ACCEPT_RETRY_INITIAL, ACCEPT_RETRY_MAX);
        loop {
            let stream = match listener.accept() {
                Ok(stream) => {
                    backoff.reset();
                    stream
                }
                Err(error) => {
                    if server_shutdown.load(Ordering::Acquire) {
                        break;
                    }
                    if crate::backoff::accept_error_needs_backoff(&error) {
                        backoff.sleep();
                    }
                    continue;
                }
            };
            if server_shutdown.load(Ordering::Acquire) {
                break;
            }
            let Some(permit) = claim_connection(&active_connections) else { continue };
            let mux = server_mux.clone();
            let render_service = render_service.clone();
            let _ = std::thread::Builder::new().name("mux-conn".into()).spawn(move || {
                handle_connection_with_permit(mux, stream, render_service, Some(permit));
            });
        }
    });
    if let Err(error) = server {
        cleanup(&path);
        return Err(error.into());
    }
    Ok(PendingServer { path: Some(path), mux, shutdown })
}

/// Bind the socket and serve connections on background threads.
pub fn serve(mux: Arc<Mux>, path: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    serve_paused(mux, path)?.mark_ready()
}
