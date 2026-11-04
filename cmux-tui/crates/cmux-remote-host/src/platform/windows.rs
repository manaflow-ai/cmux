//! Windows: Toolhelp and process tokens for identity, named pipes with an
//! owner-only DACL (client process id and token SID checked per connection),
//! SYSTEM/Administrators-only configuration, and the interactive session.
//!
//! The host runs in the person's interactive session (an interactive logon
//! task, never Session 0, which has no desktop); a daemon in an SSH session
//! (Session 0) reaches it over its named pipe, as upstream documents
//! (cua-driver guides, "Windows over SSH").

#![allow(unsafe_code)]

use std::ffi::{OsStr, OsString, c_void};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{Value, json};
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use windows_sys::Win32::Foundation::{CloseHandle, FILETIME, HANDLE, LocalFree};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetNamedSecurityInfoW,
    SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, GetAce, GetTokenInformation,
    OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::System::Pipes::GetNamedPipeClientProcessId;
use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, GetProcessTimes, OpenProcess, OpenProcessToken, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};

/// The accepted stream.
pub type LocalStream = NamedPipeServer;

const SYSTEM_SID: &str = "S-1-5-18";
const ADMINISTRATORS_SID: &str = "S-1-5-32-544";
const TRUSTED_INSTALLER_SID: &str = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
/// On the file: FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES | DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_ALL | GENERIC_WRITE
const FILE_WRITE_RIGHTS: u32 = 0x0002 | 0x0004 | 0x0010 | 0x0100 | 0x0001_0000 | 0x0004_0000 | 0x0008_0000 | 0x1000_0000 | 0x4000_0000;
/// On its folder, the rights that could replace the file: FILE_DELETE_CHILD | DELETE | WRITE_DAC |
/// WRITE_OWNER | GENERIC_ALL. Adding files (FILE_ADD_FILE, which every user inherits on
/// %ProgramData%) cannot replace an existing one.
const FOLDER_REPLACE_RIGHTS: u32 = 0x0040 | 0x0001_0000 | 0x0004_0000 | 0x0008_0000 | 0x1000_0000;
const INHERIT_ONLY_ACE: u8 = 0x08;

fn wide(text: &OsStr) -> Vec<u16> {
    text.encode_wide().chain(std::iter::once(0)).collect()
}

struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: a handle this wrapper owns.
            unsafe { CloseHandle(self.0) };
        }
    }
}

fn open_process(pid: u32) -> Option<Handle> {
    // SAFETY: plain call; a null result is handled.
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    (!handle.is_null()).then_some(Handle(handle))
}

/// The creation time (100 ns since 1601) of a live process.
pub fn process_start(pid: u32) -> Option<u64> {
    let process = open_process(pid)?;
    let mut created = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let mut exited = created;
    let mut kernel = created;
    let mut user = created;
    // SAFETY: four valid FILETIME out pointers.
    let ok = unsafe { GetProcessTimes(process.0, &mut created, &mut exited, &mut kernel, &mut user) } != 0;
    // A process that exited still answers until its last handle closes: exited time set means gone.
    let gone = exited.dwLowDateTime != 0 || exited.dwHighDateTime != 0;
    (ok && !gone).then(|| (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime))
}

/// The parent of one process (`NtQueryInformationProcess`, ProcessBasicInformation):
/// a single pid's record, never an enumeration.
pub fn parent_pid(pid: u32) -> Option<u32> {
    #[repr(C)]
    struct ProcessBasicInformation {
        exit_status: i32,
        peb: *mut c_void,
        affinity: usize,
        priority: i32,
        unique_pid: usize,
        parent_pid: usize,
    }
    #[link(name = "ntdll")]
    unsafe extern "system" {
        fn NtQueryInformationProcess(process: HANDLE, class: u32, info: *mut c_void, length: u32, returned: *mut u32) -> i32;
    }
    let process = open_process(pid)?;
    // SAFETY: plain data; filled below.
    let mut info: ProcessBasicInformation = unsafe { std::mem::zeroed() };
    let mut returned = 0_u32;
    // SAFETY: a correctly sized ProcessBasicInformation (class 0).
    let status = unsafe {
        NtQueryInformationProcess(
            process.0,
            0,
            (&raw mut info).cast(),
            std::mem::size_of::<ProcessBasicInformation>() as u32,
            &mut returned,
        )
    };
    (status >= 0).then(|| u32::try_from(info.parent_pid).ok()).flatten()
}

pub fn process_exe(pid: u32) -> Option<PathBuf> {
    let process = open_process(pid)?;
    let mut buffer = vec![0_u16; 32_768];
    let mut length = buffer.len() as u32;
    // SAFETY: the buffer holds `length` UTF-16 units.
    let ok = unsafe { QueryFullProcessImageNameW(process.0, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut length) } != 0;
    ok.then(|| PathBuf::from(OsString::from_wide(&buffer[..length as usize])))
}

