//! `--exit-with-pid`: an owner started for one process (a test harness)
//! ends its terminals and stops when that process exits (cmux-tui-core
//! `server::exit_with_process`). `server ensure --exit-with-pid <pid>` reads
//! that process's start time and hands `<pid>:<start ms>` to an owner it
//! spawns, so a reused pid never stands in for it; a running owner keeps its
//! own. The app never passes it: its owner outlives the app. macOS and Linux
//! only (a kqueue or pidfd exit watch); elsewhere the option is refused.

/// The option, on `server ensure` and on the owner's own command line.
pub(crate) const EXIT_WITH_PID_ARG: &str = "--exit-with-pid";

/// The process an owner ends with: its pid and kernel start time in
/// milliseconds (0 when unknown).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ExitWith {
    pub pid: u32,
    pub started_ms: u64,
}

impl ExitWith {
    /// The owner's argument value.
    pub(crate) fn arg(self) -> String {
        format!("{}:{}", self.pid, self.started_ms)
    }
}

fn parse_pid(value: &str) -> Result<u32, String> {
    if !cfg!(any(target_vendor = "apple", target_os = "linux")) {
        return Err(format!("{EXIT_WITH_PID_ARG} is unsupported on {}", std::env::consts::OS));
    }
    value
        .parse::<u32>()
        .ok()
        .filter(|pid| *pid > 1 && i32::try_from(*pid).is_ok())
        .ok_or_else(|| format!("{EXIT_WITH_PID_ARG} needs a process id above 1"))
}

/// `server ensure --exit-with-pid <pid>`: the running process `pid` and its
/// start time. A process that is already gone is refused.
pub(crate) fn resolve_exit_with_pid(value: &str) -> Result<ExitWith, String> {
    let pid = parse_pid(value)?;
    current(pid).ok_or_else(|| format!("{EXIT_WITH_PID_ARG} {pid}: no such process"))
}

#[cfg(any(target_vendor = "apple", target_os = "linux"))]
fn current(pid: u32) -> Option<ExitWith> {
    cmux_tui_core::server::Starter::current(pid)
        .map(|starter| ExitWith { pid, started_ms: starter.started_ms })
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
fn current(_pid: u32) -> Option<ExitWith> {
    None
}

/// The owner's `--exit-with-pid <pid>:<start ms>` (the start time may be
/// left out, as when started by hand: then the pid alone names it).
pub(crate) fn parse_owner_exit_with(value: &str) -> Result<ExitWith, String> {
    let (pid, started) = value.split_once(':').unwrap_or((value, "0"));
    let started_ms = started
        .parse::<u64>()
        .map_err(|_| format!("{EXIT_WITH_PID_ARG} needs <pid>[:<start ms>]"))?;
    Ok(ExitWith { pid: parse_pid(pid)?, started_ms })
}

/// Starts the owner's watch. A watch that cannot start is reported and
/// leaves the owner running, as without the option.
#[cfg(any(target_vendor = "apple", target_os = "linux"))]
pub(crate) fn exit_with(mux: &std::sync::Arc<cmux_tui_core::Mux>, exit_with: Option<ExitWith>) {
    let Some(ExitWith { pid, started_ms }) = exit_with else { return };
    let starter = cmux_tui_core::server::Starter { pid, started_ms };
    if let Err(error) = cmux_tui_core::server::exit_with_process(mux, starter) {
        crate::client_log::stderr_log!(
            "startup",
            "{BIN}: {EXIT_WITH_PID_ARG} {pid} unavailable: {error}"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::{ExitWith, parse_owner_exit_with, resolve_exit_with_pid};

    #[cfg(any(target_vendor = "apple", target_os = "linux"))]
    #[test]
    fn exit_with_pid_takes_a_live_process_and_its_start_time() {
        let me = std::process::id();
        let resolved = resolve_exit_with_pid(&me.to_string()).unwrap();
        assert_eq!(resolved.pid, me);
        assert_ne!(resolved.started_ms, 0, "ensure records a known start time");
        assert_eq!(parse_owner_exit_with(&resolved.arg()), Ok(resolved));
        assert_eq!(parse_owner_exit_with("4242"), Ok(ExitWith { pid: 4242, started_ms: 0 }));
        for invalid in ["", "0", "1", "-5", "x", "4294967295", "4242:x"] {
            assert!(parse_owner_exit_with(invalid).is_err(), "{invalid}");
        }
        let mut gone = cmux_process::Command::new("true").spawn().unwrap();
        let pid = gone.id();
        gone.wait().unwrap();
        assert!(resolve_exit_with_pid(&pid.to_string()).is_err());
    }

    #[cfg(any(target_vendor = "apple", target_os = "linux"))]
    #[test]
    fn the_owner_takes_exit_with_pid_only_when_headless() {
        let parse = |argv: &[&str]| crate::parse_args_result(argv.iter().map(|a| a.to_string()));
        let owner = parse(&["--headless", "--exit-with-pid", "4242:17"]).unwrap();
        assert_eq!(owner.exit_with_pid, Some(ExitWith { pid: 4242, started_ms: 17 }));
        assert!(parse(&["--exit-with-pid", "4242"]).is_err());
        assert!(parse(&["--headless", "--exit-with-pid", "1"]).is_err());
        assert!(parse(&["--headless", "--exit-with-pid", "7", "--exit-with-pid", "8"]).is_err());
    }

    /// No exit watch on this platform: the option is refused, never ignored.
    #[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
    #[test]
    fn exit_with_pid_is_refused_where_no_exit_watch_exists() {
        assert!(resolve_exit_with_pid(&std::process::id().to_string()).is_err());
        assert!(parse_owner_exit_with("4242:17").is_err());
        let parse = |argv: &[&str]| crate::parse_args_result(argv.iter().map(|a| a.to_string()));
        assert!(parse(&["--headless", "--exit-with-pid", "4242"]).is_err());
        let _ = ExitWith { pid: 0, started_ms: 0 };
    }
}
