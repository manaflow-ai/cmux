//! The host's endpoint listener (the `HostListener` seam, Windows side):
//! `cmux::local_socket::listen` (an AF_UNIX socket owned by our token user,
//! in an owner-only directory, refusing peers of another user or a
//! sandbox), nonblocking accepts, and the accept loop's wait on the listener
//! or the accept waker: `WSAEventSelect(FD_ACCEPT)` on an auto-reset event
//! and `WaitForMultipleObjects` with the waker's event.

use std::io;
use std::os::windows::io::{AsRawHandle, AsRawSocket, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::ptr;
use std::time::Duration;

use windows_sys::Win32::Foundation::{HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows_sys::Win32::Networking::WinSock::{FD_ACCEPT, SOCKET, WSAEventSelect, WSAGetLastError};
use windows_sys::Win32::System::Threading::{CreateEventW, INFINITE, WaitForMultipleObjects};

use super::super::HostStream;
use super::seams::AcceptWaker;

pub(crate) struct HostListener {
    inner: cmux::local_socket::Listener,
    /// Auto-reset: set when a connection is waiting (FD_ACCEPT), reset by
    /// the wait that observes it.
    accept_event: OwnedHandle,
}

// SAFETY: a socket and an event handle; accept and wait are thread-safe.
unsafe impl Send for HostListener {}
unsafe impl Sync for HostListener {}

fn wsa_error() -> io::Error {
    // SAFETY: reads this thread's last Winsock error.
    io::Error::from_raw_os_error(unsafe { WSAGetLastError() })
}

impl HostListener {
    /// Bind `endpoint` (its directory is ours and owner-only), and make
    /// accepts nonblocking (`WSAEventSelect` does that).
    pub(crate) fn bind(endpoint: &Path) -> anyhow::Result<Self> {
        let inner = cmux::local_socket::listen(endpoint)?;
        // SAFETY: an unnamed auto-reset event, initially unset.
        let event = unsafe { CreateEventW(ptr::null(), 0, 0, ptr::null()) };
        if event.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: a new handle owned here.
        let accept_event = unsafe { OwnedHandle::from_raw_handle(event) };
        // SAFETY: the listener's socket and the event above, both live.
        if unsafe { WSAEventSelect(inner.raw_socket() as SOCKET, event as isize, FD_ACCEPT as i32) }
            != 0
        {
            return Err(wsa_error().into());
        }
        Ok(Self { inner, accept_event })
    }

    /// The next waiting client (`WouldBlock` when none). The accepted socket
    /// inherits the listener's event selection and nonblocking mode; both
    /// are cleared, so the stream blocks as on Unix.
    pub(crate) fn accept(&self) -> io::Result<HostStream> {
        let stream = self.inner.accept()?;
        let socket = stream.as_raw_socket() as SOCKET;
        // SAFETY: the accepted socket, live; a null event cancels the
        // selection.
        if unsafe { WSAEventSelect(socket, 0, 0) } != 0 {
            return Err(wsa_error());
        }
        stream.set_nonblocking(false)?;
        Ok(stream)
    }

    /// Block until a client is waiting, the waker fires, or `timeout`
    /// passes (`None`: no timeout). Ok(true) when the waker fired.
    pub(crate) fn wait(&self, waker: &AcceptWaker, timeout: Option<Duration>) -> io::Result<bool> {
        let millis = match timeout {
            None => INFINITE,
            Some(remaining) => {
                u32::try_from(remaining.as_millis().saturating_add(1)).unwrap_or(INFINITE - 1)
            }
        };
        let handles = [self.accept_event.as_raw_handle() as HANDLE, waker.raw()];
        // SAFETY: two live event handles, owned by `self` and the waker.
        match unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, millis) } {
            WAIT_OBJECT_0 | WAIT_TIMEOUT => Ok(false),
            woke if woke == WAIT_OBJECT_0 + 1 => Ok(true),
            _ => Err(io::Error::last_os_error()),
        }
    }
}
