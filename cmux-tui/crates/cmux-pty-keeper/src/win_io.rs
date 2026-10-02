//! Blocking helpers over overlapped named-pipe handles.
//!
//! Synchronous pipe handles serialize every operation, so a blocked read
//! would block the `EXIT` write. Both ends open their pipe with
//! `FILE_FLAG_OVERLAPPED` and wait on a private event per operation, which
//! lets one thread read while another writes.

use std::io;
use std::ptr;

use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_PIPE_CONNECTED, GetLastError, HANDLE,
    TRUE,
};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};
use windows_sys::Win32::System::IO::{GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Pipes::ConnectNamedPipe;
use windows_sys::Win32::System::Threading::CreateEventW;

/// An owned handle that is safe to share between threads.
pub struct Handle(pub HANDLE);

// SAFETY: kernel handles are process-wide values, valid on any thread.
unsafe impl Send for Handle {}
// SAFETY: as above; overlapped operations on one handle may run concurrently.
unsafe impl Sync for Handle {}

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: this wrapper owns the handle.
            unsafe { CloseHandle(self.0) };
        }
    }
}

struct Pending {
    // Held only to keep the event alive until the operation completes.
    _event: Handle,
    overlapped: OVERLAPPED,
}

impl Pending {
    fn new() -> io::Result<Self> {
        // SAFETY: plain manual-reset event with no name or attributes.
        let event = unsafe { CreateEventW(ptr::null(), TRUE, 0, ptr::null()) };
        if event.is_null() {
            return Err(io::Error::last_os_error());
        }
        let overlapped = OVERLAPPED { hEvent: event, ..Default::default() };
        Ok(Self { _event: Handle(event), overlapped })
    }

    /// Completes an operation that returned `ok`, waiting if it is pending.
    fn finish(&mut self, handle: HANDLE, ok: i32, mut done: u32) -> io::Result<u32> {
        if ok == 0 {
            // SAFETY: reads the calling thread's last error.
            let error = unsafe { GetLastError() };
            if error != ERROR_IO_PENDING {
                return Err(io::Error::from_raw_os_error(error as i32));
            }
            // SAFETY: `overlapped` belongs to this pending operation on `handle`.
            if unsafe { GetOverlappedResult(handle, &self.overlapped, &mut done, TRUE) } == 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(done)
    }
}

/// Reads up to `buf.len()` bytes. Returns 0 at end of stream.
pub fn read(handle: &Handle, buf: &mut [u8]) -> io::Result<usize> {
    let mut pending = Pending::new()?;
    let mut done = 0u32;
    let len = u32::try_from(buf.len()).unwrap_or(u32::MAX);
    // SAFETY: `buf` and `pending` outlive the operation, which `finish` waits for.
    let ok =
        unsafe { ReadFile(handle.0, buf.as_mut_ptr(), len, &mut done, &mut pending.overlapped) };
    match pending.finish(handle.0, ok, done) {
        Ok(n) => Ok(n as usize),
        Err(error) if error.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) => Ok(0),
        Err(error) => Err(error),
    }
}

pub fn read_exact(handle: &Handle, mut buf: &mut [u8]) -> io::Result<()> {
    while !buf.is_empty() {
        let n = read(handle, buf)?;
        if n == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        buf = &mut buf[n..];
    }
    Ok(())
}

pub fn write_all(handle: &Handle, mut buf: &[u8]) -> io::Result<()> {
    while !buf.is_empty() {
        let mut pending = Pending::new()?;
        let mut done = 0u32;
        let len = u32::try_from(buf.len()).unwrap_or(u32::MAX);
        // SAFETY: `buf` and `pending` outlive the operation, which `finish` waits for.
        let ok =
            unsafe { WriteFile(handle.0, buf.as_ptr(), len, &mut done, &mut pending.overlapped) };
        let n = pending.finish(handle.0, ok, done)? as usize;
        if n == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        buf = &buf[n..];
    }
    Ok(())
}

/// Waits for a client on a server pipe instance.
pub fn connect(handle: &Handle) -> io::Result<()> {
    let mut pending = Pending::new()?;
    // SAFETY: `pending` outlives the operation, which `finish` waits for.
    let ok = unsafe { ConnectNamedPipe(handle.0, &mut pending.overlapped) };
    match pending.finish(handle.0, ok, 0) {
        Ok(_) => Ok(()),
        Err(error) if error.raw_os_error() == Some(ERROR_PIPE_CONNECTED as i32) => Ok(()),
        Err(error) => Err(error),
    }
}
