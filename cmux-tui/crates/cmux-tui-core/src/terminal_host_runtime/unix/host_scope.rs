//! Per-host systemd scopes on Cloud Linux (cx-6so.49, L1).
//!
//! On a Cloud machine the daemon runs under the `cmux-tui-daemon` system
//! unit (`KillMode=control-group`), and every terminal host it spawns used
//! to stay in that unit's cgroup (`setsid` does not change the cgroup). A
//! `systemctl stop` or `restart` of the unit therefore ended every terminal.
//! With `CMUX_TUI_HOST_SCOPES=systemd` (set by the Cloud supervisor, never a
//! default) the daemon moves each new host into its own transient scope
//! `cmux-terminal-host-<pid>.scope` in `cmuxhosts.slice`, right
//! after it starts the host process and before the host gets a terminal. A
//! unit stop then leaves the hosts running for the next daemon to adopt; a
//! machine shutdown still stops every scope (systemd, PID 1, sends `SIGTERM`,
//! which a host honors). The shell a host starts inherits the host's scope.
//!
//! The move is `StartTransientUnit` with the host PID, through `busctl`. A
//! root daemon calls it directly; a daemon that runs as the Cloud user calls
//! it through `sudo -n` (that user has non-interactive sudo on Cloud
//! machines; `-n` never prompts). The host was already started with the
//! daemon's environment, so nothing is lost to sudo's environment reset. A
//! failed move is reported once and the host keeps running in the daemon's
//! unit, as before.

use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

/// The opt-in environment switch and its only accepted value.
pub(crate) const HOST_SCOPES_ENV: &str = "CMUX_TUI_HOST_SCOPES";
const HOST_SCOPES_SYSTEMD: &str = "systemd";
/// The slice every host scope joins.
/// Dash-free: systemd reads dashes in a slice name as nesting.
pub(crate) const HOST_SLICE: &str = "cmuxhosts.slice";
/// How long `place_host` waits for the move to show in the host's cgroup.
const PLACEMENT_WAIT: std::time::Duration = std::time::Duration::from_secs(2);

static REPORTED_FAILURE: AtomicBool = AtomicBool::new(false);

/// Whether this daemon moves hosts into their own scopes.
pub(crate) fn enabled() -> bool {
    std::env::var(HOST_SCOPES_ENV).is_ok_and(|value| value == HOST_SCOPES_SYSTEMD)
        && std::path::Path::new("/run/systemd/system").is_dir()
}

/// The scope unit name of the host with `pid`.
pub(crate) fn scope_unit(pid: u32) -> String {
    format!("cmux-terminal-host-{pid}.scope")
}

/// The `busctl` arguments that create the scope for `pid`.
pub(crate) fn busctl_args(pid: u32) -> Vec<String> {
    [
        "--system",
        "--quiet",
        "call",
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
        "ssa(sv)a(sa(sv))",
    ]
    .into_iter()
    .map(str::to_string)
    .chain([scope_unit(pid), "fail".into(), "3".into()])
    .chain(["PIDs".into(), "au".into(), "1".into(), pid.to_string()])
    .chain(["Slice".into(), "s".into(), HOST_SLICE.into()])
    .chain(["CollectMode".into(), "s".into(), "inactive-or-failed".into()])
    .chain(["0".into()])
    .collect()
}

/// The parent PID of `pid` from `/proc/<pid>/stat` (Linux).
fn parent_pid(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // The command name may hold spaces or parentheses: parse after the last ')'.
    stat.rsplit_once(')')?.1.split_whitespace().nth(1)?.parse().ok()
}

