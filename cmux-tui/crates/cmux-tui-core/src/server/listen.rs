//! Binding the local control socket: the private runtime socket directory,
//! the cross-process start lock that serializes probe, unlink and bind, the
//! paused server whose lifecycle endpoint is not ready yet, and `serve`.
//! Accepted connections go to `handle_connection_with_permit`; this module
//! owns no protocol handling.

use cmux_threads::checked::fs as files;
use std::fs;
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
use cmux_threads::ThreadQos;

/// A bound local server whose lifecycle endpoint is not ready yet.
pub struct PendingServer {
    path: Option<PathBuf>,
    mux: Arc<Mux>,
    shutdown: Arc<AtomicBool>,
}

impl PendingServer {
    pub(super) fn from_parts(path: PathBuf, mux: Arc<Mux>, shutdown: Arc<AtomicBool>) -> Self {
        Self { path: Some(path), mux, shutdown }
    }

    /// Publish lifecycle readiness and transfer socket cleanup to the caller.
    pub fn mark_ready(mut self) -> anyhow::Result<PathBuf> {
        self.mux.mark_server_lifecycle_ready();
        #[cfg(unix)]
        start_apps_when_ready(&self.mux);
        self.path.take().ok_or_else(|| anyhow::anyhow!("pending server path was already taken"))
    }

    /// Transfer socket cleanup while another startup owner publishes readiness.
    pub fn into_bound_path(mut self) -> PathBuf {
        self.path.take().unwrap_or_default()
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
        files::create_dir_all(parent)?;
    }
    cmux::local_socket::private_directory(dir)?;
    Ok(())
}

#[cfg(not(windows))]
pub(super) fn prepare_runtime_socket_directory(dir: &Path) -> anyhow::Result<()> {
    match files::symlink_metadata(dir) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                anyhow::bail!("runtime socket directory must not be a symlink: {}", dir.display());
            }
            if !metadata.is_dir() {
                anyhow::bail!("runtime socket path parent is not a directory: {}", dir.display());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            files::create_dir_all(dir)?;
        }
        Err(error) => return Err(error.into()),
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let metadata = files::symlink_metadata(dir)?;
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

    match files::symlink_metadata(dir) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                anyhow::bail!("explicit socket path parent is not a directory: {}", dir.display());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            files::create_dir_all(dir)?;
            let metadata = files::symlink_metadata(dir)?;
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

    let metadata = files::symlink_metadata(dir)?;
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
    _file: fs::File,
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
        let mut options = fs::File::options();
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
        let file = files::open_with(&options, &path)?;
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
            crate::request_path::sleep(retry_delay);
            if Instant::now() >= deadline {
                return Err(socket_start_lock_timeout());
            }
        }
    }
}

/// How long a server start may wait for a concurrent starter of the same
/// socket. Holders keep the lock only across probe, unlink, and bind (an
/// owner binds before it restores its session, and `server ensure` holds it
/// only across one probe and the spawn), so a healthy contender clears in
/// milliseconds; the bound exists to surface a wedged holder as an error
/// instead of a hang.
pub const START_LOCK_DEADLINE: Duration = Duration::from_secs(10);

/// A session socket this process bound, before any session serves it.
/// Dropping it closes the listener and removes the socket file.
pub struct BoundSocket {
    // Declared first: the listener closes before the file is removed.
    listener: transport::Listener,
    file: SocketFile,
}

/// Removes the socket file on drop unless ownership moved on (`release`).
struct SocketFile {
    path: PathBuf,
    owned: bool,
}

impl SocketFile {
    fn release(mut self) -> PathBuf {
        self.owned = false;
        std::mem::take(&mut self.path)
    }
}

impl Drop for SocketFile {
    fn drop(&mut self) {
        if self.owned {
            cleanup(&self.path);
        }
    }
}

impl BoundSocket {
    pub fn path(&self) -> &Path {
        &self.file.path
    }

    /// The listener and the socket path, whose cleanup the caller takes.
    pub(super) fn into_parts(self) -> (PathBuf, transport::Listener) {
        let Self { listener, file } = self;
        (file.release(), listener)
    }
}

