//! Windows parts of cmux Remote (docs/cmux-remote.md, "Windows and Linux"):
//! a sha256-verified copy of `cmux-remote-host.exe` from beside the daemon,
//! started in the person's interactive session, and the host's named pipe.
//!
//! The host needs a desktop, so it never runs in Session 0 (services, and the
//! SSH sessions of Windows OpenSSH). A daemon inside the interactive session
//! starts it directly; a daemon outside it registers an on-demand task with an
//! interactive logon for this user (`schtasks /Create /XML`, the template in
//! `crates/cmux-remote-host/dist/cmux-remote-host-task.xml`) and runs it, then
//! waits on a named event the host sets once it serves. Either way the daemon
//! talks to the host over its owner-only named pipe, as upstream's SSH proxy does.

#![allow(unsafe_code)]

use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_process::{Command, Stdio};
use serde_json::Value;
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_BROKEN_PIPE, ERROR_IO_PENDING, FILETIME, GENERIC_READ, GENERIC_WRITE, GetLastError, HANDLE,
    INVALID_HANDLE_VALUE, LocalFree, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows_sys::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_OVERLAPPED, OPEN_EXISTING, ReadFile, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
    WriteFile,
};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId;
use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows_sys::Win32::System::Threading::{
    CreateEventW, GetCurrentProcess, GetProcessTimes, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
    WaitForSingleObject,
};

use super::Paths;

const EXECUTABLE: &str = "cmux-remote-host.exe";
const TASK_TEMPLATE: &str = include_str!("../../../cmux-remote-host/dist/cmux-remote-host-task.xml");

fn wide(text: &OsStr) -> Vec<u16> {
    text.encode_wide().chain(std::iter::once(0)).collect()
}

struct OwnedHandle(HANDLE);

// SAFETY: a kernel handle; the operations below are thread safe.
unsafe impl Send for OwnedHandle {}
// SAFETY: as above.
unsafe impl Sync for OwnedHandle {}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            // SAFETY: a handle this wrapper owns.
            unsafe { CloseHandle(self.0) };
        }
    }
}

/// The client end of the host's pipe, opened for overlapped I/O, so one thread
/// can wait in a read while another writes (synchronous pipe handles
/// serialize every operation).
pub(super) struct PipeStream {
    handle: Arc<OwnedHandle>,
    read_timeout: Mutex<Option<Duration>>,
}

impl PipeStream {
    /// Opens the pipe, waiting up to 2 s for an instance while the host
    /// creates the next one (`ERROR_PIPE_BUSY`).
    pub(super) fn connect(path: &Path) -> std::io::Result<Self> {
        const ERROR_PIPE_BUSY: i32 = 231;
        for _ in 0..4 {
            match Self::open(path) {
                Err(error) if error.raw_os_error() == Some(ERROR_PIPE_BUSY) => {
                    let name = wide(path.as_os_str());
                    // SAFETY: a NUL-terminated name; a bounded wait for a free instance.
                    unsafe { windows_sys::Win32::System::Pipes::WaitNamedPipeW(name.as_ptr(), 500) };
                }
                other => return other,
            }
        }
        Self::open(path)
    }

