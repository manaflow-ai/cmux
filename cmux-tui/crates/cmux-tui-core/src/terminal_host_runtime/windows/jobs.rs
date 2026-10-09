//! The named, owner-only Job Object of one terminal (design: "Job Objects").
//! The host that runs a terminal's child creates it and keeps it open for
//! its life; the name goes in the host record (`job_name`). A daemon that
//! did not create it (one restarted after the host started) opens it by
//! name, checks that its owner is our token user (a job another user or a
//! squatter named first is refused), and then reads a process's cwd, name
//! or usage only when `IsProcessInJob` says the process is in it.

use std::ffi::c_void;
use std::io;
use std::ptr;

use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo,
    SE_KERNEL_OBJECT, SE_OBJECT_TYPE,
};
use windows_sys::Win32::Security::{
    EqualSid, GetTokenInformation, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
    SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob, JOB_OBJECT_QUERY, OpenJobObjectW,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

const SDDL_REVISION_1: u32 = 1;

/// `Local\cmux-tui-job-<user>-<session token>-<terminal hex>-<incarnation hex>`:
/// session-local, one per terminal incarnation. None for a component with
/// characters outside `[0-9A-Za-z_]` (no separators: a name never reaches
/// another namespace).
pub fn job_name(
    user: &str,
    session_token: &str,
    terminal_hex: &str,
    incarnation_hex: &str,
) -> Option<String> {
    let ok = |s: &str| {
        !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
    };
    (ok(user) && ok(session_token) && ok(terminal_hex) && ok(incarnation_hex)).then(|| {
        format!("Local\\cmux-tui-job-{user}-{session_token}-{terminal_hex}-{incarnation_hex}")
    })
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// An open job handle, closed on drop.
#[derive(Debug)]
pub struct NamedJob {
    handle: HANDLE,
    name: String,
}

// SAFETY: a kernel handle; the calls made on it are thread-safe.
unsafe impl Send for NamedJob {}
unsafe impl Sync for NamedJob {}

impl Drop for NamedJob {
    fn drop(&mut self) {
        // SAFETY: the handle this value owns.
        unsafe { CloseHandle(self.handle) };
    }
}

impl NamedJob {
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Creates the job with a protected DACL that gives only our token user
    /// any access, and that user as owner. Refuses a name that already
    /// exists (someone else's object, or a second host for one incarnation).
    pub fn create(name: &str) -> io::Result<Self> {
        let sid = current_user_sid_string()?;
        let sddl = wide(&format!("O:{sid}D:P(A;;GA;;;{sid})"));
        let mut descriptor: PSECURITY_DESCRIPTOR = ptr::null_mut();
        // SAFETY: a NUL-terminated SDDL string; the descriptor is freed below.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        let wname = wide(name);
        // SAFETY: valid attributes and name for the call.
        let handle = unsafe { CreateJobObjectW(&attributes, wname.as_ptr()) };
        let created_error = unsafe { GetLastError() };
        // SAFETY: the descriptor the conversion allocated.
        unsafe { LocalFree(descriptor as _) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let job = Self { handle, name: name.to_owned() };
        if created_error == ERROR_ALREADY_EXISTS {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("job {name} already exists"),
            ));
        }
        Ok(job)
    }

    /// Opens an existing job for queries and checks that its owner is our
    /// token user.
    pub fn open_checked(name: &str) -> io::Result<Self> {
        let wname = wide(name);
        // SAFETY: a NUL-terminated name.
        let handle = unsafe { OpenJobObjectW(JOB_OBJECT_QUERY, 0, wname.as_ptr()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let job = Self { handle, name: name.to_owned() };
        if !owned_by_current_user(job.handle, SE_KERNEL_OBJECT)? {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("job {name} has another owner"),
            ));
        }
        Ok(job)
    }

    /// Puts `process` (a handle with PROCESS_SET_QUOTA | PROCESS_TERMINATE)
    /// in the job. Start the process suspended and resume it after this, so
    /// nothing it starts runs outside the job.
    pub fn assign(&self, process: HANDLE) -> io::Result<()> {
        // SAFETY: valid job and process handles.
        if unsafe { AssignProcessToJobObject(self.handle, process) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// Whether `process` (PROCESS_QUERY_LIMITED_INFORMATION) runs in it.
    pub fn contains(&self, process: HANDLE) -> bool {
        let mut result = 0;
        // SAFETY: valid handles and out pointer.
        let ok = unsafe { IsProcessInJob(process, self.handle, &mut result) };
        ok != 0 && result != 0
    }
}

/// Our token user's SID as a string (S-1-5-21-...).
fn current_user_sid_string() -> io::Result<String> {
    with_current_user_sid(|sid| {
        let mut text: *mut u16 = ptr::null_mut();
        // SAFETY: a valid SID; the string is freed below.
        if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a NUL-terminated string the call allocated.
        let len = (0..).take_while(|&i| unsafe { *text.add(i) } != 0).count();
        let value = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, len) });
        unsafe { LocalFree(text as _) };
        Ok(value)
    })
}