/// Hashes the running image's file (Windows keeps a running image's file from being written).
pub fn process_exe_sha256(pid: u32) -> Option<String> {
    crate::wire::sha256_file(&process_exe(pid)?).ok()
}

fn sid_string(sid: PSID) -> Option<String> {
    let mut text: *mut u16 = std::ptr::null_mut();
    // SAFETY: a valid SID; the string is freed with LocalFree.
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 || text.is_null() {
        return None;
    }
    // SAFETY: a NUL-terminated string from the call above.
    let length = (0..).take_while(|&index| unsafe { *text.add(index) } != 0).count();
    // SAFETY: `length` units were just read.
    let value = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, length) });
    // SAFETY: allocated by ConvertSidToStringSidW.
    unsafe { LocalFree(text.cast()) };
    Some(value)
}

/// The user SID of a process's token, as a string.
fn token_user(process: HANDLE) -> Option<String> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: a process handle with query rights.
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return None;
    }
    let token = Handle(token);
    let mut needed = 0_u32;
    // SAFETY: a size query.
    unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut needed) };
    let mut buffer = vec![0_u8; needed as usize];
    // SAFETY: the buffer is `needed` bytes.
    if unsafe { GetTokenInformation(token.0, TokenUser, buffer.as_mut_ptr().cast(), needed, &mut needed) } == 0 {
        return None;
    }
    // SAFETY: the buffer holds a TOKEN_USER.
    let user = unsafe { &*(buffer.as_ptr().cast::<TOKEN_USER>()) };
    sid_string(user.User.Sid)
}

pub fn my_sid() -> Option<String> {
    // SAFETY: the pseudo handle needs no close.
    token_user(unsafe { GetCurrentProcess() })
}

pub fn process_sid(pid: u32) -> Option<String> {
    token_user(open_process(pid)?.0)
}

/// The client of an accepted pipe: same user (token SID) and its process id.
pub fn peer_of(stream: &LocalStream) -> Option<(bool, u32)> {
    let mut pid = 0_u32;
    // SAFETY: a connected server handle.
    if unsafe { GetNamedPipeClientProcessId(stream.as_raw_handle() as HANDLE, &mut pid) } == 0 {
        return None;
    }
    let same = process_sid(pid).is_some_and(|sid| Some(sid) == my_sid());
    Some((same, pid))
}

/// The process serving a local endpoint of this user: a named pipe
/// (`GetNamedPipeServerProcessId`) or an AF_UNIX socket file, which acpmux
/// serves on Windows (`SIO_AF_UNIX_GETPEERPID`). None for another user's.
pub fn listener_pid(endpoint: &Path) -> Option<u32> {
    let pid = if endpoint.as_os_str().to_string_lossy().starts_with(r"\\.\pipe\") {
        pipe_server_pid(endpoint)?
    } else {
        unix_socket_peer_pid(endpoint)?
    };
    (process_sid(pid)? == my_sid()?).then_some(pid)
}

fn pipe_server_pid(endpoint: &Path) -> Option<u32> {
    use windows_sys::Win32::Storage::FileSystem::{CreateFileW, OPEN_EXISTING, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT};
    use windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId;
    let name = wide(endpoint.as_os_str());
    // SAFETY: a NUL-terminated name; identification only, so the server cannot impersonate us.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            0x8000_0000 | 0x4000_0000,
            0,
            std::ptr::null(),
            OPEN_EXISTING,
            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
            std::ptr::null_mut(),
        )
    };
    if handle as isize == -1 {
        return None;
    }
    let handle = Handle(handle);
    let mut pid = 0_u32;
    // SAFETY: a connected client handle.
    (unsafe { GetNamedPipeServerProcessId(handle.0, &mut pid) } != 0).then_some(pid)
}

