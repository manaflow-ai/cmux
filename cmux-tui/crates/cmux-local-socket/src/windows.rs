//! Windows AF_UNIX (uds_windows) with the same-user rules of
//! [`crate::policy`]. Experiments behind the choices: windows-daemon.md
//! ("Experiments").

use std::io;
use std::path::Path;
use std::ptr::null_mut;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{CloseHandle, ERROR_SUCCESS, HANDLE, LocalFree};
use windows_sys::Win32::Networking::WinSock::{SOCKET, SOCKET_ERROR, WSAGetLastError, WSAIoctl};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
    GetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT, SetNamedSecurityInfoW,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, GetAce,
    GetSecurityDescriptorControl, GetSidSubAuthority, GetSidSubAuthorityCount,
    GetTokenInformation, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
    SE_DACL_PROTECTED, SECURITY_ATTRIBUTES, TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TOKEN_USER,
    TokenIntegrityLevel, TokenIsAppContainer, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::CreateDirectoryW;
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};

use crate::{PeerIdentity, owner_allowed, peer_allowed};

/// A connected local socket. Not inheritable (uds_windows creates it so).
pub type Stream = uds_windows::UnixStream;

/// `_WSAIOR(IOC_VENDOR, 256)`: the peer process id of an AF_UNIX socket.
const SIO_AF_UNIX_GETPEERPID: u32 = 0x5800_0100;
/// `ACCESS_ALLOWED_ACE_TYPE`.
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;

fn denied(message: String) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

fn win32(code: u32, what: &str) -> io::Error {
    io::Error::new(io::Error::from_raw_os_error(code as i32).kind(), format!("{what}: {}", io::Error::from_raw_os_error(code as i32)))
}

fn wide(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str().encode_wide().chain([0]).collect()
}

/// Frees a `LocalAlloc` block on drop.
struct Local(*mut core::ffi::c_void);

impl Drop for Local {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: a block the OS allocated with LocalAlloc for us.
            unsafe { LocalFree(self.0) };
        }
    }
}

struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: an open handle this value owns.
        unsafe { CloseHandle(self.0) };
    }
}

fn sid_string(sid: PSID) -> io::Result<String> {
    let mut text: *mut u16 = null_mut();
    // SAFETY: `sid` is a valid SID; the OS allocates `text`.
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let _free = Local(text.cast());
    let mut length = 0;
    // SAFETY: a NUL-terminated string the OS wrote.
    while unsafe { *text.add(length) } != 0 {
        length += 1;
    }
    // SAFETY: `length` u16s are valid.
    Ok(String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, length) }))
}

