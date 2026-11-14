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

/// The test process this owner runs under (`cmux_tui_core::test_owner`,
/// cx-leo45), for an owner no `--exit-with-pid` names one for: a fixture that
/// kills its daemon, panics or times out leaves no terminal behind.
#[cfg(any(target_vendor = "apple", target_os = "linux"))]
pub(crate) fn test_owner_exit_with() -> Option<ExitWith> {
    cmux_tui_core::test_owner::owner()
        .map(|starter| ExitWith { pid: starter.pid, started_ms: starter.started_ms })
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
mod tests;
