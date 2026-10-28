//! `--exit-with-pid <pid>`: an owner started for one process (a test
//! harness) ends its terminals and stops when that process exits
//! (cmux-tui-core `server::exit_with_process`). `server ensure` takes it and
//! hands it to an owner it spawns, as with the reap grace; a running owner
//! keeps its own. The app never passes it: its owner outlives the app.

/// The option, on `server ensure` and on the owner's own command line.
pub(crate) const EXIT_WITH_PID_ARG: &str = "--exit-with-pid";

/// A process id above 1 (0 names no process; 1 never exits).
pub(crate) fn parse_exit_with_pid(value: &str) -> Result<u32, String> {
    value
        .parse::<u32>()
        .ok()
        .filter(|pid| *pid > 1 && i32::try_from(*pid).is_ok())
        .ok_or_else(|| format!("{EXIT_WITH_PID_ARG} needs a process id above 1"))
}

/// Starts the owner's watch. A watch that cannot start is reported and
/// leaves the owner running, as without the option.
pub(crate) fn exit_with(mux: &std::sync::Arc<cmux_tui_core::Mux>, pid: Option<u32>) {
    let Some(pid) = pid else { return };
    if let Err(error) = cmux_tui_core::server::exit_with_process(mux, pid) {
        crate::client_log::stderr_log!(
            "startup",
            "{BIN}: {EXIT_WITH_PID_ARG} {pid} unavailable: {error}"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::parse_exit_with_pid;

    #[test]
    fn exit_with_pid_takes_a_real_process_id() {
        assert_eq!(parse_exit_with_pid("4242"), Ok(4242));
        for invalid in ["", "0", "1", "-5", "x", "4294967295"] {
            assert!(parse_exit_with_pid(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn the_owner_takes_exit_with_pid_only_when_headless() {
        let parse = |argv: &[&str]| crate::parse_args_result(argv.iter().map(|a| a.to_string()));
        let owner = parse(&["--headless", "--exit-with-pid", "4242"]).unwrap();
        assert_eq!(owner.exit_with_pid, Some(4242));
        assert!(parse(&["--exit-with-pid", "4242"]).is_err());
        assert!(parse(&["--headless", "--exit-with-pid", "1"]).is_err());
        assert!(parse(&["--headless", "--exit-with-pid", "7", "--exit-with-pid", "8"]).is_err());
    }
}
