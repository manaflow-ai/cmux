//! The agent socket on Windows: a local named pipe (`\\.\pipe\...`) whose
//! DACL lets only this user in, remote clients rejected, and every client
//! checked again by its process token's user SID.
//!
//! Overlapped I/O, so one connection's reader thread and the call threads
//! answering on it never serialize on the handle.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_NO_DATA, ERROR_PIPE_CONNECTED,
    ERROR_PIPE_NOT_CONNECTED, GENERIC_READ, GENERIC_WRITE, GetLastError, HANDLE,
    INVALID_HANDLE_VALUE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::{
    EqualSid, GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY,
    TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, OPEN_EXISTING,
    PIPE_ACCESS_DUPLEX, ReadFile, WriteFile,
};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, GetNamedPipeClientProcessId,
    PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES,
    PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::{
    CreateEventW, GetCurrentProcess, OpenProcess, OpenProcessToken,
    PROCESS_QUERY_LIMITED_INFORMATION,
};

use super::Stream;

const BUFFER: u32 = 64 * 1024;

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

struct Owned(HANDLE);
unsafe impl Send for Owned {}
unsafe impl Sync for Owned {}
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            // SAFETY: a handle this module opened.
            unsafe { CloseHandle(self.0) };
        }
    }
}

/// The user SID of a process token, as bytes.
fn token_user_sid(process: HANDLE) -> io::Result<Vec<u8>> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: out parameter.
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let token = Owned(token);
    let mut len = 0u32;
    // SAFETY: size query.
    unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut len) };
    let mut buf = vec![0u8; len as usize];
    // SAFETY: buffer of the size Windows asked for.
    if unsafe { GetTokenInformation(token.0, TokenUser, buf.as_mut_ptr().cast(), len, &mut len) }
        == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(buf)
}

fn sid_of(token_user: &[u8]) -> *mut core::ffi::c_void {
    // SAFETY: the buffer holds a TOKEN_USER (from GetTokenInformation).
    unsafe { (*(token_user.as_ptr() as *const TOKEN_USER)).User.Sid }
}

fn sid_string(token_user: &[u8]) -> io::Result<String> {
    let mut text: *mut u16 = std::ptr::null_mut();
    // SAFETY: a valid SID; out string freed below.
    if unsafe { ConvertSidToStringSidW(sid_of(token_user), &mut text) } == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: NUL-terminated wide string from Windows.
    let len = (0..).take_while(|i| unsafe { *text.add(*i) } != 0).count();
    let out = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, len) });
    // SAFETY: allocated by ConvertSidToStringSidW.
    unsafe { LocalFree(text.cast()) };
    Ok(out)
}

pub(super) struct Listener {
    name: Vec<u16>,
    /// This user's TOKEN_USER (the owner the DACL admits).
    me: Vec<u8>,
    descriptor: PSECURITY_DESCRIPTOR,
    first: AtomicBool,
}

unsafe impl Send for Listener {}
unsafe impl Sync for Listener {}

impl Drop for Listener {
    fn drop(&mut self) {
        if !self.descriptor.is_null() {
            // SAFETY: from ConvertStringSecurityDescriptorToSecurityDescriptorW.
            unsafe { LocalFree(self.descriptor) };
        }
    }
}

impl Listener {
    pub(super) fn bind(endpoint: &str) -> io::Result<Self> {
        if !endpoint.starts_with(r"\\.\pipe\") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "a Windows endpoint is \\\\.\\pipe\\NAME",
            ));
        }
        // SAFETY: the pseudo handle of this process.
        let me = token_user_sid(unsafe { GetCurrentProcess() })?;
        // Protected DACL: this user only (no inherited entries, no Everyone, no SYSTEM).
        let sddl = wide(&format!("D:P(A;;GA;;;{})", sid_string(&me)?));
        let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: valid SDDL string and out pointer.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let listener = Self { name: wide(endpoint), me, descriptor, first: AtomicBool::new(true) };
        // Claim the name now (FILE_FLAG_FIRST_PIPE_INSTANCE fails if another process owns it).
        Ok(listener)
    }

    fn instance(&self) -> io::Result<Owned> {
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.descriptor,
            bInheritHandle: 0,
        };
        let mut open = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
        if self.first.swap(false, Ordering::SeqCst) {
            open |= FILE_FLAG_FIRST_PIPE_INSTANCE;
        }
        // SAFETY: valid name and attributes.
        let handle = unsafe {
            CreateNamedPipeW(
                self.name.as_ptr(),
                open,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                BUFFER,
                BUFFER,
                0,
                &attributes,
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        Ok(Owned(handle))
    }

    pub(super) fn accept(&self) -> io::Result<(Arc<dyn Stream>, Result<(), String>)> {
        let pipe = self.instance()?;
        let ov = Overlapped::new()?;
        // SAFETY: an overlapped connect on our handle; waited for below.
        let connected = unsafe { ConnectNamedPipe(pipe.0, ov.ptr()) } != 0;
        if !connected {
            // SAFETY: plain call.
            match unsafe { GetLastError() } {
                ERROR_PIPE_CONNECTED => {}
                ERROR_IO_PENDING => {
                    ov.wait(pipe.0)?;
                }
                code => return Err(io::Error::from_raw_os_error(code as i32)),
            }
        }
        let admitted = self.check_client(pipe.0);
        Ok((Arc::new(Conn { pipe, closed: AtomicBool::new(false) }), admitted))
    }

    fn check_client(&self, pipe: HANDLE) -> Result<(), String> {
        let mut pid = 0u32;
        // SAFETY: out parameter.
        if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 {
            return Err("unknown peer".into());
        }
        // SAFETY: plain call; closed by Owned.
        let process = Owned(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) });
        if process.0.is_null() {
            return Err("unknown peer".into());
        }
        let theirs = token_user_sid(process.0).map_err(|_| "unknown peer".to_string())?;
        // SAFETY: two valid SIDs.
        if unsafe { EqualSid(sid_of(&self.me), sid_of(&theirs)) } != 0 {
            Ok(())
        } else {
            Err("another user".into())
        }
    }

    pub(super) fn wake(&self) {
        // SAFETY: opening our own pipe as a client, closed at once.
        let handle = unsafe {
            CreateFileW(
                self.name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                std::ptr::null(),
                OPEN_EXISTING,
                0,
                std::ptr::null_mut(),
            )
        };
        drop(Owned(handle));
    }

    pub(super) fn remove(&self) {}
}

