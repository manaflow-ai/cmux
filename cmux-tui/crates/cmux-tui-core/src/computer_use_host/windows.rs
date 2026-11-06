//! Starting the worker on Windows. The worker must run in the person's
//! interactive session (session 0 has no desktop to see or drive):
//!
//! - A daemon in an interactive session starts it as a plain hidden child
//!   (no console window) with its stdin and stdout as the control channel.
//! - A daemon in session 0 (a service) cannot start a process in the
//!   person's session itself without SYSTEM's `WTSQueryUserToken`; it
//!   registers a scheduled task for the console user with "run only when
//!   the user is logged on" (`/IT`) and runs it. That worker reaches the
//!   daemon over two named pipes (`<name>-in`, `<name>-out`) whose DACL
//!   admits only the daemon's account and that user.
//!
//! Also the owner-file check: the policy file must be owned by SYSTEM or
//! Administrators, and no other account may write it.

use std::ffi::c_void;
use std::os::windows::io::FromRawHandle;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use windows_sys::Win32::Foundation::{
    ERROR_PIPE_CONNECTED, GENERIC_READ, GENERIC_WRITE, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
    LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
    GetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    ACL, DACL_SECURITY_INFORMATION, GetAce, GetTokenInformation, LookupAccountNameW,
    OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, SID_NAME_USE,
    TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, OPEN_EXISTING, PIPE_ACCESS_INBOUND, PIPE_ACCESS_OUTBOUND,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS,
    PIPE_TYPE_BYTE, PIPE_WAIT,
};
use windows_sys::Win32::System::RemoteDesktop::{
    ProcessIdToSessionId, WTS_CURRENT_SERVER_HANDLE, WTSDomainName, WTSFreeMemory,
    WTSGetActiveConsoleSessionId, WTSQuerySessionInformationW, WTSUserName,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

use cmux_process::{Command, Stdio};

use super::{Launcher, WORKER_MODE, WorkerProcess};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// How long a scheduled worker has to connect its control pipes.
const TASK_CONNECT: Duration = Duration::from_secs(20);

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn wide_os(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
}

/// A NUL-terminated wide string from Windows.
unsafe fn from_wide(ptr: *const u16) -> String {
    if ptr.is_null() {
        return String::new();
    }
    // SAFETY: the caller passes a NUL-terminated string.
    let len = (0..).take_while(|i| unsafe { *ptr.add(*i) } != 0).count();
    // SAFETY: `len` units are readable.
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn sid_string(sid: *mut c_void) -> Option<String> {
    let mut text: *mut u16 = std::ptr::null_mut();
    // SAFETY: a valid SID; the string is freed below.
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
        return None;
    }
    // SAFETY: from ConvertSidToStringSidW.
    let out = unsafe { from_wide(text) };
    // SAFETY: allocated by ConvertSidToStringSidW.
    unsafe { LocalFree(text.cast()) };
    Some(out)
}

/// This process's user SID as a string.
fn own_sid() -> Result<String, String> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: the pseudo handle of this process; out parameter.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err("cannot read this process's token".into());
    }
    let token = Handle(token);
    let mut len = 0u32;
    // SAFETY: size query.
    unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut len) };
    let mut buf = vec![0u8; len as usize];
    // SAFETY: a buffer of the size Windows asked for.
    if unsafe { GetTokenInformation(token.0, TokenUser, buf.as_mut_ptr().cast(), len, &mut len) }
        == 0
    {
        return Err("cannot read this process's user".into());
    }
    // SAFETY: the buffer holds a TOKEN_USER.
    let sid = unsafe { (*(buf.as_ptr() as *const TOKEN_USER)).User.Sid };
    sid_string(sid).ok_or_else(|| "cannot name this process's user".into())
}

struct Handle(HANDLE);
// SAFETY: a kernel handle, usable from any thread.
unsafe impl Send for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            // SAFETY: a handle this module opened.
            unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
        }
    }
}

