//! One thread reads every socket and pipe the daemon watches for another
//! process (p05-ipc-147): the acpmux links (`agent_session_link.rs`) and the
//! browser hosts' stdout (`browser_runtime.rs`). Each used to hold a thread
//! blocked in `read` (`mux-acpmux-link`, `mux-browser-runtime-out`), so 5
//! agent attachments held 5 threads. Chrome reads every pipe of a process
//! on its one IO thread, whose message pump watches each descriptor
//! (base/message_loop/message_pump_epoll.cc, `WatchFileDescriptor`;
//! base/files/file_descriptor_watcher_posix.h) and runs a callback when it
//! is readable; this is that thread.
//!
//! - A reader owns its descriptor, set non-blocking, and reads what it holds
//!   when `poll` says it is readable or hung up. It never waits: the
//!   handlers it calls only queue (an attachment's stream, a reply slot).
//! - Its watch ends when it returns false (an end of file, an error), and
//!   the reader drops with its descriptor. Closing the socket from another
//!   thread (`AcpmuxLink::close`) ends it that way.
//! - The thread starts with the first watch and waits in `poll` with no
//!   timeout: no watched descriptor ready, no wakeup. A watch added later
//!   reaches it through a wake socket; dropping the owner closes that
//!   socket's write end, which ends the thread and drops every reader.

use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::Arc;

use cmux_threads::sync::Mutex;

use crate::panic_free::RecoverPoison;

/// A watched descriptor's reader. It runs on the readers' thread, so it
/// never waits.
pub(crate) trait FdReader: Send + 'static {
    /// The descriptor it reads. The reader owns it and keeps it open, set
    /// non-blocking, for as long as it is watched.
    fn fd(&self) -> RawFd;
    /// The descriptor is readable or hung up: reads what it holds without
    /// waiting. False ends the watch, and the reader drops.
    fn readable(&mut self) -> bool;
}

type Queue = Arc<Mutex<Vec<Box<dyn FdReader>>>>;

/// The started thread's hand-off: the readers it has not taken yet, and
/// the write end of its wake socket.
struct Running {
    added: Queue,
    wake: UnixStream,
}

/// The daemon's descriptor readers: one thread for every watch.
#[derive(Default)]
pub(crate) struct FdReaders {
    running: Mutex<Option<Running>>,
}

impl FdReaders {
    /// Reads `reader`'s descriptor on the readers' thread until it ends the
    /// watch. The first watch starts the thread.
    pub(crate) fn watch(&self, reader: Box<dyn FdReader>) -> std::io::Result<()> {
        let mut running = self.running.lock().recover_poison();
        if running.is_none() {
            *running = Some(start()?);
        }
        let Some(running) = running.as_mut() else {
            return Err(std::io::Error::other("the descriptor readers did not start"));
        };
        running.added.lock().recover_poison().push(reader);
        // One pending byte wakes the thread; a full socket means one is
        // pending already.
        match running.wake.write(&[1]) {
            Ok(_) => Ok(()),
            Err(error) if error.kind() == ErrorKind::WouldBlock => Ok(()),
            Err(error) => Err(error),
        }
    }
}

fn start() -> std::io::Result<Running> {
    let (wake, woken) = UnixStream::pair()?;
    wake.set_nonblocking(true)?;
    woken.set_nonblocking(true)?;
    let added = Queue::default();
    let taken = added.clone();
    // A request waits in `AcpmuxLink::call` for a reply this thread reads:
    // its class is the request's (threading-model.md, control streams).
    cmux_threads::spawn(
        "mux-fd-readers",
        crate::thread_qos::ThreadType::Interactive.qos(),
        move || run(&taken, woken),
    )?;
    Ok(Running { added, wake })
}

fn run(added: &Queue, mut woken: UnixStream) {
    let mut readers: Vec<Box<dyn FdReader>> = Vec::new();
    let mut fds: Vec<libc::pollfd> = Vec::new();
    loop {
        readers.append(&mut added.lock().recover_poison());
        fds.clear();
        fds.push(libc::pollfd { fd: woken.as_raw_fd(), events: libc::POLLIN, revents: 0 });
        fds.extend(readers.iter().map(|reader| libc::pollfd {
            fd: reader.fd(),
            events: libc::POLLIN,
            revents: 0,
        }));
        // No timeout: with nothing ready the thread does not wake.
        // SAFETY: `fds` is a valid array of pollfd for its length.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if ready < 0 {
            if std::io::Error::last_os_error().kind() == ErrorKind::Interrupted {
                continue;
            }
            // A broken poll cannot wait; end every watch rather than spin.
            eprintln!(
                "cmux-tui: descriptor readers: poll failed: {}",
                std::io::Error::last_os_error()
            );
            return;
        }
        let mut ready = fds.iter().map(|fd| fd.revents != 0);
        if ready.next().unwrap_or(false) && !drain_wake(&mut woken) {
            return;
        }
        readers.retain_mut(|reader| !ready.next().unwrap_or(false) || reader.readable());
    }
}

/// Reads the wake bytes. False once the owner dropped (an end of file).
fn drain_wake(woken: &mut UnixStream) -> bool {
    let mut bytes = [0_u8; 64];
    loop {
        match woken.read(&mut bytes) {
            Ok(0) => return false,
            Ok(_) => {}
            Err(error) if error.kind() == ErrorKind::WouldBlock => return true,
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(_) => return false,
        }
    }
}

impl Drop for FdReaders {
    fn drop(&mut self) {
        // Dropping the wake's write end ends the thread, which drops every
        // reader with its descriptor.
        drop(self.running.lock().recover_poison().take());
    }
}

#[cfg(test)]
#[path = "fd_readers_tests.rs"]
mod tests;