/// Bind the session socket under the start lock, refusing a live socket and
/// removing a stale one. An owner calls this before it restores its session,
/// so the socket names the one process that owns the session for the whole
/// restore: a second owner finds it live and exits before it touches the
/// registry or a terminal host, and `server ensure` sees a restoring owner
/// instead of an absent one (cx-n3bs).
pub fn bind_session_socket(session: &str, path: Option<PathBuf>) -> anyhow::Result<BoundSocket> {
    let (path, is_derived) = match path {
        Some(path) => (path, false),
        None => (try_default_socket_path(session)?, true),
    };
    // Refuse a path longer than sun_path before creating its parent or lock.
    cmux_unix_socket::check_path(&path)?;
    // Only harden directories selected by the daemon. An explicit socket path
    // is authoritative, so its parent may be a shared or pre-configured path
    // such as /tmp and must not be chmod'ed or ownership-checked.
    prepare_socket_parent(&path, is_derived)?;
    let start_lock = SocketStartLock::acquire(&path, Instant::now() + START_LOCK_DEADLINE)?;
    // Refuse to clobber a live socket; remove a stale one.
    if files::metadata(&path).is_ok() {
        match transport::connect(&path) {
            Ok(_) => anyhow::bail!(
                "session socket {} is already in use (another instance running?)",
                path.display()
            ),
            Err(_) => files::remove_file(&path)?,
        }
    }
    let listener = transport::listen(&path)?;
    drop(start_lock);
    let bound = BoundSocket { listener, file: SocketFile { path, owned: true } };
    platform::restrict_file(bound.path())?;
    Ok(bound)
}

/// The session a bound socket's accept loop hands connections to, once the
/// owner has one.
#[derive(Clone)]
pub(super) struct ServedSession {
    pub(super) mux: Arc<Mux>,
    pub(super) render_service: Arc<RenderService>,
}

impl ServedSession {
    /// Serve one accepted connection on its own thread (bounded by the
    /// session's connection permits).
    pub(super) fn serve(&self, stream: Box<dyn transport::Stream>) {
        let Some(permit) = claim_connection(self.mux.connection_stats()) else {
            refuse_busy(stream);
            return;
        };
        let mux = self.mux.clone();
        let render_service = self.render_service.clone();
        let _ = super::spawn_connection_reader("mux-conn", move || {
            handle_connection_with_permit(mux, stream, render_service, Some(permit));
        });
    }
}

/// The one line a connection refused at the connection limit reads before
/// the close, so the client can say the session is busy instead of a broken
/// pipe or a closed transport. The CLI reads `type: "refused"`.
pub(super) const REFUSED_BUSY_LINE: &str = concat!(
    r#"{"protocol":"cmux.protocol/2","type":"refused","code":"server.busy","#,
    r#""message":"the session is at its connection limit; retry"}"#,
    "\n"
);

/// Best effort: a short write timeout keeps the accept loop from waiting on a
/// client that does not read.
fn refuse_busy(mut stream: Box<dyn transport::Stream>) {
    use std::io::Write as _;
    let _ = stream.set_write_timeout(Some(Duration::from_millis(50)));
    let _ = stream.write_all(REFUSED_BUSY_LINE.as_bytes());
    let _ = stream.flush();
}

/// Kernel buffer each accepted control connection asks for, each way
/// (p05-ipc.md 3.2; the app's end does the same in LineTransport). macOS
/// gives a Unix stream socket 8 KiB (`net.local.stream.sendspace`), so a
/// snapshot or a 256 KiB output burst took dozens of writes that each hit
/// EAGAIN. A write lands in the kernel on the writer's own thread until the
/// buffer is full, as Mojo's ChannelPosix::Write does
/// (mojo/core/channel_posix.cc); 512 KiB drains in well under 1 ms.
pub(super) const CONNECTION_SOCKET_BUFFER: usize = 512 * 1024;

/// What getsockopt reports for a full grant of [`CONNECTION_SOCKET_BUFFER`]:
/// Linux stores twice the ask (its bookkeeping share, `sk_setsockopt` in
/// net/core/sock.c), macOS stores the ask.
pub(super) fn full_grant() -> usize {
    if cfg!(target_os = "linux") { 2 * CONNECTION_SOCKET_BUFFER } else { CONNECTION_SOCKET_BUFFER }
}