fn session_of_this_process() -> Option<u32> {
    let mut session = 0u32;
    // SAFETY: out parameter.
    (unsafe { ProcessIdToSessionId(std::process::id(), &mut session) } != 0).then_some(session)
}

/// The console session's user as `DOMAIN\name`.
fn console_user() -> Result<(u32, String), String> {
    // SAFETY: plain call.
    let session = unsafe { WTSGetActiveConsoleSessionId() };
    if session == u32::MAX {
        return Err("no one is signed in at this PC's console".into());
    }
    let query = |class| -> String {
        let mut buf: *mut u16 = std::ptr::null_mut();
        let mut bytes = 0u32;
        // SAFETY: out parameters; freed below.
        if unsafe {
            WTSQuerySessionInformationW(
                WTS_CURRENT_SERVER_HANDLE,
                session,
                class,
                &mut buf,
                &mut bytes,
            )
        } == 0
        {
            return String::new();
        }
        // SAFETY: a NUL-terminated string from WTS.
        let text = unsafe { from_wide(buf) };
        // SAFETY: allocated by WTSQuerySessionInformationW.
        unsafe { WTSFreeMemory(buf.cast()) };
        text
    };
    let (user, domain) = (query(WTSUserName), query(WTSDomainName));
    if user.is_empty() {
        return Err("no one is signed in at this PC's console".into());
    }
    Ok((session, if domain.is_empty() { user } else { format!("{domain}\\{user}") }))
}

fn account_sid(account: &str) -> Result<String, String> {
    let name = wide(account);
    let (mut sid_len, mut domain_len, mut kind) = (0u32, 0u32, 0 as SID_NAME_USE);
    // SAFETY: size query.
    unsafe {
        LookupAccountNameW(
            std::ptr::null(),
            name.as_ptr(),
            std::ptr::null_mut(),
            &mut sid_len,
            std::ptr::null_mut(),
            &mut domain_len,
            &mut kind,
        )
    };
    let mut sid = vec![0u8; sid_len as usize];
    let mut domain = vec![0u16; domain_len as usize];
    // SAFETY: buffers of the sizes Windows asked for.
    if unsafe {
        LookupAccountNameW(
            std::ptr::null(),
            name.as_ptr(),
            sid.as_mut_ptr().cast(),
            &mut sid_len,
            domain.as_mut_ptr(),
            &mut domain_len,
            &mut kind,
        )
    } == 0
    {
        return Err(format!("cannot find the account {account}"));
    }
    sid_string(sid.as_mut_ptr().cast()).ok_or_else(|| format!("cannot name the account {account}"))
}

pub(crate) struct NativeLauncher {
    exe: PathBuf,
}

impl NativeLauncher {
    pub(crate) fn new(exe: PathBuf) -> Self {
        Self { exe }
    }