    fn open(path: &Path) -> std::io::Result<Self> {
        let name = wide(path.as_os_str());
        // SAFETY: a NUL-terminated name; SQOS identification keeps the host from impersonating the daemon.
        let handle = unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                std::ptr::null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Self { handle: Arc::new(OwnedHandle(handle)), read_timeout: Mutex::new(None) })
    }

    pub(super) fn try_clone(&self) -> std::io::Result<Self> {
        Ok(Self { handle: Arc::clone(&self.handle), read_timeout: Mutex::new(None) })
    }

    pub(super) fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        *self.read_timeout.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = timeout;
        Ok(())
    }

    fn io(&self, buffer: *mut u8, length: usize, write: bool, timeout: Option<Duration>) -> std::io::Result<usize> {
        let length = u32::try_from(length.min(1 << 20)).unwrap_or(1 << 20);
        // SAFETY: an unnamed manual-reset event, closed by the wrapper.
        let event = OwnedHandle(unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) });
        if event.0.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: OVERLAPPED is plain data.
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        overlapped.hEvent = event.0;
        let handle = self.handle.0;
        // SAFETY: the buffer and OVERLAPPED outlive the operation (it completes or is cancelled below).
        let started = unsafe {
            if write {
                WriteFile(handle, buffer.cast_const(), length, std::ptr::null_mut(), &mut overlapped)
            } else {
                ReadFile(handle, buffer.cast(), length, std::ptr::null_mut(), &mut overlapped)
            }
        };
        if started == 0 {
            // SAFETY: no preconditions.
            let error = unsafe { GetLastError() };
            if error == ERROR_BROKEN_PIPE {
                return Ok(0);
            }
            if error != ERROR_IO_PENDING {
                return Err(std::io::Error::from_raw_os_error(error as i32));
            }
        }
        let mut done = 0_u32;
        if let Some(timeout) = timeout {
            let millis = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX - 1);
            // SAFETY: a valid event.
            let waited = unsafe { WaitForSingleObject(event.0, millis) };
            if waited == WAIT_TIMEOUT {
                // SAFETY: cancels only this operation, then waits for it to finish.
                unsafe {
                    CancelIoEx(handle, &overlapped);
                    GetOverlappedResult(handle, &overlapped, &mut done, 1);
                }
                // The read may have finished before the cancel: its bytes are off the pipe.
                if done > 0 {
                    return Ok(done as usize);
                }
                return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "read timed out"));
            }
            if waited != WAIT_OBJECT_0 {
                return Err(std::io::Error::last_os_error());
            }
        }
        // SAFETY: waits for this operation.
        if unsafe { GetOverlappedResult(handle, &overlapped, &mut done, 1) } == 0 {
            // SAFETY: no preconditions.
            let error = unsafe { GetLastError() };
            return if error == ERROR_BROKEN_PIPE { Ok(0) } else { Err(std::io::Error::from_raw_os_error(error as i32)) };
        }
        Ok(done as usize)
    }
}

impl Read for PipeStream {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let timeout = *self.read_timeout.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.io(buffer.as_mut_ptr(), buffer.len(), false, timeout)
    }
}

