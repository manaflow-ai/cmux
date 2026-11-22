//! Windows process data for terminals: the process tree, usage, the
//! foreground process, its name and its working directory
//! (plans/cmux-next/windows-daemon.md, section 2).
//!
//! Access rule: a process is read (usage, name, cwd from its PEB) only when
//! this daemon started it (it runs in a terminal's Job Object,
//! `cmux_pty::windows_jobs`), as the same user and in the same session; every
//! other process is refused. All checks and reads use one handle, opened
//! once, so a reused pid cannot slip in between.
//!
//! Foreground: ConPTY has no foreground process group. Heuristic: the newest
//! live descendant of the terminal's shell (by creation time), skipping the
//! console hosts; the shell itself when it has none.
//!
//! 32-bit (WOW64) processes have no cwd in this version.

use std::collections::HashMap;
use std::ffi::c_void;
use std::ptr::null_mut;

use windows_sys::Wdk::System::Threading::{NtQueryInformationProcess, ProcessBasicInformation};
use windows_sys::Win32::Foundation::{CloseHandle, FILETIME, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TokenSessionId};
use windows_sys::Win32::System::Diagnostics::Debug::ReadProcessMemory;
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::ProcessStatus::{
    K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX,
    PROCESS_MEMORY_COUNTERS_EX2,
};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, GetProcessTimes, IsWow64Process, OpenProcess, OpenProcessToken,
    PROCESS_BASIC_INFORMATION, PROCESS_NAME_WIN32, PROCESS_QUERY_INFORMATION,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_VM_READ, QueryFullProcessImageNameW,
};

/// Why a process is not read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Not in a terminal job of this daemon.
    NotStartedByUs,
    OtherUser,
    OtherSession,
}

/// The access rule over what the OS reports (pure, so tested with values a
/// test cannot make: another user, another session).
pub fn may_read(
    in_our_job: bool,
    user_sid: &str,
    session: u32,
    our_user_sid: &str,
    our_session: u32,
) -> Result<(), Refusal> {
    if !in_our_job {
        return Err(Refusal::NotStartedByUs);
    }
    if cmux::local_socket::owner_allowed(user_sid, our_user_sid).is_err() {
        return Err(Refusal::OtherUser);
    }
    if session != our_session {
        return Err(Refusal::OtherSession);
    }
    Ok(())
}

pub struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: an open handle this value owns.
        unsafe { CloseHandle(self.0) };
    }
}

fn open(pid: u32, access: u32) -> Option<Handle> {
    // SAFETY: plain call; null is failure.
    let handle = unsafe { OpenProcess(access, 0, pid) };
    (!handle.is_null()).then_some(Handle(handle))
}

fn token_session(process: HANDLE) -> Option<u32> {
    let mut token: HANDLE = null_mut();
    // SAFETY: a valid process handle.
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return None;
    }
    let token = Handle(token);
    let mut session = 0u32;
    let mut size = 0u32;
    // SAFETY: a u32 out-buffer of the size passed.
    let ok = unsafe {
        GetTokenInformation(token.0, TokenSessionId, (&raw mut session).cast(), 4, &mut size)
    };
    (ok != 0).then_some(session)
}

/// This daemon's user and session.
fn ours() -> Option<(String, u32)> {
    let me = cmux::local_socket::win::current_identity().ok()?;
    // SAFETY: the current process pseudo-handle.
    let session = token_session(unsafe { GetCurrentProcess() })?;
    Some((me.user_sid, session))
}

/// Process `pid`, opened once with `access` (plus query rights), when the
/// access rule admits it; None otherwise.
pub fn open_started_by_us(pid: u32, access: u32) -> Option<Handle> {
    let handle = open(pid, access | PROCESS_QUERY_LIMITED_INFORMATION)?;
    let (our_user, our_session) = ours()?;
    let in_job = cmux_pty::windows_jobs::contains(handle.0.cast::<c_void>());
    let identity = cmux::local_socket::win::handle_identity(handle.0.cast::<c_void>()).ok()?;
    let session = token_session(handle.0)?;
    may_read(in_job, &identity.user_sid, session, &our_user, our_session).ok()?;
    Some(handle)
}

fn filetime(t: FILETIME) -> u64 {
    (u64::from(t.dwHighDateTime) << 32) | u64::from(t.dwLowDateTime)
}