/// A token's information block of class `class`.
fn token_info(token: HANDLE, class: i32) -> io::Result<Vec<u8>> {
    let mut size = 0u32;
    // SAFETY: a size query.
    unsafe { GetTokenInformation(token, class, null_mut(), 0, &mut size) };
    let mut buffer = vec![0u8; size.max(4) as usize];
    // SAFETY: the buffer has `size` bytes.
    if unsafe { GetTokenInformation(token, class, buffer.as_mut_ptr().cast(), size, &mut size) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(buffer)
}

fn token_identity(token: HANDLE) -> io::Result<PeerIdentity> {
    let user = token_info(token, TokenUser)?;
    // SAFETY: GetTokenInformation(TokenUser) wrote a TOKEN_USER at the start.
    let user_sid = sid_string(unsafe { (*(user.as_ptr() as *const TOKEN_USER)).User.Sid })?;
    let label = token_info(token, TokenIntegrityLevel)?;
    // SAFETY: a TOKEN_MANDATORY_LABEL; its SID's last subauthority is the RID.
    let integrity_rid = unsafe {
        let sid = (*(label.as_ptr() as *const TOKEN_MANDATORY_LABEL)).Label.Sid;
        let count = *GetSidSubAuthorityCount(sid);
        if count == 0 { 0 } else { *GetSidSubAuthority(sid, u32::from(count) - 1) }
    };
    let container = token_info(token, TokenIsAppContainer)?;
    let app_container = u32::from_ne_bytes([container[0], container[1], container[2], container[3]]) != 0;
    Ok(PeerIdentity { user_sid, integrity_rid, app_container })
}

/// This process's token user, integrity and AppContainer flag.
pub fn current_identity() -> io::Result<PeerIdentity> {
    let mut token: HANDLE = null_mut();
    // SAFETY: the current process pseudo-handle; `token` is closed below.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let token = Handle(token);
    token_identity(token.0)
}

/// Process `pid`'s token user, integrity and AppContainer flag.
pub fn process_identity(pid: u32) -> io::Result<PeerIdentity> {
    // SAFETY: plain call; null is failure.
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return Err(io::Error::last_os_error());
    }
    let process = Handle(process);
    let mut token: HANDLE = null_mut();
    // SAFETY: a valid process handle.
    if unsafe { OpenProcessToken(process.0, TOKEN_QUERY, &mut token) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let token = Handle(token);
    token_identity(token.0)
}

/// The owner of a file or directory, as a string SID.
pub fn owner_of(path: &Path) -> io::Result<String> {
    let name = wide(path);
    let mut owner: PSID = null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: out-pointers valid; `descriptor` is freed by `Local`.
    let status = unsafe {
        GetNamedSecurityInfoW(name.as_ptr(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &mut owner, null_mut(), null_mut(), null_mut(), &mut descriptor)
    };
    let _free = Local(descriptor);
    if status != ERROR_SUCCESS {
        return Err(win32(status, "read the owner"));
    }
    sid_string(owner)
}

/// True when `path` is owned by `our_user_sid` and its DACL is protected
/// (inherits nothing) and allows only that user.
pub fn directory_is_owner_only(path: &Path, our_user_sid: &str) -> io::Result<bool> {
    let name = wide(path);
    let mut owner: PSID = null_mut();
    let mut dacl: *mut ACL = null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: out-pointers valid; `descriptor` is freed by `Local`.
    let status = unsafe {
        GetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut descriptor,
        )
    };
    let _free = Local(descriptor);
    if status != ERROR_SUCCESS {
        return Err(win32(status, "read the directory's security"));
    }
    if owner_allowed(&sid_string(owner)?, our_user_sid).is_err() || dacl.is_null() {
        return Ok(false);
    }
    let (mut control, mut revision) = (0u16, 0u32);
    // SAFETY: a valid descriptor.
    if unsafe { GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) } == 0 {
        return Err(io::Error::last_os_error());
    }
    if control & SE_DACL_PROTECTED == 0 {
        return Ok(false);
    }
    // SAFETY: a valid ACL from the descriptor.
    let count = unsafe { (*dacl).AceCount };
    if count == 0 {
        return Ok(false);
    }
    for index in 0..u32::from(count) {
        let mut ace: *mut core::ffi::c_void = null_mut();
        // SAFETY: index below AceCount.
        if unsafe { GetAce(dacl, index, &mut ace) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: every ACE starts with an ACE_HEADER.
        let header = unsafe { &*(ace as *const ACE_HEADER) };
        if header.AceType != ACCESS_ALLOWED_ACE_TYPE {
            return Ok(false);
        }
        // SAFETY: an ACCESS_ALLOWED_ACE; its SID starts at SidStart.
        let sid = unsafe { (&raw mut (*(ace as *mut ACCESS_ALLOWED_ACE)).SidStart).cast::<core::ffi::c_void>() };
        if owner_allowed(&sid_string(sid)?, our_user_sid).is_err() {
            return Ok(false);
        }
    }
    Ok(true)
}

/// `O:<user>D:P(A;OICI;FA;;;<user>)`: owned by our user, a protected DACL
/// that grants only our user, inherited by the socket file.
fn owner_only_sddl(user_sid: &str) -> Vec<u16> {
    format!("O:{user_sid}D:P(A;OICI;FA;;;{user_sid})").encode_utf16().chain([0]).collect()
}

/// Makes `dir` owner-only, or checks an existing one; refuses a wider one.
fn ensure_private_directory(dir: &Path, user_sid: &str) -> io::Result<()> {
    if let Some(parent) = dir.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    let sddl = owner_only_sddl(user_sid);
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: a NUL-terminated SDDL string; `descriptor` is freed by `Local`.
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut()) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let _free = Local(descriptor);
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    let name = wide(dir);
    // SAFETY: valid name and attributes.
    let created = unsafe { CreateDirectoryW(name.as_ptr(), &attributes) } != 0;
    if !created {
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::AlreadyExists {
            return Err(error);
        }
    }
    if !directory_is_owner_only(dir, user_sid)? {
        return Err(denied(format!(
            "refused: the socket directory {} is not owner-only (its owner or access list is wider); remove it",
            dir.display()
        )));
    }
    Ok(())
}

/// Sets the owner of `path` to `user_sid` (the socket file of an elevated
/// process is otherwise owned by BUILTIN\Administrators).
fn set_owner(path: &Path, user_sid: &str) -> io::Result<()> {
    let sddl: Vec<u16> = format!("O:{user_sid}").encode_utf16().chain([0]).collect();
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    // SAFETY: as in `ensure_private_directory`.
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut()) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let _free = Local(descriptor);
    let mut owner: PSID = null_mut();
    let mut defaulted = 0;
    // SAFETY: a valid descriptor.
    if unsafe { windows_sys::Win32::Security::GetSecurityDescriptorOwner(descriptor, &mut owner, &mut defaulted) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut name = wide(path);
    // SAFETY: valid name and SID.
    let status = unsafe {
        SetNamedSecurityInfoW(name.as_mut_ptr(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, owner, null_mut(), null_mut(), null_mut())
    };
    if status != ERROR_SUCCESS {
        return Err(win32(status, "set the socket's owner"));
    }
    Ok(())
}

/// A listening local socket that refuses foreign and sandboxed peers.
pub struct Listener {
    inner: uds_windows::UnixListener,
    user_sid: String,
}

/// Binds `path` in an owner-only directory and makes our token user the
/// socket file's owner.
pub fn listen(path: &Path) -> io::Result<Listener> {
    let me = current_identity()?;
    let dir = path.parent().filter(|d| !d.as_os_str().is_empty()).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, format!("socket path {} has no directory", path.display()))
    })?;
    ensure_private_directory(dir, &me.user_sid)?;
    let inner = uds_windows::UnixListener::bind(path)?;
    set_owner(path, &me.user_sid)?;
    Ok(Listener { inner, user_sid: me.user_sid })
}

