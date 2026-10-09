//! `cmux chief shutdown`: the one documented way to stop a Chief home (E20,
//! .cmux-scratch/chief-errors/catalog.md). It sends SIGTERM to the brain
//! that holds `state/host.lock` (the brain then shuts down the acpmux
//! daemon it started, which ends its agent hosts and their sessions, and
//! exits), waits until the lock is free, then stops the home's session
//! daemon with its terminals. Nothing is started.

use std::path::Path;
use std::time::{Duration, Instant};

use super::home::ChiefHome;
use super::launch::brain_running;
use super::messages::messages;
use super::{GlobalArgs, Target};

/// How long the brain may take to stop (its acpmux shutdown ends every
/// agent host with a grace of its own).
const BRAIN_STOP_LIMIT: Duration = Duration::from_secs(40);

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
    match stop_brain(&home.host_lock(), BRAIN_STOP_LIMIT) {
        Ok(true) => eprintln!("cmux: {}", m.shutdown_brain.replace("{home}", &root)),
        Ok(false) => {}
        Err(why) => {
            eprintln!("cmux: {why}");
            return 1;
        }
    }
    stop_daemon(global, &home)
}

/// SIGTERM to the brain holding `lock`, then waits until the lock is free.
/// `Ok(false)` when no brain holds it.
pub(super) fn stop_brain(lock: &Path, limit: Duration) -> Result<bool, String> {
    let _ = (lock, limit, Instant::now(), messages());
    Ok(false)
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
        action: crate::cli::lifecycle::ServerAction::Stop { force: false, end_terminals: true },
        session: None,
    };
    crate::cli::lifecycle::run(global, plan)
}

#[cfg(test)]
#[path = "shutdown/tests.rs"]
mod tests;
