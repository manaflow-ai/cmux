use super::*;

fn update(u: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"update": u}})
}

/// One check call of `command` in `session`, finished with `status` and `output`.
fn run(session: &str, id: &str, command: &str, status: &str, output: &str) {
    watch(session, &update(json!({"toolCallId": id, "rawInput": {"command": command}})));
    watch(session, &update(json!({"toolCallId": id, "status": status, "rawOutput": output})));
}

fn end(session: &str) -> Value {
    let mut msg = json!({"status": "completed"});
    stamp(session, &mut msg);
    msg
}

#[test]
fn the_trigger_is_off_unless_its_setting_is_true() {
    assert!(!enabled_with(None, None));
    let on = json!({"agents": {"harnessMagic": {"bestOfN": {"enabled": true}}}});
    assert!(enabled_with(Some(&on), None));
    assert!(!enabled_with(Some(&on), Some("0")));
    assert!(enabled_with(None, Some("1")));
    let off = json!({"agents": {"harnessMagic": {"bestOfN": {"enabled": false}}}});
    assert!(!enabled_with(Some(&off), None));
}

#[test]
fn checks_are_tests_builds_and_type_checks_not_other_commands() {
    for c in [
        "cargo test -p acpmux --lib",
        "cd cmux-tui && cargo clippy",
        "cmux-ci test -- bash -c \"cargo test\"",
        "pnpm run typecheck",
        "npx tsc --noEmit",
        "python3 -m pytest tests",
        "go test ./...",
    ] {
        assert!(is_check(c), "{c}");
    }
    for c in ["git status", "ls -la", "cat Cargo.toml", "echo test"] {
        assert!(!is_check(c), "{c}");
    }
}

#[test]
fn the_second_red_run_of_one_check_in_a_row_makes_it_due() {
    let s = "bon-two-reds";
    begin(s, true);
    run(s, "a", "cargo test -p x", "failed", "test result: FAILED. 1 passed; 1 failed");
    let first = end(s);
    assert_eq!(first["bestOfN"], json!({"due": false, "check": "cargo test -p x", "reds": 1}));
    assert_eq!(first["harnessMagic"]["bestOfN"]["due"], 0);
    // The task's next turn: the same check, red again.
    begin(s, true);
    run(s, "b", "cargo  test -p x", "completed", "Exit code 101\ntest result: FAILED.");
    let second = end(s);
    assert_eq!(second["bestOfN"], json!({"due": true, "check": "cargo test -p x", "reds": 2}));
    assert_eq!(second["harnessMagic"]["bestOfN"]["due"], 1);
    assert_eq!(second["harnessMagic"]["bestOfN"]["checks"], 1);
    assert_eq!(second["harnessMagic"]["bestOfN"]["reds"], 1);
}

#[test]
fn a_green_run_between_two_reds_ends_the_streak() {
    let s = "bon-green-between";
    begin(s, true);
    run(s, "a", "cargo check", "failed", "error: could not compile `x`");
    run(s, "b", "cargo check", "completed", "Finished `dev` profile");
    run(s, "c", "cargo check", "failed", "error: could not compile `x`");
    let msg = end(s);
    assert_eq!(msg["bestOfN"]["due"], false);
    assert_eq!(msg["bestOfN"]["reds"], 1);
    assert_eq!(msg["harnessMagic"]["bestOfN"]["checks"], 3);
}

#[test]
fn a_wrapper_that_exits_zero_but_prints_a_failure_is_red() {
    let s = "bon-wrapper";
    begin(s, true);
    run(s, "a", "cmux-ci test -- cargo test", "completed", "cmux-ci test: FAILURE route=x");
    run(s, "b", "cmux-ci test -- cargo test", "completed", "lane-gh ci: FAILURE https://x");
    assert_eq!(end(s)["bestOfN"]["due"], true);
}

#[test]
fn two_different_checks_red_once_each_are_not_due() {
    let s = "bon-two-checks";
    begin(s, true);
    run(s, "a", "cargo test -p a", "failed", "");
    run(s, "b", "cargo test -p b", "failed", "");
    let msg = end(s);
    assert_eq!(msg["bestOfN"]["due"], false);
    assert_eq!(msg["harnessMagic"]["bestOfN"]["reds"], 2);
}

#[test]
fn off_watches_nothing_and_drops_the_streaks() {
    let s = "bon-off";
    begin(s, true);
    run(s, "a", "cargo test", "failed", "");
    begin(s, false);
    run(s, "b", "cargo test", "failed", "");
    let msg = end(s);
    assert!(msg.get("bestOfN").is_none());
    assert!(msg.get("harnessMagic").is_none());
    // A chat this daemon never saw start a turn is not watched either.
    run("bon-never", "a", "cargo test", "failed", "");
    assert!(end("bon-never").get("bestOfN").is_none());
}

#[test]
fn a_turn_with_no_check_and_no_open_streak_is_left_alone() {
    let s = "bon-quiet";
    begin(s, true);
    watch(s, &update(json!({"toolCallId": "a", "rawInput": {"command": "git status"}})));
    watch(s, &update(json!({"toolCallId": "a", "status": "failed"})));
    assert_eq!(end(s), json!({"status": "completed"}));
}
