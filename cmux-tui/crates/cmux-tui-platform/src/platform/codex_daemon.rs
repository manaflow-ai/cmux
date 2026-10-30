//! Whether a Codex hook runs inside Codex's shared app-server daemon.
//!
//! A reviewed exception to the no-process-scan rule
//! (`scripts/cmux-next/process-scan-baseline.tsv`, plans/cmux-next/pty-holder.md
//! section 4): no enumeration, only this process's own parent chain, at most
//! two levels, read once by a short-lived hook helper or the codex wrapper.
//! Codex gives a daemon-run hook nothing else to tell it apart: its
//! environment is the daemon's, inherited from whichever shell started it.

/// Whether this process runs for Codex's shared app-server daemon
/// (`codex app-server ... --managed-daemon`, started by the first Codex TUI
/// that needed it). That daemon keeps the environment of whichever shell
/// started it, so `CMUX_TUI_*` values seen by a hook it runs may belong to an
/// unrelated, possibly closed, terminal. Codex starts a hook or a tool command
/// as `$SHELL -lc <command>`: the hook's parent is that shell and its
/// grandparent the daemon, and a single-command tool (`codex ...` through the
/// shim, which execs) has the daemon as its parent. The walk stops there:
/// the daemon also hosts every Codex session's tool commands, so a process
/// further down (a cmux-tui server or a `cargo test` started by Codex, and
/// the shells, wrappers and hooks below it) is not running for the daemon.
/// A launcher between the daemon and the shell (a sandbox wrapper that
/// forks, or one that hides the daemon's argv) makes this return false, so
/// such a hook keeps the old behavior and posts by its inherited route.
pub fn descends_from_codex_app_server_daemon() -> bool {
    const MAX_ANCESTORS: usize = 2;
    // SAFETY: getppid has no preconditions.
    #[cfg(unix)]
    let mut pid = u32::try_from(unsafe { libc::getppid() }).ok();
    #[cfg(not(unix))]
    let mut pid: Option<u32> = None;
    for _ in 0..MAX_ANCESTORS {
        let Some(current) = pid.filter(|pid| *pid > 1) else { return false };
        if process_arguments(current).is_some_and(|argv| is_codex_app_server_daemon(&argv)) {
            return true;
        }
        pid = parent_process_id(current);
    }
    false
}

fn is_codex_app_server_daemon(argv: &[String]) -> bool {
    argv.iter().skip(1).any(|arg| arg == "app-server")
        && (argv.iter().any(|arg| arg == "--managed-daemon")
            || argv.first().is_some_and(|program| program.contains("/app-server-daemon/")))
}

#[cfg(target_os = "linux")]
pub(super) fn process_arguments(pid: u32) -> Option<Vec<String>> {
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let cmdline = cmdline.strip_suffix(&[0]).unwrap_or(&cmdline);
    Some(
        cmdline
            .split(|byte| *byte == 0)
            .map(|arg| String::from_utf8_lossy(arg).into_owned())
            .collect(),
    )
}

#[cfg(target_os = "linux")]
pub(super) fn parent_process_id(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // Fields after the parenthesized command name are state(3) ppid(4).
    let fields = stat.get(stat.rfind(')')? + 1..)?;
    fields.split_whitespace().nth(1)?.parse().ok()
}

#[cfg(target_os = "macos")]
pub(super) fn process_arguments(pid: u32) -> Option<Vec<String>> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut arg_max: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: the out pointer and size describe `arg_max`.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            std::ptr::from_mut(&mut arg_max).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 {
        return None;
    }
    let mut buffer = vec![0u8; usize::try_from(arg_max).ok()?];
    let mut size = buffer.len();
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    // SAFETY: the out pointer and size describe `buffer`.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 {
        return None;
    }
    // Layout: argc (int), the executable path, NUL padding, then argc
    // NUL-terminated arguments followed by the environment.
    let buffer = buffer.get(..size)?;
    let argc = usize::try_from(i32::from_ne_bytes(buffer.get(..4)?.try_into().ok()?)).ok()?;
    let mut rest = buffer.get(4..)?;
    let path_end = rest.iter().position(|byte| *byte == 0)?;
    rest = &rest[path_end..];
    let start = rest.iter().position(|byte| *byte != 0)?;
    rest = &rest[start..];
    let argv: Vec<String> = rest
        .split(|byte| *byte == 0)
        .take(argc)
        .map(|arg| String::from_utf8_lossy(arg).into_owned())
        .collect();
    (argv.len() == argc).then_some(argv)
}

#[cfg(target_os = "macos")]
pub(super) fn parent_process_id(pid: u32) -> Option<u32> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
    // SAFETY: proc_pidinfo writes at most `size` bytes into `info` and
    // returns the initialized byte count.
    let written = unsafe {
        libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
    };
    if written != size {
        return None;
    }
    // SAFETY: proc_pidinfo initialized the full structure.
    Some(unsafe { info.assume_init() }.pbi_ppid)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(super) fn process_arguments(_pid: u32) -> Option<Vec<String>> {
    None
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(super) fn parent_process_id(_pid: u32) -> Option<u32> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_app_server_daemon_is_recognized_only_by_its_daemon_argv() {
        let argv = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
        assert!(is_codex_app_server_daemon(&argv(&[
            "/home/me/.codex/packages/app-server-daemon/releases/0.162.1/bin/codex",
            "app-server",
            "--listen",
            "unix://",
            "--analytics-default-enabled",
            "--managed-daemon",
        ])));
        // An older managed binary without the startup flag.
        assert!(is_codex_app_server_daemon(&argv(&[
            "/home/me/.codex/packages/app-server-daemon/releases/0.161.0/bin/codex",
            "app-server",
            "--listen",
            "unix://",
        ])));
        // The embedded TUI, an editor's own app-server, and a prompt that
        // merely mentions the words.
        assert!(!is_codex_app_server_daemon(&argv(&["codex", "--enable", "hooks", "-c", "x=1"])));
        assert!(!is_codex_app_server_daemon(&argv(&["/opt/codex", "app-server"])));
        assert!(!is_codex_app_server_daemon(&argv(&["app-server", "--managed-daemon"])));
        assert!(!is_codex_app_server_daemon(&argv(&["codex", "explain app-server"])));
    }
}
