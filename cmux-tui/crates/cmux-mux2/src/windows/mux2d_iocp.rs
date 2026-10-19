//! One IO completion port for the whole server, and the overlapped
//! endpoint ([`Slot`]) that every PTY pipe and client socket goes through.
//!
//! A slot keeps at most one read and one write in flight. Handles are set
//! to FILE_SKIP_COMPLETION_PORT_ON_SUCCESS, so an operation that completes
//! at once is handled inline without a trip through the port: a busy pipe is
//! drained by back-to-back synchronous reads, as a Unix server drains a
//! readable descriptor. Only an operation that has to wait posts a packet.
//!
//! Reads use two buffers: when a read completes the next one is issued into
//! the spare buffer before the caller parses the filled one, so the producer
//! (conhost, or a client) keeps writing while the server parses.

use std::cell::UnsafeCell;
use std::io;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};

use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_BROKEN_PIPE, ERROR_HANDLE_EOF, ERROR_IO_PENDING, ERROR_NO_DATA,
    ERROR_OPERATION_ABORTED, ERROR_PIPE_NOT_CONNECTED, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Networking::WinSock::{
    SOCKET, WSABUF, WSAEnumProtocolsW, WSAGetLastError, WSAPROTOCOL_INFOW, WSARecv, WSASend,
    XP1_IFS_HANDLES, closesocket,
};
use windows_sys::Win32::Storage::FileSystem::{
    ReadFile, SetFileCompletionNotificationModes, WriteFile,
};
use windows_sys::Win32::System::IO::{
    CancelIoEx, CreateIoCompletionPort, GetQueuedCompletionStatusEx, OVERLAPPED, OVERLAPPED_ENTRY,
    PostQueuedCompletionStatus,
};

const FILE_SKIP_COMPLETION_PORT_ON_SUCCESS: u8 = 1;
const FILE_SKIP_SET_EVENT_ON_HANDLE: u8 = 2;
const WSA_IO_PENDING: i32 = 997;

/// First read buffer of a slot. A read that fills its buffer grows the next
/// one (x4) up to [`READ_MAX`], so an idle terminal costs two small buffers
/// and a flooding one reads in large chunks.
const READ_MIN: usize = 4 << 10;
const READ_MAX: usize = 256 << 10;
/// Most bytes handed to one overlapped write.
pub(super) const WRITE_MAX: usize = 1 << 20;
/// Consecutive failed pipe reads, with an error that is not end of file,
/// after which the pipe is treated as ended anyway.
const READ_RETRIES: u32 = 16;

/// Statuses (NTSTATUS in packets, Win32 codes from an immediate failure)
/// that mean the pipe has ended: conhost closed it, or the slot was closed.
fn ends_pipe(code: u32) -> bool {
    const STATUS_END_OF_FILE: u32 = 0xC000_0011;
    const STATUS_PIPE_DISCONNECTED: u32 = 0xC000_00B0;
    const STATUS_PIPE_CLOSING: u32 = 0xC000_00B1;
    const STATUS_PIPE_BROKEN: u32 = 0xC000_014B;
    const STATUS_CANCELLED: u32 = 0xC000_0120;
    matches!(
        code,
        ERROR_BROKEN_PIPE
            | ERROR_PIPE_NOT_CONNECTED
            | ERROR_HANDLE_EOF
            | ERROR_NO_DATA
            | ERROR_OPERATION_ABORTED
            | STATUS_END_OF_FILE
            | STATUS_PIPE_DISCONNECTED
            | STATUS_PIPE_CLOSING
            | STATUS_PIPE_BROKEN
            | STATUS_CANCELLED
    )
}

/// Whether every installed socket provider hands out kernel (IFS) handles.
/// Only then does an immediate socket success skip the port; a layered
/// non-IFS provider would still post a packet for it.
fn sockets_skip_safe() -> bool {
    static SAFE: OnceLock<bool> = OnceLock::new();
    *SAFE.get_or_init(|| {
        let mut len = 0u32;
        // SAFETY: the documented size query, then the real call into a
        // buffer of that many bytes.
        unsafe {
            WSAEnumProtocolsW(std::ptr::null(), std::ptr::null_mut(), &mut len);
            let n = len as usize / size_of::<WSAPROTOCOL_INFOW>() + 1;
            let mut buf: Vec<WSAPROTOCOL_INFOW> = Vec::with_capacity(n);
            let mut len = (n * size_of::<WSAPROTOCOL_INFOW>()) as u32;
            let count = WSAEnumProtocolsW(std::ptr::null(), buf.as_mut_ptr(), &mut len);
            if count <= 0 {
                return false;
            }
            buf.set_len(count as usize);
            buf.iter().all(|p| p.dwServiceFlags1 & XP1_IFS_HANDLES != 0)
        }
    })
}

