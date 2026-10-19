//! The Windows parts of the client.

use std::ffi::OsStr;
use std::io;
use std::os::windows::ffi::OsStrExt;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0};
use windows_sys::Win32::System::Console::{
    CONSOLE_MODE, CONSOLE_SCREEN_BUFFER_INFO, DISABLE_NEWLINE_AUTO_RETURN, ENABLE_ECHO_INPUT,
    ENABLE_LINE_INPUT, ENABLE_PROCESSED_INPUT, ENABLE_VIRTUAL_TERMINAL_INPUT,
    ENABLE_VIRTUAL_TERMINAL_PROCESSING, GetConsoleMode, GetConsoleScreenBufferInfo, GetStdHandle,
    STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, SetConsoleMode,
};
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, CREATE_UNICODE_ENVIRONMENT, CreateEventW,
    CreateProcessW, DETACHED_PROCESS, GetCurrentProcessId, PROCESS_INFORMATION,
    STARTF_USESTDHANDLES, STARTUPINFOW, WaitForMultipleObjects,
};

/// A program that waits for input forever, and one whose console echoes
/// what is typed (cmd's line editor), for `mux2 bench`.
pub(super) const IDLE_ARGV: &[&[u8]] = &[b"cmd.exe", b"/d", b"/k"];
pub(super) const ECHO_ARGV: &[&[u8]] = &[b"cmd.exe", b"/d", b"/q", b"/k"];
/// The Enter key on a Windows console is CR.
pub(super) const ENTER: &[u8] = b"\r";

pub(super) fn cwd_bytes() -> Vec<u8> {
    std::env::current_dir()
        .ok()
        .and_then(|p| p.to_str().map(|s| s.as_bytes().to_vec()))
        .unwrap_or_default()
}

/// Starts `daemon` detached from this console (and, when the job allows it,
/// out of this session's job, so it outlives an ssh session), then waits
/// until it listens: it sets the named event in MUX2_READY_EVENT, or exits.
///
/// CreateProcessW is called directly with handle inheritance off. std's
/// Command inherits every inheritable handle of this process, among them a
/// pipe this client's caller reads its output from: the server would keep
/// that pipe open for its whole life, and the caller would never see EOF.
pub(super) fn spawn_server(daemon: &std::path::Path) -> io::Result<()> {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    // SAFETY: GetCurrentProcessId has no preconditions.
    let name = format!(r"Local\mux2-ready-{}-{nonce:x}", unsafe { GetCurrentProcessId() });
    let wname = wide(OsStr::new(&name));
    // SAFETY: a new named manual-reset event, initially unset.
    let event = unsafe { CreateEventW(std::ptr::null(), 1, 0, wname.as_ptr()) };
    if event.is_null() {
        return Err(io::Error::last_os_error());
    }
    // The environment block: ours, plus MUX2_READY_EVENT.
    let mut env: Vec<u16> = Vec::new();
    for (k, v) in std::env::vars_os() {
        if k.eq_ignore_ascii_case("MUX2_READY_EVENT") {
            continue;
        }
        env.extend(k.encode_wide());
        env.push(b'=' as u16);
        env.extend(v.encode_wide());
        env.push(0);
    }
    env.extend(OsStr::new("MUX2_READY_EVENT=").encode_wide());
    env.extend(OsStr::new(&name).encode_wide());
    env.extend([0, 0]);
    let mut line: Vec<u16> = vec![b'"' as u16];
    line.extend(daemon.as_os_str().encode_wide());
    line.extend([b'"' as u16, 0]);
    let app = wide(daemon.as_os_str());
    let mut si = STARTUPINFOW { cb: size_of::<STARTUPINFOW>() as u32, ..Default::default() };
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = INVALID_HANDLE_VALUE;
    si.hStdOutput = INVALID_HANDLE_VALUE;
    si.hStdError = INVALID_HANDLE_VALUE;
    let base = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT;
    let mut pi = PROCESS_INFORMATION::default();
    let mut spawn = |flags| {
        // SAFETY: valid, NUL-terminated buffers; no handles are inherited.
        unsafe {
            CreateProcessW(
                app.as_ptr(),
                line.as_mut_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                flags,
                env.as_ptr().cast(),
                std::ptr::null(),
                &si,
                &mut pi,
            ) != 0
        }
    };
    if !spawn(base | CREATE_BREAKAWAY_FROM_JOB) && !spawn(base) {
        let e = io::Error::last_os_error();
        // SAFETY: closing our event.
        unsafe { CloseHandle(event) };
        return Err(io::Error::other(format!("cannot start {}: {e}", daemon.display())));
    }
    let both = [event, pi.hProcess];
    // SAFETY: waiting on our event and the child's process handle.
    let which = unsafe { WaitForMultipleObjects(2, both.as_ptr(), 0, u32::MAX) };
    // SAFETY: closing the handles we own.
    unsafe {
        CloseHandle(event);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
    if which != WAIT_OBJECT_0 {
        return Err(io::Error::other("server failed to start"));
    }
    Ok(())
}

fn wide(s: &OsStr) -> Vec<u16> {
    s.encode_wide().chain(Some(0)).collect()
}

pub(super) fn term_size() -> (u16, u16) {
    let mut info = CONSOLE_SCREEN_BUFFER_INFO::default();
    // SAFETY: querying our console output, if there is one.
    let ok = unsafe { GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &mut info) } != 0;
    let w = info.srWindow;
    if ok && w.Right > w.Left {
        ((w.Right - w.Left + 1) as u16, (w.Bottom - w.Top + 1) as u16)
    } else {
        (80, 24)
    }
}

/// VT input without line editing or echo, VT output, restored on drop.
pub(super) struct RawMode {
    input: (HANDLE, CONSOLE_MODE),
    output: (HANDLE, CONSOLE_MODE),
}

impl RawMode {
    pub(super) fn enter() -> Option<Self> {
        // SAFETY: reading and setting our own console modes.
        unsafe {
            let (i, o) = (GetStdHandle(STD_INPUT_HANDLE), GetStdHandle(STD_OUTPUT_HANDLE));
            if i == INVALID_HANDLE_VALUE || o == INVALID_HANDLE_VALUE {
                return None;
            }
            let (mut im, mut om) = (0, 0);
            if GetConsoleMode(i, &mut im) == 0 || GetConsoleMode(o, &mut om) == 0 {
                return None;
            }
            let raw_in = (im & !(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT))
                | ENABLE_VIRTUAL_TERMINAL_INPUT;
            SetConsoleMode(i, raw_in);
            SetConsoleMode(
                o,
                om | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN,
            );
            Some(RawMode { input: (i, im), output: (o, om) })
        }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        // SAFETY: restoring the saved modes.
        unsafe {
            SetConsoleMode(self.input.0, self.input.1);
            SetConsoleMode(self.output.0, self.output.1);
        }
    }
}

/// A Windows console reports size changes only as input records, which a
/// VT-mode byte reader does not see: the size is sent once, at attach.
pub(super) fn follow_resize(_resized: impl FnMut() -> bool + Send + 'static) {}
