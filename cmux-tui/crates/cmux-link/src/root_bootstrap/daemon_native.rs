//! Native recipients own the whole receiving lifetime. Completion is observed
//! before accepting a replacement role, and root is acknowledged after drain.
use std::io::{self, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::thread::JoinHandle;

use super::refused;
use crate::caller::verify_inherited_root_parent;

type Recipient = Arc<dyn Fn(UnixStream, UnixStream) -> io::Result<()> + Send + Sync>;

struct Active {
    stop: UnixStream,
    done: UnixStream,
    task: Option<JoinHandle<io::Result<()>>>,
}

impl Active {
    fn start(role: UnixStream, recipient: Recipient) -> io::Result<Self> {
        let mut receipt = role.try_clone()?;
        let (stop, watch) = UnixStream::pair()?;
        let (done, finished) = UnixStream::pair()?;
        let task =
            std::thread::Builder::new().name("cmux-native-role".into()).spawn(move || {
                if recipient(role, watch).is_err() {
                    // The recipient has already drained and reaped its child.
                    // A failed attempt must not close the daemon's root control
                    // channel: root retires its generation before another role.
                    eprintln!("cmux link: Native receiving attempt stopped");
                }
                // Resources are gone before either signal. Make done observable
                // BEFORE root can receive its ack and send the next role fd.
                drop(finished);
                receipt.write_all(&[1])
            })?;
        Ok(Self { stop, done, task: Some(task) })
    }

    fn finish(mut self) -> io::Result<()> {
        self.task.take().ok_or_else(refused)?.join().map_err(|_| refused())?
    }
}

impl Drop for Active {
    fn drop(&mut self) {
        let _ = self.stop.shutdown(Shutdown::Both);
        if let Some(task) = self.task.take() {
            let _ = task.join();
        }
    }
}

pub(super) fn run(
    parent: &UnixStream,
    control: &UnixStream,
    recipient: Recipient,
) -> io::Result<()> {
    let mut active: Option<Active> = None;
    loop {
        let mut fds = vec![
            libc::pollfd { fd: parent.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: control.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        if let Some(role) = &active {
            fds.push(libc::pollfd { fd: role.done.as_raw_fd(), events: libc::POLLIN, revents: 0 });
        }
        // SAFETY: all initialized descriptors remain owned throughout poll.
        if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) } < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if fds[0].revents != 0 {
            return Ok(());
        }
        // Complete the previous recipient before reading a replacement role.
        if fds.get(2).is_some_and(|fd| fd.revents != 0) {
            active.take().ok_or_else(refused)?.finish()?;
        }
        if fds[1].revents != 0 {
            let (bytes, descriptor) = cmux_unix_socket::descriptor::receive(control, 1)?;
            if bytes != [2] || active.is_some() {
                return Err(refused());
            }
            let role = UnixStream::from(descriptor.ok_or_else(refused)?);
            verify_inherited_root_parent(role.as_raw_fd()).map_err(io::Error::from)?;
            role.set_nonblocking(true)?;
            active = Some(Active::start(role, recipient.clone())?);
        }
    }
}
