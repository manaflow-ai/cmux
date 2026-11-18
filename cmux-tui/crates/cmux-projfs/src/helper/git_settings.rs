//! git on a projected folder must not rehash the tree (hard case 2 of the design).
//!
//! The projection reports the Mac's size, mtime and ctime, but its inode and device numbers are
//! the machine's. With git's default stat checks every file then looks changed to `git status`,
//! which rehashes it and so reads, and faults from the Mac, the whole working tree. With
//! `core.checkStat=minimal` and `core.trustctime=false` git compares size and mtime only.
//!
//! The helper makes both hold for the machine's user (`git config --global`) after the overlay is
//! mounted, best effort: a machine without git, or a config git cannot write, never fails a mount.
//! Each command runs with an argument vector, stdin closed.

use std::ffi::OsStr;
use std::process::{Command, Stdio};

/// The settings, and the value each must have.
pub(super) const SETTINGS: [(&str, &str); 2] =
    [("core.checkStat", "minimal"), ("core.trustctime", "false")];

/// What [`ensure`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Outcome {
    /// At least one setting was written; both hold now.
    Set,
    /// Both already held.
    Kept,
    /// No git, or one setting could not be read or written.
    Unavailable,
}

impl Outcome {
    /// The word the ready line carries (`"git"`).
    pub(super) fn word(self) -> &'static str {
        match self {
            Outcome::Set => "set",
            Outcome::Kept => "kept",
            Outcome::Unavailable => "unavailable",
        }
    }
}

/// Makes [`SETTINGS`] hold in the global git config of this process's user.
pub(super) fn ensure() -> Outcome {
    ensure_with(OsStr::new("git"), &[])
}

/// [`ensure`] with `git` as the program and `env` added to its environment (tests point
/// `HOME` and `GIT_CONFIG_GLOBAL` at a folder of their own).
pub(super) fn ensure_with(git: &OsStr, env: &[(&str, &OsStr)]) -> Outcome {
    let mut wrote = false;
    for (key, value) in SETTINGS {
        match current(git, env, key) {
            Some(Some(now)) if now.eq_ignore_ascii_case(value) => continue,
            Some(_) => {}
            None => return Outcome::Unavailable,
        }
        if !run(git, env, &["config", "--global", key, value]).is_some_and(|out| out.0) {
            return Outcome::Unavailable;
        }
        wrote = true;
    }
    if wrote { Outcome::Set } else { Outcome::Kept }
}

/// The global value of `key`: `Some(None)` when it is not set, `None` when git cannot run.
fn current(git: &OsStr, env: &[(&str, &OsStr)], key: &str) -> Option<Option<String>> {
    let (ok, stdout, code) = run(git, env, &["config", "--global", "--get", key])?;
    match (ok, code) {
        (true, _) => Some(Some(stdout.trim().to_owned())),
        // `git config --get` exits 1 for a key that is not set.
        (false, Some(1)) => Some(None),
        _ => None,
    }
}

/// Runs `git args…`: whether it succeeded, its stdout and its exit code; `None` when it could
/// not start.
fn run(git: &OsStr, env: &[(&str, &OsStr)], args: &[&str]) -> Option<(bool, String, Option<i32>)> {
    let mut command = Command::new(git);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    for (name, value) in env {
        command.env(name, value);
    }
    let output = command.output().ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    Some((output.status.success(), stdout, output.status.code()))
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    /// A `HOME` of its own under the system temp folder, removed on drop.
    struct Home(PathBuf);

    impl Drop for Home {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn home() -> (Home, PathBuf) {
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("cmux-projfs-git-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("gitconfig");
        (Home(dir), config)
    }

    fn env<'a>(home: &'a Home, config: &'a Path) -> [(&'a str, &'a OsStr); 2] {
        [("HOME", home.0.as_os_str()), ("GIT_CONFIG_GLOBAL", config.as_os_str())]
    }

    #[test]
    fn the_settings_are_written_once_then_kept() {
        let (dir, config) = home();
        let env = env(&dir, &config);
        let git = OsStr::new("git");
        assert_eq!(ensure_with(git, &env), Outcome::Set);
        let text = std::fs::read_to_string(&config).unwrap();
        assert!(text.contains("checkStat = minimal"), "{text}");
        assert!(text.contains("trustctime = false"), "{text}");
        assert_eq!(ensure_with(git, &env), Outcome::Kept, "the second mount changes nothing");
        assert_eq!(std::fs::read_to_string(&config).unwrap(), text);
    }

    #[test]
    fn a_wrong_value_is_replaced_and_other_settings_stay() {
        let (dir, config) = home();
        std::fs::write(&config, "[core]\n\tcheckStat = default\n[user]\n\tname = agent\n").unwrap();
        let env = env(&dir, &config);
        assert_eq!(ensure_with(OsStr::new("git"), &env), Outcome::Set);
        let text = std::fs::read_to_string(&config).unwrap();
        assert!(text.contains("checkStat = minimal") && !text.contains("default"), "{text}");
        assert!(text.contains("name = agent"), "{text}");
    }

    #[test]
    fn no_git_is_unavailable_and_never_a_failure() {
        let (dir, config) = home();
        let env = env(&dir, &config);
        let missing = OsStr::new("cmux-projfs-no-such-git");
        assert_eq!(ensure_with(missing, &env), Outcome::Unavailable);
        assert!(!config.exists());
        assert_eq!(Outcome::Unavailable.word(), "unavailable");
    }
}
