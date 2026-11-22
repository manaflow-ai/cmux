//! The room check of the inline key write (#35872; #35413 s17ga, STATUS 13254, 13302): whether one host connection's
//! socket takes a small frame whole, now, without waiting, on the key's own request thread.
//!
//! - macOS: a send with MSG_DONTWAIT on a blocking stream socket still waits for room (XNU honours only the socket's
//!   own non-blocking mode there, and this socket blocks: its reader shares it), so the room is checked first. A
//!   zero-timeout poll() did that, but XNU's poll opens a kernel event queue, registers a knote under the socket lock
//!   and frees both on every call, and sleeps about 10 us when there is no room. The s17ga A/B measured the lane's
//!   write call at 0.019-0.020 ms at p50 against 0.005 ms for the old path's direct write. Each connection now keeps
//!   one queue with the socket's write filter registered once, and a key reads it with
//!   kevent64(KEVENT_FLAG_IMMEDIATE): one call, no allocation, no sleep.
//! - Linux: MSG_DONTWAIT is honoured, and a Unix stream socket takes a frame this small whole or not at all, so the
//!   send needs no check.
//! - Other Unix targets: a zero-timeout poll().

use std::os::fd::RawFd;

/// One host connection's room check. Made with the connection's input route and used only under the connection's
/// writer guard: that writer is the socket's only writer, so the room cannot shrink between the check and the send.
#[derive(Default)]
pub(crate) struct RoomCheck {
    /// The connection's kernel event queue, made at its first key; `None` when `kqueue()` failed (poll() instead).
    #[cfg(target_vendor = "apple")]
    queue: std::sync::OnceLock<Option<WriteQueue>>,
}

impl RoomCheck {
    /// Whether the socket `fd` takes `len` more bytes now, whole, without waiting. The socket is the same for every
    /// call: the route that owns this check also holds the connection's writer, so the descriptor stays open.
    #[cfg(target_vendor = "apple")]
    pub(crate) fn has_room(&self, fd: RawFd, len: usize) -> bool {
        match self.queue.get_or_init(|| WriteQueue::register(fd).ok()) {
            Some(queue) => queue.has_room(len),
            None => poll_has_room(fd),
        }
    }

    /// Linux: always. The send's MSG_DONTWAIT refuses a frame that the socket cannot take whole now.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    pub(crate) fn has_room(&self, _fd: RawFd, _len: usize) -> bool {
        true
    }

    #[cfg(all(
        unix,
        not(any(target_vendor = "apple", target_os = "linux", target_os = "android"))
    ))]
    pub(crate) fn has_room(&self, fd: RawFd, _len: usize) -> bool {
        poll_has_room(fd)
    }
}

/// A kernel event queue with one socket's write filter registered. Level-triggered: a read reports the filter while
/// the socket has room for at least its send low-water mark (2048 bytes by default, more than any inline frame).
/// Closing the socket removes the registration (a later read then finds no room, and the key goes to the port);
/// dropping the queue closes it.
#[cfg(target_vendor = "apple")]
struct WriteQueue(std::os::fd::OwnedFd);

#[cfg(target_vendor = "apple")]
impl WriteQueue {
    fn register(socket: RawFd) -> std::io::Result<Self> {
        use std::os::fd::{AsRawFd as _, FromRawFd as _};
        #[cfg(test)]
        room_check_queues::opened();
        // SAFETY: no pointers. Darwin makes kqueues close-on-exec and close-on-fork.
        let fd = unsafe { libc::kqueue() };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: the successful call returned a new descriptor that only this queue owns.
        let queue = Self(unsafe { std::os::fd::OwnedFd::from_raw_fd(fd) });
        let ident = u64::try_from(socket).map_err(|_| std::io::ErrorKind::InvalidInput)?;
        let change = libc::kevent64_s {
            ident,
            filter: libc::EVFILT_WRITE,
            flags: libc::EV_ADD | libc::EV_ENABLE,
            fflags: 0,
            data: 0,
            udata: 0,
            ext: [0; 2],
        };
        // SAFETY: one initialized change and no output entries: registers the filter and returns without waiting.
        let result = unsafe {
            libc::kevent64(
                queue.0.as_raw_fd(),
                &change,
                1,
                std::ptr::null_mut(),
                0,
                0,
                std::ptr::null(),
            )
        };
        if result < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(queue)
    }

    /// Whether the registered socket takes `len` more bytes now. KEVENT_FLAG_IMMEDIATE returns at once, with or
    /// without room (a zero-timeout poll sleeps on an already-due timer when there is none). The filter's `data` is
    /// the socket's room. EOF (the socket was shut down, or the host closed its end) or an error is no room: the key
    /// goes to the port, whose writer meets the same state and handles it (a lost host's reconnect).
    fn has_room(&self, len: usize) -> bool {
        use std::os::fd::AsRawFd as _;
        let mut event = std::mem::MaybeUninit::<libc::kevent64_s>::uninit();
        // SAFETY: one writable event slot, written only when the call returns 1; the flag keeps the call from waiting.
        let ready = unsafe {
            libc::kevent64(
                self.0.as_raw_fd(),
                std::ptr::null(),
                0,
                event.as_mut_ptr(),
                1,
                libc::KEVENT_FLAG_IMMEDIATE,
                std::ptr::null(),
            )
        };
        if ready != 1 {
            return false;
        }
        // SAFETY: the call returned 1, so it wrote the one event.
        let event = unsafe { event.assume_init() };
        event.filter == libc::EVFILT_WRITE
            && event.flags & (libc::EV_EOF | libc::EV_ERROR) == 0
            && usize::try_from(event.data).is_ok_and(|room| room >= len)
    }
}

/// Whether the socket `fd` can take a small write now (POLLOUT, no error or hang-up). The zero timeout keeps poll from
/// waiting for room or for the host; on macOS it is only the fallback when a connection has no event queue.
#[cfg(all(unix, not(any(target_os = "linux", target_os = "android"))))]
fn poll_has_room(fd: RawFd) -> bool {
    // On XNU a poll() opens a kernel event queue for the call and frees it after (sys_generic.c poll_nocancel).
    #[cfg(all(test, target_vendor = "apple"))]
    room_check_queues::opened();
    let mut ready = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
    // SAFETY: one valid pollfd for a count of 1; the zero timeout keeps poll from waiting for room.
    let count = unsafe { libc::poll(&mut ready, 1, 0) };
    count == 1
        && ready.revents & libc::POLLOUT != 0
        && ready.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) == 0
}

/// Tests: the kernel event queues that this thread's room checks opened. An inline key runs its room check on its
/// request's own thread, so a test that sends keys counts its own keys' queues.
#[cfg(all(test, target_vendor = "apple"))]
pub(crate) mod room_check_queues {
    use std::cell::Cell;

    thread_local! {
        static OPENED: Cell<usize> = const { Cell::new(0) };
    }

    pub(crate) fn opened() {
        OPENED.with(|opened| opened.set(opened.get().saturating_add(1)));
    }

    /// The queues this thread's room checks opened so far.
    pub(crate) fn count() -> usize {
        OPENED.with(Cell::get)
    }
}