/// The send and receive buffer sizes the kernel reports after the ask. Linux
/// caps the ask at `net.core.wmem_max` / `rmem_max` before it doubles it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct SocketBuffers {
    pub(super) send: usize,
    pub(super) receive: usize,
}

impl SocketBuffers {
    /// Whether a system limit sized either buffer below a full grant.
    fn is_short(&self) -> bool {
        self.send < full_grant() || self.receive < full_grant()
    }
}

/// Ask for [`CONNECTION_SOCKET_BUFFER`] each way on `stream` and return what
/// the kernel granted; `None` for a stream that is not one socket.
pub(super) fn size_connection_buffers(
    stream: &dyn transport::Stream,
) -> Option<std::io::Result<SocketBuffers>> {
    #[cfg(unix)]
    {
        let fd = stream.socket_fd()?;
        // SAFETY: `fd` belongs to `stream`, which outlives this borrow.
        let fd = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) };
        let socket = socket2::SockRef::from(&fd);
        let grant = || -> std::io::Result<SocketBuffers> {
            socket.set_send_buffer_size(CONNECTION_SOCKET_BUFFER)?;
            socket.set_recv_buffer_size(CONNECTION_SOCKET_BUFFER)?;
            Ok(SocketBuffers {
                send: socket.send_buffer_size()?,
                receive: socket.recv_buffer_size()?,
            })
        };
        Some(grant())
    }
    #[cfg(not(unix))]
    {
        let _ = stream;
        None
    }
}

/// One accept loop's log of the buffers the kernel grants: the first sized
/// connection's sizes are logged, with the system limit to raise when the
/// grant is short; later ones are not (each would repeat the same sizes).
#[derive(Default)]
pub(super) struct SocketBufferLog {
    logged: bool,
}

impl SocketBufferLog {
    /// The line to log for this connection's result, at most once per loop.
    pub(super) fn line(&mut self, result: &std::io::Result<SocketBuffers>) -> Option<String> {
        if self.logged {
            return None;
        }
        self.logged = true;
        Some(match result {
            Ok(granted) if granted.is_short() => format!(
                "cmux-tui: control socket buffers are {} B send, {} B receive; a full grant of \
                 the {CONNECTION_SOCKET_BUFFER} B ask reads {} B (system limit: Linux \
                 net.core.wmem_max and rmem_max, macOS kern.ipc.maxsockbuf)",
                granted.send,
                granted.receive,
                full_grant()
            ),
            Ok(granted) => format!(
                "cmux-tui: control socket buffers are {} B send, {} B receive \
                 ({CONNECTION_SOCKET_BUFFER} B asked)",
                granted.send, granted.receive
            ),
            Err(error) => format!("cmux-tui: control socket buffers not sized: {error}"),
        })
    }
}

/// The QoS of an accept loop: the request class. Every connection (each CLI
/// command, hook, agent call and app reconnect) waits on an accept before its
/// own thread exists, and the threads started here inherit this class.
/// Chromium accepts IPC connections on the browser IO thread, which serves
/// requests (content/browser/browser_process_io_thread.cc).
pub(super) const ACCEPT_THREAD_QOS: ThreadQos = super::connection_scheduler::REQUEST_THREAD_QOS;

/// Start the accept loop for `listener`. Every accepted connection goes to
/// `slot`: served by the session once it is attached, parked until then.
pub(super) fn spawn_accept_loop(
    listener: transport::Listener,
    slot: Arc<super::restoring::SessionSlot>,
    shutdown: Arc<AtomicBool>,
) -> std::io::Result<()> {
    cmux_threads::spawn("mux-server", ACCEPT_THREAD_QOS, move || {
        // Resource exhaustion (EMFILE, ENFILE, ENOBUFS) persists across
        // accepts, and an immediate retry ran this thread at 100% CPU until
        // descriptors freed up. Space those retries; per-connection errors
        // need none because the next accept blocks.
        let mut backoff = crate::backoff::Backoff::new(ACCEPT_RETRY_INITIAL, ACCEPT_RETRY_MAX);
        let mut buffer_log = SocketBufferLog::default();
        loop {
            let stream = match listener.accept() {
                Ok(stream) => {
                    backoff.reset();
                    stream
                }
                Err(error) => {
                    if shutdown.load(Ordering::Acquire) {
                        break;
                    }
                    if crate::backoff::accept_error_needs_backoff(&error) {
                        backoff.sleep();
                    }
                    continue;
                }
            };
            if shutdown.load(Ordering::Acquire) {
                break;
            }
            if let Some(result) = size_connection_buffers(stream.as_ref())
                && let Some(line) = buffer_log.line(&result)
            {
                eprintln!("{line}");
            }
            if let Some((session, stream)) = slot.route(stream) {
                session.serve(stream);
            }
        }
    })?;
    Ok(())
}

