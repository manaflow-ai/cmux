//! `cmux-app-host`: spawned by the daemon's app supervisor with fd 3 as its
//! channel. `--sandbox-self-test <path>` exists for the integration tests.

use cmux_app_host::host_loop::{self, exit};
use cmux_app_host::{Limits, sandbox};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--sandbox-self-test") {
        std::process::exit(sandbox::self_test(args.get(1).map_or("/etc/hosts", String::as_str)));
    }
    std::process::exit(serve());
}

#[cfg(unix)]
fn serve() -> i32 {
    use std::os::fd::FromRawFd;
    use std::os::unix::net::UnixStream;

    // SAFETY: fstat on a descriptor number only inspects it.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
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
    host_loop::run(stream, write, Limits::default())
}

#[cfg(not(unix))]
fn serve() -> i32 {
    eprintln!("cmux-app-host: this platform has no app host");
    exit::SANDBOX
}
