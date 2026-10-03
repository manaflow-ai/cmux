//! Process creation: the session host (direct spawn, `setsid`, dropped to
//! the work user like `setpriv --init-groups`) and helper jobs (low CPU
//! and idle I/O priority). Never through `systemd-run`: on a resumed clone
//! systemd waits about 1.8 s before it starts the first transient unit.

use std::ffi::{CStr, CString};
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

use crate::config::{Config, Paths};
use crate::daemon_spec::{DaemonLayout, DaemonSpec, LayoutKind, ROOT_HOME, WORK_HOME, WORK_USER, binary_path};

/// A passwd entry.
pub struct User {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub home: PathBuf,
}

/// `getpwnam_r`.
pub fn lookup_user(name: &str) -> Option<User> {
    let cname = CString::new(name).ok()?;
    let mut pwd = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut buf = vec![0 as libc::c_char; 16 * 1024];
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call; `result` is set to
    // `pwd` on success.
    let rc = unsafe { libc::getpwnam_r(cname.as_ptr(), pwd.as_mut_ptr(), buf.as_mut_ptr(), buf.len(), &mut result) };
    if rc != 0 || result.is_null() {
        return None;
    }
    // SAFETY: `result` points at the initialized `pwd`, whose strings
    // live in `buf`.
    let pwd = unsafe { pwd.assume_init() };
    let home = unsafe { CStr::from_ptr(pwd.pw_dir) }.to_string_lossy().into_owned();
    Some(User { name: name.to_owned(), uid: pwd.pw_uid, gid: pwd.pw_gid, home: PathBuf::from(home) })
}

/// The name of the effective user.
pub fn current_user_name() -> Option<String> {
    // SAFETY: getpwuid_r as above, keyed by uid.
    unsafe {
        let mut pwd = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut buf = vec![0 as libc::c_char; 16 * 1024];
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        let rc = libc::getpwuid_r(libc::geteuid(), pwd.as_mut_ptr(), buf.as_mut_ptr(), buf.len(), &mut result);
        if rc != 0 || result.is_null() {
            return None;
        }
        Some(CStr::from_ptr(pwd.assume_init().pw_name).to_string_lossy().into_owned())
    }
}

/// `getgrouplist`: the user's supplementary groups.
fn group_list(name: &str, gid: u32) -> Vec<u32> {
    let Ok(cname) = CString::new(name) else { return vec![gid] };
    let mut count: libc::c_int = 64;
    loop {
        let mut groups = vec![0 as libc::gid_t; count as usize];
        let before = count;
        // SAFETY: `groups` has `count` entries; the call updates `count`.
        let rc = unsafe { libc::getgrouplist(cname.as_ptr(), gid, groups.as_mut_ptr(), &mut count) };
        if rc >= 0 {
            groups.truncate(count.max(0) as usize);
            return groups;
        }
        if count <= before {
            return vec![gid];
        }
    }
}

fn layout_for(user: &User, kind: LayoutKind, home: PathBuf, bin: PathBuf) -> DaemonLayout {
    DaemonLayout {
        kind,
        user: user.name.clone(),
        uid: user.uid,
        gid: user.gid,
        groups: group_list(&user.name, user.gid),
        home,
        bin,
    }
}

fn on_path(program: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|path| std::env::split_paths(&path).any(|dir| is_executable(&dir.join(program))))
}

