//! `cmux host run` where there is no bind agent (macOS, or `--roles-only`
//! on a plain Linux server): only the process role loop (server.md 5.1).
//! SIGHUP reloads `server.json`; SIGTERM and SIGINT stop every role and
//! exit 0. The main thread waits in `sigwait`, so nothing polls.

use std::path::PathBuf;
use std::time::Instant;

use cmux_server_core::layout::Layout;

use crate::proc_roles::{RolePaths, Supervisor, load_roles};
use crate::roles::ROLE_STOP_GRACE;

#[cfg(unix)]
pub fn run_roles(layout: &Layout) -> u8 {
    // SAFETY: plain libc signal-set calls on a local set; the mask is set
    // before any thread starts, so every thread inherits it and only
    // `sigwait` here receives these signals. Children get an empty mask
    // from std's spawn.
    let set = unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaddset(&mut set, signal);
        }
        if libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut()) != 0 {
            eprintln!("cmux host run: cannot block signals");
            return 1;
        }
        set
    };
    let config = PathBuf::from(layout.config_file.as_str());
    let supervisor = match Supervisor::start(RolePaths::from_layout(layout)) {
        Ok(sup) => sup,
        Err(e) => {
            eprintln!("cmux host run: role supervisor: {e}");
            return 1;
        }
    };
    supervisor.apply(load_roles(&config));
    eprintln!("cmux-host: roles-only loop started ({})", config.display());
    loop {
        let mut signal = 0;
        // SAFETY: `set` is a valid signal set; `signal` is an out parameter.
        if unsafe { libc::sigwait(&set, &mut signal) } != 0 {
            continue;
        }
        if signal == libc::SIGHUP {
            eprintln!("cmux-host: reloading roles");
            supervisor.apply(load_roles(&config));
            continue;
        }
        let left = supervisor.stop_all(Instant::now() + ROLE_STOP_GRACE);
        if !left.is_empty() {
            eprintln!("cmux-host: still running at the deadline: {}", left.join(", "));
        }
        return 0;
    }
}

#[cfg(not(unix))]
pub fn run_roles(_layout: &Layout) -> u8 {
    eprintln!("cmux host run: process roles need a Unix host");
    4
}