    fn direct(&self, log: &Path) -> Result<WorkerProcess, String> {
        let log_file = open_log(log)?;
        let mut child = Command::new(&self.exe)
            .arg(WORKER_MODE)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(log_file))
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|error| format!("the Computer Use worker did not start: {error}"))?;
        let input = child.stdin.take().ok_or("the worker has no stdin")?;
        let output = child.stdout.take().ok_or("the worker has no stdout")?;
        Ok(WorkerProcess {
            input: Box::new(input),
            output: Box::new(output),
            reap: Box::new(move || {
                let _ = child.wait();
            }),
        })
    }

    /// Session 0: a scheduled task in the console user's session.
    fn scheduled(&self) -> Result<WorkerProcess, String> {
        let (_session, user) = console_user()?;
        let sddl = format!("D:P(A;;GA;;;{})(A;;GA;;;{})", own_sid()?, account_sid(&user)?);
        let mut nonce = [0u8; 8];
        getrandom::fill(&mut nonce).map_err(|e| format!("{e}"))?;
        let name = format!("cmux-cu-ctl-{}", cmux_computer_use::wire::hex(&nonce));
        let to_worker = Pipe::create(&format!(r"\\.\pipe\{name}-in"), PIPE_ACCESS_OUTBOUND, &sddl)?;
        let from_worker =
            Pipe::create(&format!(r"\\.\pipe\{name}-out"), PIPE_ACCESS_INBOUND, &sddl)?;
        let task = format!(r"cmux\Computer Use {}", user.replace('\\', " "));
        let action = format!("\"{}\" {WORKER_MODE} --control {name}", self.exe.display());
        schtasks(&[
            "/Create",
            "/F",
            "/TN",
            &task,
            "/SC",
            "ONCE",
            "/ST",
            "00:00",
            "/SD",
            "01/01/2000",
            "/RU",
            &user,
            "/IT",
            "/RL",
            "LIMITED",
            "/TR",
            &action,
        ])?;
        schtasks(&["/Run", "/TN", &task])?;
        let input = to_worker.accept()?;
        let output = from_worker.accept()?;
        Ok(WorkerProcess {
            input: Box::new(input),
            output: Box::new(output),
            reap: Box::new(move || {
                let _ = schtasks(&["/Delete", "/F", "/TN", &task]);
            }),
        })
    }
}

fn open_log(log: &Path) -> Result<std::fs::File, String> {
    if let Some(dir) = log.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .map_err(|error| format!("{}: {error}", log.display()))
}

fn schtasks(args: &[&str]) -> Result<(), String> {
    let output = Command::new("schtasks.exe")
        .args(args)
        .stdin(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|error| format!("schtasks: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!("schtasks {}: {}", args[0], String::from_utf8_lossy(&output.stderr).trim()))
    }
}

/// One server end of a control pipe.
struct Pipe {
    handle: Handle,
    name: Vec<u16>,
}

impl Pipe {
    fn create(name: &str, direction: u32, sddl: &str) -> Result<Self, String> {
        let sddl = wide(sddl);
        let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: a valid SDDL string; freed below.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err("cannot build the control pipe's access list".into());
        }
        let mut attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        let wide_name = wide(name);
        // SAFETY: valid name and attributes; one instance.
        let handle = unsafe {
            CreateNamedPipeW(
                wide_name.as_ptr(),
                direction,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                64 * 1024,
                64 * 1024,
                0,
                &mut attributes,
            )
        };
        // SAFETY: from ConvertStringSecurityDescriptorToSecurityDescriptorW.
        unsafe { LocalFree(descriptor) };
        if handle == INVALID_HANDLE_VALUE {
            return Err(format!("cannot create {name}"));
        }
        Ok(Self { handle: Handle(handle), name: wide_name })
    }

    /// Waits for the worker to open it; unblocks itself after [`TASK_CONNECT`].
    fn accept(self) -> Result<std::fs::File, String> {
        let (tx, rx) = mpsc::channel();
        let Pipe { handle, name } = self;
        let raw = handle.0 as usize;
        std::thread::spawn(move || {
            // SAFETY: a blocking connect on our own pipe handle.
            let ok = unsafe { ConnectNamedPipe(raw as HANDLE, std::ptr::null_mut()) } != 0
                // SAFETY: plain call.
                || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
            let _ = tx.send(ok);
        });
        let connected = match rx.recv_timeout(TASK_CONNECT) {
            Ok(ok) => ok,
            Err(_) => {
                // Connect to ourselves so the waiting thread returns, then give up.
                // SAFETY: opening our own pipe as a client; closed at once.
                drop(Handle(unsafe {
                    CreateFileW(
                        name.as_ptr(),
                        GENERIC_READ | GENERIC_WRITE,
                        0,
                        std::ptr::null(),
                        OPEN_EXISTING,
                        0,
                        std::ptr::null_mut(),
                    )
                }));
                let _ = rx.recv();
                false
            }
        };
        if !connected {
            return Err("the scheduled Computer Use worker did not connect".into());
        }
        let raw = handle.0;
        std::mem::forget(handle);
        // SAFETY: we own the handle and hand it to the File.
        Ok(unsafe { std::fs::File::from_raw_handle(raw) })
    }
}

