//! A login shell read that fails at the daemon's start (a startup file slower than
//! `login_env::TIMEOUT`: a first `compinit`, a version manager's update, a cold disk) is read
//! again at a later spawn's check, as a failed refresh already is. Before, the failed read kept
//! the startup files' fingerprint, so every later check found "no change" and every agent of
//! that daemon started without the person's PATH and exports until a startup file was edited
//! or the daemon restarted.
//!
//! One test: the login environment is process-wide (ACPMUX_HOME, HOME, SHELL).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The login shell is a stand-in (`loginsh`), as in `login_env_child_plan.rs`.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::login_env::{self, Outcome};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn write_executable(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-env-retry-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    for sub in ["home", "acpmux"] {
        std::fs::create_dir_all(root.join(sub)).unwrap();
    }
    let root = std::fs::canonicalize(&root).unwrap();
    // A login shell that sources `~/.zshrc`, then runs the `-c` script.
    write_executable(
        &root.join("loginsh"),
        "#!/bin/sh\nfor a; do last=$a; done\n. \"$HOME/.zshrc\"\neval \"$last\"\n",
    );
    // Slow while `~/slow` exists: a condition of the machine, not an edit of a startup file.
    std::fs::write(
        root.join("home/.zshrc"),
        "[ -f \"$HOME/slow\" ] && sleep \"$(cat \"$HOME/slow\")\"\nexport OPENAI_BASE_URL=http://127.0.0.1:9/v1\n",
    )
    .unwrap();
    root
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_login_read_that_failed_at_start_is_read_again_at_a_later_check() {
    let root = scratch();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("HOME", root.join("home"));
        std::env::set_var("SHELL", root.join("loginsh"));
        std::env::remove_var("OPENAI_BASE_URL");
    }
    let _ = HERMETIC;
    // The daemon starts while the shell is slower than the read's limit.
    std::fs::write(root.join("home/slow"), "30").unwrap();
    login_env::begin();
    login_env::import().await;
    assert_eq!(login_env::outcome(), Outcome::Failed, "the slow read did not fail");

    // The machine is fast again; no startup file changed. Past the spawn check's limit (10 s
    // after `begin`), a spawn's check reads the shell again.
    std::fs::remove_file(root.join("home/slow")).unwrap();
    tokio::time::sleep(Duration::from_secs(11)).await;
    login_env::refresh_if_changed();
    let deadline = Instant::now() + Duration::from_secs(10);
    while login_env::outcome() != Outcome::Shell && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(
        login_env::outcome(),
        Outcome::Shell,
        "a spawn's check after the failed startup read never read the shell again"
    );
    let cache = std::fs::read_to_string(root.join("acpmux/login-env.json")).unwrap();
    assert!(cache.contains("OPENAI_BASE_URL"), "the second read was not cached: {cache}");
    let _ = std::fs::remove_dir_all(&root);
}
