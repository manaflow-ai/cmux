//! `cmux status wait KEY [--target <ws>] [--until settled|cleared|state=<s>]
//! [--timeout D]` through a real daemon (cx-6so.14,
//! plans/cmux-next/status-indicators.md section 5): the wait follows the
//! session's event stream until the workspace status entry `KEY` holds the
//! condition, prints the entry, and fails a timeout with exit code 124.
//!
//! The default, `settled`, is the spec's `0 success/cleared, 1 error`: the
//! entry is gone (cleared, its owner ended or its TTL passed) or shows
//! `success` (exit 0), or shows `error` (exit 1).
use super::super::*;
use super::{entry, spawn_sleeper, status_output};

const SECONDS_10: Duration = Duration::from_secs(10);

fn new_workspace(server: &HeadlessServer, name: &str) -> String {
    state_cli(server, None, &["workspace", "create", "--name", name, "--empty"]);
    workspace_id_named(server, name)
}

/// `status set KEY --label KEY --target WORKSPACE` plus `extra`, from its
/// own process.
fn set(server: &HeadlessServer, workspace: &str, key: &str, extra: &[&str]) {
    let mut args = vec!["status", "set", key, "--label", key, "--target", workspace];
    args.extend(extra);
    assert_success(&status_output(server, None, &args));
}

fn spawn_wait(server: &HeadlessServer, workspace: &str, key: &str, args: &[&str]) -> Child {
    Command::new(bin())
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["status", "wait", key, "--target", workspace])
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