/// Creation time (100 ns since 1601) and kernel + user CPU time in ns.
fn times(process: HANDLE) -> Option<(u64, u64)> {
    let zero = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    let (mut created, mut exited, mut kernel, mut user) = (zero, zero, zero, zero);
    // SAFETY: a valid handle; four FILETIME out-pointers.
    if unsafe { GetProcessTimes(process, &mut created, &mut exited, &mut kernel, &mut user) } == 0 {
        return None;
    }
    Some((filetime(created), (filetime(kernel) + filetime(user)).saturating_mul(100)))
}

/// One process of a snapshot.
#[derive(Clone, Debug)]
pub struct Entry {
    pub parent: u32,
    pub exe: String,
}

/// Every process now: pid -> (parent pid, executable file name).
pub fn snapshot() -> HashMap<u32, Entry> {
    let mut out = HashMap::new();
    // SAFETY: the snapshot handle is checked and closed by `Handle`; the
    // entry's size is set as the API requires.
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap == INVALID_HANDLE_VALUE || snap.is_null() {
            return out;
        }
        let _snap = Handle(snap);
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
        let mut more = Process32FirstW(snap, &mut entry) != 0;
        while more {
            let length =
                entry.szExeFile.iter().position(|c| *c == 0).unwrap_or(entry.szExeFile.len());
            let exe = String::from_utf16_lossy(&entry.szExeFile[..length]);
            out.insert(entry.th32ProcessID, Entry { parent: entry.th32ParentProcessID, exe });
            more = Process32NextW(snap, &mut entry) != 0;
        }
    }
    out
}

/// Creation time of `pid` (None: gone or not openable).
pub fn created(pid: u32) -> Option<u64> {
    let handle = open(pid, PROCESS_QUERY_LIMITED_INFORMATION)?;
    times(handle.0).map(|(created, _)| created)
}

/// Whether `child`'s recorded parent really is `parent`: a parent pid can be
/// reused, so the child must have been created after the parent.
pub fn born_after(parent_created: Option<u64>, child_created: Option<u64>) -> bool {
    matches!((parent_created, child_created), (Some(p), Some(c)) if c >= p)
}

/// CPU ns and private working set (else private bytes) of `pid`, when the
/// access rule admits it.
pub fn usage(pid: u32) -> Option<(u64, u64)> {
    let handle = open_started_by_us(pid, 0)?;
    let (_, cpu) = times(handle.0)?;
    // SAFETY: out structs sized as the API takes them.
    unsafe {
        let mut ex2: PROCESS_MEMORY_COUNTERS_EX2 = std::mem::zeroed();
        let size = size_of::<PROCESS_MEMORY_COUNTERS_EX2>() as u32;
        if K32GetProcessMemoryInfo(handle.0, (&raw mut ex2).cast::<PROCESS_MEMORY_COUNTERS>(), size)
            != 0
            && ex2.PrivateWorkingSetSize > 0
        {
            return Some((cpu, ex2.PrivateWorkingSetSize as u64));
        }
        let mut ex: PROCESS_MEMORY_COUNTERS_EX = std::mem::zeroed();
        let size = size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32;
        (K32GetProcessMemoryInfo(handle.0, (&raw mut ex).cast::<PROCESS_MEMORY_COUNTERS>(), size)
            != 0)
            .then_some((cpu, ex.PrivateUsage as u64))
    }
}

/// The full image path of `pid`, when the access rule admits it.
pub fn image_path(pid: u32) -> Option<String> {
    let handle = open_started_by_us(pid, 0)?;
    image_path_of(handle.0)
}

fn image_path_of(process: HANDLE) -> Option<String> {
    let mut buffer = vec![0u16; 32_768];
    let mut length = buffer.len() as u32;
    // SAFETY: the buffer holds `length` u16s.
    let ok = unsafe {
        QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut length)
    };
    (ok != 0).then(|| String::from_utf16_lossy(&buffer[..length as usize]))
}

/// Whether `pid` runs this daemon's own executable (a terminal host). Only a
/// path comparison, no memory read: no access rule.
pub fn runs_own_executable(pid: u32) -> bool {
    let Some(handle) = open(pid, PROCESS_QUERY_LIMITED_INFORMATION) else { return false };
    let (Some(other), Ok(own)) = (image_path_of(handle.0), std::env::current_exe()) else {
        return false;
    };
    other.eq_ignore_ascii_case(&own.to_string_lossy())
}

