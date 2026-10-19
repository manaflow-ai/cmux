//! Terminals on Windows: a pseudoconsole (ConPTY) per terminal, its two
//! pipes opened overlapped on the server's side, and a job object per child
//! so the program and everything it starts die with the terminal (and with
//! the server: the job handle closes when the server exits).
//!
//! ConPTY runs a conhost per pseudoconsole. The server reads conhost's VT
//! output, not the program's bytes: conhost renders its own screen buffer
//! and sends what changed, unless passthrough mode is on and the program
//! writes VT itself. See GOAL.md (Windows) for what that means for exactness.

use std::ffi::OsStr;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};

use windows_sys::Win32::Foundation::{
    CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, OPEN_EXISTING,
    PIPE_ACCESS_INBOUND, PIPE_ACCESS_OUTBOUND,
};
use windows_sys::Win32::System::Console::{COORD, HPCON};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject,
};
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows_sys::Win32::System::Pipes::{
    CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::{
    CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessW, DeleteProcThreadAttributeList,
    EXTENDED_STARTUPINFO_PRESENT, GetCurrentProcessId, InitializeProcThreadAttributeList,
    LPPROC_THREAD_ATTRIBUTE_LIST, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, PROCESS_INFORMATION,
    RegisterWaitForSingleObject, ResumeThread, STARTF_USESTDHANDLES, STARTUPINFOEXW,
    TerminateProcess, UnregisterWaitEx, WT_EXECUTEONLYONCE,
};

/// conhost's resize does not reflow and repaint: the terminal does that.
const PSEUDOCONSOLE_RESIZE_QUIRK: u32 = 0x2;
/// conhost forwards VT a program writes instead of rendering it.
const PSEUDOCONSOLE_PASSTHROUGH_MODE: u32 = 0x8;

type CreateFn = unsafe extern "system" fn(COORD, HANDLE, HANDLE, u32, *mut HPCON) -> i32;
type ResizeFn = unsafe extern "system" fn(HPCON, COORD) -> i32;
type CloseFn = unsafe extern "system" fn(HPCON);
/// What GetProcAddress returns.
type Proc = unsafe extern "system" fn() -> isize;

/// The pseudoconsole entry points: from `conpty.dll` next to the server (or
/// `MUX2_CONPTY_DLL`) when present, the out-of-band ConPTY that ships with
/// Windows Terminal and runs its own OpenConsole; else the system's.
struct Api {
    create: CreateFn,
    resize: ResizeFn,
    close: CloseFn,
    source: &'static str,
}

fn wide(s: &OsStr) -> Vec<u16> {
    s.encode_wide().chain(Some(0)).collect()
}

fn api() -> &'static Api {
    static API: OnceLock<Api> = OnceLock::new();
    API.get_or_init(|| {
        let dll = std::env::var_os("MUX2_CONPTY_DLL").map(std::path::PathBuf::from).or_else(|| {
            let p = std::env::current_exe().ok()?.with_file_name("conpty.dll");
            p.exists().then_some(p)
        });
        if let Some(path) = dll {
            let name = wide(path.as_os_str());
            // SAFETY: loading a library by a NUL-terminated wide path and
            // resolving three exports with their documented signatures.
            unsafe {
                let module = LoadLibraryW(name.as_ptr());
                if !module.is_null() {
                    let c = GetProcAddress(module, c"CreatePseudoConsole".as_ptr().cast());
                    let r = GetProcAddress(module, c"ResizePseudoConsole".as_ptr().cast());
                    let x = GetProcAddress(module, c"ClosePseudoConsole".as_ptr().cast());
                    if let (Some(c), Some(r), Some(x)) = (c, r, x) {
                        return Api {
                            create: std::mem::transmute::<Proc, CreateFn>(c),
                            resize: std::mem::transmute::<Proc, ResizeFn>(r),
                            close: std::mem::transmute::<Proc, CloseFn>(x),
                            source: "conpty.dll",
                        };
                    }
                }
            }
        }
        Api {
            create: windows_sys::Win32::System::Console::CreatePseudoConsole,
            resize: windows_sys::Win32::System::Console::ResizePseudoConsole,
            close: windows_sys::Win32::System::Console::ClosePseudoConsole,
            source: "kernel32",
        }
    })
}