/// Bind the socket and accept protocol clients before lifecycle readiness.
pub fn serve_paused(mux: Arc<Mux>, path: Option<PathBuf>) -> anyhow::Result<PendingServer> {
    let bound = bind_session_socket(&mux.session, path)?;
    serve_bound(mux, bound)
}

/// Serve `mux` on a socket bound earlier, before lifecycle readiness.
pub fn serve_bound(mux: Arc<Mux>, bound: BoundSocket) -> anyhow::Result<PendingServer> {
    Ok(bound.serve_restoring()?.attach(mux))
}

/// Bind the socket and serve connections on background threads.
pub fn serve(mux: Arc<Mux>, path: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    // Key-press flow marks start here, before the first request (`CMUX_TRACE_FLOWS`).
    cmux_flow_trace::init();
    serve_paused(mux, path)?.mark_ready()
}

#[cfg(all(test, unix))]
mod refuse_busy_tests {
    use std::io::{BufRead, BufReader};
    use std::os::unix::net::UnixStream;

    use super::{REFUSED_BUSY_LINE, refuse_busy};

    #[test]
    fn a_refused_connection_reads_one_busy_line_then_end_of_stream() {
        let (server, client) = UnixStream::pair().unwrap();
        refuse_busy(Box::new(server));
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert_eq!(line, REFUSED_BUSY_LINE);
        let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["type"], "refused");
        assert_eq!(reply["code"], "server.busy");
        line.clear();
        assert_eq!(reader.read_line(&mut line).unwrap(), 0, "the refused stream closes");
    }
}

#[cfg(all(test, unix))]
mod socket_buffer_tests {
    use std::io::{Read as _, Write as _};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use super::{
        CONNECTION_SOCKET_BUFFER, SocketBufferLog, SocketBuffers, bind_session_socket, full_grant,
        size_connection_buffers,
    };
    use crate::platform::transport;

    /// The least the kernel may report for the ask: Linux caps the ask at
    /// `net.core.{w,r}mem_max` and doubles it; macOS reports the ask.
    fn least_grant(limit: &str) -> usize {
        if cfg!(target_os = "linux") {
            let path = format!("/proc/sys/net/core/{limit}");
            let max: usize = std::fs::read_to_string(path).unwrap().trim().parse().unwrap();
            full_grant().min(max * 2)
        } else {
            full_grant()
        }
    }

