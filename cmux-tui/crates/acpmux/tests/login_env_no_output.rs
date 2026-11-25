//! A login shell that never prints the environment is a failed read, never an empty one. A
//! startup file that replaces the shell before its command runs (`exec tmux` or `exec fish`
//! behind an interactive guard; the read's shell is interactive and has no terminal) printed
//! nothing, and that empty output was taken as the whole login environment: the cache of the
//! last good read was written over with no variables and no PATH, so agents started without the
//! person's PATH, also after the next restart.
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
async fn a_shell_that_prints_no_environment_keeps_the_last_good_read() {
    let root = scratch("env-none");
    let _ = HERMETIC;
    login_env::begin();
    login_env::import().await;
    assert_eq!(login_env::outcome(), Outcome::Shell);
    assert!(cache(&root).contains("OPENAI_BASE_URL"), "{}", cache(&root));
    // The startup file now replaces the shell before the read's command runs.
    std::fs::write(root.join("home/.zshrc"), format!("exec /bin/sh -c 'exit 0'\n{URL}")).unwrap();
    login_env::import().await;
    let kept = cache(&root);
    let outcome = login_env::outcome();
    let _ = std::fs::remove_dir_all(&root);
    assert_eq!(outcome, Outcome::Failed, "a shell that printed nothing was a read");
    assert!(kept.contains("OPENAI_BASE_URL"), "the last good read's cache was replaced: {kept}");
}
