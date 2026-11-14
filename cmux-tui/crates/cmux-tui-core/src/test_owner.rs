//! Nothing a test starts outlives the test process (cx-leo45).
//!
//! A daemon and its terminal hosts are detached on purpose (`setsid`), so a
//! test fixture that kills its daemon with SIGKILL, panics before its
//! teardown, or is stopped by nextest's time limit leaves them running: a
//! host waits for a restarted daemon to adopt it, and a debug build's host
//! ends its PTY only after its 10 minute orphan grace. A full
//! `cmux-tui-rust-check.sh test` run left 11 hosts with their shells and PTYs
//! this way (landq gate 20261104T222336), and earlier runs on macOS ran out
//! of PTYs (`kern.tty.ptmx_max`) in the middle of the run.
//!
//! So every process started under a test knows the test process: the first
//! `cmux-tui` process of a test ([`adopt`], under nextest only) names it in
//! [`TEST_OWNER_ENV`] as `<pid>:<start ms>`, and every process it starts
//! inherits that. A headless daemon stops with it as `--exit-with-pid` does
//! (its terminals end first), and a terminal host ends its terminal when it
//! exits ([`follow`]), also when the test ran its daemon in its own process
//! or killed it.
//!
//! The test process is found from this process alone, with no read of
//! another process (cmux-next never scans processes,
//! `check-no-process-scan.py`): nextest runs each test in a process group of
//! its own, so the test leads the group of everything it starts that did not
//! leave it (a fixture's shell wrapper, a short-lived CLI that starts the
//! daemon). A process that leads its own group (a test spawned it with
//! `process_group(0)`) names its parent instead.
//!
//! The app never sets the variable and never runs under nextest, so an
//! installed daemon and its hosts are unchanged: they outlive the app by
//! design.

use crate::server::Starter;

/// `<pid>:<start ms>` (or a bare `<pid>`) of the test process that every
/// process it started ends with.
pub const TEST_OWNER_ENV: &str = "CMUX_TUI_TEST_OWNER";

/// Set by nextest in every test process (and inherited by what it starts).
const NEXTEST_ENV: &str = "NEXTEST_RUN_ID";

/// Names the test process this process runs under in [`TEST_OWNER_ENV`],
/// when it runs under nextest and no process before it did.
///
/// # Safety
///
/// Writes the environment: call it while this process runs one thread only
/// (the first statements of `main`, or a terminal host before its threads).
pub unsafe fn adopt() {
    if std::env::var_os(TEST_OWNER_ENV).is_some() || std::env::var_os(NEXTEST_ENV).is_none() {
        return;
    }
    // SAFETY: getpgrp and getppid take no arguments and cannot fail.
    let (group, parent) = unsafe { (libc::getpgrp(), libc::getppid()) };
    let Some(test) = test_process(std::process::id(), group as u32, parent as u32) else {
        return;
    };
    let Some(starter) = Starter::current(test) else { return };
    // SAFETY: the caller runs this process on one thread.
    unsafe { std::env::set_var(TEST_OWNER_ENV, format!("{}:{}", starter.pid, starter.started_ms)) };
}

/// The test process this process was started for, from [`TEST_OWNER_ENV`];
/// `None` when it names none (or names this process).
pub fn owner() -> Option<Starter> {
    let value = std::env::var(TEST_OWNER_ENV).ok()?;
    parse(&value).filter(|starter| starter.pid != std::process::id())
}

/// Runs `on_exit` once on a thread of its own when the test process this
/// process was started for exits (at once when it already did). Nothing
/// happens without a test process ([`owner`]) or when the watch cannot start.
pub fn follow(on_exit: impl FnOnce() + Send + 'static) {
    let Some(starter) = owner() else { return };
    let spawned = std::thread::Builder::new().name("test-owner-exit".into()).spawn(move || {
        let pid = starter.pid;
        match crate::state::status_owners::wait_for_process_exit_if(pid, || starter.still_running())
        {
            Ok(()) => on_exit(),
            Err(error) => eprintln!("cmux-tui: cannot watch test process {pid}: {error}"),
        }
    });
    if let Err(error) = spawned {
        eprintln!("cmux-tui: cannot start the test process watch: {error}");
    }
}

/// `<pid>[:<start ms>]`; a pid of 0 or 1 names no process.
fn parse(value: &str) -> Option<Starter> {
    let (pid, started) = value.trim().split_once(':').unwrap_or((value.trim(), "0"));
    let pid = pid.parse::<u32>().ok().filter(|pid| *pid > 1 && i32::try_from(*pid).is_ok())?;
    Some(Starter { pid, started_ms: started.parse().ok()? })
}

/// The test process of a process `pid` in process group `group` with parent
/// `parent`: the group's leader, or the parent when `pid` leads its group;
/// `None` for init or no process.
fn test_process(pid: u32, group: u32, parent: u32) -> Option<u32> {
    let test = if group == pid { parent } else { group };
    (test > 1 && i32::try_from(test).is_ok()).then_some(test)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_test_process_leads_the_group_of_what_it_starts() {
        // A CLI the test ran through a shell: the shell and the CLI stay in
        // the test's group.
        assert_eq!(test_process(50, 30, 40), Some(30));
        // A daemon the test spawned in a group of its own.
        assert_eq!(test_process(50, 50, 30), Some(30));
    }

    #[test]
    fn init_or_no_process_names_no_test() {
        // A process that leads its group and was adopted by init.
        assert_eq!(test_process(50, 50, 1), None);
        assert_eq!(test_process(50, 0, 30), None);
        assert_eq!(test_process(50, 50, 0), None);
    }

    #[test]
    fn the_variable_names_a_pid_and_its_start_time() {
        assert_eq!(
            parse("4242:1700000000000"),
            Some(Starter { pid: 4242, started_ms: 1_700_000_000_000 })
        );
        assert_eq!(parse(" 4242\n"), Some(Starter { pid: 4242, started_ms: 0 }));
        assert_eq!(parse("1"), None);
        assert_eq!(parse("0:5"), None);
        assert_eq!(parse("x"), None);
        assert_eq!(parse("42:x"), None);
        assert_eq!(parse("4294967295"), None);
    }
}
