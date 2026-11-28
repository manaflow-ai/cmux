//! Owner-only local administration channel for a running remote daemon.
//!
//! Enrollment decisions mutate in-memory approval channels, so admin clients
//! talk to the daemon instead of reopening its state files in another process.

use std::fmt;
use std::future::Future;
use std::io;
#[cfg(any(target_os = "linux", target_vendor = "apple"))]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use cmux_remote_protocol::SessionId;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{Semaphore, oneshot, watch};
use tokio::task::JoinSet;

use crate::daemon::RemoteDaemon;
use crate::identity::{EnrollmentRelayAccess, IdentityError};
use crate::unix_socket::{
    OwnedUnixListener, UnixAcceptBackoff, UnixSocketCleanup, UnixSocketError,
};

const MAX_ADMIN_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_ADMIN_CONNECTIONS: usize = 32;
const ADMIN_IO_TIMEOUT: Duration = Duration::from_secs(5);

/// Failure to authenticate the process on the other end of a Unix socket.
#[derive(Debug)]
pub enum UnixPeerAuthError {
    Credentials(io::Error),
    WrongUid { peer_uid: u32, expected_uid: u32 },
}

impl fmt::Display for UnixPeerAuthError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Credentials(error) => {
                write!(formatter, "could not read Unix peer credentials: {error}")
            }
            Self::WrongUid { peer_uid, expected_uid } => write!(
                formatter,
                "Unix peer uid {peer_uid} does not match effective uid {expected_uid}"
            ),
        }
    }
}

impl std::error::Error for UnixPeerAuthError {}

/// Authenticates an authoritative Unix-socket responder as the effective user.
///
/// Clients must call this after connecting and before sending any bytes.
pub fn verify_unix_peer_owner(stream: &UnixStream) -> Result<(), UnixPeerAuthError> {
    verify_unix_peer_uid(stream, effective_uid())
}

pub(crate) fn verify_unix_peer_uid(
    stream: &UnixStream,
    expected_uid: u32,
) -> Result<(), UnixPeerAuthError> {
    let peer_uid = stream.peer_cred().map_err(UnixPeerAuthError::Credentials)?.uid();
    if peer_uid != expected_uid {
        return Err(UnixPeerAuthError::WrongUid { peer_uid, expected_uid });
    }
    Ok(())
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid has no preconditions and does not dereference pointers.
    unsafe { libc::geteuid() }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "method", rename_all = "kebab-case")]
pub enum AdminRequest {
    Status,
    CreateInvitation {
        #[serde(default = "default_invitation_ttl")]
        ttl_seconds: u64,
        #[serde(default)]
        route_hints: Vec<String>,
        #[serde(default)]
        relay_access: Vec<EnrollmentRelayAccess>,
    },
    Pending,
    Approve {
        invitation_id: String,
    },
    Deny {
        invitation_id: String,
    },
    Devices,
    Connections,
    Revoke {
        device_id: String,
    },
    Disconnect {
        device_id: String,
        session_id: String,
    },
    Shutdown,
    ShutdownLifecycle {
        lifecycle_id: String,
    },
}

