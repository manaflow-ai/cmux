//! `cmux-tui __computer-use-worker`: the Linux and Windows Computer Use
//! worker, started and supervised by the cmux-tui daemon
//! (cmux-tui-core `computer_use_host.rs`). Hidden: people and agents never
//! run it. Its stdin and stdout are the daemon's control channel
//! (`cmux_computer_use::worker`); it serves the agent socket until stdin
//! closes.
//!
//! A worker the daemon starts from session 0 through a scheduled task
//! (Windows) has no inherited pipes: `--control NAME` opens the daemon's
//! `\\.\pipe\NAME-in` and `\\.\pipe\NAME-out` instead.

/// Runs the worker; the process exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    if wants_no_new_privs(
        std::env::var(cmux_tui_core::computer_use_host::NO_NEW_PRIVS_ENV).ok().as_deref(),
    ) && let Err(error) = drop_privilege_gain()
    {
        // Asked for and not possible: no worker rather than one that can gain privileges.
        eprintln!("cmux Computer Use worker: cannot drop the right to gain privileges: {error}");
        return 1;
    }
    match args {
        [] => cmux_computer_use::worker::run_stdio(std::io::stdin().lock(), std::io::stdout()),
        [flag, name] if flag == "--control" && control_name(name) => control_pipes(name),
        _ => {
            eprintln!(
                "usage: cmux-tui {} [--control NAME]",
                cmux_tui_core::computer_use_host::WORKER_MODE
            );
            2
        }
    }
}

/// Whether the worker's env (`NO_NEW_PRIVS_ENV`) asks it to give up gaining privileges: `1` only.
fn wants_no_new_privs(value: Option<&str>) -> bool {
    value.is_some_and(|v| v.trim() == "1")
}

/// `PR_SET_NO_NEW_PRIVS` for this process; every child it starts inherits it.
#[cfg(target_os = "linux")]
fn drop_privilege_gain() -> std::io::Result<()> {
    // SAFETY: prctl with integer arguments only.
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "linux"))]
fn drop_privilege_gain() -> std::io::Result<()> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "no PR_SET_NO_NEW_PRIVS here"))
}

/// Only the daemon's own pipe names (`cmux-cu-ctl-<hex>`).
fn control_name(name: &str) -> bool {
    name.strip_prefix("cmux-cu-ctl-").is_some_and(|rest| {
        !rest.is_empty() && rest.len() <= 64 && rest.bytes().all(|b| b.is_ascii_hexdigit())
    })
}

#[cfg(windows)]
fn control_pipes(name: &str) -> i32 {
    let open = |suffix: &str, write: bool| {
        std::fs::OpenOptions::new()
            .read(!write)
            .write(write)
            .open(format!(r"\\.\pipe\{name}-{suffix}"))
    };
    match (open("in", false), open("out", true)) {
        (Ok(input), Ok(output)) => {
            cmux_computer_use::worker::run_stdio(std::io::BufReader::new(input), output)
        }
        (Err(error), _) | (_, Err(error)) => {
            eprintln!("cmux Computer Use worker: cannot open the control pipes: {error}");
            1
        }
    }
}

#[cfg(not(windows))]
fn control_pipes(_name: &str) -> i32 {
    eprintln!("cmux Computer Use worker: --control is for Windows");
    2
}

#[cfg(test)]
mod tests {
    #[test]
    fn only_one_asks_the_worker_to_give_up_gaining_privileges() {
        assert!(super::wants_no_new_privs(Some("1")));
        assert!(super::wants_no_new_privs(Some(" 1\n")));
        for other in [None, Some(""), Some("0"), Some("true"), Some("yes")] {
            assert!(!super::wants_no_new_privs(other), "{other:?}");
        }
    }

    #[test]
    fn only_the_daemons_pipe_names_are_accepted() {
        assert!(super::control_name("cmux-cu-ctl-0a1b"));
        assert!(!super::control_name("cmux-cu-ctl-"));
        assert!(!super::control_name("cmux-cu-ctl-..\\x"));
        assert!(!super::control_name("other"));
    }
}