fn unix_socket_peer_pid(endpoint: &Path) -> Option<u32> {
    use windows_sys::Win32::Networking::WinSock::{
        AF_UNIX, SOCK_STREAM, SOCKADDR, SOCKADDR_UN, WSADATA, WSAIoctl, WSAStartup, closesocket, connect, socket,
    };
    /// _WSAIOR(IOC_VENDOR, 256)
    const SIO_AF_UNIX_GETPEERPID: u32 = 0x5800_0100;
    let path = endpoint.to_str()?.as_bytes();
    // SAFETY: plain data.
    let mut address: SOCKADDR_UN = unsafe { std::mem::zeroed() };
    if path.len() >= address.sun_path.len() {
        return None;
    }
    address.sun_family = AF_UNIX;
    for (slot, byte) in address.sun_path.iter_mut().zip(path) {
        *slot = *byte as _;
    }
    // SAFETY: WSAStartup is reference counted; a later call is harmless.
    let mut data: WSADATA = unsafe { std::mem::zeroed() };
    unsafe { WSAStartup(0x0202, &mut data) };
    // SAFETY: a new socket, closed below.
    let sock = unsafe { socket(i32::from(AF_UNIX), SOCK_STREAM, 0) };
    if sock == usize::MAX {
        return None;
    }
    // SAFETY: a valid sockaddr_un of its full size.
    let connected = unsafe {
        connect(sock, (&raw const address).cast::<SOCKADDR>(), std::mem::size_of::<SOCKADDR_UN>() as i32)
    } == 0;
    let mut pid = 0_u32;
    let mut returned = 0_u32;
    // SAFETY: a connected socket and a u32 out buffer.
    let ok = connected
        && unsafe {
            WSAIoctl(
                sock,
                SIO_AF_UNIX_GETPEERPID,
                std::ptr::null(),
                0,
                (&raw mut pid).cast(),
                4,
                &mut returned,
                std::ptr::null_mut(),
                None,
            )
        } == 0;
    // SAFETY: the socket from above.
    unsafe { closesocket(sock) };
    (ok && pid != 0).then_some(pid)
}

/// Owner-only DACL: generic all for this user's SID, nothing for anyone else.
struct PipeSecurity {
    descriptor: PSECURITY_DESCRIPTOR,
    attributes: SECURITY_ATTRIBUTES,
}

// SAFETY: the descriptor is immutable after creation and freed once in Drop.
unsafe impl Send for PipeSecurity {}
// SAFETY: as above.
unsafe impl Sync for PipeSecurity {}

impl PipeSecurity {
    fn owner_only() -> Result<Self, String> {
        let sid = my_sid().ok_or("cannot read this user's SID")?;
        let sddl = wide(OsStr::new(&format!("D:P(A;;GA;;;{sid})")));
        let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: a NUL-terminated SDDL string; the descriptor is freed in Drop.
        let ok = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), 1, &mut descriptor, std::ptr::null_mut())
        } != 0;
        if !ok {
            return Err(format!("cannot build the pipe's DACL: {}", std::io::Error::last_os_error()));
        }
        let attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        Ok(Self { descriptor, attributes })
    }
}

impl Drop for PipeSecurity {
    fn drop(&mut self) {
        // SAFETY: allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
        unsafe { LocalFree(self.descriptor) };
    }
}

/// A named pipe endpoint that accepts one client per instance.
pub struct PipeListener {
    name: OsString,
    security: PipeSecurity,
    next: Mutex<Option<NamedPipeServer>>,
}

impl PipeListener {
    fn instance(&self, first: bool) -> std::io::Result<NamedPipeServer> {
        let mut attributes = self.security.attributes;
        let mut options = ServerOptions::new();
        options.first_pipe_instance(first).reject_remote_clients(true);
        // SAFETY: valid SECURITY_ATTRIBUTES that outlive the call.
        unsafe { options.create_with_security_attributes_raw(&self.name, (&raw mut attributes).cast::<c_void>()) }
    }
}

/// Serves `name` (`\\.\pipe\...`) with the owner-only DACL. The first instance
/// fails when another process already owns the name.
pub fn listen(name: &Path) -> Result<PipeListener, String> {
    let security = PipeSecurity::owner_only()?;
    let listener = PipeListener { name: name.as_os_str().to_owned(), security, next: Mutex::new(None) };
    let first = listener.instance(true).map_err(|error| format!("{}: {error}", name.display()))?;
    *listener.next.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(first);
    Ok(listener)
}

pub async fn accept(listener: &PipeListener) -> std::io::Result<LocalStream> {
    let server = listener.next.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    let server = match server {
        Some(server) => server,
        None => listener.instance(false)?,
    };
    server.connect().await?;
    let next = listener.instance(false)?;
    *listener.next.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(next);
    Ok(server)
}

/// Creates `dir`; a folder under the user's profile is private to the user by inheritance.
pub fn make_private_dir(dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    let meta = std::fs::symlink_metadata(dir).map_err(|error| format!("{error}"))?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err(format!("{} is not a directory", dir.display()));
    }
    Ok(())
}

pub fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("no parent directory")?;
    make_private_dir(dir)?;
    let temporary = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&temporary, bytes).map_err(|error| format!("{}: {error}", temporary.display()))?;
    std::fs::rename(&temporary, path).map_err(|error| format!("{}: {error}", path.display()))
}

pub fn read_private(path: &Path) -> Result<Vec<u8>, String> {
    std::fs::read(path).map_err(|error| format!("{}: {error}", path.display()))
}