impl Listener {
    /// The next connection whose peer passes [`crate::peer_allowed`]; a
    /// refused one is closed and reported as `PermissionDenied`.
    pub fn accept(&self) -> io::Result<Stream> {
        self.accept_with_peer().map(|(stream, _)| stream)
    }

    /// As [`Listener::accept`], with the peer's identity.
    pub fn accept_with_peer(&self) -> io::Result<(Stream, PeerIdentity)> {
        let (stream, _) = self.inner.accept()?;
        let pid = peer_pid(&stream)?;
        let peer = process_identity(pid)
            .map_err(|e| denied(format!("refused: cannot read peer process {pid}'s token: {e}")))?;
        if let Err(refusal) = peer_allowed(&peer, &self.user_sid) {
            let _ = stream.shutdown(std::net::Shutdown::Both);
            return Err(denied(format!("{refusal} (pid {pid})")));
        }
        Ok((stream, peer))
    }

    pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()> {
        self.inner.set_nonblocking(nonblocking)
    }

    /// The raw socket (tests: inheritance).
    pub fn raw_socket(&self) -> u64 {
        std::os::windows::io::AsRawSocket::as_raw_socket(&self.inner)
    }
}

/// A plain connect (no owner check): for a path the caller trusts.
pub fn connect(path: &Path) -> io::Result<Stream> {
    uds_windows::UnixStream::connect(path)
}

/// Refuses the socket at `path` unless its owner is our token user, then
/// connects.
pub fn connect_same_user(path: &Path) -> io::Result<Stream> {
    let me = current_identity()?;
    let owner = owner_of(path)?;
    owner_allowed(&owner, &me.user_sid).map_err(|refusal| denied(format!("{refusal}: {}", path.display())))?;
    connect(path)
}

/// [`connect_same_user`] retried until `timeout`: a missing socket or a
/// refused connection (the daemon still starting) waits `poll_interval`,
/// running `check` between attempts (an error from it ends the wait). An
/// owner refusal is final.
pub fn connect_with_deadline(
    path: &Path,
    timeout: Duration,
    poll_interval: Duration,
    mut check: impl FnMut() -> io::Result<()>,
) -> io::Result<Stream> {
    if poll_interval.is_zero() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "connect poll interval must be greater than zero"));
    }
    let deadline = Instant::now() + timeout;
    loop {
        match connect_same_user(path) {
            Ok(stream) => return Ok(stream),
            Err(e) if e.kind() == io::ErrorKind::PermissionDenied => return Err(e),
            Err(e) => {
                let now = Instant::now();
                if now >= deadline {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, format!("connect {}: {e}", path.display())));
                }
                check()?;
                std::thread::sleep(deadline.saturating_duration_since(now).min(poll_interval));
            }
        }
    }
}

/// The process id at the other end of `stream` (`SIO_AF_UNIX_GETPEERPID`).
pub fn peer_pid(stream: &Stream) -> io::Result<u32> {
    let socket = std::os::windows::io::AsRawSocket::as_raw_socket(stream) as SOCKET;
    let mut pid = 0u32;
    let mut returned = 0u32;
    // SAFETY: a connected socket; the output buffer is 4 bytes.
    let status = unsafe {
        WSAIoctl(socket, SIO_AF_UNIX_GETPEERPID, null_mut(), 0, (&raw mut pid).cast(), 4, &mut returned, null_mut(), None)
    };
    if status == SOCKET_ERROR {
        // SAFETY: plain call.
        return Err(io::Error::from_raw_os_error(unsafe { WSAGetLastError() }));
    }
    Ok(pid)
}

#[cfg(test)]
mod tests {
    #[test]
    fn owner_only_sddl_is_protected_and_inherited_by_children() {
        let s = String::from_utf16_lossy(&super::owner_only_sddl("S-1-5-21-1-2-3-1002"));
        assert_eq!(s.trim_end_matches('\0'), "O:S-1-5-21-1-2-3-1002D:P(A;OICI;FA;;;S-1-5-21-1-2-3-1002)");
    }
}
