//! A startup file that leaves a background job holding the shell's output open (`cmd &` with
//! no redirection) does not fail the login read. The read waited for the end of the output,
//! which only the job's exit brings: every read ran into its 3 s limit, failed, and killed the
//! person's job with the shell's process group.
//!
//! One test: the login environment is process-wide (ACPMUX_HOME, HOME, SHELL).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The login shell is a stand-in (`loginsh`), as in `login_env_child_plan.rs`.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::login_env::{self, Outcome};
use std::path::{Path, PathBuf};

const URL: &str = "export OPENAI_BASE_URL=http://127.0.0.1:9/v1\n";

fn write_executable(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn scratch(tag: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-{tag}-{}", std::process::id()));
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
    std::fs::write(root.join("home/.zshrc"), URL).unwrap();
    // SAFETY: the only test in this binary; nothing else reads the env now.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("HOME", root.join("home"));
        std::env::set_var("SHELL", root.join("loginsh"));
        std::env::remove_var("OPENAI_BASE_URL");
    }
    root
}

fn cache(root: &Path) -> String {
    std::fs::read_to_string(root.join("acpmux/login-env.json")).unwrap_or_default()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_background_job_of_the_startup_file_neither_fails_the_read_nor_dies() {
    let root = scratch("env-bg");
    let _ = HERMETIC;
    let job = root.join("home/job");
    std::fs::write(root.join("home/.zshrc"), format!("(sleep 8 & echo $! > \"$HOME/job\")\n{URL}"))
        .unwrap();
    login_env::begin();
    let started = std::time::Instant::now();
    login_env::import().await;
    let took = started.elapsed();
    let outcome = login_env::outcome();
    let pid: i32 =
        std::fs::read_to_string(&job).ok().and_then(|t| t.trim().parse().ok()).unwrap_or(0);
    // SAFETY: signal 0 only asks whether the job runs.
    let alive = pid > 0 && unsafe { libc::kill(pid, 0) } == 0;
    if alive {
        // SAFETY: the job this test's startup file started.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    let cached = cache(&root);
    let _ = std::fs::remove_dir_all(&root);
    assert_eq!(outcome, Outcome::Shell, "the read failed after {took:?}");
    assert!(took < login_env::TIMEOUT, "the read waited for the job: {took:?}");
    assert!(cached.contains("OPENAI_BASE_URL"), "{cached}");
    assert!(alive, "the read killed the startup file's background job");
}