/// Why `path`'s owner and DACL do not make it the machine owner's, or None.
fn owner_only_problem(path: &Path, rights: u32) -> Option<String> {
    let name = wide(path.as_os_str());
    let mut owner: PSID = std::ptr::null_mut();
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    // SAFETY: out pointers into this frame; the descriptor is freed below.
    let status = unsafe {
        GetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            std::ptr::null_mut(),
            &mut dacl,
            std::ptr::null_mut(),
            &mut descriptor,
        )
    };
    if status != 0 {
        return Some(format!("{}: cannot read its security ({status})", path.display()));
    }
    let trusted = |sid: &str| sid == SYSTEM_SID || sid == ADMINISTRATORS_SID || sid == TRUSTED_INSTALLER_SID;
    let problem = (|| {
        let owner = sid_string(owner)?;
        if !trusted(&owner) {
            return Some(format!("{} is owned by {owner}, not SYSTEM or Administrators", path.display()));
        }
        if dacl.is_null() {
            return Some(format!("{} has no DACL (everyone may write it)", path.display()));
        }
        // SAFETY: a valid ACL from GetNamedSecurityInfoW.
        let count = unsafe { (*dacl).AceCount };
        for index in 0..u32::from(count) {
            let mut ace: *mut c_void = std::ptr::null_mut();
            // SAFETY: index below AceCount.
            if unsafe { GetAce(dacl, index, &mut ace) } == 0 {
                return Some(format!("{}: unreadable ACE", path.display()));
            }
            // SAFETY: every ACE starts with an ACE_HEADER.
            let header = unsafe { &*(ace.cast::<ACE_HEADER>()) };
            if header.AceType != 0 || header.AceFlags & INHERIT_ONLY_ACE != 0 {
                continue; // only ACCESS_ALLOWED entries that apply here grant anything
            }
            // SAFETY: an ACCESS_ALLOWED_ACE (type 0).
            let allowed = unsafe { &*(ace.cast::<ACCESS_ALLOWED_ACE>()) };
            if allowed.Mask & rights == 0 {
                continue;
            }
            let sid = sid_string((&raw const allowed.SidStart).cast_mut().cast())?;
            if !trusted(&sid) {
                return Some(format!("{} grants write access to {sid}", path.display()));
            }
        }
        None
    })();
    // SAFETY: allocated by GetNamedSecurityInfoW.
    unsafe { LocalFree(descriptor) };
    problem
}

/// Reads a file only SYSTEM and Administrators can change (file and folder).
pub fn read_owner_file(path: &Path) -> Result<String, String> {
    if let Some(problem) = owner_only_problem(path, FILE_WRITE_RIGHTS) {
        return Err(problem);
    }
    if let Some(problem) = path.parent().and_then(|folder| owner_only_problem(folder, FOLDER_REPLACE_RIGHTS)) {
        return Err(problem);
    }
    std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))
}

/// Whether this process runs in an interactive session (not Session 0).
pub fn interactive_session() -> Option<bool> {
    let mut session = 0_u32;
    // SAFETY: an out pointer.
    let ok = unsafe { ProcessIdToSessionId(std::process::id(), &mut session) } != 0;
    ok.then_some(session != 0)
}

/// `status.permissions`: `interactive-session` (the driver needs a desktop).
pub fn permissions(_state_dir: &Path) -> Value {
    json!({"interactive-session": interactive_session().unwrap_or(false)})
}

pub fn display_kind() -> Option<&'static str> {
    interactive_session().unwrap_or(false).then_some("windows")
}

/// The variables a worker needs (never cmux tokens).
pub const DESKTOP_ENV: &[&str] = &[
    "SystemRoot",
    "SystemDrive",
    "windir",
    "USERPROFILE",
    "USERNAME",
    "USERDOMAIN",
    "LOCALAPPDATA",
    "APPDATA",
    "ProgramData",
    "TEMP",
    "TMP",
    "PATH",
    "PATHEXT",
    "COMPUTERNAME",
];

/// Sets the daemon's `Global\cmux-remote-<leaf>-ready` event (the daemon may
/// run in Session 0 while the host runs in the interactive session).
pub fn notify_ready(leaf: &str) -> bool {
    use windows_sys::Win32::System::Threading::{OpenEventW, SetEvent};
    let name = wide(OsStr::new(&format!("Global\\cmux-remote-{leaf}-ready")));
    // SAFETY: a NUL-terminated name; EVENT_MODIFY_STATE (2) is all SetEvent needs.
    let event = Handle(unsafe { OpenEventW(2, 0, name.as_ptr()) });
    // SAFETY: a valid event or null (then nothing is set).
    !event.0.is_null() && unsafe { SetEvent(event.0) } != 0
}

pub fn has_polkit_agent() -> bool {
    false
}

pub fn xdg_config_home(state_dir: &Path) -> PathBuf {
    state_dir.join("config")
}
