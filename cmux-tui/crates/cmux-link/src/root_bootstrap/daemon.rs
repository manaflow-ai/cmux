//! Version 1 acknowledges only an empty lifetime fence. No service or private
//! payload is accepted by this transport-only recipient.
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::thread::JoinHandle;

use super::refused;
use crate::caller::verify_inherited_root_parent;

/// A private root-parent watcher, owned by the session daemon's startup scope.
pub struct Daemon {
    parent: Arc<UnixStream>,
    control: Arc<UnixStream>,
    task: Option<JoinHandle<io::Result<()>>>,
}

impl Daemon {
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
        parent.set_nonblocking(true)?;
        let (control, host) = UnixStream::pair()?;
        // The returned endpoint was created after the work-uid transition:
        // its credentials name this actual child, not the inherited creator.
        cmux_unix_socket::descriptor::send(&parent, &[1], host.as_raw_fd())?;
        drop(host);
        control.set_nonblocking(true)?;
        let parent = Arc::new(parent);
        let control = Arc::new(control);
        let watched_parent = parent.clone();
        let watched_control = control.clone();
        let task = std::thread::Builder::new()
            .name("cmux-root-bootstrap".into())
            .spawn(move || run(&watched_parent, &watched_control))?;
        Ok(Some(Self { parent, control, task: Some(task) }))
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
        if fds[0].revents != 0 {
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
        if fds[1].revents != 0 {
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
