//! Initialize the Linux sandbox inside bubblewrap before the child execs.
//! This process is single-threaded and runs before acpmux builds a tokio
//! runtime. Every error exits 125, which is the spawn-refused status.

use std::ffi::{CString, OsString};
use std::io;
use std::net::TcpListener;
use std::os::fd::{AsRawFd, RawFd};
use std::path::Path;
use std::ptr;

use super::seccomp;

struct Options {
    handoff_fd: RawFd,
    proxy_port: u16,
    api_port: Option<u16>,
    program: String,
    args: Vec<String>,
}

fn fail(error: impl std::fmt::Display) -> ! {
    eprintln!("remote sandbox init: {error}");
    std::process::exit(125)
}

fn parse(args: Vec<OsString>) -> Result<Options, String> {
    let values: Result<Vec<String>, _> = args.into_iter().map(|arg| arg.into_string()).collect();
    let values = values.map_err(|_| "arguments must be UTF-8".to_owned())?;
    let mut index = 0;
    let mut handoff_fd = None;
    let mut proxy_port = None;
    let mut api_port = None;
    while index < values.len() {
        match values[index].as_str() {
            "--handoff-fd" => {
                index += 1;
                let value = values.get(index).ok_or("--handoff-fd needs a value")?;
                let fd = value.parse::<i32>().map_err(|_| "invalid --handoff-fd")?;
                if fd <= 2 {
                    return Err("--handoff-fd must be above standard descriptors".into());
                }
                if handoff_fd.replace(fd).is_some() {
                    return Err("duplicate --handoff-fd".into());
                }
            }
            "--proxy-port" => {
                index += 1;
                let value = values.get(index).ok_or("--proxy-port needs a value")?;
                let port = value.parse::<u16>().map_err(|_| "invalid --proxy-port")?;
                if proxy_port.replace(port).is_some() {
                    return Err("duplicate --proxy-port".into());
                }
            }
            "--api-port" => {
                index += 1;
                let value = values.get(index).ok_or("--api-port needs a value")?;
                let port = value.parse::<u16>().map_err(|_| "invalid --api-port")?;
                if api_port.replace(port).is_some() {
                    return Err("duplicate --api-port".into());
                }
            }
            "--" => {
                index += 1;
                let program = values.get(index).cloned().ok_or("missing program after --")?;
                let args = values[index + 1..].to_vec();
                let handoff_fd = handoff_fd.ok_or("missing --handoff-fd")?;
                let proxy_port = proxy_port.ok_or("missing --proxy-port")?;
                return Ok(Options { handoff_fd, proxy_port, api_port, program, args });
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
        index += 1;
    }
    Err("missing -- and program".into())
}

fn listener(port: u16, name: &str) -> Result<TcpListener, String> {
    TcpListener::bind(("127.0.0.1", port)).map_err(|error| format!("{name} listener: {error}"))
}

fn send_handoff(fd: RawFd, listeners: &[RawFd], proxy: u16, api: Option<u16>) -> io::Result<()> {
    let payload = match api {
        Some(port) => format!("{{\"proxy\":{proxy},\"api\":{port}}}\n"),
        None => format!("{{\"proxy\":{proxy},\"api\":null}}\n"),
    };
    let mut iov =
        libc::iovec { iov_base: payload.as_ptr() as *mut libc::c_void, iov_len: payload.len() };
    let control_len = unsafe {
        libc::CMSG_SPACE((std::mem::size_of::<RawFd>() * listeners.len()) as u32) as usize
    };
    let mut control = vec![0u8; control_len];
    // SAFETY: control is CMSG_SPACE-sized and remains alive through sendmsg.
    unsafe {
        let header = control.as_mut_ptr().cast::<libc::cmsghdr>();
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len =
            libc::CMSG_LEN((std::mem::size_of::<RawFd>() * listeners.len()) as u32) as usize;
        ptr::copy_nonoverlapping(
            listeners.as_ptr().cast::<u8>(),
            libc::CMSG_DATA(header),
            std::mem::size_of::<RawFd>() * listeners.len(),
        );
        let mut message: libc::msghdr = std::mem::zeroed();
        message.msg_iov = &mut iov;
        message.msg_iovlen = 1;
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = control.len();
        let sent = libc::sendmsg(fd, &message, libc::MSG_NOSIGNAL);
        if sent < 0 {
            return Err(io::Error::last_os_error());
        }
        if sent as usize != payload.len() {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "short handoff message"));
        }
    }
    Ok(())
}