    /// A fresh directory for one test's socket.
    fn socket_directory() -> PathBuf {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "cmux-sockbuf-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    /// getsockopt SO_SNDBUF and SO_RCVBUF on `stream`'s socket.
    fn buffers_of(stream: &dyn transport::Stream) -> SocketBuffers {
        let fd = stream.socket_fd().unwrap();
        // SAFETY: `stream` owns `fd` for this borrow.
        let fd = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) };
        let socket = socket2::SockRef::from(&fd);
        SocketBuffers {
            send: socket.send_buffer_size().unwrap(),
            receive: socket.recv_buffer_size().unwrap(),
        }
    }

    #[test]
    fn an_accepted_connection_gets_512_kib_buffers_each_way() {
        let directory = socket_directory();
        let path = directory.join("s.sock");
        let listener = transport::listen(&path).unwrap();
        let mut client = transport::connect(&path).unwrap();
        let mut server = listener.accept().unwrap();

        let granted = size_connection_buffers(server.as_ref()).unwrap().unwrap();
        assert_eq!(granted, buffers_of(server.as_ref()), "getsockopt SO_SNDBUF / SO_RCVBUF");
        assert!(granted.send >= least_grant("wmem_max"), "SO_SNDBUF {}", granted.send);
        assert!(granted.receive >= least_grant("rmem_max"), "SO_RCVBUF {}", granted.receive);

        // The sized socket still carries bytes.
        server.write_all(b"ping").unwrap();
        let mut reply = [0u8; 4];
        client.read_exact(&mut reply).unwrap();
        assert_eq!(&reply, b"ping");
        drop(listener);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn the_daemon_accept_loop_sizes_every_connection_it_accepts() {
        let directory = socket_directory();
        let path = directory.join("s.sock");
        let bound = bind_session_socket("sockbuf-test", Some(path.clone())).unwrap();
        let server = bound.serve_restoring().unwrap();
        let _client = transport::connect(&path).unwrap();

        // The loop sizes a connection before it parks it, so a parked stream
        // is sized.
        let deadline = Instant::now() + Duration::from_secs(10);
        let parked = loop {
            if let Some(parked) = server.take_parked() {
                break parked;
            }
            assert!(Instant::now() < deadline, "the accept loop parked no connection");
            std::thread::sleep(Duration::from_millis(1));
        };
        let granted = buffers_of(parked.as_ref());
        assert!(granted.send >= least_grant("wmem_max"), "SO_SNDBUF {}", granted.send);
        assert!(granted.receive >= least_grant("rmem_max"), "SO_RCVBUF {}", granted.receive);
        drop(parked);
        drop(server);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn a_stream_without_a_socket_is_left_alone() {
        struct NoSocket;
        impl std::io::Read for NoSocket {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                Ok(0)
            }
        }
        impl std::io::Write for NoSocket {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        impl transport::Stream for NoSocket {
            fn try_clone_box(&self) -> std::io::Result<Box<dyn transport::Stream>> {
                Ok(Box::new(NoSocket))
            }
            fn set_read_timeout(&self, _: Option<Duration>) -> std::io::Result<()> {
                Ok(())
            }
            fn set_write_timeout(&self, _: Option<Duration>) -> std::io::Result<()> {
                Ok(())
            }
            fn shutdown(&self, _: std::net::Shutdown) -> std::io::Result<()> {
                Ok(())
            }
        }
        assert!(size_connection_buffers(&NoSocket).is_none());
    }

    #[test]
    fn the_granted_sizes_are_logged_once_per_accept_loop() {
        let full = SocketBuffers { send: full_grant(), receive: full_grant() };
        let short = SocketBuffers { send: 212_992, receive: 425_984 };
        let mut log = SocketBufferLog::default();
        let line = log.line(&Ok(full)).expect("the first full grant logs its sizes");
        let size = full_grant();
        assert!(line.contains(&format!("{size} B send, {size} B receive")), "{line}");
        assert!(!line.contains("system limit"), "a full grant names no limit: {line}");
        assert_eq!(log.line(&Ok(full)), None, "the second connection does not log");
        assert_eq!(log.line(&Ok(short)), None, "nor does a later short grant");
        let error = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        assert_eq!(log.line(&Err(error)), None, "nor does a later failure");

        let mut log = SocketBufferLog::default();
        let line = log.line(&Ok(short)).expect("the first short grant logs");
        assert!(line.contains("212992 B send, 425984 B receive"), "{line}");
        assert!(line.contains("system limit"), "a short grant names the limit: {line}");
        assert_eq!(log.line(&Ok(short)), None, "the second short grant does not");

        let mut log = SocketBufferLog::default();
        let error = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        assert!(log.line(&Err(error)).unwrap().contains("not sized"));
    }

    /// Linux caps the ask at wmem_max before it doubles it: with wmem_max at
    /// 400000 getsockopt reads 800000, above the 512 KiB ask but short.
    #[test]
    #[cfg(target_os = "linux")]
    fn a_linux_grant_capped_between_the_ask_and_twice_it_is_short() {
        let capped = SocketBuffers { send: 800_000, receive: full_grant() };
        let line = SocketBufferLog::default().line(&Ok(capped)).unwrap();
        assert!(line.contains("800000 B send"), "{line}");
        assert!(line.contains("system limit"), "{line}");
        assert!(line.contains(&format!("reads {} B", 2 * CONNECTION_SOCKET_BUFFER)), "{line}");
    }
}