const fn default_invitation_ttl() -> u64 {
    300
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdminResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl AdminResponse {
    fn success(value: impl Serialize) -> Self {
        match serde_json::to_value(value) {
            Ok(value) => Self { ok: true, result: Some(value), error: None },
            Err(error) => Self::failure(error.to_string()),
        }
    }

    fn failure(error: impl Into<String>) -> Self {
        Self { ok: false, result: None, error: Some(error.into()) }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonStatus {
    pub daemon_name: String,
    pub daemon_fingerprint: String,
    pub connected_clients: usize,
}

pub struct AdminServer {
    path: PathBuf,
    socket_cleanup: Arc<UnixSocketCleanup>,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<Result<(), AdminError>>>,
}

impl AdminServer {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn shutdown(mut self) -> Result<(), AdminError> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            return task.await.map_err(|error| {
                AdminError::Protocol(format!("admin listener task failed: {error}"))
            })?;
        }
        Ok(())
    }
}

impl Drop for AdminServer {
    fn drop(&mut self) {
        // The listener is owned by the accept task. Unlink the path here as
        // well, because aborting a task only schedules cancellation; its
        // listener may not be dropped before this wrapper returns.
        let _ = self.socket_cleanup.unlink();
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        // Dropping a JoinHandle detaches the accept loop. Abort it as a
        // fallback so an AdminServer dropped during runtime shutdown cannot
        // leave a listener task alive until the executor drains it.
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

pub async fn serve_admin(
    daemon: Arc<RemoteDaemon>,
    path: impl Into<PathBuf>,
    default_route_hints: Vec<String>,
) -> Result<AdminServer, AdminError> {
    serve_admin_with_shutdown(daemon, path, default_route_hints, None, None).await
}

pub async fn serve_admin_with_shutdown(
    daemon: Arc<RemoteDaemon>,
    path: impl Into<PathBuf>,
    default_route_hints: Vec<String>,
    lifecycle_id: Option<String>,
    owner_shutdown: Option<watch::Sender<bool>>,
) -> Result<AdminServer, AdminError> {
    let path = path.into();
    let listener = OwnedUnixListener::bind(path.clone()).await.map_err(|error| match error {
        UnixSocketError::Io(error) => AdminError::Io(error),
        UnixSocketError::Protocol(message) => {
            AdminError::Protocol(format!("could not own admin Unix socket: {message}"))
        }
    })?;
    let socket_cleanup = listener.cleanup();
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let permits = Arc::new(Semaphore::new(MAX_ADMIN_CONNECTIONS));
    let task = tokio::spawn(async move {
        let mut accept_backoff = UnixAcceptBackoff::new();
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    connections.shutdown().await;
                    return Ok(())
                },
                Some(_) = connections.join_next(), if !connections.is_empty() => {},
                accepted = listener.listener().accept() => {
                    let (stream, _) = match accepted {
                        Ok(accepted) => {
                            accept_backoff.reset();
                            accepted
                        }
                        Err(error) => {
                            let Some(delay) = accept_backoff.retry_delay(&error) else {
                                if let Some(owner_shutdown) = &owner_shutdown {
                                    let _ = owner_shutdown.send(true);
                                }
                                return Err(AdminError::Io(io::Error::new(
                                    error.kind(),
                                    format!("admin Unix listener accept failed: {error}"),
                                )));
                            };
                            tokio::select! {
                                _ = &mut shutdown_rx => {
                                    connections.shutdown().await;
                                    return Ok(())
                                },
                                _ = tokio::time::sleep(delay) => {}
                            }
                            continue;
                        }
                    };
                    if validate_peer(&stream).is_err() {
                        continue;
                    }
                    let Ok(permit) = permits.clone().try_acquire_owned() else {
                        continue;
                    };
                    let daemon = daemon.clone();
                    let default_route_hints = default_route_hints.clone();
                    let lifecycle_id = lifecycle_id.clone();
                    let owner_shutdown = owner_shutdown.clone();
                    connections.spawn(async move {
                        let _permit = permit;
                        let _ = serve_connection(
                            daemon,
                            default_route_hints,
                            lifecycle_id,
                            owner_shutdown,
                            stream,
                        )
                        .await;
                    });
                }
            }
        }
    });
    Ok(AdminServer { path, socket_cleanup, shutdown: Some(shutdown_tx), task: Some(task) })
}

pub async fn call_admin(
    path: impl AsRef<Path>,
    request: &AdminRequest,
) -> Result<AdminResponse, AdminError> {
    let stream = UnixStream::connect(path).await?;
    verify_unix_peer_owner(&stream)?;
    call_admin_over_stream(stream, request).await
}

/// Calls an owner-authenticated admin socket while retaining a kernel process
/// observer for the exact peer that accepted the request.
///
/// Upgrade handoff uses this for `Shutdown`: legacy daemons can remove their
/// lifecycle file before their final in-process writes complete, so filesystem
/// disappearance alone is not a process-exit fence.
pub async fn call_admin_with_peer_exit(
    path: impl AsRef<Path>,
    request: &AdminRequest,
) -> Result<(AdminResponse, UnixPeerProcessExit), AdminError> {
    let stream = UnixStream::connect(path).await?;
    verify_unix_peer_owner(&stream)?;
    let peer_pid = stream.peer_cred()?.pid().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "this platform cannot identify the admin peer process",
        )
    })?;
    let peer_exit = UnixPeerProcessExit::observe(peer_pid).map_err(|error| {
        io::Error::new(error.kind(), format!("could not observe the admin peer process: {error}"))
    })?;
    let response = call_admin_over_stream(stream, request).await?;
    Ok((response, peer_exit))
}

/// Kernel-backed exit observation for one exact Unix peer process.
pub struct UnixPeerProcessExit {
    #[cfg(target_os = "linux")]
    linux: LinuxPeerProcessExit,
    #[cfg(target_vendor = "apple")]
    descriptor: OwnedFd,
    exited: bool,
}