pub fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// `setpriv --reuid=cmux --regid=cmux --init-groups <argv>` succeeds.
fn as_work_user(argv: &[&str]) -> bool {
    Command::new("setpriv")
        .args(["--reuid", WORK_USER, "--regid", WORK_USER, "--init-groups"])
        .args(argv)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// The layout `cmuxTuiLayoutSelector()` picks: the work user only when it
/// exists, `setpriv` exists, its home is writable by it and it really has
/// passwordless sudo; anything else is the root layout. Overrides (tests)
/// name the user, home and binary directly.
pub fn select_layout(cfg: &Config) -> io::Result<DaemonLayout> {
    if let Some(name) = cfg.daemon.user.as_deref() {
        let user = lookup_user(name).ok_or_else(|| io::Error::other(format!("no user {name}")))?;
        let home = cfg.daemon.home.clone().unwrap_or_else(|| user.home.clone());
        let bin = cfg.daemon.bin.clone().unwrap_or_else(|| binary_path(&home));
        let kind = if user.uid == 0 { LayoutKind::Root } else { LayoutKind::User };
        return Ok(layout_for(&user, kind, home, bin));
    }
    let work = lookup_user(WORK_USER).filter(|_| {
        on_path("setpriv") && as_work_user(&["test", "-w", WORK_HOME]) && as_work_user(&["sudo", "-n", "true"])
    });
    let (user, kind, home) = match work {
        Some(user) => (user, LayoutKind::User, PathBuf::from(WORK_HOME)),
        None => (lookup_user("root").ok_or_else(|| io::Error::other("no root user"))?, LayoutKind::Root, PathBuf::from(ROOT_HOME)),
    };
    let bin = cfg.daemon.bin.clone().unwrap_or_else(|| binary_path(&home));
    Ok(layout_for(&user, kind, home, bin))
}

/// Unblocks every signal (the agent blocks SIGTERM, SIGINT and SIGCHLD for
/// its signalfd; children must not inherit that mask).
///
/// # Safety
/// Only async-signal-safe calls; runs between fork and exec.
unsafe fn reset_signal_mask() -> io::Result<()> {
    let mut set = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
    // SAFETY: sigemptyset initializes the set before sigprocmask reads it.
    unsafe {
        libc::sigemptyset(set.as_mut_ptr());
        if libc::sigprocmask(libc::SIG_SETMASK, set.as_ptr(), std::ptr::null_mut()) < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Spawns the session host: own session, the spec's user, groups, cwd and
/// environment, stdin from /dev/null, stdout and stderr to the agent's
/// (the journal). Drops privileges only when the target differs from the
/// agent's effective user.
pub fn spawn_daemon(spec: &DaemonSpec) -> io::Result<Child> {
    let mut command = Command::new(&spec.program);
    command.args(&spec.args).current_dir(&spec.cwd).stdin(Stdio::null());
    for name in &spec.remove_env {
        command.env_remove(name);
    }
    command.envs(spec.set_env.iter().map(|(k, v)| (k, v)));
    // SAFETY: geteuid has no preconditions.
    let drop_to = (spec.uid != unsafe { libc::geteuid() }).then(|| (spec.uid, spec.gid, spec.groups.clone()));
    // SAFETY: the closure makes only async-signal-safe calls and allocates
    // nothing (the group list is moved in before fork).
    unsafe {
        command.pre_exec(move || {
            reset_signal_mask()?;
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            if let Some((uid, gid, groups)) = &drop_to {
                if libc::setgroups(groups.len(), groups.as_ptr()) < 0
                    || libc::setgid(*gid) < 0
                    || libc::setuid(*uid) < 0
                {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    command.spawn()
}

/// Spawns a helper job in its own session. `low_priority`: nice 19 and the
/// idle I/O class, so it never competes with the session host's start.
pub fn spawn_job(program: &Path, args: &[String], low_priority: bool) -> io::Result<Child> {
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).env_remove("NOTIFY_SOCKET");
    // SAFETY: async-signal-safe calls only.
    unsafe {
        command.pre_exec(move || {
            reset_signal_mask()?;
            libc::setsid();
            if low_priority {
                libc::setpriority(libc::PRIO_PROCESS, 0, 19);
                // ioprio_set(IOPRIO_WHO_PROCESS, self, IOPRIO_CLASS_IDLE).
                libc::syscall(libc::SYS_ioprio_set, 1, 0, 3 << 13);
            }
            Ok(())
        });
    }
    command.spawn()
}

/// A program found on `PATH`.
pub fn which(program: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join(program)).find(|p| is_executable(p))
}

/// systemd is PID 1 on this root.
pub fn has_systemd(paths: &Paths) -> bool {
    paths.is_system_root() && paths.at(crate::config::SYSTEMD_RUNTIME_DIR).is_dir()
}
