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
