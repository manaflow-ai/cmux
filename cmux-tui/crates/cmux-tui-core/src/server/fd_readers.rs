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
//! - One reader cannot end the others' watches: a panic in a reader ends
//!   its own watch, and the reader drops (Chrome's pump runs each watcher's
//!   callback on its own). If the thread ends anyway (a failed `poll`), every
//!   reader drops and the next watch starts a new thread.

use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::panic::{AssertUnwindSafe, catch_unwind};
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

/// The readers the thread has not taken yet. Once `ended`, the thread is
/// gone and takes none.
#[derive(Default)]
struct Added {
    readers: Vec<Box<dyn FdReader>>,
    ended: bool,
}

type Queue = Arc<Mutex<Added>>;

/// The started thread's hand-off: its queue and the write end of its wake
/// socket.
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
    /// watch. The first watch starts the thread, and so does the first one
    /// after the thread ended. An error drops `reader` unwatched.
    pub(crate) fn watch(&self, reader: Box<dyn FdReader>) -> std::io::Result<()> {
        let mut running = self.running.lock().recover_poison();
        let mut reader = Some(reader);
        if let Some(current) = running.as_ref() {
            let mut added = current.added.lock().recover_poison();
            if !added.ended {
                added.readers.extend(reader.take());
            }
        }
        if let Some(reader) = reader {
            let current = start()?;
            current.added.lock().recover_poison().readers.push(reader);
            *running = Some(current);
        }
        let Some(current) = running.as_ref() else {
            return Err(std::io::Error::other("the descriptor readers did not start"));
        };
        // One pending byte wakes the thread; a full socket means one is
        // pending already. Any other failure means the thread has ended:
        // its exit took the reader and ended that watch.
        let _ = (&current.wake).write(&[1]);
        Ok(())
    }
}

fn start() -> std::io::Result<Running> {
    let (wake, woken) = UnixStream::pair()?;
    wake.set_nonblocking(true)?;
    woken.set_nonblocking(true)?;
    let added = Queue::default();
    let exit = Exit { added: added.clone(), woken };
    // A request waits in `AcpmuxLink::call` for a reply this thread reads:
    // its class is the request's (threading-model.md, control streams).
    cmux_threads::spawn(
        "mux-fd-readers",
        crate::thread_qos::ThreadType::Interactive.qos(),
        move || {
            let mut exit = exit;
            run(&exit.added, &mut exit.woken);
        },
    )?;
    Ok(Running { added, wake })
}

/// The thread's end, however it ends: its queue takes no more readers, the
/// ones it had not taken drop, and only then does its wake socket close.
struct Exit {
    added: Queue,
    woken: UnixStream,
}

impl Drop for Exit {
    fn drop(&mut self) {
        let left = {
            let mut added = self.added.lock().recover_poison();
            added.ended = true;
            std::mem::take(&mut added.readers)
        };
        left.into_iter().for_each(end_watch);
    }
}

fn run(added: &Queue, woken: &mut UnixStream) {
    let mut readers: Vec<Box<dyn FdReader>> = Vec::new();
    let mut fds: Vec<libc::pollfd> = Vec::new();
    let mut ended: Vec<Box<dyn FdReader>> = Vec::new();
    loop {
        readers.append(&mut added.lock().recover_poison().readers);
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
            readers.drain(..).for_each(end_watch);
            return;
        }
        let mut ready = fds.iter().map(|fd| fd.revents != 0);
        if ready.next().unwrap_or(false) && !drain_wake(woken) {
            readers.drain(..).for_each(end_watch);
            return;
        }
        // A panic in a reader ends its watch alone.
        ended.extend(readers.extract_if(.., |reader| {
            ready.next().unwrap_or(false)
                && !catch_unwind(AssertUnwindSafe(|| reader.readable())).unwrap_or(false)
        }));
        ended.drain(..).for_each(end_watch);
    }
}

/// Drops a reader whose watch ended: a panic in its drop ends no other watch.
fn end_watch(reader: Box<dyn FdReader>) {
    let _ = catch_unwind(AssertUnwindSafe(move || drop(reader)));
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
        // reader with its descriptor; dropping the queue drops the ones it
        // had not taken.
        drop(self.running.lock().recover_poison().take());
    }
}

#[cfg(test)]
#[path = "fd_readers_tests.rs"]
mod tests;
