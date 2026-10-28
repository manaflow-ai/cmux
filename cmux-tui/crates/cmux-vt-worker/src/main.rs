//! `cmux-vt-worker`: started by the daemon with its socket at fd 3 and
//! nothing else ([`cmux_vt_worker::serve`]).

use std::os::fd::{FromRawFd, OwnedFd};
use std::process::ExitCode;

/// The descriptor the daemon passes the worker's socket at.
const SOCKET_FD: libc::c_int = 3;

fn main() -> ExitCode {
    // SAFETY: F_GETFD only reads the descriptor's flags.
    if unsafe { libc::fcntl(SOCKET_FD, libc::F_GETFD) } < 0 {
        eprintln!("cmux-vt-worker: no socket at fd {SOCKET_FD}");
        return ExitCode::from(2);
    }
    // SAFETY: the daemon passed this descriptor for the worker to own, and
    // nothing else in the process holds it.
    let socket = unsafe { OwnedFd::from_raw_fd(SOCKET_FD) };
    match cmux_vt_worker::serve::run(socket) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-vt-worker: {error}");
            ExitCode::from(error.exit_code())
        }
    }
}