impl Write for PipeStream {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.io(buffer.as_ptr().cast_mut(), buffer.len(), true, None)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// The copy that runs.
pub(super) struct Staged {
    pub(super) executable: PathBuf,
    pub(super) digest: String,
}

fn sha256_file(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let mut file = std::fs::File::open(path).map_err(|error| format!("{}: {error}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1 << 20];
    loop {
        let count = file.read(&mut buffer).map_err(|error| format!("{}: {error}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn beside_daemon(name: &str) -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let path = exe.parent()?.join(name);
    path.is_file().then_some(path)
}

pub(super) fn acpmux_executable() -> Option<PathBuf> {
    beside_daemon("acpmux.exe")
}

/// A verified copy of the shipped host under `state\bin\<digest>\`.
pub(super) fn stage(state: &Path) -> Result<Staged, String> {
    let source = std::env::var_os("CMUX_REMOTE_HOST_BIN")
        .map(PathBuf::from)
        .filter(|path| path.is_file())
        .or_else(|| beside_daemon(EXECUTABLE))
        .ok_or_else(|| format!("this cmux build has no {EXECUTABLE} beside the daemon"))?;
    let digest = sha256_file(&source)?;
    if let Ok(pinned) = std::fs::read_to_string(source.with_file_name("cmux-remote-host.sha256"))
        && pinned.split_whitespace().next().map(str::to_ascii_lowercase).as_deref() != Some(digest.as_str())
    {
        return Err(format!("{} does not match its pinned sha256", source.display()));
    }
    let slot = state.join("bin").join(&digest[..16]);
    let executable = slot.join(EXECUTABLE);
    let ready = std::fs::read_to_string(slot.join(".verified")).is_ok_and(|text| text.trim() == digest)
        && sha256_file(&executable).is_ok_and(|copy| copy == digest);
    if !ready {
        let temporary = state.join("bin").join(format!(".staging-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temporary);
        std::fs::create_dir_all(&temporary).map_err(|error| format!("{error}"))?;
        let copy = temporary.join(EXECUTABLE);
        std::fs::copy(&source, &copy).map_err(|error| format!("cannot stage {EXECUTABLE}: {error}"))?;
        if sha256_file(&copy)? != digest {
            let _ = std::fs::remove_dir_all(&temporary);
            return Err("the staged copy differs from the shipped binary".into());
        }
        std::fs::write(temporary.join(".verified"), &digest).map_err(|error| format!("{error}"))?;
        let _ = std::fs::remove_dir_all(&slot);
        std::fs::rename(&temporary, &slot).map_err(|error| format!("{error}"))?;
    }
    Ok(Staged { executable, digest })
}

fn session_of(pid: u32) -> Option<u32> {
    let mut session = 0_u32;
    // SAFETY: an out pointer.
    (unsafe { ProcessIdToSessionId(pid, &mut session) } != 0).then_some(session)
}

fn my_sid() -> Option<String> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: the pseudo handle of this process.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return None;
    }
    let token = OwnedHandle(token);
    let mut needed = 0_u32;
    // SAFETY: a size query.
    unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut needed) };
    let mut buffer = vec![0_u8; needed as usize];
    // SAFETY: the buffer is `needed` bytes.
    if unsafe { GetTokenInformation(token.0, TokenUser, buffer.as_mut_ptr().cast(), needed, &mut needed) } == 0 {
        return None;
    }
    // SAFETY: the buffer holds a TOKEN_USER.
    let sid = unsafe { (*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid };
    let mut text: *mut u16 = std::ptr::null_mut();
    // SAFETY: a valid SID; freed below.
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 || text.is_null() {
        return None;
    }
    // SAFETY: NUL-terminated.
    let length = (0..).take_while(|&index| unsafe { *text.add(index) } != 0).count();
    // SAFETY: `length` units.
    let value = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, length) });
    // SAFETY: allocated by ConvertSidToStringSidW.
    unsafe { LocalFree(text.cast()) };
    Some(value)
}

fn leaf(paths: &Paths) -> String {
    paths.runtime.file_name().map(|leaf| leaf.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Starts the host in the interactive session and waits until it serves.
pub(super) fn spawn_host(staged: &Staged, paths: &Paths, bootstrap: &Value, ready_timeout: Duration) -> Result<u32, String> {
    std::fs::create_dir_all(&paths.runtime).map_err(|error| format!("{error}"))?;
    let file = paths.runtime.join("bootstrap.json");
    let bytes = serde_json::to_vec(bootstrap).map_err(|error| format!("{error}"))?;
    super::write_private(&file, &bytes);
    let worker_state = paths.state.join("worker");
    // The host sets this event once it serves (Global: a daemon in Session 0 and a host in Session 1+ share it).
    let event_name = wide(OsStr::new(&format!("Global\\cmux-remote-{}-ready", leaf(paths))));
    // Only this user may set it (an elevated SSH daemon's default DACL may name Administrators,
    // which the host's least-privilege token is not).
    let sid = my_sid().ok_or("cannot read this user's SID")?;
    let security = UserOnlySecurity::new(&sid)?;
    // SAFETY: a named manual-reset event with that DACL, closed by the wrapper.
    let ready = OwnedHandle(unsafe { CreateEventW(&security.attributes, 1, 0, event_name.as_ptr()) });
    if ready.0.is_null() {
        return Err(format!("cannot create the ready event: {}", std::io::Error::last_os_error()));
    }
    let interactive = session_of(std::process::id()).is_some_and(|session| session != 0);
    if interactive {
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(paths.runtime.join("host.log"))
            .map_err(|error| format!("host.log: {error}"))?;
        let mut child = Command::new(&staged.executable)
            .args(["host", "--layout-dir"])
            .arg(&paths.runtime)
            .arg("--state-dir")
            .arg(&worker_state)
            .args(["--scope", &paths.scope, "--bootstrap-file"])
            .arg(&file)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(log))
            .spawn()
            .map_err(|error| format!("cmux Remote did not start: {error}"))?;
        let pid = child.id();
        let stdout = child.stdout.take();
        let _ = std::thread::Builder::new().name("remote-host-reap".into()).spawn(move || {
            if let Some(stdout) = stdout {
                let mut line = String::new();
                let _ = BufReader::new(stdout).read_line(&mut line);
            }
            let _ = child.wait();
        });
        wait_ready(&ready, ready_timeout, paths)?;
        return Ok(pid);
    }
    // Outside the interactive session (SSH, a service): an interactive logon task of this user.
    let task_name = format!("cmux Remote {}", leaf(paths));
    let xml = task_xml(&sid, &staged.executable, &paths.runtime, &worker_state, &paths.scope, &file);
    let xml_path = paths.runtime.join("task.xml");
    let mut encoded: Vec<u8> = vec![0xFF, 0xFE];
    encoded.extend(xml.encode_utf16().flat_map(u16::to_le_bytes));
    std::fs::write(&xml_path, encoded).map_err(|error| format!("{error}"))?;
    let run = |args: &[&OsStr]| -> Result<(), String> {
        let output = Command::new("schtasks.exe")
            .args(args)
            .stdin(Stdio::null())
            .output()
            .map_err(|error| format!("schtasks: {error}"))?;
        output
            .status
            .success()
            .then_some(())
            .ok_or_else(|| format!("schtasks: {}", String::from_utf8_lossy(&output.stderr).trim()))
    };
    run(&[OsStr::new("/Create"), OsStr::new("/F"), OsStr::new("/TN"), OsStr::new(&task_name), OsStr::new("/XML"), xml_path.as_os_str()])?;
    run(&[OsStr::new("/Run"), OsStr::new("/TN"), OsStr::new(&task_name)])
        .map_err(|error| format!("{error} (is this user signed in at the console or over RDP? `query session`)"))?;
    wait_ready(&ready, ready_timeout, paths)?;
    // The host's pid: the server end of its pipe (this probe connection sends nothing and is dropped).
    let probe = PipeStream::connect(&paths.supervisor_socket()).map_err(|error| format!("{error}"))?;
    peer_pid(&probe).ok_or_else(|| "cannot read the host's pid".into())
}

/// The owner-only descriptor acpmux `owner_only` writes: owned by `sid`,
/// a protected DACL granting only `sid` full access, inherited by what is
/// made in a folder (`OICI`).
fn owner_only_descriptor(sid: &str, folder: bool) -> std::io::Result<UserOnlySecurity> {
    let flags = if folder { "OICI" } else { "" };
    UserOnlySecurity::from_sddl(&format!("O:{sid}D:P(A;{flags};FA;;;{sid})")).map_err(std::io::Error::other)
}

/// Creates `path` (which must not exist) for writing with an owner-only DACL,
/// never through a reparse point (`O_EXCL | O_NOFOLLOW`, mode 0600 on Unix).
pub(super) fn create_owner_only(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::windows::io::FromRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{CREATE_NEW, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OPEN_REPARSE_POINT};
    let sid = my_sid().ok_or_else(|| std::io::Error::other("cannot read this user's SID"))?;
    let security = owner_only_descriptor(&sid, false)?;
    let name = wide(path.as_os_str());
    // SAFETY: a NUL-terminated name and attributes that outlive the call; the handle is owned below.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            GENERIC_WRITE,
            0,
            &security.attributes,
            CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: a handle CreateFileW returned; the File owns it.
    Ok(unsafe { std::fs::File::from_raw_handle(handle as _) })
}

/// Makes `dir`: missing parents by inheritance, `dir` itself owner-only when
/// this creates it; an existing folder is kept (the files in it carry their
/// own owner-only DACL).
pub(super) fn make_owner_only_dir(dir: &Path) -> std::io::Result<()> {
    use windows_sys::Win32::Storage::FileSystem::CreateDirectoryW;
    if let Some(parent) = dir.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let sid = my_sid().ok_or_else(|| std::io::Error::other("cannot read this user's SID"))?;
    let security = owner_only_descriptor(&sid, true)?;
    let name = wide(dir.as_os_str());
    // SAFETY: a NUL-terminated name and attributes that outlive the call.
    if unsafe { CreateDirectoryW(name.as_ptr(), &security.attributes) } == 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::AlreadyExists {
            return Err(error);
        }
    }
    let meta = std::fs::symlink_metadata(dir)?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err(std::io::Error::other(format!("{} is not a directory", dir.display())));
    }
    Ok(())
}

/// A user-only DACL for the ready event.
struct UserOnlySecurity {
    descriptor: *mut core::ffi::c_void,
    attributes: windows_sys::Win32::Security::SECURITY_ATTRIBUTES,
}

impl UserOnlySecurity {
    fn new(sid: &str) -> Result<Self, String> {
        Self::from_sddl(&format!("D:P(A;;GA;;;{sid})"))
    }