#[cfg(target_os = "linux")]
enum LinuxPeerProcessExit {
    PidFd(OwnedFd),
    Procfs(LinuxProcProcessExit),
}

#[cfg(target_os = "linux")]
struct LinuxProcProcessExit {
    directory: OwnedFd,
    start_time: u64,
}

#[cfg(target_os = "linux")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct LinuxProcStat {
    state: u8,
    start_time: u64,
}

#[cfg(target_os = "linux")]
impl LinuxProcStat {
    fn has_exited(self) -> bool {
        matches!(self.state, b'Z' | b'X' | b'x')
    }
}

#[cfg(all(test, target_os = "linux"))]
std::thread_local! {
    static FORCE_PIDFD_UNAVAILABLE: std::cell::Cell<bool> = const {
        std::cell::Cell::new(false)
    };
}

impl UnixPeerProcessExit {
    #[cfg(target_os = "linux")]
    fn observe(pid: libc::pid_t) -> io::Result<Self> {
        match Self::open_pidfd(pid) {
            Ok(descriptor) => {
                Ok(Self { linux: LinuxPeerProcessExit::PidFd(descriptor), exited: false })
            }
            Err(error) if pidfd_can_fall_back(&error) => {
                let (observer, exited) = LinuxProcProcessExit::observe(pid)?;
                Ok(Self { linux: LinuxPeerProcessExit::Procfs(observer), exited })
            }
            Err(error) => Err(error),
        }
    }

    #[cfg(target_os = "linux")]
    fn open_pidfd(pid: libc::pid_t) -> io::Result<OwnedFd> {
        #[cfg(test)]
        if FORCE_PIDFD_UNAVAILABLE.with(std::cell::Cell::get) {
            return Err(io::Error::from_raw_os_error(libc::ENOSYS));
        }
        let descriptor = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: pidfd_open returned a new owned descriptor.
        Ok(unsafe { OwnedFd::from_raw_fd(descriptor as libc::c_int) })
    }

    #[cfg(target_vendor = "apple")]
    fn observe(pid: libc::pid_t) -> io::Result<Self> {
        let descriptor = unsafe { libc::kqueue() };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: kqueue returned a new owned descriptor.
        let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
        let change = libc::kevent {
            ident: pid as libc::uintptr_t,
            filter: libc::EVFILT_PROC,
            flags: libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
            fflags: libc::NOTE_EXIT,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        let registered = unsafe {
            libc::kevent(
                descriptor.as_raw_fd(),
                &raw const change,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        };
        if registered < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { descriptor, exited: false })
    }

    #[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
    fn observe(_pid: libc::pid_t) -> io::Result<Self> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "kernel process-exit observation is unavailable",
        ))
    }

    /// Returns once the observed process has exited, including while it is
    /// waiting to be reaped by its parent.
    pub fn has_exited(&mut self) -> io::Result<bool> {
        if self.exited {
            return Ok(true);
        }
        self.exited = self.poll_exit()?;
        Ok(self.exited)
    }

    #[cfg(target_os = "linux")]
    fn poll_exit(&self) -> io::Result<bool> {
        match &self.linux {
            LinuxPeerProcessExit::PidFd(descriptor) => poll_pidfd(descriptor),
            LinuxPeerProcessExit::Procfs(observer) => observer.has_exited(),
        }
    }

    #[cfg(target_vendor = "apple")]
    fn poll_exit(&self) -> io::Result<bool> {
        let mut event = unsafe { std::mem::zeroed::<libc::kevent>() };
        let timeout = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        loop {
            let ready = unsafe {
                libc::kevent(
                    self.descriptor.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    &raw mut event,
                    1,
                    &raw const timeout,
                )
            };
            if ready > 0 {
                return Ok(true);
            }
            if ready == 0 {
                return Ok(false);
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }

    #[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
    fn poll_exit(&self) -> io::Result<bool> {
        Ok(false)
    }
}

#[cfg(target_os = "linux")]
fn pidfd_can_fall_back(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ENOSYS | libc::EPERM | libc::EACCES))
}

#[cfg(target_os = "linux")]
fn poll_pidfd(descriptor: &OwnedFd) -> io::Result<bool> {
    let mut descriptor =
        libc::pollfd { fd: descriptor.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    loop {
        let ready = unsafe { libc::poll(&raw mut descriptor, 1, 0) };
        if ready > 0 {
            if descriptor.revents & libc::POLLNVAL != 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "admin peer process descriptor became invalid",
                ));
            }
            return Ok(descriptor.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0);
        }
        if ready == 0 {
            return Ok(false);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(target_os = "linux")]