/// Which ConPTY and flags terminals get, for STATS.
pub(super) fn describe() -> String {
    format!("{} flags={:#x}", api().source, flags())
}

fn flags() -> u32 {
    // MUX2_CONPTY_FLAGS overrides; default: resize quirk, plus passthrough
    // unless MUX2_CONPTY_PASSTHROUGH=0. A ConPTY that does not know the
    // passthrough flag refuses the create, and the server retries without it.
    if let Some(f) = std::env::var("MUX2_CONPTY_FLAGS").ok().and_then(|v| {
        let v = v.trim_start_matches("0x");
        u32::from_str_radix(v, 16).ok()
    }) {
        return f;
    }
    let pass = std::env::var("MUX2_CONPTY_PASSTHROUGH").map_or(true, |v| v != "0");
    PSEUDOCONSOLE_RESIZE_QUIRK | if pass { PSEUDOCONSOLE_PASSTHROUGH_MODE } else { 0 }
}

static PASSTHROUGH_REFUSED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

pub(super) fn passthrough_refused() -> bool {
    PASSTHROUGH_REFUSED.load(Ordering::Relaxed)
}

/// Owner-only security for the pipes: the server's user and SYSTEM.
fn owner_only() -> io::Result<OwnerOnly> {
    let sddl = wide(OsStr::new("D:P(A;;GA;;;OW)(A;;GA;;;SY)"));
    let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    // SAFETY: converting a constant SDDL string; freed by OwnerOnly's Drop.
    let ok = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut sd,
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(OwnerOnly(sd))
}

struct OwnerOnly(PSECURITY_DESCRIPTOR);

impl Drop for OwnerOnly {
    fn drop(&mut self) {
        // SAFETY: freeing the descriptor the conversion allocated.
        unsafe { LocalFree(self.0) };
    }
}

/// Creates a pipe and returns (server end, overlapped; conhost end, synchronous).
fn pipe_pair(inbound: bool, buffer: u32) -> io::Result<(HANDLE, HANDLE)> {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let sd = owner_only()?;
    let sa = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: sd.0,
        bInheritHandle: 0,
    };
    // SAFETY: GetCurrentProcessId has no preconditions.
    let pid = unsafe { GetCurrentProcessId() };
    let name = format!(r"\\.\pipe\mux2-{pid}-{}", SEQ.fetch_add(1, Ordering::Relaxed));
    let name = wide(OsStr::new(&name));
    let access = if inbound { PIPE_ACCESS_INBOUND } else { PIPE_ACCESS_OUTBOUND };
    // SAFETY: a new single-instance pipe with our security attributes.
    let server = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            access | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            buffer,
            buffer,
            0,
            &sa,
        )
    };
    if server == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    let client_access = if inbound { GENERIC_WRITE } else { GENERIC_READ };
    // SAFETY: opening the client end of the pipe just created.
    let client = unsafe {
        CreateFileW(name.as_ptr(), client_access, 0, &sa, OPEN_EXISTING, 0, std::ptr::null_mut())
    };
    if client == INVALID_HANDLE_VALUE {
        let e = io::Error::last_os_error();
        // SAFETY: closing the server end we created.
        unsafe { CloseHandle(server) };
        return Err(e);
    }
    Ok((server, client))
}

/// A running terminal's OS objects.
pub(super) struct Child {
    pub(super) hpc: HPCON,
    /// Server ends: conhost's output (read) and its input (write).
    pub(super) out: HANDLE,
    pub(super) input: HANDLE,
    pub(super) process: HANDLE,
    pub(super) job: HANDLE,
    pub(super) pid: u32,
    pub(super) wait: HANDLE,
}