fn wait_ack(fd: RawFd) -> Result<(), String> {
    let mut pollfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    // Stop condition: this single poll returns on one ack, hangup/error, or
    // the ten-second deadline; it never waits indefinitely for the parent.
    let result = unsafe { libc::poll(&mut pollfd, 1, 10_000) };
    if result < 0 {
        return Err(format!("handoff poll: {}", io::Error::last_os_error()));
    }
    if result == 0 {
        return Err("handoff acknowledgement timed out".into());
    }
    if pollfd.revents & libc::POLLIN == 0
        && pollfd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0
    {
        return Err("handoff closed before acknowledgement".into());
    }
    let mut byte = [0u8; 1];
    let received = unsafe { libc::recv(fd, byte.as_mut_ptr().cast(), 1, 0) };
    if received == 1 {
        Ok(())
    } else if received == 0 {
        Err("handoff EOF before acknowledgement".into())
    } else {
        Err(format!("handoff acknowledgement: {}", io::Error::last_os_error()))
    }
}

fn close_extra_fds() -> io::Result<()> {
    // SAFETY: close_range only acts on this process's descriptors >= 3.
    let result = unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) };
    if result == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if !matches!(error.raw_os_error(), Some(libc::ENOSYS | libc::EINVAL)) {
        return Err(error);
    }
    let entries = std::fs::read_dir("/proc/self/fd")?;
    let mut descriptors = Vec::new();
    for entry in entries {
        let name = entry?.file_name();
        if let Ok(fd) = name.to_string_lossy().parse::<RawFd>() {
            if fd > 2 {
                descriptors.push(fd);
            }
        }
    }
    for fd in descriptors {
        // SAFETY: each value came from /proc/self/fd and is closed at most once.
        unsafe {
            libc::close(fd);
        }
    }
    Ok(())
}

fn set_proxy_environment(proxy: u16) {
    let value = format!("http://127.0.0.1:{proxy}");
    for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"]
    {
        // SAFETY: initialization is single-threaded before exec and no Rust
        // thread can concurrently inspect the process environment.
        unsafe {
            std::env::set_var(key, &value);
        }
    }
    for key in ["NO_PROXY", "no_proxy"] {
        // SAFETY: see the set_var safety argument above.
        unsafe {
            std::env::remove_var(key);
        }
    }
}

fn exec_program(program: String, args: Vec<String>) -> Result<(), String> {
    if !Path::new(&program).is_absolute() {
        return Err("program path must be absolute".into());
    }
    let program = CString::new(program).map_err(|_| "program contains NUL")?;
    let mut argv = Vec::with_capacity(args.len() + 2);
    argv.push(program.clone());
    for arg in args {
        argv.push(CString::new(arg).map_err(|_| "argument contains NUL")?);
    }
    let mut pointers: Vec<*const libc::c_char> = argv.iter().map(|arg| arg.as_ptr()).collect();
    pointers.push(ptr::null());
    // SAFETY: all CString buffers and the pointer array live until execv;
    // the program path is absolute and argv is NUL-terminated.
    unsafe {
        libc::execv(program.as_ptr(), pointers.as_ptr());
    }
    Err(format!("execv: {}", io::Error::last_os_error()))
}

pub(crate) fn main(args: Vec<OsString>) -> ! {
    let options = match parse(args) {
        Ok(options) => options,
        Err(error) => fail(error),
    };
    let proxy = match listener(options.proxy_port, "proxy") {
        Ok(listener) => listener,
        Err(error) => fail(error),
    };
    let api = match options.api_port.map(|port| listener(port, "api")).transpose() {
        Ok(api) => api,
        Err(error) => fail(error),
    };
    let proxy_port = match proxy.local_addr() {
        Ok(address) => address.port(),
        Err(error) => fail(format!("proxy listener address: {error}")),
    };
    let api_port = match api.as_ref().map(TcpListener::local_addr).transpose() {
        Ok(address) => address.map(|address| address.port()),
        Err(error) => fail(format!("api listener address: {error}")),
    };
    let mut fds = vec![proxy.as_raw_fd()];
    if let Some(listener) = &api {
        fds.push(listener.as_raw_fd());
    }
    if let Err(error) = send_handoff(options.handoff_fd, &fds, proxy_port, api_port) {
        fail(format!("handoff send: {error}"));
    }
    if let Err(error) = wait_ack(options.handoff_fd) {
        fail(error);
    }
    drop(api);
    drop(proxy);
    // The handoff descriptor is no longer needed and must not reach PROGRAM.
    unsafe {
        libc::close(options.handoff_fd);
    }
    set_proxy_environment(proxy_port);
    if let Err(error) = close_extra_fds() {
        fail(format!("close leaked descriptors: {error}"));
    }
    let filter = match seccomp::deny_filter() {
        Ok(filter) => filter,
        Err(error) => fail(error),
    };
    if let Err(error) = seccomp::install(&filter) {
        fail(format!("install seccomp: {error}"));
    }
    match exec_program(options.program, options.args) {
        Ok(()) => fail("execv returned unexpectedly"),
        Err(error) => {
            eprintln!("remote sandbox init: {error}");
            std::process::exit(127)
        }
    }
}