impl LinuxProcProcessExit {
    fn observe(pid: libc::pid_t) -> io::Result<(Self, bool)> {
        let path = std::ffi::CString::new(format!("/proc/{pid}"))
            .expect("a decimal process id cannot contain NUL");
        let directory = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        if directory < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: open returned a new owned descriptor.
        let directory = unsafe { OwnedFd::from_raw_fd(directory) };
        let stat = read_linux_proc_stat(&directory)?;
        Ok((Self { directory, start_time: stat.start_time }, stat.has_exited()))
    }

    fn has_exited(&self) -> io::Result<bool> {
        match read_linux_proc_stat(&self.directory) {
            Ok(stat) => Ok(stat.has_exited() || stat.start_time != self.start_time),
            Err(error) if matches!(error.raw_os_error(), Some(libc::ENOENT | libc::ESRCH)) => {
                Ok(true)
            }
            Err(error) => Err(error),
        }
    }
}

#[cfg(target_os = "linux")]
fn read_linux_proc_stat(directory: &OwnedFd) -> io::Result<LinuxProcStat> {
    use std::io::Read as _;

    const MAX_PROC_STAT_BYTES: u64 = 16 * 1024;
    let descriptor = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c"stat".as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openat returned a new owned descriptor.
    let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
    let mut contents = Vec::new();
    std::fs::File::from(descriptor).take(MAX_PROC_STAT_BYTES + 1).read_to_end(&mut contents)?;
    if contents.len() as u64 > MAX_PROC_STAT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "admin peer process stat exceeded the size limit",
        ));
    }
    parse_linux_proc_stat(&contents)
}

#[cfg(target_os = "linux")]
fn parse_linux_proc_stat(contents: &[u8]) -> io::Result<LinuxProcStat> {
    let comm_end = contents
        .windows(2)
        .rposition(|window| window == b") ")
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "malformed process stat"))?;
    let mut fields =
        contents[comm_end + 2..].split(u8::is_ascii_whitespace).filter(|field| !field.is_empty());
    let state = fields
        .next()
        .filter(|field| field.len() == 1)
        .map(|field| field[0])
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing process state"))?;
    // starttime is field 22. `fields` now starts at field 4 because state,
    // field 3, was consumed above.
    let start_time = fields
        .nth(18)
        .and_then(|field| std::str::from_utf8(field).ok())
        .and_then(|field| field.parse().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing process start time"))?;
    Ok(LinuxProcStat { state, start_time })
}

#[cfg(test)]
async fn call_admin_with_expected_uid(
    path: impl AsRef<Path>,
    request: &AdminRequest,
    expected_uid: u32,
) -> Result<AdminResponse, AdminError> {
    let stream = UnixStream::connect(path).await?;
    verify_unix_peer_uid(&stream, expected_uid)?;
    call_admin_over_stream(stream, request).await
}

async fn call_admin_over_stream(
    mut stream: UnixStream,
    request: &AdminRequest,
) -> Result<AdminResponse, AdminError> {
    let mut encoded = serde_json::to_vec(request)?;
    if encoded.len().saturating_add(1) > MAX_ADMIN_MESSAGE_BYTES {
        return Err(AdminError::MessageTooLarge(encoded.len()));
    }
    encoded.push(b'\n');
    timeout_admin_io("writing admin request", stream.write_all(&encoded)).await?;
    // The newline completes the request. A write-half close can race the
    // daemon's one-response close and return ENOTCONN on macOS.
    let mut reader = BufReader::new(stream);
    let mut response = Vec::new();
    let size = timeout_admin_io(
        "reading admin response",
        read_bounded_admin_message(&mut reader, &mut response),
    )
    .await?;
    if size == 0 {
        return Err(AdminError::Protocol("daemon closed the admin connection".into()));
    }
    if size > MAX_ADMIN_MESSAGE_BYTES {
        return Err(AdminError::MessageTooLarge(size));
    }
    Ok(serde_json::from_slice(&response)?)
}