fn read<T: Copy>(process: HANDLE, at: usize) -> Option<T> {
    let mut value = std::mem::MaybeUninit::<T>::uninit();
    let mut read = 0usize;
    // SAFETY: reads size_of::<T>() bytes into `value`; checked complete.
    let ok = unsafe {
        ReadProcessMemory(
            process,
            at as *const c_void,
            value.as_mut_ptr().cast(),
            size_of::<T>(),
            &mut read,
        )
    };
    // SAFETY: fully written when the read succeeded in full.
    (ok != 0 && read == size_of::<T>()).then(|| unsafe { value.assume_init() })
}

/// The working directory of `pid` from its PEB
/// (`RTL_USER_PROCESS_PARAMETERS.CurrentDirectory.DosPath`, 64-bit layout),
/// when the access rule admits it. None for 32-bit processes (v1).
#[cfg(target_pointer_width = "64")]
pub fn cwd(pid: u32) -> Option<String> {
    let handle = open_started_by_us(pid, PROCESS_QUERY_INFORMATION | PROCESS_VM_READ)?;
    let mut wow64 = 0;
    // SAFETY: a valid handle.
    if unsafe { IsWow64Process(handle.0, &mut wow64) } == 0 || wow64 != 0 {
        return None;
    }
    // SAFETY: the info struct is the size passed.
    let peb = unsafe {
        let mut info: PROCESS_BASIC_INFORMATION = std::mem::zeroed();
        let mut returned = 0u32;
        let size = size_of::<PROCESS_BASIC_INFORMATION>() as u32;
        if NtQueryInformationProcess(
            handle.0,
            ProcessBasicInformation,
            (&raw mut info).cast(),
            size,
            &mut returned,
        ) < 0
        {
            return None;
        }
        info.PebBaseAddress as usize
    };
    let params: usize = read(handle.0, peb.checked_add(0x20)?)?;
    let length: u16 = read(handle.0, params.checked_add(0x38)?)?;
    let buffer: usize = read(handle.0, params.checked_add(0x40)?)?;
    if length == 0 || buffer == 0 || length > 4096 {
        return None;
    }
    let mut wide = vec![0u16; usize::from(length) / 2];
    let mut read_bytes = 0usize;
    // SAFETY: reads `length` bytes into `wide` (length / 2 u16s).
    let ok = unsafe {
        ReadProcessMemory(
            handle.0,
            buffer as *const c_void,
            wide.as_mut_ptr().cast(),
            wide.len() * 2,
            &mut read_bytes,
        )
    };
    if ok == 0 || read_bytes != wide.len() * 2 {
        return None;
    }
    Some(trim_dir(String::from_utf16_lossy(&wide)))
}

#[cfg(not(target_pointer_width = "64"))]
pub fn cwd(_pid: u32) -> Option<String> {
    None
}

/// "C:\dir\" is "C:\dir"; a drive root keeps its separator.
pub fn trim_dir(s: String) -> String {
    if s.len() > 3 && s.ends_with('\\') { s[..s.len() - 1].to_owned() } else { s }
}

/// Console hosts are not the program the user runs.
pub fn is_console_host(exe: &str) -> bool {
    exe.eq_ignore_ascii_case("conhost.exe") || exe.eq_ignore_ascii_case("OpenConsole.exe")
}

/// The foreground heuristic over a snapshot: the newest descendant of
/// `shell` (by creation time, children born after their parent), console
/// hosts skipped; the shell itself when it has none.
pub fn newest_descendant(
    shell: u32,
    processes: &HashMap<u32, Entry>,
    created: impl Fn(u32) -> Option<u64>,
) -> Option<u32> {
    let shell_created = created(shell)?;
    let mut best = (shell_created, shell);
    let mut queue = vec![(shell, shell_created)];
    let mut seen = std::collections::HashSet::from([shell]);
    while let Some((pid, pid_created)) = queue.pop() {
        for (&child, entry) in processes {
            if entry.parent != pid || child == pid || !seen.insert(child) {
                continue;
            }
            let Some(child_created) = created(child) else { continue };
            if child_created < pid_created {
                continue;
            }
            queue.push((child, child_created));
            if !is_console_host(&entry.exe) && child_created >= best.0 {
                best = (child_created, child);
            }
        }
    }
    Some(best.1)
}