impl Launcher for NativeLauncher {
    fn launch(&self, log: &Path) -> Result<WorkerProcess, String> {
        match session_of_this_process() {
            Some(0) => self.scheduled(),
            _ => self.direct(log),
        }
    }
}

/// SIDs that may own or write the owner file.
const TRUSTED_WRITERS: &[&str] = &[
    "S-1-5-18",                                                       // SYSTEM
    "S-1-5-32-544",                                                   // Administrators
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464", // TrustedInstaller
];
/// Rights that let an account change the file.
const WRITE_RIGHTS: u32 = 0x0000_0002 // FILE_WRITE_DATA
    | 0x0000_0004 // FILE_APPEND_DATA
    | 0x0000_0010 // FILE_WRITE_EA
    | 0x0000_0100 // FILE_WRITE_ATTRIBUTES
    | 0x0001_0000 // DELETE
    | 0x0004_0000 // WRITE_DAC
    | 0x0008_0000 // WRITE_OWNER
    | 0x1000_0000 // GENERIC_ALL
    | 0x4000_0000; // GENERIC_WRITE
const INHERIT_ONLY_ACE: u8 = 0x08;

#[repr(C)]
struct AceHeader {
    kind: u8,
    flags: u8,
    size: u16,
}

#[repr(C)]
struct AllowedAce {
    header: AceHeader,
    mask: u32,
    sid_start: u32,
}

/// The owner file is owned by SYSTEM or Administrators and only they (or
/// TrustedInstaller) may write it.
pub(crate) fn owner_only_file(path: &Path) -> Result<(), String> {
    let name = wide_os(path);
    let mut owner: *mut c_void = std::ptr::null_mut();
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    // SAFETY: out parameters; the descriptor is freed below.
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
        return Err(format!("{}: cannot read its owner", path.display()));
    }
    let result = (|| {
        let owner = sid_string(owner).unwrap_or_default();
        if !TRUSTED_WRITERS.contains(&owner.as_str()) {
            return Err(format!("{} is not owned by SYSTEM or Administrators", path.display()));
        }
        if dacl.is_null() {
            return Err(format!("{} has no access list (everyone may write it)", path.display()));
        }
        // SAFETY: a valid ACL from GetNamedSecurityInfoW.
        let count = unsafe { (*dacl).AceCount };
        for index in 0..u32::from(count) {
            let mut ace: *mut c_void = std::ptr::null_mut();
            // SAFETY: index below AceCount.
            if unsafe { GetAce(dacl, index, &mut ace) } == 0 {
                return Err(format!("{}: unreadable access list", path.display()));
            }
            // SAFETY: every ACE starts with an ACE_HEADER.
            let header = unsafe { &*(ace as *const AceHeader) };
            if header.kind != 0 || header.flags & INHERIT_ONLY_ACE != 0 {
                continue; // Only ACCESS_ALLOWED entries that apply to the file grant anything.
            }
            // SAFETY: an ACCESS_ALLOWED_ACE; its SID starts at sid_start.
            let allowed = unsafe { &*(ace as *const AllowedAce) };
            if allowed.mask & WRITE_RIGHTS == 0 {
                continue;
            }
            let sid =
                sid_string((&raw const allowed.sid_start).cast_mut().cast()).unwrap_or_default();
            if !TRUSTED_WRITERS.contains(&sid.as_str()) {
                return Err(format!("{} is writable by {sid}", path.display()));
            }
        }
        Ok(())
    })();
    // SAFETY: from GetNamedSecurityInfoW.
    unsafe { LocalFree(descriptor) };
    result
}
