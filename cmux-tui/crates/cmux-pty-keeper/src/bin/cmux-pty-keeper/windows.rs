//! Windows keeper: owns a ConPTY and its child. The main thread waits for
//! the child, one thread accepts pipe clients, and one thread serves each
//! client.

use std::ffi::{CStr, OsStr, c_void};
use std::os::windows::ffi::OsStrExt;
use std::ptr;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

use cmux_pty_keeper::protocol::{self, FRAME_LEN, Frame, Size};
use cmux_pty_keeper::win_io::{self, Handle};
use windows_sys::Win32::Foundation::{
    DUPLICATE_SAME_ACCESS, DuplicateHandle, FALSE, HANDLE, INVALID_HANDLE_VALUE, LocalFree,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::{
    GetTokenInformation, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX,
};
use windows_sys::Win32::System::Console::{GetStdHandle, STD_OUTPUT_HANDLE};
use windows_sys::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
use windows_sys::Win32::System::Pipes::{
    CreateNamedPipeW, CreatePipe, GetNamedPipeClientProcessId, PIPE_READMODE_BYTE,
    PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::{
    CREATE_UNICODE_ENVIRONMENT, CreateProcessW, DeleteProcThreadAttributeList,
    EXTENDED_STARTUPINFO_PRESENT, GetCurrentProcess, GetExitCodeProcess, INFINITE,
    InitializeProcThreadAttributeList, OpenProcess, OpenProcessToken,
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, PROCESS_DUP_HANDLE, PROCESS_INFORMATION,
    STARTF_USESTDHANDLES, STARTUPINFOEXW, UpdateProcThreadAttribute, WaitForSingleObject,
};

use crate::{Launch, report};

type Hpcon = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct Coord {
    x: i16,
    y: i16,
}

impl Coord {
    fn new(cols: u16, rows: u16) -> Self {
        let clamp = |n: u16| n.min(i16::MAX as u16) as i16;
        Self { x: clamp(cols), y: clamp(rows) }
    }
}

type RawFn = unsafe extern "system" fn() -> isize;
type CreateFn = unsafe extern "system" fn(Coord, HANDLE, HANDLE, u32, *mut Hpcon) -> i32;
type ResizeFn = unsafe extern "system" fn(Hpcon, Coord) -> i32;
type CloseFn = unsafe extern "system" fn(Hpcon);

/// ConPTY is resolved at runtime so the keeper starts, and reports a clear
/// error, on Windows builds that predate it.
#[derive(Clone, Copy)]
struct ConPty {
    create: CreateFn,
    resize: ResizeFn,
    close: CloseFn,
}

impl ConPty {
    fn load() -> Option<Self> {
        let kernel = wide(OsStr::new("kernel32.dll"));
        // SAFETY: kernel32 is always loaded; the names are NUL-terminated.
        unsafe {
            let module = GetModuleHandleW(kernel.as_ptr());
            if module.is_null() {
                return None;
            }
            let find = |name: &CStr| GetProcAddress(module, name.as_ptr().cast());
            let create = find(c"CreatePseudoConsole")?;
            let resize = find(c"ResizePseudoConsole")?;
            let close = find(c"ClosePseudoConsole")?;
            Some(Self {
                create: std::mem::transmute::<RawFn, CreateFn>(create),
                resize: std::mem::transmute::<RawFn, ResizeFn>(resize),
                close: std::mem::transmute::<RawFn, CloseFn>(close),
            })
        }
    }
}

struct Console(Hpcon);

// SAFETY: a pseudoconsole handle may be used from any thread.
unsafe impl Send for Console {}

struct Security(SECURITY_ATTRIBUTES);

// SAFETY: the descriptor it points to is leaked and never mutated.
unsafe impl Send for Security {}

struct Client {
    pipe: Handle,
    exit_sent: std::sync::atomic::AtomicBool,
}

struct State {
    exit: Option<u32>,
    delivered: bool,
    clients: Vec<Arc<Client>>,
    /// Last size applied to the console, reported after `HELLO`.
    size: Size,
    /// Number of resizes applied; lets clients order `SIZE` reports.
    generation: u64,
}

struct Shared {
    conpty: ConPty,
    console: Mutex<Option<Console>>,
    input: Handle,
    output: Handle,
    child_pid: u32,
    state: Mutex<State>,
    done: Condvar,
}

fn fail(context: &str) -> ! {
    report(&format!("error {context}: {}", std::io::Error::last_os_error()));
    std::process::exit(1);
}

fn fail_with(message: &str) -> ! {
    report(&format!("error {message}"));
    std::process::exit(1);
}

fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(Some(0)).collect()
}

pub fn run(launch: Launch) -> ! {
    if !launch.endpoint.to_string_lossy().starts_with(r"\\.\pipe\") {
        fail_with(r"endpoint must start with \\.\pipe\");
    }
    let name = wide(&launch.endpoint);
    let conpty = ConPty::load()
        .unwrap_or_else(|| fail_with("ConPTY unavailable; requires Windows 10 1809 or later"));
    // SAFETY: Win32 setup on handles this process creates and owns.
    unsafe {
        let security = Security(user_only_security());
        let first = create_instance(&name, &security, true).unwrap_or_else(|| fail("create pipe"));

        let (mut pty_input, mut input) = (ptr::null_mut(), ptr::null_mut());
        let (mut output, mut pty_output) = (ptr::null_mut(), ptr::null_mut());
        if CreatePipe(&mut pty_input, &mut input, ptr::null(), 0) == 0
            || CreatePipe(&mut output, &mut pty_output, ptr::null(), 0) == 0
        {
            fail("CreatePipe");
        }
        let (pty_input, pty_output) = (Handle(pty_input), Handle(pty_output));
        let mut console = ptr::null_mut();
        let result = (conpty.create)(
            Coord::new(launch.cols, launch.rows),
            pty_input.0,
            pty_output.0,
            0,
            &mut console,
        );
        if result < 0 {
            fail_with(&format!("CreatePseudoConsole: HRESULT {result:#x}"));
        }
        let (child, child_pid) = spawn_child(console, &launch);
        drop((pty_input, pty_output));

        // The keeper must not keep a user directory busy for its whole life.
        let root = std::env::var_os("SystemRoot").unwrap_or_else(|| r"C:\".into());
        let _ = std::env::set_current_dir(root);

        report(&format!("ready {}", std::process::id()));
        windows_sys::Win32::Foundation::CloseHandle(GetStdHandle(STD_OUTPUT_HANDLE));

        let shared = Arc::new(Shared {
            conpty,
            console: Mutex::new(Some(Console(console))),
            input: Handle(input),
            output: Handle(output),
            child_pid,
            state: Mutex::new(State {
                exit: None,
                delivered: false,
                clients: Vec::new(),
                size: Size::new(launch.cols, launch.rows),
                generation: 0,
            }),
            done: Condvar::new(),
        });
        let acceptor = Arc::clone(&shared);
        thread::spawn(move || accept_loop(acceptor, name, security, first));

        WaitForSingleObject(child.0, INFINITE);
        let mut code = 0u32;
        GetExitCodeProcess(child.0, &mut code);
        shared.on_exit(code);
    }
    std::process::exit(0);
}

impl Shared {
    fn on_exit(&self, code: u32) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.exit = Some(code);
        let exit = Frame::new(protocol::EXIT, code, 0, 0).encode();
        for client in &state.clients {
            if win_io::write_all(&client.pipe, &exit).is_ok() {
                client.exit_sent.store(true, std::sync::atomic::Ordering::SeqCst);
            }
        }
        drop(state);
        // Readers see end of output only once the console is gone.
        self.close_console();
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        while !(state.delivered && state.clients.is_empty()) {
            state = self.done.wait(state).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// Ends the console on a helper thread: on older Windows builds
    /// `ClosePseudoConsole` blocks until its output is drained.
    fn close_console(&self) {
        let taken = self.console.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(console) = taken {
            let close = self.conpty.close;
            thread::spawn(move || {
                let console = console;
                // SAFETY: the console was taken, so no other call can use it.
                unsafe { close(console.0) };
            });
        }
    }

    /// Applies a size and reports it to every client, so all of them
    /// converge on the last writer's size.
    fn resize(&self, size: Size) {
        if size.cols == 0 || size.rows == 0 {
            return;
        }
        // Lock order: console, then state.
        let console = self.console.lock().unwrap_or_else(|e| e.into_inner());
        let Some(console) = console.as_ref() else { return };
        // SAFETY: the console stays open while its lock is held.
        if unsafe { (self.conpty.resize)(console.0, Coord::new(size.cols, size.rows)) } < 0 {
            return;
        }
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.size = size;
        state.generation += 1;
        let report = Frame::size_report(size, state.generation).encode();
        for client in &state.clients {
            let _ = win_io::write_all(&client.pipe, &report);
        }
    }

    fn serve(&self, pipe: Handle) {
        let client = Arc::new(Client { pipe, exit_sent: false.into() });
        if !self.greet(&client) {
            return;
        }
        let mut buf = [0u8; FRAME_LEN];
        while win_io::read_exact(&client.pipe, &mut buf).is_ok() {
            let Some(frame) = Frame::decode(&buf) else { break };
            match frame.kind {
                protocol::RESIZE => self.resize(frame.size()),
                protocol::TERMINATE => self.close_console(),
                _ => {}
            }
        }
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.clients.retain(|other| !Arc::ptr_eq(other, &client));
        if client.exit_sent.load(std::sync::atomic::Ordering::SeqCst) {
            state.delivered = true;
        }
        self.done.notify_all();
    }

    /// Sends `HELLO` with handles duplicated into the client, and `EXIT`
    /// when the child already exited.
    fn greet(&self, client: &Arc<Client>) -> bool {
        let mut client_pid = 0;
        // SAFETY: queries and opens the connected client process.
        let process = unsafe {
            GetNamedPipeClientProcessId(client.pipe.0, &mut client_pid);
            Handle(OpenProcess(PROCESS_DUP_HANDLE, FALSE, client_pid))
        };
        if process.0.is_null() {
            return false;
        }
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let (input, output) = match state.exit {
            None => {
                (duplicate_into(process.0, self.input.0), duplicate_into(process.0, self.output.0))
            }
            Some(_) => (0, 0),
        };
        let hello = Frame::new(protocol::HELLO, self.child_pid, input, output).encode();
        let report = Frame::size_report(state.size, state.generation).encode();
        if win_io::write_all(&client.pipe, &hello).is_err()
            || win_io::write_all(&client.pipe, &report).is_err()
        {
            return false;
        }
        if let Some(code) = state.exit {
            let sent =
                win_io::write_all(&client.pipe, &Frame::new(protocol::EXIT, code, 0, 0).encode())
                    .is_ok();
            client.exit_sent.store(sent, std::sync::atomic::Ordering::SeqCst);
        }
        state.clients.push(Arc::clone(client));
        true
    }
}

fn duplicate_into(process: HANDLE, source: HANDLE) -> u64 {
    let mut target = ptr::null_mut();
    // SAFETY: duplicates a keeper-owned handle into an opened client process.
    let ok = unsafe {
        DuplicateHandle(
            GetCurrentProcess(),
            source,
            process,
            &mut target,
            0,
            FALSE,
            DUPLICATE_SAME_ACCESS,
        )
    };
    if ok == 0 { 0 } else { target as usize as u64 }
}

fn accept_loop(shared: Arc<Shared>, name: Vec<u16>, security: Security, mut instance: Handle) {
    loop {
        let connected = win_io::connect(&instance);
        // Create the next instance first so the pipe name never disappears.
        let next = create_instance(&name, &security, false);
        if connected.is_ok() {
            let shared = Arc::clone(&shared);
            thread::spawn(move || shared.serve(instance));
        }
        match next {
            Some(handle) => instance = handle,
            None => return,
        }
    }
}

fn create_instance(name: &[u16], security: &Security, first: bool) -> Option<Handle> {
    let first_flag = if first { FILE_FLAG_FIRST_PIPE_INSTANCE } else { 0 };
    // SAFETY: `name` is NUL-terminated; `security` points at a leaked descriptor.
    let handle = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | first_flag,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            4096,
            4096,
            0,
            &security.0,
        )
    };
    (handle != INVALID_HANDLE_VALUE).then_some(Handle(handle))
}

/// A pipe DACL that grants access to this process's user only. The default
/// named-pipe DACL lets every user read.
unsafe fn user_only_security() -> SECURITY_ATTRIBUTES {
    // SAFETY: token queries on this process with correctly sized buffers.
    unsafe {
        let mut token = ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            fail("OpenProcessToken");
        }
        let token = Handle(token);
        let mut len = 0u32;
        GetTokenInformation(token.0, TokenUser, ptr::null_mut(), 0, &mut len);
        let mut buf = vec![0u64; (len as usize).div_ceil(8)];
        if GetTokenInformation(token.0, TokenUser, buf.as_mut_ptr().cast(), len, &mut len) == 0 {
            fail("GetTokenInformation");
        }
        let user = &*buf.as_ptr().cast::<TOKEN_USER>();
        let mut text = ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
            fail("ConvertSidToStringSidW");
        }
        let mut end = 0;
        while *text.add(end) != 0 {
            end += 1;
        }
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, end));
        LocalFree(text.cast());
        let sddl = wide(OsStr::new(&format!("D:P(A;;GA;;;{sid})")));
        let mut descriptor = ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            ptr::null_mut(),
        ) == 0
        {
            fail("security descriptor");
        }
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: FALSE,
        }
    }
}