async fn serve_connection(
    daemon: Arc<RemoteDaemon>,
    default_route_hints: Vec<String>,
    lifecycle_id: Option<String>,
    owner_shutdown: Option<watch::Sender<bool>>,
    stream: UnixStream,
) -> Result<(), AdminError> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut encoded = Vec::new();
    let size = timeout_admin_io(
        "reading admin request",
        read_bounded_admin_message(&mut reader, &mut encoded),
    )
    .await?;
    let response = if size == 0 {
        AdminResponse::failure("empty admin request")
    } else if size > MAX_ADMIN_MESSAGE_BYTES {
        AdminResponse::failure("admin request is too large")
    } else {
        match serde_json::from_slice::<AdminRequest>(&encoded) {
            Ok(request) => {
                dispatch(
                    &daemon,
                    &default_route_hints,
                    lifecycle_id.as_deref(),
                    owner_shutdown.as_ref(),
                    request,
                )
                .await
            }
            Err(error) => AdminResponse::failure(format!("invalid admin request: {error}")),
        }
    };
    let response = encode_admin_response(response)?;
    timeout_admin_io("writing admin response", writer.write_all(&response)).await?;
    timeout_admin_io("closing admin response", writer.shutdown()).await?;
    Ok(())
}

fn encode_admin_response(response: AdminResponse) -> Result<Vec<u8>, AdminError> {
    let mut encoded = serde_json::to_vec(&response)?;
    if encoded.len().saturating_add(1) > MAX_ADMIN_MESSAGE_BYTES {
        encoded = serde_json::to_vec(&AdminResponse::failure("admin response is too large"))?;
    }
    encoded.push(b'\n');
    Ok(encoded)
}

async fn read_bounded_admin_message<R>(reader: &mut R, encoded: &mut Vec<u8>) -> io::Result<usize>
where
    R: AsyncBufRead + Unpin,
{
    encoded.clear();
    let size = reader.take((MAX_ADMIN_MESSAGE_BYTES + 1) as u64).read_until(b'\n', encoded).await?;
    if encoded.last() == Some(&b'\n') {
        encoded.pop();
    }
    Ok(size)
}

async fn timeout_admin_io<T>(
    operation: &'static str,
    future: impl Future<Output = io::Result<T>>,
) -> Result<T, AdminError> {
    tokio::time::timeout(ADMIN_IO_TIMEOUT, future)
        .await
        .map_err(|_| {
            AdminError::Io(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("timed out {operation}"),
            ))
        })?
        .map_err(AdminError::Io)
}

async fn dispatch(
    daemon: &RemoteDaemon,
    default_route_hints: &[String],
    lifecycle_id: Option<&str>,
    owner_shutdown: Option<&watch::Sender<bool>>,
    request: AdminRequest,
) -> AdminResponse {
    let auth = daemon.auth();
    let result: Result<Value, IdentityError> = match request {
        AdminRequest::Status => Ok(serde_json::to_value(DaemonStatus {
            daemon_name: auth.daemon_name().to_string(),
            daemon_fingerprint: auth.identity().fingerprint(),
            connected_clients: daemon.connections().await.len(),
        })
        .expect("daemon status is serializable")),
        AdminRequest::CreateInvitation { ttl_seconds, route_hints, relay_access } => auth
            .create_invitation_with_relay_access(
                Duration::from_secs(ttl_seconds),
                if route_hints.is_empty() { default_route_hints.to_vec() } else { route_hints },
                relay_access,
            )
            .await
            .and_then(|invitation| invitation.to_uri())
            .map(|uri| serde_json::json!({ "uri": uri })),
        AdminRequest::Pending => Ok(serde_json::to_value(auth.pending_enrollments().await)
            .expect("pending enrollments are serializable")),
        AdminRequest::Approve { invitation_id } => auth
            .approve(&invitation_id)
            .await
            .map(|record| serde_json::to_value(record).expect("device record is serializable")),
        AdminRequest::Deny { invitation_id } => {
            auth.deny(&invitation_id).await.map(|()| serde_json::json!({}))
        }
        AdminRequest::Devices => Ok(serde_json::to_value(auth.list_devices().await)
            .expect("device records are serializable")),
        AdminRequest::Connections => Ok(serde_json::to_value(daemon.connection_snapshots().await)
            .expect("connection snapshots are serializable")),
        AdminRequest::Revoke { device_id } => {
            auth.revoke(&device_id).await.map(|()| serde_json::json!({}))
        }
        AdminRequest::Disconnect { device_id, session_id } => {
            match SessionId::from_hex(&session_id) {
                Ok(session_id) => match daemon.disconnect(&device_id, session_id).await {
                    Ok(true) => Ok(serde_json::json!({ "disconnected": true })),
                    Ok(false) => Err(IdentityError::Invalid(format!(
                        "no active session {session_id:?} for device {device_id}"
                    ))),
                    Err(error) => Err(IdentityError::Invalid(format!(
                        "could not disconnect session: {error}"
                    ))),
                },
                Err(error) => Err(IdentityError::Invalid(error)),
            }
        }
        AdminRequest::Shutdown => request_shutdown(lifecycle_id, None, owner_shutdown),
        AdminRequest::ShutdownLifecycle { lifecycle_id: requested_lifecycle_id } => {
            request_shutdown(lifecycle_id, Some(&requested_lifecycle_id), owner_shutdown)
        }
    };
    match result {
        Ok(value) => AdminResponse::success(value),
        Err(error) => AdminResponse::failure(error.to_string()),
    }
}

