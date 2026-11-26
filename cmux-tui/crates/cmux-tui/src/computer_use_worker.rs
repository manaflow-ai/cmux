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
    fn only_the_daemons_pipe_names_are_accepted() {
        assert!(super::control_name("cmux-cu-ctl-0a1b"));
        assert!(!super::control_name("cmux-cu-ctl-"));
        assert!(!super::control_name("cmux-cu-ctl-..\\x"));
        assert!(!super::control_name("other"));
    }
}