fn coord(cols: u16, rows: u16) -> COORD {
    COORD { X: cols.min(i16::MAX as u16) as i16, Y: rows.min(i16::MAX as u16) as i16 }
}

/// Quotes one argument for CommandLineToArgvW / the MSVC runtime.
fn quote(arg: &OsStr, out: &mut Vec<u16>) {
    let a: Vec<u16> = arg.encode_wide().collect();
    let needs = a.is_empty()
        || a.iter().any(|&c| c == b' ' as u16 || c == b'\t' as u16 || c == b'"' as u16);
    if !needs {
        out.extend_from_slice(&a);
        return;
    }
    out.push(b'"' as u16);
    let mut backslashes = 0;
    for &c in &a {
        if c == b'\\' as u16 {
            backslashes += 1;
            continue;
        }
        if c == b'"' as u16 {
            out.extend(std::iter::repeat_n(b'\\' as u16, backslashes * 2 + 1));
        } else {
            out.extend(std::iter::repeat_n(b'\\' as u16, backslashes));
        }
        backslashes = 0;
        out.push(c);
    }
    out.extend(std::iter::repeat_n(b'\\' as u16, backslashes * 2));
    out.push(b'"' as u16);
}

pub(super) fn command_line(argv: &[std::ffi::OsString]) -> Vec<u16> {
    let mut line = Vec::new();
    for (i, a) in argv.iter().enumerate() {
        if i > 0 {
            line.push(b' ' as u16);
        }
        quote(a, &mut line);
    }
    line.push(0);
    line
}

/// `%COMSPEC%` (cmd.exe), the shell a new console starts.
pub(super) fn default_argv() -> Vec<std::ffi::OsString> {
    vec![std::env::var_os("COMSPEC").unwrap_or_else(|| r"C:\Windows\System32\cmd.exe".into())]
}

/// The exit-wait callback: posts the terminal's exit token to the port.
unsafe extern "system" fn exited(context: *mut core::ffi::c_void, _timed_out: bool) {
    super::iocp::post(context as usize as u64, 0);
}

/// A pseudoconsole with nothing attached yet, and the server ends of its pipes.
pub(super) struct Console {
    pub(super) hpc: HPCON,
    pub(super) out: HANDLE,
    pub(super) input: HANDLE,
    pub(super) cols: u16,
    pub(super) rows: u16,
}

// SAFETY: the handles are plain kernel handles, usable from any thread.
unsafe impl Send for Console {}

/// Creates a pseudoconsole of `cols` x `rows` (conhost starts here: most of
/// a create's cost, which is why the server keeps one spare).
pub(super) fn open_console(cols: u16, rows: u16) -> io::Result<Console> {
    let (out_server, out_client) = pipe_pair(true, 128 << 10)?;
    let (in_server, in_client) = match pipe_pair(false, 16 << 10) {
        Ok(p) => p,
        Err(e) => {
            close_handle(out_server);
            close_handle(out_client);
            return Err(e);
        }
    };
    let mut hpc: HPCON = 0;
    let api = api();
    let mut fl = flags();
    if passthrough_refused() {
        fl &= !PSEUDOCONSOLE_PASSTHROUGH_MODE;
    }
    // SAFETY: valid pipe handles and an out pointer.
    let mut hr = unsafe { (api.create)(coord(cols, rows), in_client, out_client, fl, &mut hpc) };
    // E_INVALIDARG: this conhost does not know the passthrough flag.
    if hr == 0x8007_0057_u32 as i32 && fl & PSEUDOCONSOLE_PASSTHROUGH_MODE != 0 {
        PASSTHROUGH_REFUSED.store(true, Ordering::Relaxed);
        fl &= !PSEUDOCONSOLE_PASSTHROUGH_MODE;
        // SAFETY: as above.
        hr = unsafe { (api.create)(coord(cols, rows), in_client, out_client, fl, &mut hpc) };
    }
    // conhost holds its own duplicates of the client ends.
    close_handle(in_client);
    close_handle(out_client);
    if hr < 0 {
        close_handle(in_server);
        close_handle(out_server);
        return Err(io::Error::other(format!("CreatePseudoConsole: {hr:#x}")));
    }
    Ok(Console { hpc, out: out_server, input: in_server, cols, rows })
}

