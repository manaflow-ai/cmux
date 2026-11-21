//! `cmux vm runner|pool ...` reach their own handlers, never the app's Cloud action (`vm VERB` is
//! `cloud VERB` for every word `vm` does not own). Run as the built binary, with no app and no
//! CMUX_* environment: a live end-to-end run once answered `usage: cmux cloud <action>` (exit 2)
//! for both words.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn run(args: &[&str]) -> (i32, String, String) {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cxr-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("cmux")).unwrap();
    let mut command = Command::new(dir.join("cmux"));
    command.args(args).current_dir(&dir).env("HOME", &dir).env("TMPDIR", &dir);
    for (name, _) in std::env::vars() {
        if name.starts_with("CMUX") {
            command.env_remove(name);
        }
    }
    let out = command.output().unwrap();
    let _ = fs::remove_dir_all(&dir);
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn vm_runner_help_prints_the_runner_help_with_no_app() {
    for args in [&["vm", "runner", "--help"][..], &["vm", "runner", "new", "--help"]] {
        let (code, stdout, stderr) = run(args);
        assert_eq!(code, 0, "{args:?}: {stderr}");
        assert!(stdout.contains("usage: cmux vm runner <verb>"), "{args:?}: {stdout}{stderr}");
        assert!(!stderr.contains("cmux cloud <action>"), "{args:?}: {stderr}");
    }
}

#[test]
fn vm_pool_is_not_sent_to_the_cloud_action() {
    let (_, stdout, stderr) = run(&["vm", "pool", "--help"]);
    assert!(!format!("{stdout}{stderr}").contains("cmux cloud <action>"), "{stdout}{stderr}");
}