/// Quotes one argument with the rules `CommandLineToArgvW` and the C
/// runtime use to split it again.
fn push_quoted(arg: &OsStr, out: &mut Vec<u16>) {
    let arg: Vec<u16> = arg.encode_wide().collect();
    let special =
        |c: &u16| *c == u16::from(b' ') || *c == u16::from(b'\t') || *c == u16::from(b'"');
    if !arg.is_empty() && !arg.iter().any(special) {
        out.extend(arg);
        return;
    }
    let backslash = u16::from(b'\\');
    out.push(u16::from(b'"'));
    let mut pending = 0;
    for c in arg {
        if c == backslash {
            pending += 1;
            continue;
        }
        let repeat = if c == u16::from(b'"') { pending * 2 + 1 } else { pending };
        out.extend(std::iter::repeat_n(backslash, repeat));
        out.push(c);
        pending = 0;
    }
    out.extend(std::iter::repeat_n(backslash, pending * 2));
    out.push(u16::from(b'"'));
}

unsafe fn spawn_child(console: Hpcon, launch: &Launch) -> (Handle, u32) {
    let mut command = Vec::new();
    push_quoted(&launch.program, &mut command);
    for arg in &launch.args {
        command.push(u16::from(b' '));
        push_quoted(arg, &mut command);
    }
    command.push(0);
    // SAFETY: standard ConPTY process creation with buffers that outlive it.
    unsafe {
        let mut size = 0usize;
        InitializeProcThreadAttributeList(ptr::null_mut(), 1, 0, &mut size);
        let mut list = vec![0u64; size.div_ceil(8)];
        let attributes = list.as_mut_ptr().cast();
        if InitializeProcThreadAttributeList(attributes, 1, 0, &mut size) == 0
            || UpdateProcThreadAttribute(
                attributes,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                console as *const c_void,
                size_of::<Hpcon>(),
                ptr::null_mut(),
                ptr::null(),
            ) == 0
        {
            fail("process attributes");
        }
        let mut startup = STARTUPINFOEXW::default();
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        // Without explicit invalid handles the child inherits the keeper's
        // redirected stdio instead of the console.
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
        startup.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
        startup.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
        startup.lpAttributeList = attributes;
        let mut info: PROCESS_INFORMATION = std::mem::zeroed();
        let ok = CreateProcessW(
            ptr::null(),
            command.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            FALSE,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            ptr::null(),
            ptr::null(),
            &startup.StartupInfo,
            &mut info,
        );
        if ok == 0 {
            fail(&format!("spawn {}", launch.program.to_string_lossy()));
        }
        DeleteProcThreadAttributeList(attributes);
        drop(Handle(info.hThread));
        (Handle(info.hProcess), info.dwProcessId)
    }
}
