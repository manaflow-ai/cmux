//! `cmux chief shutdown`: the one documented way to stop a Chief home (E20,
//! .cmux-scratch/chief-errors/catalog.md). It sends SIGTERM to the brain
//! that holds `state/host.lock` (the brain then shuts down the acpmux
//! daemon it started, which ends its agent hosts and their sessions, and
//! exits) and waits until that process has ended. First it writes
//! `state/shutdown`, so the app (ChiefBrainWatch) does not start a new
//! brain; an older app that still does gets its brain stopped the same
//! way. Then it stops the home's session daemon
//! with its terminals, also after a brain that did not stop in time (a
//! daemon left running keeps the Chief on old code across an upgrade,
//! cosmic-gray 2026-10-14). Nothing is started.

use std::path::Path;
use std::time::{Duration, Instant};

use super::home::ChiefHome;
use super::launch::brain_running;
use super::messages::messages;
use super::{GlobalArgs, Target};

/// How long the brain may take to stop: its acpmux shutdown waits up to
/// 35 s for a daemon start in flight, then up to 20 s for the daemon's
/// own shutdown (optchat-chief acpmux_daemon.rs).
const BRAIN_STOP_LIMIT: Duration = Duration::from_secs(60);

/// How long a brain the app starts in place of the stopped one may take to
/// hold the lock.
const RESTART_GRACE: Duration = Duration::from_secs(1);

/// The most brains one shutdown stops: the one it found and the app's
/// restarts of it.
const MAX_BRAINS: usize = 4;

pub(super) fn run(global: &GlobalArgs, chief_home: Option<&Path>) -> i32 {
    let m = messages();
    let home = match super::target(global, chief_home) {
        Ok(Target::Home(home)) => home,
        Ok(Target::Explicit(..)) => {
            eprintln!("cmux: {}", m.shutdown_needs_home);
            return 2;
        }
        Err((code, message)) => {
            eprintln!("cmux: {message}");
            return code;
        }
    };
    let root = home.root.display().to_string();
    let marker = home.shutdown_marker();
    if let Err(error) = marker
        .parent()
        .map_or(Ok(()), cmux_blocking::fs::create_dir_all)
        .and_then(|()| cmux_blocking::fs::write(&marker, "cmux chief shutdown\n"))
    {
        eprintln!("cmux: {}: {error}", marker.display());
    }
    let brain = stop_brain(&home.host_lock(), BRAIN_STOP_LIMIT);
    match &brain {
        Ok(true) => eprintln!("cmux: {}", m.shutdown_brain.replace("{home}", &root)),
        Ok(false) => {}
        Err(why) => {
            // The brain still runs: its next crash is restarted as before.
            let _ = cmux_blocking::fs::remove_file(&marker);
            eprintln!("cmux: {why}");
        }
    }
    let daemon = stop_daemon(global, &home);
    if brain.is_err() { 1 } else { daemon }
}

/// SIGTERM to the brain holding `lock`, then waits until that process has
/// ended; a brain that holds the lock within `RESTART_GRACE` after (the
/// app's restart) is stopped the same way. `Ok(false)` when no brain holds
/// it.
pub(super) fn stop_brain(lock: &Path, limit: Duration) -> Result<bool, String> {
    let deadline = Instant::now() + limit;
    let mut stopped: Vec<i32> = Vec::new();
    while held_within(lock, if stopped.is_empty() { Duration::ZERO } else { RESTART_GRACE }) {
        let Some(pid) = holder(lock).filter(|pid| !stopped.contains(pid)) else {
            // The new holder has not written its pid yet.
            if Instant::now() >= deadline {
                return Err(timeout(stopped.last().copied().unwrap_or(0), limit));
            }
            cmux_blocking::thread::sleep(Duration::from_millis(20));
            continue;
        };
        if stopped.len() >= MAX_BRAINS {
            return Err(timeout(pid, limit));
        }
        // SAFETY: kill(2) with a pid read from the lock its holder wrote; the
        // lock is held, so the pid is the running holder.
        if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(format!("SIGTERM to the brain (pid {pid}): {error}"));
            }
        }
        stopped.push(pid);
        // Ended: gone, or no longer the lock's holder (an exited brain whose
        // parent has not reaped it yet still answers kill(pid, 0)).
        while alive(pid) && brain_running(lock) && holder(lock) == Some(pid) {
            if Instant::now() >= deadline {
                return Err(timeout(pid, limit));
            }
            cmux_blocking::thread::sleep(Duration::from_millis(100));
        }
    }
    Ok(!stopped.is_empty())
}

/// Whether a brain holds `lock` now or within `grace`.
fn held_within(lock: &Path, grace: Duration) -> bool {
    let until = Instant::now() + grace;
    loop {
        if brain_running(lock) {
            return true;
        }
        if Instant::now() >= until {
            return false;
        }
        cmux_blocking::thread::sleep(Duration::from_millis(20));
    }
}

/// The pid the lock's holder wrote on its first line.
fn holder(lock: &Path) -> Option<i32> {
    cmux_blocking::fs::read_to_string(lock)
        .ok()
        .and_then(|text| text.lines().next()?.trim().parse::<i32>().ok())
        .filter(|pid| *pid > 1)
}

/// Whether process `pid` still runs.
fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    let found = unsafe { libc::kill(pid, 0) } == 0;
    found || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

fn timeout(pid: i32, limit: Duration) -> String {
    messages()
        .shutdown_timeout
        .replace("{pid}", &pid.to_string())
        .replace("{secs}", &limit.as_secs().to_string())
}

/// Stops the home's session daemon and its terminals (`daemon stop
/// --end-terminals` on its socket); a daemon that does not run is fine.
fn stop_daemon(global: &GlobalArgs, home: &ChiefHome) -> i32 {
    let Ok(socket) = home.socket() else {
        return 0;
    };
    if std::os::unix::net::UnixStream::connect(&socket).is_err() {
        return 0;
    }
    let global = GlobalArgs {
        socket: Some(socket),
        session: None,
        output: global.output,
        ..GlobalArgs::default()
    };
    let plan = crate::cli::lifecycle::ServerPlan {
        action: crate::cli::lifecycle::ServerAction::Stop {
            force: false,
            end_terminals: true,
            restore_wait: crate::local_owner::RESTORE_DEADLINE,
        },
        session: None,
    };
    crate::cli::lifecycle::run(global, plan)
}