/// Starts `argv` on `console`, resized to `cols` x `rows` first if needed.
/// `exit_key` is posted to the port when the program exits. On failure the
/// console is ended.
pub(super) fn spawn(
    console: Console,
    argv: &[std::ffi::OsString],
    cwd: Option<&OsStr>,
    cols: u16,
    rows: u16,
    exit_key: u64,
) -> io::Result<Child> {
    if (console.cols, console.rows) != (cols, rows) {
        resize(console.hpc, cols, rows);
    }
    let Console { hpc, out: out_server, input: in_server, .. } = console;
    let close_all = |hs: &[HANDLE]| {
        for &h in hs {
            close_handle(h);
        }
    };
    let fail = |e: io::Error, extra: &[HANDLE]| {
        close_later(hpc);
        close_all(&[in_server, out_server]);
        close_all(extra);
        Err(e)
    };

    let mut size = 0usize;
    // SAFETY: the documented size query (fails with the size filled in).
    unsafe { InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut size) };
    let mut attrs = vec![0u8; size];
    let list = attrs.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
    // SAFETY: list has `size` bytes; the pseudoconsole attribute takes the
    // HPCON value itself as lpValue.
    let ok = unsafe {
        InitializeProcThreadAttributeList(list, 1, 0, &mut size) != 0
            && windows_sys::Win32::System::Threading::UpdateProcThreadAttribute(
                list,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                hpc as *const core::ffi::c_void,
                size_of::<HPCON>(),
                std::ptr::null_mut(),
                std::ptr::null(),
            ) != 0
    };
    if !ok {
        return fail(io::Error::last_os_error(), &[]);
    }
    let mut si = STARTUPINFOEXW::default();
    si.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
    // Without explicit (invalid) std handles a child of a server whose own
    // std handles are redirected would inherit those instead of the console.
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
    si.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
    si.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
    si.lpAttributeList = list;
    let mut line = command_line(argv);
    let cwd_w = cwd.map(wide);
    let mut pi = PROCESS_INFORMATION::default();
    // SAFETY: every pointer is valid for the call; the command line buffer
    // is writable as CreateProcessW requires.
    let created = unsafe {
        CreateProcessW(
            std::ptr::null(),
            line.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
            std::ptr::null(),
            cwd_w.as_ref().map_or(std::ptr::null(), |w| w.as_ptr()),
            &si.StartupInfo,
            &mut pi,
        )
    } != 0;
    let spawn_err = (!created).then(io::Error::last_os_error);
    // SAFETY: the list was initialized above.
    unsafe { DeleteProcThreadAttributeList(list) };
    if let Some(e) = spawn_err {
        return fail(e, &[]);
    }
    // SAFETY: a new unnamed job; the limit struct is fully initialized.
    let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: setting limits on and assigning to our own new job.
    let job_ok = !job.is_null()
        && unsafe {
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            ) != 0
                && AssignProcessToJobObject(job, pi.hProcess) != 0
        };
    if !job_ok {
        let e = io::Error::last_os_error();
        // SAFETY: the child never ran (it is suspended): end it.
        unsafe { TerminateProcess(pi.hProcess, 1) };
        let mut extra = vec![pi.hProcess, pi.hThread];
        if !job.is_null() {
            extra.push(job);
        }
        return fail(e, &extra);
    }
    let mut wait: HANDLE = std::ptr::null_mut();
    // SAFETY: waiting once on our child's handle; the callback only posts a
    // packet with the key passed as its context.
    let waited = unsafe {
        RegisterWaitForSingleObject(
            &mut wait,
            pi.hProcess,
            Some(exited),
            exit_key as usize as *const core::ffi::c_void,
            u32::MAX,
            WT_EXECUTEONLYONCE,
        )
    } != 0;
    if !waited {
        let e = io::Error::last_os_error();
        // SAFETY: as above.
        unsafe { TerminateJobObject(job, 1) };
        return fail(e, &[pi.hProcess, pi.hThread, job]);
    }
    // SAFETY: starting the suspended main thread, then dropping its handle.
    unsafe {
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
    }
    Ok(Child {
        hpc,
        out: out_server,
        input: in_server,
        process: pi.hProcess,
        job,
        pid: pi.dwProcessId,
        wait,
    })
}

