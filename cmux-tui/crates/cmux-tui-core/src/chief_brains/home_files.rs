//! The brain homes on disk: the lock a running brain holds, a deleted
//! Chief's folder, and the per-Chief acpmux homes of earlier builds. The
//! supervisor thread calls these (it may block); never a request thread.

use std::path::{Path, PathBuf};

use cmux_threads::checked::fs as files;

use cmux_agent_pane_policy::build_identity::{BuildIdentity, NIGHTLY_BUNDLE_ID};

use super::account_home;

/// Whether a process holds `lock` (`flock`, as optchat-chief's lock.rs
/// takes it). A missing file means no brain.
pub(super) fn lock_held(lock: &Path) -> bool {
    #[cfg(unix)]
    {
        let Ok(file) = files::open_with(files::File::options().read(true), lock) else {
            return false;
        };
        // The probe lock is released when `file` drops.
        files::advisory_lock(&file, libc::LOCK_EX | libc::LOCK_NB).is_err()
    }
    #[cfg(not(unix))]
    {
        let _ = lock;
        false
    }
}

/// Removes deleted Chief `chief`'s brain folder: a real folder only (never a link out of the
/// Chief home), whose `chief-id` names that Chief (never another Chief's with the same id tail),
/// and never while a brain still holds its lock (a stale holder that has not exited yet keeps
/// it; the folder then stays).
pub(super) fn remove_brain_home(dir: &Path, chief: &str) {
    let owner = files::read_to_string(dir.join("chief-id")).unwrap_or_default();
    if !files::symlink_metadata(dir).is_ok_and(|m| m.is_dir())
        || owner.trim() != chief
        || lock_held(&dir.join("state/host.lock"))
    {
        return;
    }
    if let Err(error) = files::remove_dir_all(dir) {
        eprintln!("cmux-tui: removing {}: {error}", dir.display());
    }
}

/// SIGTERM to the process that holds `lock` (a brain an earlier owner left),
/// by the pid optchat-chief writes in it.
pub(super) fn stop_lock_holder(lock: &Path) {
    #[cfg(unix)]
    if lock_held(lock)
        && let Some(pid) = files::read_to_string(lock)
            .ok()
            .and_then(|text| text.split_whitespace().next()?.parse::<i32>().ok())
            .filter(|pid| *pid > 1)
    {
        // SAFETY: kill and getpgid have no memory preconditions; the lock
        // is held, so its recorded holder is alive. A group leader (as this
        // supervisor starts brains) gets the signal for its whole group.
        let target = if unsafe { libc::getpgid(pid) } == pid { -pid } else { pid };
        // SAFETY: as above.
        unsafe { libc::kill(target, libc::SIGTERM) };
    }
    #[cfg(not(unix))]
    let _ = lock;
}

/// Removes the per-Chief acpmux homes `<home>/c/<tail>/a` that brains of
/// earlier builds used (before one acpmux per Chief home): `acpmux daemon
/// shutdown --end-agents` there first (that Chief's own daemon, not the shared one),
/// then the folder. Only inside this build's Chief home `home`, never in
/// the person's shared `~/.cmux/chief/default` (NIGHTLY's), and not while
/// a brain an earlier owner left holds that Chief's lock (it still uses
/// its acpmux; a later start removes it). Runs on the supervisor thread
/// before the first brain starts.
pub(super) fn remove_old_acpmux_homes(home: &Path, acpmux_bin: Option<&Path>) {
    // Without HOME the person's default home cannot be ruled out: keep all.
    let Some(user) = std::env::var_os("HOME").filter(|h| !h.is_empty()) else { return };
    // NIGHTLY's Chief home, named by the build identity resolver.
    let nightly = BuildIdentity::new(Some(NIGHTLY_BUNDLE_ID), None);
    let Ok(canonical) = files::canonicalize(home) else { return };
    // NIGHTLY's home under the inherited HOME and under the account's home
    // (a job runner's HOME differs from it).
    let defaults = [Some(PathBuf::from(user)), account_home().map(PathBuf::from)];
    if defaults.into_iter().flatten().any(|user| {
        files::canonicalize(nightly.chief_home(&user, "default")).ok().as_deref()
            == Some(canonical.as_path())
    }) {
        return;
    }
    let Ok(entries) = files::read_dir(home.join("c")) else { return };
    for entry in entries.flatten() {
        let chief_dir = home.join("c").join(entry.file_name());
        let old = chief_dir.join("a");
        // A real folder only: never follow a link out of the Chief home.
        let is_dir = files::symlink_metadata(&chief_dir).is_ok_and(|m| m.is_dir())
            && files::symlink_metadata(&old).is_ok_and(|m| m.is_dir());
        if !is_dir || lock_held(&chief_dir.join("state/host.lock")) {
            continue;
        }
        let acpmux = acpmux_bin.map(Path::to_path_buf).unwrap_or_else(|| "acpmux".into());
        let user = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
        let stop = |end_flag: bool| {
            let mut command = cmux_process::Command::new(&acpmux);
            command.args(["daemon", "shutdown"]);
            if end_flag {
                command.arg("--end-agents");
            }
            command
                .env_clear()
                .env("ACPMUX_HOME", &old)
                .stdin(cmux_process::Stdio::null())
                .stdout(cmux_process::Stdio::null())
                .stderr(cmux_process::Stdio::null());
            for key in ["PATH", "HOME", "USER", "TMPDIR"] {
                if let Some(value) = user(key) {
                    command.env(key, value);
                }
            }
            crate::request_path::note(crate::request_path::BlockingKind::ChildProcess);
            command.status().ok()
        };
        // On this thread only: `daemon shutdown --end-agents` ends that daemon's agents
        // first (acpmux bounds its own grace), then the folder goes. An acpmux of a build
        // before the flag refuses it (usage error, exit 2); its plain shutdown ends them.
        // A stop that failed (no acpmux to ask, or no daemon there: acpmux exits 1) removes the
        // folder only when no daemon holds its lock; a running one keeps it.
        let stopped = match stop(true) {
            Some(status) if status.code() == Some(2) => stop(false),
            other => other,
        };
        if !stopped.is_some_and(|status| status.success()) && lock_held(&old.join("daemon.lock")) {
            continue;
        }
        if let Err(error) = files::remove_dir_all(&old) {
            eprintln!("cmux-tui: removing {}: {error}", old.display());
        }
    }
}