/// Move the freshly started host `pid` into its own scope when enabled.
/// `pid` must be a child this process spawned and has not reaped (its PID
/// cannot be reused); it is checked again against `/proc` before the call.
/// The argv is fixed (no shell). Best effort: a failure leaves the host in
/// the daemon's unit and never fails the terminal.
pub(crate) fn place_host(pid: u32) {
    if !enabled() {
        return;
    }
    if parent_pid(pid) != Some(std::process::id()) {
        if !REPORTED_FAILURE.swap(true, Ordering::AcqRel) {
            eprintln!("cmux-tui: terminal host {pid} is not this daemon's child; not moving it");
        }
        return;
    }
    // SAFETY: geteuid has no preconditions.
    let root = unsafe { libc::geteuid() } == 0;
    let mut command = if root {
        Command::new("busctl")
    } else {
        let mut sudo = Command::new("sudo");
        sudo.args(["-n", "--", "busctl"]);
        sudo
    };
    command.args(busctl_args(pid)).stdin(Stdio::null()).stdout(Stdio::null());
    let result = command.stderr(Stdio::piped()).output();
    let failure = match result {
        Ok(output) if output.status.success() => {
            // StartTransientUnit only queues the job. The host must not get
            // Launch (and fork its shell) before the move is done, or the
            // shell stays in the daemon unit. Bounded; fail open.
            if wait_until_placed(pid) {
                return;
            }
            format!("the scope did not take the host within {PLACEMENT_WAIT:?}")
        }
        Ok(output) => {
            format!("{}: {}", output.status, String::from_utf8_lossy(&output.stderr).trim())
        }
        Err(error) => error.to_string(),
    };
    if !REPORTED_FAILURE.swap(true, Ordering::AcqRel) {
        eprintln!(
            "cmux-tui: could not move terminal host {pid} into {}: {failure}; \
             hosts stay in the daemon unit and a unit stop ends them",
            scope_unit(pid)
        );
    }
}

/// Whether `/proc/<pid>/cgroup` text places `pid` in its own scope.
fn cgroup_names_scope(cgroup: &str, pid: u32) -> bool {
    let scope = format!("/{}", scope_unit(pid));
    cgroup.lines().any(|line| line.trim_end().ends_with(&scope))
}

/// Wait until the host's cgroup names its scope, at most PLACEMENT_WAIT.
fn wait_until_placed(pid: u32) -> bool {
    let deadline = std::time::Instant::now() + PLACEMENT_WAIT;
    loop {
        let cgroup = std::fs::read_to_string(format!("/proc/{pid}/cgroup")).unwrap_or_default();
        if cgroup_names_scope(&cgroup, pid) {
            return true;
        }
        if std::time::Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The move is complete only when the host's own cgroup names its scope:
    /// the host forks the shell right after Launch, and a shell forked
    /// before the move stays in the daemon unit (cx-6so.49 Cloud proof:
    /// a `systemctl restart` then killed it after the 90 s stop timeout).
    #[test]
    fn a_host_counts_as_placed_only_when_its_cgroup_names_its_scope() {
        let placed = "0::/cmuxhosts.slice/cmux-terminal-host-4242.scope\n";
        assert!(cgroup_names_scope(placed, 4242));
        assert!(!cgroup_names_scope(placed, 424));
        assert!(!cgroup_names_scope("0::/system.slice/cmux-tui-daemon.service\n", 4242));
        assert_eq!(HOST_SLICE, "cmuxhosts.slice", "a dash in a slice name nests slices");
    }

    #[test]
    fn scope_request_names_the_host_pid_and_the_host_slice() {
        let args = busctl_args(4242);
        let joined = args.join(" ");
        assert!(
            joined.contains(
                "StartTransientUnit ssa(sv)a(sa(sv)) cmux-terminal-host-4242.scope fail 3"
            ),
            "{joined}"
        );
        assert!(joined.contains("PIDs au 1 4242"), "{joined}");
        assert!(joined.contains(&format!("Slice s {HOST_SLICE}")), "{joined}");
        assert!(joined.ends_with("CollectMode s inactive-or-failed 0"), "{joined}");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn only_this_processs_child_is_recognized() {
        let mut child = Command::new("sleep").arg("5").spawn().unwrap();
        assert_eq!(parent_pid(child.id()), Some(std::process::id()));
        assert_ne!(parent_pid(1), Some(std::process::id()));
        let _ = child.kill();
        let _ = child.wait();
    }
}