    fn from_sddl(sddl: &str) -> Result<Self, String> {
        use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
        let sddl = wide(OsStr::new(sddl));
        let mut descriptor: *mut core::ffi::c_void = std::ptr::null_mut();
        // SAFETY: a NUL-terminated SDDL; freed in Drop.
        if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), 1, &mut descriptor, std::ptr::null_mut()) } == 0 {
            return Err(format!("cannot build a DACL: {}", std::io::Error::last_os_error()));
        }
        let attributes = windows_sys::Win32::Security::SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<windows_sys::Win32::Security::SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        Ok(Self { descriptor, attributes })
    }
}

impl Drop for UserOnlySecurity {
    fn drop(&mut self) {
        // SAFETY: allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
        unsafe { LocalFree(self.descriptor) };
    }
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

/// The task's XML with every value escaped; the template's comment is dropped first.
pub(super) fn task_xml(sid: &str, exe: &Path, layout: &Path, state: &Path, scope: &str, bootstrap: &Path) -> String {
    let template = match (TASK_TEMPLATE.find("<!--"), TASK_TEMPLATE.find("-->")) {
        (Some(start), Some(end)) if start < end => format!("{}{}", &TASK_TEMPLATE[..start], &TASK_TEMPLATE[end + 3..]),
        _ => TASK_TEMPLATE.to_owned(),
    };
    let value = |path: &Path| xml_escape(&path.display().to_string());
    template
        .replace("USER_SID", &xml_escape(sid))
        .replace("HOST_EXE", &value(exe))
        .replace("LAYOUT_DIR", &value(layout))
        .replace("STATE_DIR", &value(state))
        .replace("BOOTSTRAP", &value(bootstrap))
        .replace("SCOPE", &xml_escape(scope))
}

fn wait_ready(event: &OwnedHandle, timeout: Duration, paths: &Paths) -> Result<(), String> {
    let millis = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX - 1);
    // SAFETY: a valid event handle.
    match unsafe { WaitForSingleObject(event.0, millis) } {
        WAIT_OBJECT_0 => Ok(()),
        _ => Err(format!("cmux Remote did not report ready (see {})", paths.runtime.join("host.log").display())),
    }
}

/// A live process's creation time (100 ns since 1601) and 0.
pub(super) fn process_start(pid: u32) -> Option<(u64, u64)> {
    // SAFETY: plain call; a null result is handled.
    let process = OwnedHandle(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) });
    if process.0.is_null() {
        return None;
    }
    let mut created = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut exited, mut kernel, mut user) = (created, created, created);
    // SAFETY: four FILETIME out pointers.
    let ok = unsafe { GetProcessTimes(process.0, &mut created, &mut exited, &mut kernel, &mut user) } != 0;
    let gone = exited.dwLowDateTime != 0 || exited.dwHighDateTime != 0;
    (ok && !gone).then(|| ((u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime), 0))
}

/// The process serving the pipe.
pub(super) fn peer_pid(stream: &PipeStream) -> Option<u32> {
    let mut pid = 0_u32;
    // SAFETY: a connected client handle.
    (unsafe { GetNamedPipeServerProcessId(stream.handle.0, &mut pid) } != 0).then_some(pid)
}