/// One OVERLAPPED with its own manual-reset event.
struct Overlapped {
    ov: Box<std::cell::UnsafeCell<OVERLAPPED>>,
    _event: Owned,
}

impl Overlapped {
    fn new() -> io::Result<Self> {
        // SAFETY: an unnamed manual-reset event.
        let event = unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
        if event.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: OVERLAPPED is plain data; zero is its initial state.
        let mut ov: OVERLAPPED = unsafe { std::mem::zeroed() };
        ov.hEvent = event;
        Ok(Self { ov: Box::new(std::cell::UnsafeCell::new(ov)), _event: Owned(event) })
    }
    fn ptr(&self) -> *mut OVERLAPPED {
        self.ov.get()
    }
    fn wait(&self, handle: HANDLE) -> io::Result<u32> {
        let mut n = 0u32;
        // SAFETY: the operation started on `handle` with this OVERLAPPED.
        if unsafe { GetOverlappedResult(handle, self.ptr(), &mut n, 1) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(n)
    }
}

struct Conn {
    pipe: Owned,
    closed: AtomicBool,
}

fn pipe_end(code: u32) -> bool {
    matches!(code, ERROR_BROKEN_PIPE | ERROR_NO_DATA | ERROR_PIPE_NOT_CONNECTED)
}

impl Stream for Conn {
    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        if self.closed.load(Ordering::SeqCst) {
            return Ok(0);
        }
        let ov = Overlapped::new()?;
        let len = buf.len().min(u32::MAX as usize) as u32;
        let mut n = 0u32;
        // SAFETY: buffer valid until the operation completes (waited for below).
        if unsafe { ReadFile(self.pipe.0, buf.as_mut_ptr(), len, &mut n, ov.ptr()) } != 0 {
            return Ok(n as usize);
        }
        // SAFETY: plain call.
        match unsafe { GetLastError() } {
            ERROR_IO_PENDING => match ov.wait(self.pipe.0) {
                Ok(n) => Ok(n as usize),
                Err(e) if e.raw_os_error().is_some_and(|c| pipe_end(c as u32)) => Ok(0),
                // Cancelled by shutdown.
                Err(_) if self.closed.load(Ordering::SeqCst) => Ok(0),
                Err(e) => Err(e),
            },
            code if pipe_end(code) => Ok(0),
            code => Err(io::Error::from_raw_os_error(code as i32)),
        }
    }

    fn write_all(&self, mut buf: &[u8]) -> io::Result<()> {
        while !buf.is_empty() {
            let ov = Overlapped::new()?;
            let len = buf.len().min(u32::MAX as usize) as u32;
            let mut n = 0u32;
            // SAFETY: buffer valid until the operation completes (waited for below).
            let done = unsafe { WriteFile(self.pipe.0, buf.as_ptr(), len, &mut n, ov.ptr()) } != 0;
            if !done {
                // SAFETY: plain call.
                match unsafe { GetLastError() } {
                    ERROR_IO_PENDING => n = ov.wait(self.pipe.0)?,
                    code => return Err(io::Error::from_raw_os_error(code as i32)),
                }
            }
            if n == 0 {
                return Err(io::ErrorKind::WriteZero.into());
            }
            buf = &buf[n as usize..];
        }
        Ok(())
    }

    fn set_read_timeout(&self, _limit: Option<Duration>) {
        // The handshake's bound on Windows is the accept loop: a client that
        // never sends its secret holds only its own instance and thread.
    }

    fn shutdown(&self) {
        self.closed.store(true, Ordering::SeqCst);
        // SAFETY: cancels this handle's pending I/O, then disconnects the client.
        unsafe {
            CancelIoEx(self.pipe.0, std::ptr::null());
            DisconnectNamedPipe(self.pipe.0);
        }
    }
}
