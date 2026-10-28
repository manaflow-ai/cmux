//! `cmux-app-host`: spawned by the daemon's app supervisor with fd 3 as its
//! channel. `--profile script` runs a script session (the script limits);
//! `--panic-log <path>` appends the host's panics there;
//! `--sandbox-self-test <path>` exists for the integration tests.

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

use cmux_app_host::host_loop::{self, exit};
use cmux_app_host::protocol::{PANIC_LOG_FLAG, SCRIPT_PROFILE};
use cmux_app_host::{Limits, panic_log, sandbox};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--sandbox-self-test") {
        std::process::exit(sandbox::self_test(args.get(1).map_or("/etc/hosts", String::as_str)));
    }
    let rest = match args.as_slice() {
        [flag, path, rest @ ..] if flag == PANIC_LOG_FLAG => {
            // No log leaves the default hook (stderr, which the supervisor discards).
            if let Err(error) = panic_log::install(std::path::Path::new(path)) {
                eprintln!("cmux-app-host: panic log {path}: {error}");
            }
            rest
        }
        rest => rest,
    };
    let code = match rest {
        [] => serve(Limits::default()),
        [flag, profile] if flag == "--profile" && profile == SCRIPT_PROFILE => {
            serve(Limits::script())
        }
        _ => {
            eprintln!("cmux-app-host: unknown arguments");
            exit::PROTOCOL
        }
    };
    std::process::exit(code);
}

#[cfg(unix)]
fn serve(limits: Limits) -> i32 {
    use std::os::fd::FromRawFd;
    use std::os::unix::net::UnixStream;

    // The black box first, and its file mapped before
    // the sandbox, which refuses opening files and starting threads; the
    // mapping stays writable after it. A host whose file failed keeps the
    // heap ring.
    if let Some(open) =
        cmux_trace::init_blackbox(cmux_trace::process_dir(), cmux_trace::Role::AppHost)
    {
        let _ = open.wait();
    }
    // SAFETY: fstat on a descriptor number only inspects it.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: fstat writes one stat into `stat`, a live local; a closed fd 3 fails with EBADF.
    if unsafe { libc::fstat(3, &mut stat) } != 0 || (stat.st_mode & libc::S_IFMT) != libc::S_IFSOCK
    {
        eprintln!("cmux-app-host: fd 3 must be the supervisor's socket");
        return exit::IO;
    }
    // Sandbox first: nothing from the supervisor is read before it holds.
    if let Err(error) = sandbox::apply() {
        eprintln!("cmux-app-host: sandbox: {error}");
        return exit::SANDBOX;
    }
    // SAFETY: fd 3 is a socket handed to us by the supervisor and owned by this process from here on.
    let stream = unsafe { UnixStream::from_raw_fd(3) };
    let write = match stream.try_clone() {
        Ok(write) => write,
        Err(_) => return exit::IO,
    };
    host_loop::run(stream, write, limits)
}

#[cfg(not(unix))]
fn serve(_limits: Limits) -> i32 {
    eprintln!("cmux-app-host: this platform has no app host");
    exit::SANDBOX
}
