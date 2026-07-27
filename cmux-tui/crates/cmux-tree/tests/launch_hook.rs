#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

struct Fixture {
    root: PathBuf,
    codex_home: PathBuf,
    codex: PathBuf,
    log: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = PathBuf::from("/tmp").join(format!("cth-{}-{sequence}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let codex_home = root.join("codex-home");
        let codex = root.join("real-codex");
        let log = root.join("calls.log");
        fs::write(
            &codex,
            r#"#!/bin/sh
if [ "$1" = "app-server" ] && [ "$2" = "daemon" ] && [ "$3" = "start" ]; then
  printf 'daemon\n' >> "$CMUX_TREE_TEST_LOG"
  exit "${CMUX_TREE_TEST_DAEMON_STATUS:-0}"
fi
printf 'codex' >> "$CMUX_TREE_TEST_LOG"
for argument in "$@"; do
  printf '\t%s' "$argument" >> "$CMUX_TREE_TEST_LOG"
done
printf '\n' >> "$CMUX_TREE_TEST_LOG"
exit "${CMUX_TREE_TEST_CODEX_STATUS:-0}"
"#,
        )
        .unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o700)).unwrap();
        Self { root, codex_home, codex, log }
    }

    fn run(&self, arguments: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tree-hook"))
            .args(arguments)
            .env("CMUX_TREE_CODEX_PATH", &self.codex)
            .env("CODEX_HOME", &self.codex_home)
            .env("CMUX_TREE_TEST_LOG", &self.log)
            .env_remove("CMUX_TREE_HOOK_DEBUG")
            .output()
            .unwrap()
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(&self.log).unwrap_or_default().lines().map(str::to_owned).collect()
    }

    fn bind_daemon_socket(&self) -> UnixListener {
        let socket = self.codex_home.join("app-server-control/app-server-control.sock");
        fs::create_dir_all(socket.parent().unwrap()).unwrap();
        UnixListener::bind(socket).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn missing_daemon_is_started_before_interactive_codex() {
    let fixture = Fixture::new();

    let output = fixture.run(&["resume", "--last"]);

    assert!(output.status.success(), "{output:?}");
    assert_eq!(fixture.calls(), ["daemon", "codex\tresume\t--last"]);
}

#[test]
fn live_daemon_adds_no_subprocess_before_codex() {
    let fixture = Fixture::new();
    let _listener = fixture.bind_daemon_socket();

    let output = fixture.run(&["hello"]);

    assert!(output.status.success(), "{output:?}");
    assert_eq!(fixture.calls(), ["codex\thello"]);
}

#[test]
fn non_session_invocation_does_not_start_daemon() {
    let fixture = Fixture::new();

    let output = fixture.run(&["exec", "hello"]);

    assert!(output.status.success(), "{output:?}");
    assert_eq!(fixture.calls(), ["codex\texec\thello"]);
}

#[test]
fn daemon_start_failure_fails_open_to_normal_codex() {
    let fixture = Fixture::new();

    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tree-hook"))
        .arg("hello")
        .env("CMUX_TREE_CODEX_PATH", &fixture.codex)
        .env("CODEX_HOME", &fixture.codex_home)
        .env("CMUX_TREE_TEST_LOG", &fixture.log)
        .env("CMUX_TREE_TEST_DAEMON_STATUS", "9")
        .env_remove("CMUX_TREE_HOOK_DEBUG")
        .output()
        .unwrap();

    assert!(output.status.success(), "{output:?}");
    assert_eq!(fixture.calls(), ["daemon", "codex\thello"]);
    assert!(output.stderr.is_empty());
}

#[test]
fn hook_preserves_codex_exit_status() {
    let fixture = Fixture::new();

    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tree-hook"))
        .arg("--version")
        .env("CMUX_TREE_CODEX_PATH", &fixture.codex)
        .env("CODEX_HOME", &fixture.codex_home)
        .env("CMUX_TREE_TEST_LOG", &fixture.log)
        .env("CMUX_TREE_TEST_CODEX_STATUS", "23")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(23));
    assert_eq!(fixture.calls(), ["codex\t--version"]);
}