/// The terminal's foreground process (the heuristic above), when the shell
/// is one this daemon started.
pub fn foreground(shell: u32) -> Option<u32> {
    open_started_by_us(shell, 0)?;
    newest_descendant(shell, &snapshot(), created)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ME: &str = "S-1-5-21-1-2-3-1002";

    #[test]
    fn only_our_jobs_our_user_and_our_session_are_read() {
        assert_eq!(may_read(true, ME, 1, ME, 1), Ok(()));
        assert_eq!(may_read(false, ME, 1, ME, 1), Err(Refusal::NotStartedByUs));
        assert_eq!(may_read(true, "S-1-5-18", 1, ME, 1), Err(Refusal::OtherUser));
        assert_eq!(may_read(true, "S-1-5-21-1-2-3-1003", 1, ME, 1), Err(Refusal::OtherUser));
        assert_eq!(may_read(true, ME, 2, ME, 1), Err(Refusal::OtherSession));
    }

    fn entry(parent: u32, exe: &str) -> Entry {
        Entry { parent, exe: exe.to_string() }
    }

    #[test]
    fn foreground_is_the_newest_descendant_without_console_hosts() {
        // shell 10 -> conhost 11 (newest), node 12 -> python 13; 14 is an
        // unrelated process whose recorded parent pid 12 was reused (older).
        let processes = HashMap::from([
            (10, entry(1, "pwsh.exe")),
            (11, entry(10, "conhost.exe")),
            (12, entry(10, "node.exe")),
            (13, entry(12, "python.exe")),
            (14, entry(12, "old.exe")),
        ]);
        let times = HashMap::from([(10, 100), (11, 400), (12, 200), (13, 300), (14, 50)]);
        let created = |pid| times.get(&pid).copied();
        assert_eq!(newest_descendant(10, &processes, created), Some(13));
        // A shell with no children is its own foreground.
        let alone = HashMap::from([(20, entry(1, "cmd.exe"))]);
        assert_eq!(newest_descendant(20, &alone, |_| Some(5)), Some(20));
        // A gone shell has none.
        assert_eq!(newest_descendant(30, &alone, |_| None), None);
    }

    #[test]
    fn reused_parent_pids_are_not_children() {
        assert!(born_after(Some(10), Some(20)));
        assert!(!born_after(Some(20), Some(10)));
        assert!(!born_after(None, Some(10)));
    }

    #[test]
    fn trailing_separators_are_dropped_except_at_a_drive_root() {
        assert_eq!(trim_dir("C:\\Users\\me\\".into()), "C:\\Users\\me");
        assert_eq!(trim_dir("C:\\".into()), "C:\\");
    }

    /// A terminal child this daemon started (in its job, our user and
    /// session) is read: its cwd, usage and name; it is the foreground of
    /// itself; a process outside the job is not.
    #[test]
    fn a_terminal_child_is_read() {
        let dir = std::env::temp_dir().join(format!("cwp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pty = cmux_pty::open(cmux_pty::PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();
        let mut command = cmux_pty::PtyCommand::new("cmd.exe");
        command.args(["/d", "/c", "ping -n 30 127.0.0.1 > NUL"]);
        command.cwd(&dir);
        let spawned = pty.spawn(command).unwrap();
        let mut child = spawned.child;
        let pid = child.process_id().unwrap();
        let mut found = None;
        for _ in 0..50 {
            found = cwd(pid);
            if found.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        let expected = dir.canonicalize().unwrap();
        let got = found.expect("the cwd of a terminal child");
        assert!(
            std::path::Path::new(&got).canonicalize().unwrap() == expected,
            "{got} is {}",
            expected.display()
        );
        assert!(usage(pid).is_some_and(|(_, memory)| memory > 0));
        assert!(image_path(pid).is_some_and(|p| p.to_ascii_lowercase().ends_with("cmd.exe")));
        assert!(foreground(pid).is_some());
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The daemon's own process is in none of its terminal jobs: refused.
    #[test]
    fn a_process_outside_our_jobs_is_refused() {
        assert!(open_started_by_us(std::process::id(), 0).is_none());
        assert!(cwd(std::process::id()).is_none());
        assert!(usage(std::process::id()).is_none());
    }
}
