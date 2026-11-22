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
        let paths = RolePaths { store_bin: bin, state: dir.path().join("state"), work_user: None };
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

fn child_pid(fx: &Fixture, role: &str) -> u32 {
    let path = fx.paths.role_dir(role).join("child");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(pid) = std::fs::read_to_string(&path).ok().and_then(|s| s.trim().parse().ok()) {
            return pid;
        }
        assert!(Instant::now() < deadline, "no child pid in {}", path.display());
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn wait_dead(pid: u32) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while alive(pid) {
        assert!(Instant::now() < deadline, "pid {pid} still alive");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Review P2-a: a role whose grace outlasts the caller's deadline is killed
/// at the deadline, its whole group included.
#[test]
fn stop_kills_at_the_callers_deadline() {
    let fx = Fixture::new();
    fx.script(
        "stubborn",
        "trap '' TERM\nsleep 600 &\necho $! > \"$CMUX_ROLE_STATE_DIR/child\"\nwait",
    );
    let sup = Supervisor::start(fx.paths.clone()).unwrap();
    sup.apply(set(
        serde_json::json!({"stubborn": {"program": "stubborn", "stopGraceSeconds": 60}}),
    ));
    let child = child_pid(&fx, "stubborn");
    let started = Instant::now();
    let left = sup.stop_all(Instant::now() + Duration::from_secs(1));
    assert!(started.elapsed() < Duration::from_secs(6), "{:?}", started.elapsed());
    assert!(left.is_empty(), "{left:?}");
    wait_dead(child);
}

/// Review P2-b: when a role's leader exits, the rest of its group ends too.
#[test]
fn a_dead_leader_takes_its_group() {
    let fx = Fixture::new();
    fx.script("leaky", "sleep 600 &\necho $! > \"$CMUX_ROLE_STATE_DIR/child\"\nexit 1");
    let sup = Supervisor::start(fx.paths.clone()).unwrap();
    sup.apply(set(serde_json::json!({"leaky": {"program": "leaky", "restart": "never"}})));
    let child = child_pid(&fx, "leaky");
    wait_for(&sup, "exited", |h| state_of(h, "leaky") == Some(RoleState::Exited));
    wait_dead(child);
}

/// Review P2-c: a role that writes many status lines (more than the old
/// 1 MiB total) is not killed by SIGPIPE.
#[test]
fn many_status_lines_never_close_the_notify_pipe() {
    let fx = Fixture::new();
    fx.script(
        "chatty",
        "echo READY=1 >&3\ni=0\nwhile [ $i -lt 3000 ]; do\n\
         printf 'STATUS=%0500d\\n' $i >&3\ni=$((i+1))\ndone\necho STATUS=done >&3\nexec sleep 600",
    );
    let sup = Supervisor::start(fx.paths).unwrap();
    sup.apply(set(serde_json::json!({"chatty": {"program": "chatty", "ready": "notify"}})));
    let health = wait_for(&sup, "all status lines", |h| {
        h.first().is_some_and(|c| c.status_text.as_deref() == Some("done"))
    });
    assert_eq!(health[0].state, RoleState::Ready);
    assert_eq!(health[0].restarts, 0);
}

/// Least privilege under a root supervisor (server.md 5.1 "Root"): a role
/// runs as the work user with no supplementary groups, and a `runAsRoot`
/// entry is refused. Needs root, so it is ignored by default; run it with
/// `sudo <cmux-host test binary> --ignored roles_under_root_run_as_the_work_user`.
#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs root"]
fn roles_under_root_run_as_the_work_user() {
    // SAFETY: geteuid has no preconditions.
    assert_eq!(unsafe { libc::geteuid() }, 0, "run this test as root");
    let nobody = crate::linux::spawn::lookup_user("nobody").expect("user nobody");
    let mut fx = Fixture::new();
    std::fs::set_permissions(fx.dir.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let body = "id -u > \"$CMUX_ROLE_STATE_DIR/uid\"\nid -G > \"$CMUX_ROLE_STATE_DIR/groups\"\n\
                echo \"$HOME\" > \"$CMUX_ROLE_STATE_DIR/home\"\nexec sleep 600";
    fx.script("who", body);
    fx.paths.work_user = Some(super::super::privilege::WorkUser {
        name: nobody.name.clone(),
        uid: nobody.uid,
        gid: nobody.gid,
        home: nobody.home.clone(),
    });
    let sup = Supervisor::start(fx.paths.clone()).unwrap();
    sup.apply(set(serde_json::json!({
        "who": {"program": "who"},
        "rootwho": {"program": "who", "runAsRoot": true}
    })));
    let read = |role: &str, file: &str| {
        let path = fx.paths.role_dir(role).join(file);
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Ok(text) = std::fs::read_to_string(&path)
                && text.ends_with('\n')
            {
                return text.trim().to_owned();
            }
            assert!(Instant::now() < deadline, "no {}", path.display());
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    assert_eq!(read("who", "uid"), nobody.uid.to_string());
    assert_eq!(read("who", "groups"), nobody.gid.to_string());
    assert_eq!(read("who", "home"), nobody.home.display().to_string());
    let health = sup.health();
    assert_eq!(state_of(&health, "rootwho"), Some(RoleState::Invalid));
    assert!(!fx.paths.role_dir("rootwho").exists());
    use std::os::unix::fs::MetadataExt;
    assert_eq!(std::fs::metadata(fx.paths.role_dir("who")).unwrap().uid(), nobody.uid);
    assert!(sup.stop_all(Instant::now() + Duration::from_secs(5)).is_empty());
}

/// The app's reader fixture: `LocalServerStatusTests.roles` in
/// Packages/macOS/CmuxNext/Tests/CmuxNextServerTests/LocalServerStatusTests.swift
/// (its first, complete entry). Change both together.
const APP_READER_ROLES_FIXTURE: &str = r#"
{"roles": [
  {"name": "session", "state": "ready", "pid": 41, "restarts": 0, "last_exit": null, "last_error": null, "status_text": "ok"}
]}
"#;

/// The state spellings LocalServerStatus.roleState maps (others read as
/// unavailable in the app).
const APP_READER_STATES: [&str; 8] =
    ["ready", "starting", "backoff", "stopped", "stopping", "exited", "crash-loop", "invalid"];

/// `cmux host roles --json` (the status document) fits the app's reader:
/// the same top-level and entry keys as its fixture, and every state the
/// supervisor can report is one the app maps.
#[test]
fn roles_status_matches_the_app_reader_fixture() {
    use cmux_server_core::role_proc::{RoleHealth, RoleState};
    let fixture: serde_json::Value = serde_json::from_str(APP_READER_ROLES_FIXTURE).unwrap();
    let states = [
        RoleState::Stopped,
        RoleState::Starting,
        RoleState::Ready,
        RoleState::Stopping,
        RoleState::Backoff,
        RoleState::CrashLoop,
        RoleState::Exited,
        RoleState::Invalid,
    ];
    let roles: Vec<RoleHealth> = states
        .iter()
        .map(|state| RoleHealth {
            name: "session".to_owned(),
            state: *state,
            pid: Some(41),
            restarts: 0,
            last_exit: None,
            last_error: None,
            status_text: Some("ok".to_owned()),
        })
        .collect();
    let document = status_document(&roles);
    let keys = |v: &serde_json::Value| {
        v.as_object().unwrap().keys().cloned().collect::<std::collections::BTreeSet<_>>()
    };
    assert_eq!(keys(&document), keys(&fixture));
    let want = keys(&fixture["roles"][0]);
    for entry in document["roles"].as_array().unwrap() {
        assert_eq!(keys(entry), want, "{entry}");
        let state = entry["state"].as_str().unwrap();
        assert!(APP_READER_STATES.contains(&state), "the app does not map state {state}");
    }
    assert_eq!(document["roles"][2], fixture["roles"][0], "a ready role reads like the fixture");
    // The invalid entry of a refused config has the same keys.
    let invalid = status_document(&[RoleHealth::invalid("bad", "reason")]);
    assert_eq!(keys(&invalid["roles"][0]), want);
}