/// The port, for threads that post to it (exit waits, parse workers, the
/// accept thread). Set once at startup.
static PORT: AtomicUsize = AtomicUsize::new(0);

pub(super) fn port() -> HANDLE {
    PORT.load(Ordering::Relaxed) as HANDLE
}

pub(super) fn create_port() -> io::Result<HANDLE> {
    // SAFETY: a new port with no file attached.
    let port = unsafe { CreateIoCompletionPort(INVALID_HANDLE_VALUE, std::ptr::null_mut(), 0, 1) };
    if port.is_null() {
        return Err(io::Error::last_os_error());
    }
    PORT.store(port as usize, Ordering::Relaxed);
    Ok(port)
}

/// Posts a packet with `key` and `value` (carried in the overlapped pointer
/// slot, never dereferenced).
pub(super) fn post(key: u64, value: usize) {
    // SAFETY: posting to our own port; the pointer is an opaque value.
    unsafe { PostQueuedCompletionStatus(port(), 0, key as usize, value as *const OVERLAPPED) };
}

/// Waits for packets. Returns how many entries of `out` were filled.
pub(super) fn wait(out: &mut [OVERLAPPED_ENTRY]) -> io::Result<usize> {
    let mut n = 0u32;
    // SAFETY: out is valid for its length.
    let ok = unsafe {
        GetQueuedCompletionStatusEx(port(), out.as_mut_ptr(), out.len() as u32, &mut n, u32::MAX, 0)
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(n as usize)
}

/// Wakes the loop from a parse worker with a terminal id.
#[derive(Clone)]
pub(super) struct Waker;

impl Waker {
    pub(super) fn wake(&self, id: u32) {
        post(super::KIND_WAKE | u64::from(id), 0);
    }
}

enum ReadState {
    /// No read in flight (none started yet, or the last one was consumed).
    Idle,
    Pending,
    /// A read completed with this many bytes in `rbuf`.
    Done(usize),
    Eof,
}

/// Result of [`Slot::take_read`].
pub(super) enum Read {
    /// Filled bytes; return the buffer with [`Slot::give_back`].
    Data(Vec<u8>, usize),
    /// A read is in flight; a packet will announce it.
    Pending,
    Eof,
}

/// Which operation a packet finished.
pub(super) enum Done {
    Read,
    Write,
    Unknown,
}

/// One overlapped endpoint. Boxed, so the OVERLAPPED structures keep their
/// address while the kernel holds them; a closed slot with operations still
/// in flight must be kept until their packets arrive (the server's
/// graveyard).
/// The OVERLAPPED structures are written by the kernel while the slot is
/// borrowed, hence the cells.
pub(super) struct Slot {
    read_ov: UnsafeCell<OVERLAPPED>,
    write_ov: UnsafeCell<OVERLAPPED>,
    handle: HANDLE,
    socket: bool,
    /// FILE_SKIP_COMPLETION_PORT_ON_SUCCESS took effect: an immediate
    /// success posts no packet and is handled inline.
    skip: bool,
    rbuf: Vec<u8>,
    spare: Vec<u8>,
    rstate: ReadState,
    /// The last read filled its buffer: the next buffer is grown.
    grow: bool,
    wbuf: Vec<u8>,
    /// Bytes of `wbuf` the kernel has taken so far for the write in flight.
    wsent: usize,
    wpending: bool,
    wfailed: bool,
    outstanding: u32,
    closed: bool,
    /// Consecutive pipe reads that failed with an error other than an end.
    read_errors: u32,
}

impl Slot {
    /// Attaches `handle` (a pipe or a socket) to the port with `key`.
    pub(super) fn new(handle: HANDLE, socket: bool, key: u64) -> io::Result<Box<Slot>> {
        // SAFETY: attaching our own handle to our own port.
        if unsafe { CreateIoCompletionPort(handle, port(), key as usize, 0) }.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: plain flag change on our handle.
        let skip = (!socket || sockets_skip_safe())
            && unsafe {
                SetFileCompletionNotificationModes(
                    handle,
                    FILE_SKIP_COMPLETION_PORT_ON_SUCCESS | FILE_SKIP_SET_EVENT_ON_HANDLE,
                )
            } != 0;
        Ok(Box::new(Slot {
            read_ov: UnsafeCell::new(OVERLAPPED::default()),
            write_ov: UnsafeCell::new(OVERLAPPED::default()),
            handle,
            socket,
            skip,
            rbuf: vec![0; READ_MIN],
            spare: Vec::new(),
            rstate: ReadState::Idle,
            grow: false,
            wbuf: Vec::new(),
            wsent: 0,
            wpending: false,
            wfailed: false,
            outstanding: 0,
            closed: false,
            read_errors: 0,
        }))
    }

    /// Operations still owned by the kernel.
    pub(super) fn busy(&self) -> bool {
        self.outstanding > 0
    }

    /// Starts a read into `rbuf` if none is in flight.
    fn start_read(&mut self) {
        if !matches!(self.rstate, ReadState::Idle) || self.closed {
            return;
        }
        *self.read_ov.get_mut() = OVERLAPPED::default();
        let ov = self.read_ov.get();
        let mut n = 0u32;
        let len = self.rbuf.len() as u32;
        let (ok, err) = if self.socket {
            let buf = WSABUF { len, buf: self.rbuf.as_mut_ptr() };
            let mut flags = 0u32;
            // SAFETY: rbuf and read_ov stay valid until the read completes
            // (the slot is boxed and outlives its operations).
            let r =
                unsafe { WSARecv(self.handle as SOCKET, &buf, 1, &mut n, &mut flags, ov, None) };
            // SAFETY: reading the calling thread's last socket error.
            if r == 0 { (true, 0) } else { (false, unsafe { WSAGetLastError() }) }
        } else {
            // SAFETY: as above.
            let r = unsafe { ReadFile(self.handle, self.rbuf.as_mut_ptr(), len, &mut n, ov) };
            // SAFETY: reading the calling thread's last error.
            if r != 0 { (true, 0) } else { (false, unsafe { GetLastError() } as i32) }
        };
        if ok {
            if self.skip {
                self.read_done(n as usize);
            } else {
                // The packet still comes; the data is read then.
                self.outstanding += 1;
                self.rstate = ReadState::Pending;
            }
        } else if err == ERROR_IO_PENDING as i32 || err == WSA_IO_PENDING {
            self.outstanding += 1;
            self.rstate = ReadState::Pending;
        } else {
            self.read_failed(err as u32);
        }
    }

    /// A read failed with `code`. A socket error ends the connection. A
    /// pipe ends only on an end status; any other error (low resources, say)
    /// is retried, so no byte conhost still holds is given up early.
    fn read_failed(&mut self, code: u32) {
        self.read_errors += 1;
        let ended =
            self.socket || self.closed || ends_pipe(code) || self.read_errors > READ_RETRIES;
        self.rstate = if ended { ReadState::Eof } else { ReadState::Idle };
    }

    fn read_done(&mut self, n: usize) {
        self.read_errors = 0;
        if n == 0 && self.socket {
            self.rstate = ReadState::Eof;
        } else {
            // A zero-byte pipe read (a zero-length write) carries nothing.
            self.grow = n == self.rbuf.len();
            self.rstate = if n == 0 { ReadState::Idle } else { ReadState::Done(n) };
        }
    }

    /// The next filled buffer, issuing the following read first.
    pub(super) fn take_read(&mut self) -> Read {
        loop {
            match self.rstate {
                ReadState::Idle => {
                    self.start_read();
                    if matches!(self.rstate, ReadState::Idle) {
                        continue;
                    }
                }
                ReadState::Pending => return Read::Pending,
                ReadState::Eof => return Read::Eof,
                ReadState::Done(n) => {
                    let mut next = std::mem::take(&mut self.spare);
                    let want = if self.grow {
                        (self.rbuf.len() * 4).min(READ_MAX)
                    } else {
                        self.rbuf.len()
                    };
                    if next.len() < want {
                        next = vec![0; want];
                    }
                    let filled = std::mem::replace(&mut self.rbuf, next);
                    self.rstate = ReadState::Idle;
                    self.start_read();
                    return Read::Data(filled, n);
                }
            }
        }
    }

    /// Returns a buffer from [`Read::Data`] for reuse.
    pub(super) fn give_back(&mut self, buf: Vec<u8>) {
        if buf.len() >= self.spare.len() {
            self.spare = buf;
        }
    }

    /// True when no write is in flight, so [`Slot::write`] accepts bytes.
    pub(super) fn writable(&self) -> bool {
        !self.wpending && !self.wfailed && !self.closed
    }

    pub(super) fn write_pending(&self) -> bool {
        self.wpending
    }

    pub(super) fn write_failed(&self) -> bool {
        self.wfailed
    }

    /// Starts one write with the bytes `fill` appends (at most WRITE_MAX are
    /// expected). Returns Ok(true) when the kernel took every byte at once
    /// (another write may start now), Ok(false) when it is in flight, and an
    /// error when the endpoint is broken. Nothing is lost on Ok: bytes in
    /// flight are owned by the slot until they are written.
    pub(super) fn write(&mut self, fill: impl FnOnce(&mut Vec<u8>)) -> io::Result<bool> {
        if self.wfailed || self.closed {
            return Err(io::Error::from(io::ErrorKind::BrokenPipe));
        }
        if self.wpending {
            return Ok(false);
        }
        self.wbuf.clear();
        self.wsent = 0;
        fill(&mut self.wbuf);
        if self.wbuf.is_empty() {
            return Ok(true);
        }
        self.submit_write()
    }

    fn submit_write(&mut self) -> io::Result<bool> {
        loop {
            *self.write_ov.get_mut() = OVERLAPPED::default();
            let ov = self.write_ov.get();
            let rest = &self.wbuf[self.wsent..];
            let mut n = 0u32;
            let (ok, err) = if self.socket {
                let buf = WSABUF { len: rest.len() as u32, buf: rest.as_ptr().cast_mut() };
                // SAFETY: wbuf and write_ov stay valid until the write
                // completes; the kernel only reads the buffer.
                let r = unsafe { WSASend(self.handle as SOCKET, &buf, 1, &mut n, 0, ov, None) };
                // SAFETY: reading the calling thread's last socket error.
                if r == 0 { (true, 0) } else { (false, unsafe { WSAGetLastError() }) }
            } else {
                // SAFETY: as above.
                let r =
                    unsafe { WriteFile(self.handle, rest.as_ptr(), rest.len() as u32, &mut n, ov) };
                // SAFETY: reading the calling thread's last error.
                if r != 0 { (true, 0) } else { (false, unsafe { GetLastError() } as i32) }
            };
            if ok && self.skip {
                self.wsent += n as usize;
                if self.wsent >= self.wbuf.len() {
                    self.wbuf.clear();
                    self.wsent = 0;
                    return Ok(true);
                }
                continue;
            }
            if ok || err == ERROR_IO_PENDING as i32 || err == WSA_IO_PENDING {
                self.outstanding += 1;
                self.wpending = true;
                return Ok(false);
            }
            self.wfailed = true;
            let gone = [ERROR_BROKEN_PIPE, ERROR_NO_DATA, ERROR_PIPE_NOT_CONNECTED];
            return Err(if gone.iter().any(|e| *e as i32 == err) {
                io::Error::from(io::ErrorKind::BrokenPipe)
            } else {
                io::Error::from_raw_os_error(err)
            });
        }
    }

    /// Applies a packet for this slot. `status` is the operation's NTSTATUS.
    pub(super) fn complete(&mut self, ov: *mut OVERLAPPED, bytes: u32, status: usize) -> Done {
        let failed = status != 0;
        if std::ptr::eq(ov, self.read_ov.get()) {
            self.outstanding -= 1;
            if self.closed {
                self.rstate = ReadState::Eof;
            } else if failed {
                self.read_failed(status as u32);
            } else {
                self.read_done(bytes as usize);
            }
            Done::Read
        } else if std::ptr::eq(ov, self.write_ov.get()) {
            self.outstanding -= 1;
            self.wpending = false;
            if failed || self.closed {
                self.wfailed = true;
                return Done::Write;
            }
            self.wsent += bytes as usize;
            if self.wsent < self.wbuf.len() {
                // A short write: send the rest before anything else.
                let _ = self.submit_write();
            } else {
                self.wbuf.clear();
                self.wsent = 0;
            }
            Done::Write
        } else {
            Done::Unknown
        }
    }

    /// Cancels what is in flight and closes the handle. Packets for the
    /// cancelled operations still arrive; keep the slot until `!busy()`.
    pub(super) fn close(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        // SAFETY: cancelling and closing our own handle.
        unsafe {
            CancelIoEx(self.handle, std::ptr::null());
            if self.socket {
                closesocket(self.handle as SOCKET);
            } else {
                CloseHandle(self.handle);
            }
        }
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        // The kernel would write into freed memory. Only a panic unwinding
        // through the server can get here with an operation in flight.
        if self.busy() {
            eprintln!("mux2d: slot dropped with IO in flight; aborting");
            std::process::abort();
        }
        self.close();
    }
}
