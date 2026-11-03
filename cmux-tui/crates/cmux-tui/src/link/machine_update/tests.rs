use std::path::PathBuf;

use serde_json::json;

use super::{AfterLostStart, Request, ended, lost_start_began, machine_is_older, parse};

fn args(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parse_takes_the_flags_in_any_order() {
    let request =
        |to_bundled, if_older| Request { socket: PathBuf::from("/s"), to_bundled, if_older };
    assert_eq!(parse(&args("update --socket /s")), Some(request(false, false)));
    assert_eq!(parse(&args("update --socket /s --to-bundled")), Some(request(true, false)));
    assert_eq!(parse(&args("update --to-bundled --socket /s")), Some(request(true, false)));
    assert_eq!(
        parse(&args("update --socket /s --to-bundled --if-older")),
        Some(request(true, true))
    );
    assert_eq!(
        parse(&args("update --if-older --to-bundled --socket /s")),
        Some(request(true, true))
    );
}

#[test]
fn parse_refuses_bad_usage() {
    for line in [
        "",
        "update",
        "update --socket",
        "status --socket /s",
        "update --socket /s --if-older",
        "update --socket /s --to-bundled --to-bundled",
        "update --socket /s --socket /t",
        "update --socket /s --force",
    ] {
        assert_eq!(parse(&args(line)), None, "{line}");
    }
}

#[test]
fn a_machine_is_older_only_by_an_earlier_build_time() {
    let local = 1_793_095_467;
    // A daemon from before `build_time` in identify, or one that knows none.
    assert!(machine_is_older(None, local));
    assert!(machine_is_older(Some(0), local));
    assert!(machine_is_older(Some(local - 1), local));
    // The same source tree, or a newer build: never moved back.
    assert!(!machine_is_older(Some(local), local));
    assert!(!machine_is_older(Some(local + 1), local));
    // This client does not know its own time: no order.
    assert!(!machine_is_older(None, 0));
    assert!(!machine_is_older(Some(1), 0));
}

const OLD_PID: u64 = 4242;

fn seen(daemon_pid: Option<Option<u64>>, apply_seen: bool, staged_present: bool) -> bool {
    lost_start_began(&AfterLostStart { daemon_pid, apply_seen, staged_present }, OLD_PID)
}

#[test]
fn a_lost_start_whose_daemon_came_back_on_another_pid_began() {
    // The apply step replaced the daemon, which closed the start's connection
    // before it answered: the update goes on to its outcome, never a failure.
    assert!(seen(Some(Some(OLD_PID + 1)), false, false));
    assert!(seen(Some(Some(OLD_PID + 1)), false, true));
    // Mid-restart, no daemon answers.
    assert!(seen(None, false, true));
    // The staged build was renamed over the binary, or the step wrote its
    // outcome file (`running` while it still checks the staged build).
    assert!(seen(Some(Some(OLD_PID)), false, false));
    assert!(seen(Some(Some(OLD_PID)), true, true));
}

#[test]
fn a_lost_start_on_the_same_daemon_with_nothing_changed_is_started_again() {
    assert!(!seen(Some(Some(OLD_PID)), false, true));
}

fn code(state: &str) -> Result<String, &'static str> {
    ended(&json!({"state": state, "detail": "why"}), "own").map_err(|failed| failed.code)
}

#[test]
fn a_daemon_on_someone_elses_build_is_its_own_quiet_code_not_a_failure() {
    // Leo, 2026-11-02, on "Couldn't update leo-cloud: the daemon does not run
    // the installed binary": "WHY WOULD THIS STILL HAPPEN".
    assert_eq!(code("foreign"), Err("machine_update_foreign_daemon"));
    assert_eq!(code("busy"), Err("machine_update_busy"));
    assert_eq!(code("pending"), Err("machine_update_pending"));
    assert_eq!(code("rolled_back"), Err("machine_update_rolled_back"));
    assert_eq!(code("updated"), Ok("own".to_owned()));
    assert_eq!(code("failed"), Err("machine_update_failed"));
}