fn with_current_user_sid<R>(f: impl FnOnce(*mut c_void) -> io::Result<R>) -> io::Result<R> {
    let mut token: HANDLE = ptr::null_mut();
    // SAFETY: the current process pseudo handle; the token is closed below.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut size = 0u32;
    // SAFETY: size query.
    unsafe { GetTokenInformation(token, TokenUser, ptr::null_mut(), 0, &mut size) };
    let mut buffer = vec![0u64; (size as usize).div_ceil(8).max(1)];
    // SAFETY: a buffer of at least `size` bytes, 8-aligned.
    let ok = unsafe {
        GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), size, &mut size)
    };
    unsafe { CloseHandle(token) };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: TokenUser fills a TOKEN_USER at the start of the buffer.
    let user = unsafe { &*(buffer.as_ptr() as *const TOKEN_USER) };
    f(user.User.Sid)
}

/// Whether the object behind `handle` is owned by our token user.
pub fn owned_by_current_user(handle: HANDLE, kind: SE_OBJECT_TYPE) -> io::Result<bool> {
    let mut owner: *mut c_void = ptr::null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = ptr::null_mut();
    // SAFETY: valid handle and out pointers; the descriptor is freed below.
    let status = unsafe {
        GetSecurityInfo(
            handle,
            kind,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut descriptor,
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    // SAFETY: `owner` points into `descriptor`, alive until LocalFree.
    let same = with_current_user_sid(|ours| Ok(unsafe { EqualSid(owner, ours) } != 0));
    unsafe { LocalFree(descriptor as _) };
    same
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Security::Authorization::SE_FILE_OBJECT;

    fn unique(tag: &str) -> String {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        job_name(
            "test",
            tag,
            &format!("{:032x}", u128::from(nanos)),
            &format!("{:x}", std::process::id()),
        )
        .unwrap()
    }

    #[test]
    fn names_stay_in_the_local_namespace() {
        assert_eq!(
            job_name("u", "s1", "ab", "cd").as_deref(),
            Some("Local\\cmux-tui-job-u-s1-ab-cd")
        );
        assert!(job_name("u\\x", "s", "a", "b").is_none());
        assert!(job_name("u", "Global\\x", "a", "b").is_none());
        assert!(job_name("", "s", "a", "b").is_none());
    }

    #[test]
    fn a_restarted_daemon_opens_the_job_by_name_and_sees_the_child_in_it() {
        let name = unique("open");
        let job = NamedJob::create(&name).unwrap();
        let mut child = std::process::Command::new("cmd.exe")
            .args(["/c", "ping -n 30 127.0.0.1 >nul"])
            .spawn()
            .unwrap();
        job.assign(child.as_raw_handle() as HANDLE).unwrap();
        let opened = NamedJob::open_checked(&name).expect("our own job opens");
        assert!(opened.contains(child.as_raw_handle() as HANDLE), "the child is in the job");
        // SAFETY: the current process pseudo handle.
        assert!(!opened.contains(unsafe { GetCurrentProcess() }), "the test runner is not");
        child.kill().unwrap();
        child.wait().unwrap();
    }

    #[test]
    fn a_name_that_already_exists_is_refused() {
        let name = unique("twice");
        let _first = NamedJob::create(&name).unwrap();
        let second = NamedJob::create(&name).unwrap_err();
        assert_eq!(second.kind(), io::ErrorKind::AlreadyExists);
    }

    #[test]
    fn an_object_owned_by_someone_else_is_refused() {
        // kernel32.dll is owned by TrustedInstaller, never by the test user.
        let system = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        let file = std::fs::File::open(format!(r"{system}\System32\kernel32.dll")).unwrap();
        assert!(!owned_by_current_user(file.as_raw_handle() as HANDLE, SE_FILE_OBJECT).unwrap());
    }
}
