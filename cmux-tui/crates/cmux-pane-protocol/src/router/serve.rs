//! Router connections: spawned providers on an inherited socketpair, and
//! self-started providers and surfaces on a 0600 unix socket.

use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::Path;
use std::sync::Arc;

use tokio::net::{UnixListener, UnixStream};

use super::{Admission, Router};
use crate::transport::{self, Transport};

/// The environment variable naming the inherited router fd in a spawned
/// provider.
pub const ROUTER_FD_ENV: &str = "CMUX_PANE_ROUTER_FD";
/// The fd number the router places its socketpair end at.
const CHILD_FD: i32 = 3;

impl Router {
    /// Spawn `command` as the provider for `app_id`, with the router's end
    /// of a socketpair at fd 3 (named by `CMUX_PANE_ROUTER_FD`). No
    /// filesystem socket exists for anyone else to connect to.
    pub fn spawn_provider(
        self: &Arc<Self>,
        app_id: &str,
        command: std::process::Command,
    ) -> std::io::Result<tokio::process::Child> {
        let (ours, theirs) = std::os::unix::net::UnixStream::pair()?;
        let their_fd = theirs.as_raw_fd();
        let mut command = tokio::process::Command::from(command);
        command.env(ROUTER_FD_ENV, CHILD_FD.to_string()).kill_on_drop(true);
        // SAFETY: only async-signal-safe calls (dup2, fcntl) run between fork
        // and exec, on fds that are open in the child.
        unsafe {
            command.pre_exec(move || {
                if their_fd == CHILD_FD {
                    let flags = libc::fcntl(CHILD_FD, libc::F_GETFD);
                    if flags < 0
                        || libc::fcntl(CHILD_FD, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0
                    {
                        return Err(std::io::Error::last_os_error());
                    }
                } else if libc::dup2(their_fd, CHILD_FD) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        drop(theirs);
        ours.set_nonblocking(true)?;
        let stream = UnixStream::from_std(ours)?;
        let router = self.clone();
        let admission = Admission::Spawned(app_id.to_owned());
        tokio::spawn(router.serve_connection(transport::unix(stream), admission));
        Ok(child)
    }
}

/// Listen on `path` for self-started providers and surfaces. The parent
/// directory is created 0700 if missing and must not be writable by group
/// or others; the socket is 0600.
pub fn listen(router: Arc<Router>, path: &Path) -> std::io::Result<tokio::task::JoinHandle<()>> {
    let parent = path.parent().ok_or_else(|| std::io::Error::other("socket path has no parent"))?;
    if !parent.exists() {
        std::fs::create_dir_all(parent)?;
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    }
    if std::fs::metadata(parent)?.permissions().mode() & 0o022 != 0 {
        return Err(std::io::Error::other(format!(
            "{} is writable by group or others",
            parent.display()
        )));
    }
    if let Ok(existing) = std::fs::symlink_metadata(path) {
        if !existing.file_type().is_socket() {
            return Err(std::io::Error::other(format!(
                "{} exists and is not a socket",
                path.display()
            )));
        }
        std::fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(tokio::spawn(async move {
        let handle = |(stream, _): (UnixStream, tokio::net::unix::SocketAddr)| {
            let connection =
                router.clone().serve_connection(transport::unix(stream), Admission::SelfStarted);
            tokio::spawn(connection);
        };
        let log = crate::net::log_accept_error("router unix socket");
        crate::net::accept_loop(|| listener.accept(), handle, log).await;
    }))
}

/// In a spawned provider: the router connection inherited at
/// `CMUX_PANE_ROUTER_FD`. Call once; it takes ownership of the fd.
pub fn connect_inherited() -> std::io::Result<Transport> {
    let fd: i32 = std::env::var(ROUTER_FD_ENV)
        .map_err(|_| std::io::Error::other(format!("{ROUTER_FD_ENV} is not set")))?
        .parse()
        .map_err(|_| std::io::Error::other(format!("{ROUTER_FD_ENV} is not an fd number")))?;
    // SAFETY: the router placed an open socketpair end at this fd for this
    // process, and nothing else in the process owns it.
    let stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    stream.set_nonblocking(true)?;
    // Keep the fd out of this provider's own children.
    // SAFETY: fcntl on an fd `stream` owns.
    unsafe {
        let flags = libc::fcntl(stream.as_raw_fd(), libc::F_GETFD);
        if flags >= 0 {
            libc::fcntl(stream.as_raw_fd(), libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
    }
    Ok(transport::unix(UnixStream::from_std(stream)?))
}