/// The wait's output once it exits, failing the test when it still runs
/// after `within`.
#[track_caller]
fn finished(mut child: Child, within: Duration) -> Output {
    if !wait_for_child_exit(&mut child, within) {
        let _ = child.kill();
        let output = child.wait_with_output().unwrap();
        panic!(
            "the wait did not return within {within:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    child.wait_with_output().unwrap()
}

/// The wait has not returned after a moment in which nothing changed.
#[track_caller]
fn assert_still_waiting(child: &mut Child) {
    std::thread::sleep(Duration::from_millis(800));
    if let Some(status) = child.try_wait().unwrap() {
        let mut stderr = String::new();
        if let Some(mut pipe) = child.stderr.take() {
            let _ = pipe.read_to_string(&mut stderr);
        }
        panic!("the wait returned before its condition held: {status}: {stderr}");
    }
}

#[track_caller]
fn assert_exit(output: &Output, code: i32) -> serde_json::Value {
    assert_eq!(output.status.code(), Some(code), "{}", String::from_utf8_lossy(&output.stderr));
    json_output(output)
}

/// Every condition that already holds answers at once: a key with no entry
/// is cleared (settled, exit 0), a success entry is settled (exit 0), an
/// error entry is settled with exit 1, and `--until state=busy` matches a
/// busy entry. Each prints the entry it saw.
#[test]
fn status_wait_returns_at_once_when_the_condition_holds() {
    let server = HeadlessServer::start("status-wait-now");
    let workspace = new_workspace(&server, "alpha");

    let shown =
        assert_exit(&finished(spawn_wait(&server, &workspace, "nothing", &[]), SECONDS_10), 0);
    assert_eq!(shown["key"], "nothing", "{shown}");
    assert_eq!(shown["cleared"], true, "{shown}");
    assert!(shown["entry"].is_null(), "{shown}");

    set(&server, &workspace, "built", &["--state", "success"]);
    let shown =
        assert_exit(&finished(spawn_wait(&server, &workspace, "built", &[]), SECONDS_10), 0);
    assert_eq!(shown["cleared"], false, "{shown}");
    assert_eq!(shown["entry"]["state"], "success", "{shown}");

    set(&server, &workspace, "broken", &["--state", "error"]);
    let shown =
        assert_exit(&finished(spawn_wait(&server, &workspace, "broken", &[]), SECONDS_10), 1);
    assert_eq!(shown["entry"]["state"], "error", "{shown}");

    set(&server, &workspace, "busy", &["--state", "busy"]);
    let shown = assert_exit(
        &finished(spawn_wait(&server, &workspace, "busy", &["--until", "state=busy"]), SECONDS_10),
        0,
    );
    assert_eq!(shown["entry"]["state"], "busy", "{shown}");
    let shown = assert_exit(
        &finished(spawn_wait(&server, &workspace, "nothing", &["--until", "cleared"]), SECONDS_10),
        0,
    );
    assert_eq!(shown["cleared"], true, "{shown}");
}

/// A wait blocks while the entry does not hold its condition and returns as
/// soon as another process changes it: a busy entry set to success settles
/// the default wait, `--until state=error` returns on the error write,
/// `--until cleared` returns on `status clear`, and an entry whose owner
/// process exits is cleared by the daemon.
#[test]
fn status_wait_returns_when_another_process_changes_the_entry() {
    let server = HeadlessServer::start("status-wait-later");
    let workspace = new_workspace(&server, "beta");

    set(&server, &workspace, "build", &["--state", "busy"]);
    let mut waiting = spawn_wait(&server, &workspace, "build", &["--timeout", "60s"]);
    assert_still_waiting(&mut waiting);
    // Another entry changing does not end the wait.
    set(&server, &workspace, "other", &["--state", "success"]);
    assert_still_waiting(&mut waiting);
    set(&server, &workspace, "build", &["--state", "success"]);
    let shown = assert_exit(&finished(waiting, SECONDS_10), 0);
    assert_eq!(shown["entry"]["state"], "success", "{shown}");
    assert_eq!(shown["workspace_id"], workspace.as_str(), "{shown}");

    let mut waiting = spawn_wait(&server, &workspace, "build", &["--until", "cleared"]);
    assert_still_waiting(&mut waiting);
    assert_success(&status_output(
        &server,
        None,
        &["status", "clear", "build", "--target", &workspace],
    ));
    let shown = assert_exit(&finished(waiting, SECONDS_10), 0);
    assert_eq!(shown["cleared"], true, "{shown}");

    set(&server, &workspace, "tests", &["--state", "busy"]);
    let mut waiting = spawn_wait(&server, &workspace, "tests", &["--until", "state=error"]);
    assert_still_waiting(&mut waiting);
    set(&server, &workspace, "tests", &["--state", "waiting"]);
    assert_still_waiting(&mut waiting);
    set(&server, &workspace, "tests", &["--state", "error"]);
    let shown = assert_exit(&finished(waiting, SECONDS_10), 0);
    assert_eq!(shown["entry"]["state"], "error", "{shown}");

    let mut owner = spawn_sleeper();
    let owner_pid = owner.id().to_string();
    set(&server, &workspace, "owned", &["--state", "busy", "--pid", &owner_pid]);
    assert!(entry(&server, &workspace, "owned").is_some());
    let mut waiting = spawn_wait(&server, &workspace, "owned", &["--until", "cleared"]);
    assert_still_waiting(&mut waiting);
    owner.kill().unwrap();
    owner.wait().unwrap();
    let shown = assert_exit(&finished(waiting, Duration::from_secs(20)), 0);
    assert_eq!(shown["cleared"], true, "{shown}");
}

/// A passed `--timeout` ends a wait whose condition never held with exit
/// 124 and `wait.timeout`, no earlier than the timeout.
#[test]
fn status_wait_times_out_with_exit_124() {
    let server = HeadlessServer::start("status-wait-timeout");
    let workspace = new_workspace(&server, "gamma");
    set(&server, &workspace, "build", &["--state", "busy"]);

    for args in [&["--timeout", "1s"][..], &["--until", "cleared", "--timeout", "1s"]] {
        let started = Instant::now();
        let output = finished(spawn_wait(&server, &workspace, "build", args), SECONDS_10);
        assert!(started.elapsed() >= Duration::from_secs(1), "{args:?} ended before its timeout");
        assert_eq!(output.status.code(), Some(124), "{}", String::from_utf8_lossy(&output.stderr));
        let error = json_error(&output);
        assert_eq!(error["code"], "wait.timeout", "{error}");
    }
    assert_eq!(entry(&server, &workspace, "build").unwrap()["state"], "busy");
}

/// No KEY, an unknown condition or state, or a timeout that is not a
/// duration, is a usage error (exit 2); the help lists the verb.
#[test]
fn status_wait_refuses_bad_usage_and_is_in_the_help() {
    let server = HeadlessServer::start("status-wait-usage");
    let workspace = new_workspace(&server, "delta");
    for args in [
        &["--until", "soon"][..],
        &["--until", "state=finished"],
        &["--timeout", "later"],
        &["extra-key"],
    ] {
        let output = finished(spawn_wait(&server, &workspace, "build", args), SECONDS_10);
        assert_eq!(
            output.status.code(),
            Some(2),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let output = status_output(&server, None, &["status", "wait", "--target", &workspace]);
    assert_eq!(output.status.code(), Some(2), "{}", String::from_utf8_lossy(&output.stderr));

    let help = Command::new(bin())
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .args(["status", "wait", "--help"])
        .output()
        .unwrap();
    assert_success(&help);
    let text = String::from_utf8(help.stdout).unwrap();
    assert!(text.contains("cmux status wait KEY"), "{text}");
}