pub(super) fn resize(hpc: HPCON, cols: u16, rows: u16) {
    // SAFETY: resizing a live pseudoconsole.
    unsafe { (api().resize)(hpc, coord(cols, rows)) };
}

/// Closes a pseudoconsole on a thread of its own: ClosePseudoConsole may
/// wait until conhost has written its last frame, which the event loop must
/// be free to read, and one slow close must not hold up another.
pub(super) fn close_later(hpc: HPCON) {
    let spawned = std::thread::Builder::new().name("mux2-conpty-close".into()).spawn(move || {
        // SAFETY: each pseudoconsole is closed exactly once, here.
        unsafe { (api().close)(hpc) };
    });
    if spawned.is_err() {
        // No thread: close here; the pipe is read again once this returns.
        // SAFETY: as above.
        unsafe { (api().close)(hpc) };
    }
}

/// Pseudoconsoles made ahead of time on a thread of their own, so a create
/// does not wait for conhost to start (MUX2_SPARE_CONSOLES, default 1).
pub(super) struct Spares {
    ready: std::sync::Arc<std::sync::Mutex<Vec<Console>>>,
    refill: Option<std::sync::mpsc::Sender<()>>,
}

impl Spares {
    pub(super) fn start(count: usize) -> Spares {
        let ready = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        if count == 0 {
            return Spares { ready, refill: None };
        }
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let shelf = ready.clone();
        let made = std::thread::Builder::new().name("mux2-conpty-spare".into()).spawn(move || {
            loop {
                while shelf.lock().expect("spares").len() < count {
                    match open_console(80, 24) {
                        Ok(c) => shelf.lock().expect("spares").push(c),
                        Err(_) => break,
                    }
                }
                if rx.recv().is_err() {
                    return;
                }
            }
        });
        Spares { ready, refill: made.ok().map(|_| tx) }
    }

    /// A console of `cols` x `rows`: a spare when one is ready, else a new one.
    pub(super) fn take(&self, cols: u16, rows: u16) -> io::Result<Console> {
        let spare = self.ready.lock().expect("spares").pop();
        if let Some(tx) = &self.refill {
            let _ = tx.send(());
        }
        match spare {
            Some(c) => Ok(c),
            None => open_console(cols, rows),
        }
    }

    pub(super) fn ready(&self) -> usize {
        self.ready.lock().expect("spares").len()
    }
}

/// Stops waiting for `wait` (blocking until a running callback returns).
pub(super) fn unregister(wait: HANDLE) {
    if !wait.is_null() {
        // SAFETY: unregistering our own wait; INVALID_HANDLE_VALUE waits for
        // a callback in progress.
        unsafe { UnregisterWaitEx(wait, INVALID_HANDLE_VALUE) };
    }
}

pub(super) fn close_handle(h: HANDLE) {
    if !h.is_null() && h != INVALID_HANDLE_VALUE {
        // SAFETY: closing a handle we own, once.
        unsafe { CloseHandle(h) };
    }
}

pub(super) fn terminate(job: HANDLE) {
    // SAFETY: ending every process in our own job.
    unsafe { TerminateJobObject(job, 1) };
}
