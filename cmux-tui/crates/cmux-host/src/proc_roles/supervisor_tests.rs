#![cfg(unix)]

use super::*;
use cmux_server_core::role_spec::parse_roles;
use std::os::unix::fs::PermissionsExt;

use crate::proc_roles::tail;

struct Fixture {
    dir: tempfile::TempDir,
    paths: RolePaths,
}

impl Fixture {
    fn new() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        let paths = RolePaths { store_bin: bin, state: dir.path().join("state") };
        Fixture { dir, paths }
    }

    fn script(&self, name: &str, body: &str) {
        let path = self.paths.store_bin.join(name);
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
}

fn set(value: serde_json::Value) -> RoleSet {
    parse_roles(Some(&value))
}

/// Test-only wait: the health query is the only way to observe the thread.
fn wait_for(sup: &Supervisor, what: &str, ok: impl Fn(&[RoleHealth]) -> bool) -> Vec<RoleHealth> {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let health = sup.health();
        if ok(&health) {
            return health;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}: {health:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn state_of(health: &[RoleHealth], name: &str) -> Option<RoleState> {
    health.iter().find(|h| h.name == name).map(|h| h.state)
}

fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks existence.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

#[test]
fn notify_role_runs_logs_and_stops_with_its_group() {
    let fx = Fixture::new();
    fx.script(
        "chief",
        "echo hello from $CMUX_ROLE_NAME\necho STATUS=warming >&3\necho READY=1 >&3\n\
         sleep 600 &\nwait",
    );
    let sup = Supervisor::start(fx.paths.clone()).unwrap();
    sup.apply(set(serde_json::json!({"chief": {"program": "chief", "ready": "notify"}})));
    let health = wait_for(&sup, "ready", |h| state_of(h, "chief") == Some(RoleState::Ready));
    let chief = &health[0];
    assert_eq!(chief.status_text.as_deref(), Some("warming"));
    let pid = chief.pid.unwrap();
    let log_dir = fx.paths.log_dir();
    wait_for(&sup, "log line", |_| {
        tail(&log_dir, "chief", 1024).is_ok_and(|log| log == b"hello from chief\n")
    });
    let status = read_status(&status_path(&fx.paths)).unwrap();
    assert_eq!(status["roles"][0]["state"], "ready");
    let mode = std::fs::metadata(fx.paths.role_dir("chief")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o700);

    let left = sup.stop_all(Instant::now() + Duration::from_secs(10));
    assert!(left.is_empty(), "{left:?}");
    assert_eq!(state_of(&sup.health(), "chief"), Some(RoleState::Stopped));
    // The whole group ended, the background sleep too, and the leader was reaped.
    // SAFETY: signal 0 to the group only checks existence.
    assert_ne!(unsafe { libc::kill(-(pid as libc::pid_t), 0) }, 0);
    assert!(!alive(pid));
    drop(fx.dir);
}

#[test]
fn a_failed_run_restarts_after_backoff() {
    let fx = Fixture::new();
    let marker = fx.paths.state.join("ran-once");
    fx.script(
        "flaky",
        &format!("if [ -e '{0}' ]; then exec sleep 600; fi\ntouch '{0}'\nexit 3", marker.display()),
    );
    std::fs::create_dir_all(&fx.paths.state).unwrap();
    let sup = Supervisor::start(fx.paths).unwrap();
    sup.apply(set(serde_json::json!({"flaky": {"program": "flaky"}})));
    let health = wait_for(&sup, "restart", |h| {
        h.first().is_some_and(|f| f.restarts == 1 && f.state == RoleState::Ready)
    });
    assert_eq!(health[0].last_exit.as_deref(), Some("code 3"));
}

#[test]
fn config_changes_replace_remove_and_report_invalid_entries() {
    let fx = Fixture::new();
    fx.script("a", "exec sleep 600");
    fx.script("b", "exec sleep 600");
    let sup = Supervisor::start(fx.paths).unwrap();
    sup.apply(set(serde_json::json!({
        "a": {"program": "a"},
        "b": {"program": "b"},
        "c": {"program": "../x"}
    })));
    let health = wait_for(&sup, "both ready", |h| {
        state_of(h, "a") == Some(RoleState::Ready) && state_of(h, "b") == Some(RoleState::Ready)
    });
    assert_eq!(state_of(&health, "c"), Some(RoleState::Invalid));
    let pid_a = health.iter().find(|h| h.name == "a").unwrap().pid.unwrap();
    let pid_b = health.iter().find(|h| h.name == "b").unwrap().pid.unwrap();

    // `a` changes (new args) and `b` is removed.
    sup.apply(set(serde_json::json!({"a": {"program": "a", "args": ["x"]}})));
    let health = wait_for(&sup, "a replaced, b gone", |h| {
        h.len() == 1 && h[0].state == RoleState::Ready && h[0].pid.is_some_and(|pid| pid != pid_a)
    });
    assert_eq!(health[0].name, "a");
    assert!(!alive(pid_a) && !alive(pid_b));

    // An unchanged config keeps the same process.
    let pid = health[0].pid;
    sup.apply(set(serde_json::json!({"a": {"program": "a", "args": ["x"]}})));
    assert_eq!(sup.health()[0].pid, pid);
}

#[test]
fn a_missing_program_backs_off_with_the_reason() {
    let fx = Fixture::new();
    let sup = Supervisor::start(fx.paths).unwrap();
    sup.apply(set(serde_json::json!({"ghost": {"program": "ghost"}})));
    let health = wait_for(&sup, "backoff", |h| state_of(h, "ghost") == Some(RoleState::Backoff));
    assert!(health[0].last_error.as_deref().unwrap().contains("ghost"));
    assert!(sup.stop_all(Instant::now() + Duration::from_secs(5)).is_empty());
}
