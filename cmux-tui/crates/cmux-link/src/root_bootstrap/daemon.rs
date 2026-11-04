//! Seal private root stdin before terminal exec. Lifetime-only mode starts no
//! service; Native support is advertised only after an owned recipient attaches.
//! That recipient must drain and reap before returning a stop acknowledgement.
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::thread::JoinHandle;

use super::refused;
use crate::caller::verify_inherited_root_parent;

#[path = "daemon_native.rs"]
mod native;

/// Proof of Native support requested on this root parent's startup channel.
/// This cannot be constructed from a role frame or a public caller claim.
#[derive(Clone)]
pub struct NativePermit {
    _sealed: (),
}

/// A private root-parent watcher, owned by the session daemon's startup scope.
pub struct Daemon {
    parent: Arc<UnixStream>,
    control: Arc<UnixStream>,
    task: Option<JoinHandle<io::Result<()>>>,
    native: bool,
    pending: Option<UnixStream>,
}

impl Daemon {
    pub fn native_permit(&self) -> Option<NativePermit> {
        self.native.then_some(NativePermit { _sealed: () })
    }

    /// Attach only after the session mux and remote-entry path exist. The
    /// recipient returns only after stopping/draining and reaping its child.
    /// Its second socket ends when the root parent/control channel disappears.
    pub fn attach_native<F>(&mut self, recipient: F) -> io::Result<()>
    where
        F: Fn(UnixStream, UnixStream) -> io::Result<()> + Send + Sync + 'static,
    {
        if !self.native || self.task.is_some() {
            return Err(refused());
        }
        let endpoint = self.pending.take().ok_or_else(refused)?;
        let parent = self.parent.clone();
        let control = self.control.clone();
        let recipient = Arc::new(recipient);
        self.task =
            Some(std::thread::Builder::new().name("cmux-root-native".into()).spawn(move || {
                let result = native::run(&parent, &control, recipient);
                let _ = parent.shutdown(Shutdown::Both);
                let _ = control.shutdown(Shutdown::Both);
                result
            })?);
        if let Err(error) =
            cmux_unix_socket::descriptor::send(&self.parent, &[2], endpoint.as_raw_fd())
        {
            let _ = self.parent.shutdown(Shutdown::Both);
            let _ = self.control.shutdown(Shutdown::Both);
            return Err(error);
        }
        Ok(())
    }

    /// Call before any terminal-host exec. Ordinary stdin is left untouched.
    /// Valid private stdin is duplicated and sealed before later children run.
    pub fn from_stdin() -> io::Result<Option<Self>> {
        // SAFETY: fcntl validates stdin and returns a fresh owned descriptor.
        let fd = unsafe { libc::fcntl(0, libc::F_DUPFD_CLOEXEC, 3) };
        if fd < 0 {
            return Ok(None);
        }
        // SAFETY: fd is the fresh descriptor returned by F_DUPFD_CLOEXEC.
        let parent = UnixStream::from(unsafe { std::os::fd::OwnedFd::from_raw_fd(fd) });
        if verify_inherited_root_parent(parent.as_raw_fd()).is_err() {
            return Ok(None);
        }
        let mut magic = [0u8; 4];
        // SAFETY: a live socket and correctly sized output buffer. Peek
        // without consuming or blocking on unrelated root-owned stdin.
        let size = unsafe {
            libc::recv(
                parent.as_raw_fd(),
                magic.as_mut_ptr().cast(),
                magic.len(),
                libc::MSG_PEEK | libc::MSG_DONTWAIT,
            )
        };
        if size != magic.len() as isize || magic != super::MAGIC {
            return Ok(None);
        }
        let mut input = &parent;
        input.read_exact(&mut magic)?;
        // SAFETY: only this process's original private stdin flags are changed.
        let flags = unsafe { libc::fcntl(0, libc::F_GETFD) };
        if flags < 0 || unsafe { libc::fcntl(0, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
        // The root writes the optional suffix before spawn. Peek once without
        // delaying an old supervisor, and seal the common v1 prefix first so
        // an old daemon can safely refuse Native support without leaking stdin.
        let mut suffix = [0; 4];
        // SAFETY: live socket and correctly sized output buffer, no blocking.
        let size = unsafe {
            libc::recv(
                parent.as_raw_fd(),
                suffix.as_mut_ptr().cast(),
                suffix.len(),
                libc::MSG_PEEK | libc::MSG_DONTWAIT,
            )
        };
        let native = size == suffix.len() as isize && suffix == super::NATIVE;
        if native {
            input.read_exact(&mut suffix)?;
            // This daemon retains the original private frame while supervising
            // reception. Root startup must protect it before capability/keys.
            crate::caller::protect_private_process()?;
        }
        parent.set_nonblocking(true)?;
        let (control, host) = UnixStream::pair()?;
        // The returned endpoint was created after the work-uid transition:
        // its credentials name this actual child, not the inherited creator.
        control.set_nonblocking(true)?;
        let parent = Arc::new(parent);
        let control = Arc::new(control);
        if native {
            return Ok(Some(Self { parent, control, task: None, native, pending: Some(host) }));
        }
        cmux_unix_socket::descriptor::send(&parent, &[1], host.as_raw_fd())?;
        drop(host);
        let watched_parent = parent.clone();
        let watched_control = control.clone();
        let task = std::thread::Builder::new()
            .name("cmux-root-bootstrap".into())
            .spawn(move || run(&watched_parent, &watched_control))?;
        Ok(Some(Self { parent, control, task: Some(task), native, pending: None }))
    }

    pub fn wait(mut self) -> io::Result<()> {
        self.task.take().ok_or_else(refused)?.join().map_err(|_| refused())?
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.parent.shutdown(Shutdown::Both);
        let _ = self.control.shutdown(Shutdown::Both);
        if let Some(task) = self.task.take() {
            let _ = task.join();
        }
    }
}

fn stop(role: &mut Option<UnixStream>) -> io::Result<()> {
    if let Some(mut role) = role.take() {
        // Version 1 started nothing. A future serving recipient must retire
        // its actual receiver before producing this acknowledgement.
        role.write_all(&[1])?;
    }
    Ok(())
}

fn run(parent: &UnixStream, control: &UnixStream) -> io::Result<()> {
    let mut role: Option<UnixStream> = None;
    let result = (|| loop {
        let mut fds = vec![
            libc::pollfd { fd: parent.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: control.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        if let Some(role) = &role {
            fds.push(libc::pollfd { fd: role.as_raw_fd(), events: libc::POLLIN, revents: 0 });
        }
        // SAFETY: initialized descriptors remain owned throughout the wait.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if fds.first().is_some_and(|fd| fd.revents != 0) {
            return Ok(());
        }
        if fds.get(2).is_some_and(|fd| fd.revents != 0) {
            let mut byte = [0];
            let ended = role.as_mut().ok_or_else(refused)?.read(&mut byte)? == 0;
            stop(&mut role)?;
            if !ended {
                return Err(refused());
            }
        }
        if fds.get(1).is_some_and(|fd| fd.revents != 0) {
            let (bytes, descriptor) = cmux_unix_socket::descriptor::receive(control, 1)?;
            if bytes != [1] || role.is_some() {
                return Err(refused());
            }
            let received = UnixStream::from(descriptor.ok_or_else(refused)?);
            verify_inherited_root_parent(received.as_raw_fd()).map_err(io::Error::from)?;
            received.set_nonblocking(true)?;
            role = Some(received);
        }
    })();
    let stopped = stop(&mut role);
    result.and(stopped)
}