fn request_shutdown(
    lifecycle_id: Option<&str>,
    requested_lifecycle_id: Option<&str>,
    owner_shutdown: Option<&watch::Sender<bool>>,
) -> Result<Value, IdentityError> {
    match (lifecycle_id, requested_lifecycle_id) {
        (None, None) => {}
        (Some(expected), Some(requested)) if expected == requested => {}
        (Some(_), Some(_)) => {
            return Err(IdentityError::Invalid(
                "daemon lifecycle changed before shutdown was authorized".into(),
            ));
        }
        (Some(_), None) => {
            return Err(IdentityError::Invalid(
                "daemon shutdown requires its lifecycle identity".into(),
            ));
        }
        (None, Some(_)) => {
            return Err(IdentityError::Invalid(
                "legacy daemon shutdown does not accept a lifecycle identity".into(),
            ));
        }
    }
    match owner_shutdown {
        Some(shutdown) => shutdown
            .send(true)
            .map(|()| serde_json::json!({ "shutting_down": true }))
            .map_err(|_| IdentityError::Invalid("daemon is already shutting down".into())),
        None => Err(IdentityError::Invalid(
            "daemon shutdown is unavailable on this admin socket".into(),
        )),
    }
}

fn validate_peer(stream: &UnixStream) -> Result<(), AdminError> {
    verify_unix_peer_owner(stream).map_err(AdminError::from)
}

#[derive(Debug)]
pub enum AdminError {
    Io(io::Error),
    Json(serde_json::Error),
    Protocol(String),
    MessageTooLarge(usize),
    UnauthorizedPeer(u32),
}

impl fmt::Display for AdminError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "admin socket failed: {error}"),
            Self::Json(error) => write!(formatter, "admin JSON failed: {error}"),
            Self::Protocol(message) => write!(formatter, "admin protocol failed: {message}"),
            Self::MessageTooLarge(size) => write!(formatter, "admin message is too large: {size}"),
            Self::UnauthorizedPeer(uid) => write!(formatter, "admin peer uid {uid} is not allowed"),
        }
    }
}

impl std::error::Error for AdminError {}

impl From<io::Error> for AdminError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for AdminError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl From<UnixPeerAuthError> for AdminError {
    fn from(error: UnixPeerAuthError) -> Self {
        match error {
            UnixPeerAuthError::Credentials(error) => Self::Io(error),
            UnixPeerAuthError::WrongUid { peer_uid, .. } => Self::UnauthorizedPeer(peer_uid),
        }
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;
    use tokio::time::{Duration as TokioDuration, timeout};

    use super::*;
    use crate::identity::AuthDatabase;
    use crate::session::SessionLimits;
    use crate::unix_socket::TestFileDescriptorExhaustion;

    #[test]
    fn admin_listener_retries_recoverable_accept_errors() {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "admin::tests::admin_listener_accept_exhaustion_fixture",
                "--nocapture",
            ])
            .env("CMUX_TEST_ADMIN_ACCEPT_EXHAUSTION", "1")
            .status()
            .unwrap();

        assert!(status.success(), "admin listener stopped after a recoverable accept error");
    }

    #[tokio::test]
    async fn admin_listener_accept_exhaustion_fixture() {
        if std::env::var_os("CMUX_TEST_ADMIN_ACCEPT_EXHAUSTION").is_none() {
            return;
        }

        let directory = tempdir().unwrap();
        let auth = AuthDatabase::load_or_create(
            directory.path().join("state"),
            "accept-retry-admin",
            true,
        )
        .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();
        let _queued = std::os::unix::net::UnixStream::connect(&socket).unwrap();
        let mut exhaustion = TestFileDescriptorExhaustion::exhaust();

        tokio::time::sleep(TokioDuration::from_millis(75)).await;
        exhaustion.restore();

        let response =
            timeout(TokioDuration::from_secs(2), call_admin(&socket, &AdminRequest::Status))
                .await
                .expect("admin listener never retried after file-descriptor exhaustion")
                .unwrap();
        assert!(response.ok);
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn admin_server_shutdown_reports_listener_task_failure() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "failed-admin-task", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();
        server.task.as_ref().unwrap().abort();

        let error = server.shutdown().await.unwrap_err();

        assert!(error.to_string().contains("admin listener task failed"), "{error}");
    }

    #[tokio::test]
    async fn owner_can_create_invitation_and_read_status() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "test", true).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let server =
            serve_admin(daemon, &socket, vec!["ws://127.0.0.1:1/v1/link".into()]).await.unwrap();

        let status = call_admin(&socket, &AdminRequest::Status).await.unwrap();
        assert!(status.ok);
        assert_eq!(status.result.unwrap()["daemon_name"], "test");

        let invitation = call_admin(
            &socket,
            &AdminRequest::CreateInvitation {
                ttl_seconds: 60,
                route_hints: vec![],
                relay_access: vec![],
            },
        )
        .await
        .unwrap();
        assert!(invitation.ok);
        assert!(invitation.result.unwrap()["uri"].as_str().unwrap().starts_with("cmux://enroll/"));
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn legacy_owner_can_request_runtime_shutdown() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "shutdown-test", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let server =
            serve_admin_with_shutdown(daemon, &socket, Vec::new(), None, Some(shutdown_tx))
                .await
                .unwrap();

        let response = call_admin(&socket, &AdminRequest::Shutdown).await.unwrap();
        assert!(response.ok);
        shutdown_rx.changed().await.unwrap();
        assert!(*shutdown_rx.borrow());
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn lifecycle_shutdown_requires_the_matching_daemon_instance() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "shutdown-test", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let server = serve_admin_with_shutdown(
            daemon,
            &socket,
            Vec::new(),
            Some("current-lifecycle".into()),
            Some(shutdown_tx),
        )
        .await
        .unwrap();

        let mismatch = call_admin(
            &socket,
            &AdminRequest::ShutdownLifecycle { lifecycle_id: "stale-lifecycle".into() },
        )
        .await
        .unwrap();
        assert!(!mismatch.ok);
        assert!(!*shutdown_rx.borrow());
        assert!(!shutdown_rx.has_changed().unwrap());

        let legacy = call_admin(&socket, &AdminRequest::Shutdown).await.unwrap();
        assert!(!legacy.ok);
        assert!(!*shutdown_rx.borrow());
        assert!(!shutdown_rx.has_changed().unwrap());

        let matching = call_admin(
            &socket,
            &AdminRequest::ShutdownLifecycle { lifecycle_id: "current-lifecycle".into() },
        )
        .await
        .unwrap();
        assert!(matching.ok);
        shutdown_rx.changed().await.unwrap();
        assert!(*shutdown_rx.borrow());
        server.shutdown().await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn admin_socket_rejects_an_intermediate_symlink_before_creating_the_parent() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().unwrap();
        let target = directory.path().join("target");
        let alias = directory.path().join("alias");
        std::fs::create_dir(&target).unwrap();
        symlink(&target, &alias).unwrap();

        let result = OwnedUnixListener::bind(alias.join("missing/admin.sock")).await;

        assert!(result.is_err(), "intermediate symlink was accepted");
        assert!(!target.join("missing").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn admin_server_respects_the_socket_path_lock() {
        use std::fs::OpenOptions;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let directory = tempdir().unwrap();
        let socket = directory.path().join("admin.sock");
        let stale = UnixListener::bind(&socket).unwrap();
        drop(stale);
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(directory.path().join("admin.sock.lock"))
            .unwrap();
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "locked-admin", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());

        let result = serve_admin(daemon, &socket, Vec::new()).await;
        let ignored_lock = result.is_ok();
        if let Ok(server) = result {
            server.shutdown().await.unwrap();
        }
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);

        assert!(!ignored_lock, "admin socket ignored its ownership lock");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn admin_server_shutdown_never_unlinks_a_bound_successor() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("admin.sock");
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "admin-successor", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();

        std::fs::remove_file(&socket).unwrap();
        let successor = UnixListener::bind(&socket).unwrap();
        server.shutdown().await.unwrap();
        let successor_preserved = socket.exists();
        let reachable = timeout(TokioDuration::from_secs(1), UnixStream::connect(&socket))
            .await
            .is_ok_and(|result| result.is_ok());
        drop(successor);
        let _ = std::fs::remove_file(&socket);

        assert!(successor_preserved, "old admin server unlinked its successor socket");
        assert!(reachable, "successor admin socket was unreachable after old-server shutdown");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn repeated_admin_requests_do_not_fail_spuriously() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "stress-test", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();

        for iteration in 0..1_000 {
            let response =
                call_admin(&socket, &AdminRequest::Connections).await.unwrap_or_else(|error| {
                    panic!("admin request {iteration} failed spuriously: {error}")
                });
            assert!(response.ok);
        }

        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn oversized_unterminated_request_is_rejected_without_waiting_for_eof() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "bounded-test", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();
        let mut stream = UnixStream::connect(&socket).await.unwrap();
        verify_unix_peer_owner(&stream).unwrap();
        stream.write_all(&vec![b'x'; MAX_ADMIN_MESSAGE_BYTES + 1]).await.unwrap();

        let mut reader = BufReader::new(stream);
        let mut encoded = Vec::new();
        timeout(TokioDuration::from_secs(1), reader.read_until(b'\n', &mut encoded))
            .await
            .expect("oversized request remained buffered until EOF")
            .unwrap();
        let response: AdminResponse = serde_json::from_slice(&encoded).unwrap();
        assert!(!response.ok);
        assert_eq!(response.error.as_deref(), Some("admin request is too large"));

        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn exact_maximum_request_payload_is_accepted_before_dispatch() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "boundary-test", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();
        let empty = AdminRequest::Deny { invitation_id: String::new() };
        let fixed_bytes = serde_json::to_vec(&empty).unwrap().len();
        let request = AdminRequest::Deny {
            invitation_id: "x".repeat(MAX_ADMIN_MESSAGE_BYTES - fixed_bytes - 1),
        };
        assert_eq!(serde_json::to_vec(&request).unwrap().len() + 1, MAX_ADMIN_MESSAGE_BYTES);

        let response = call_admin(&socket, &request).await.unwrap();

        assert_eq!(response.error.as_deref(), Some("admin response is too large"));
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn exact_maximum_response_payload_is_accepted_before_decode() {
        let empty = AdminResponse::failure("");
        let fixed_bytes = serde_json::to_vec(&empty).unwrap().len();
        let expected =
            AdminResponse::failure("x".repeat(MAX_ADMIN_MESSAGE_BYTES - fixed_bytes - 1));
        let mut encoded = serde_json::to_vec(&expected).unwrap();
        assert_eq!(encoded.len() + 1, MAX_ADMIN_MESSAGE_BYTES);
        encoded.push(b'\n');
        let (client, server) = UnixStream::pair().unwrap();
        let responder = tokio::spawn(async move {
            let (reader, mut writer) = server.into_split();
            let mut reader = BufReader::new(reader);
            let mut request = Vec::new();
            reader.read_until(b'\n', &mut request).await.unwrap();
            writer.write_all(&encoded).await.unwrap();
        });

        let actual = call_admin_over_stream(client, &AdminRequest::Status).await.unwrap();

        assert_eq!(actual, expected);
        responder.await.unwrap();
    }

    #[tokio::test]
    async fn client_rejects_wrong_uid_responder_before_writing_request() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("impostor-admin.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let responder = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut byte = [0_u8; 1];
            timeout(TokioDuration::from_secs(1), stream.read(&mut byte))
                .await
                .expect("admin client kept the rejected connection open")
                .unwrap()
        });
        let wrong_uid = unsafe { libc::geteuid() }.wrapping_add(1);

        let error = call_admin_with_expected_uid(&socket, &AdminRequest::Status, wrong_uid)
            .await
            .unwrap_err();

        assert!(matches!(error, AdminError::UnauthorizedPeer(_)));
        assert_eq!(responder.await.unwrap(), 0, "admin request leaked to the wrong-uid responder");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn peer_exit_observer_falls_back_when_pidfd_is_unavailable() {
        let mut child = std::process::Command::new("sh")
            .args(["-c", "sleep 30"])
            .spawn()
            .expect("could not start fallback process fixture");
        FORCE_PIDFD_UNAVAILABLE.with(|forced| forced.set(true));
        let observer = UnixPeerProcessExit::observe(child.id() as libc::pid_t);
        FORCE_PIDFD_UNAVAILABLE.with(|forced| forced.set(false));

        let mut observer =
            observer.expect("pidfd unavailability disabled remote daemon process fencing");
        assert!(!observer.has_exited().unwrap());
        child.kill().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !observer.has_exited().unwrap() {
            assert!(
                std::time::Instant::now() < deadline,
                "procfs fallback did not observe process exit"
            );
            std::thread::sleep(Duration::from_millis(1));
        }
        child.wait().unwrap();
    }
}
