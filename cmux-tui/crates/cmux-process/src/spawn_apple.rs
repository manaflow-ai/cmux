//! macOS: `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`. The child gets
//! exactly descriptors 0-2 and the `inherit_fd` ones; every other descriptor
//! of this process closes at the exec, whatever its close-on-exec flag says
//! at that moment.

use std::collections::BTreeSet;
use std::ffi::{CString, OsStr, OsString};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::process::{ChildStderr, ChildStdin, ChildStdout};

use crate::child::Child;
use crate::command::Command;
use crate::stdio::{Kind, Stdio};

// From <spawn.h>; not bound by the pinned libc.
const POSIX_SPAWN_SETSID: libc::c_short = 0x0400;
unsafe extern "C" {
    fn posix_spawn_file_actions_addchdir_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        path: *const libc::c_char,
    ) -> libc::c_int;
    fn posix_spawn_file_actions_addinherit_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        fd: libc::c_int,
    ) -> libc::c_int;
}

/// Spawn `command`; its streams and inherited descriptors are used up.
pub(crate) fn spawn(command: &mut Command) -> io::Result<Child> {
    let env = child_env(command);
    let path = resolve(&command.program, command, &env)?;
    let argv0 = command.arg0.clone().unwrap_or_else(|| command.program.clone());
    let argv: Vec<CString> = std::iter::once(&argv0)
        .chain(&command.args)
        .map(|arg| c_string(arg))
        .collect::<io::Result<_>>()?;
    let envp: Vec<CString> = env
        .iter()
        .map(|(key, value)| {
            let mut pair = key.clone();
            pair.push("=");
            pair.push(value);
            c_string(&pair)
        })
        .collect::<io::Result<_>>()?;
    let path = c_string(path.as_os_str())?;
    let cwd = command.cwd.as_ref().map(|dir| c_string(dir.as_os_str())).transpose()?;

    // The child's descriptor plan: (source, target). Parent ends of pipes
    // go to the Child; the child ends and every source close after the spawn.
    let mut plan: Vec<(Source, RawFd)> = Vec::new();
    let mut parents: [Option<OwnedFd>; 3] = [None, None, None];
    let stdin_path =
        command.stdin_path.take().map(|path| c_string(path.as_os_str())).transpose()?;
    let streams = [command.stdin.take(), command.stdout.take(), command.stderr.take()];
    for (target, stream) in streams.into_iter().enumerate() {
        let target = target as RawFd;
        // `open_stdin_path`: opened read-write on 0 first, and 1 and 2 not
        // set are copies of it (the actions run in this order).
        if let Some(path) = &stdin_path
            && stream.is_none()
        {
            plan.push((
                if target == 0 { Source::Open(path.clone()) } else { Source::DupZero },
                target,
            ));
            continue;
        }
        match stream.unwrap_or(Stdio(Kind::Inherit)).0 {
            Kind::Null => plan.push((Source::DevNull, target)),
            Kind::Inherit => plan.push((Source::Same, target)),
            Kind::Piped => {
                let (read, write) = pipe()?;
                let (child_end, parent_end) =
                    if target == 0 { (read, write) } else { (write, read) };
                parents[target as usize] = Some(parent_end);
                plan.push((Source::Fd(child_end), target));
            }
            Kind::Fd(fd) => plan.push((Source::Fd(fd), target)),
        }
    }
    for (fd, at) in command.inherit.drain(..) {
        plan.push((Source::Fd(fd), at));
    }
    // Every descriptor source is moved above all targets first: one whose
    // number is another action's target would be replaced before its own
    // dup2, and one already at its target cannot be passed by dup2 (onto
    // itself, dup2 does not clear close-on-exec on macOS, and
    // CLOEXEC_DEFAULT then closes it). Each dup2 thus has distinct numbers
    // and always gives the child a copy without close-on-exec.
    let targets: BTreeSet<RawFd> = plan.iter().map(|(_, target)| *target).collect();
    let floor = targets.iter().max().map_or(3, |max| max + 1);
    for (source, _) in &mut plan {
        if let Source::Fd(fd) = source
            && targets.contains(&fd.as_raw_fd())
        {
            *source = Source::Fd(dup_above(fd, floor)?);
        }
    }

    let mut setup = Setup::new()?;
    let mut flags = libc::POSIX_SPAWN_SETSIGDEF as libc::c_short
        | libc::POSIX_SPAWN_SETSIGMASK as libc::c_short
        | libc::POSIX_SPAWN_CLOEXEC_DEFAULT as libc::c_short;
    if command.new_session {
        flags |= POSIX_SPAWN_SETSID;
    }
    let dev_null = c"/dev/null";
    // SAFETY: every call gets the initialized attr/actions and live strings.
    unsafe {
        let mut all: libc::sigset_t = std::mem::zeroed();
        let mut none: libc::sigset_t = std::mem::zeroed();
        libc::sigfillset(&mut all);
        libc::sigemptyset(&mut none);
        check(libc::posix_spawnattr_setsigdefault(&mut setup.attr, &all))?;
        check(libc::posix_spawnattr_setsigmask(&mut setup.attr, &none))?;
        if let Some(pgid) = command.process_group {
            flags |= libc::POSIX_SPAWN_SETPGROUP as libc::c_short;
            check(libc::posix_spawnattr_setpgroup(&mut setup.attr, pgid))?;
        }
        check(libc::posix_spawnattr_setflags(&mut setup.attr, flags))?;
        for (source, target) in &plan {
            check(match source {
                Source::DevNull => libc::posix_spawn_file_actions_addopen(
                    &mut setup.actions,
                    *target,
                    dev_null.as_ptr(),
                    if *target == 0 { libc::O_RDONLY } else { libc::O_WRONLY },
                    0,
                ),
                Source::Same => posix_spawn_file_actions_addinherit_np(&mut setup.actions, *target),
                Source::Open(path) => libc::posix_spawn_file_actions_addopen(
                    &mut setup.actions,
                    *target,
                    path.as_ptr(),
                    libc::O_RDWR,
                    0,
                ),
                Source::DupZero => {
                    libc::posix_spawn_file_actions_adddup2(&mut setup.actions, 0, *target)
                }
                Source::Fd(fd) => libc::posix_spawn_file_actions_adddup2(
                    &mut setup.actions,
                    fd.as_raw_fd(),
                    *target,
                ),
            })?;
        }
        if let Some(dir) = &cwd {
            check(posix_spawn_file_actions_addchdir_np(&mut setup.actions, dir.as_ptr()))?;
        }
    }
    let mut argv_ptrs: Vec<*mut libc::c_char> =
        argv.iter().map(|arg| arg.as_ptr().cast_mut()).collect();
    argv_ptrs.push(std::ptr::null_mut());
    let mut envp_ptrs: Vec<*mut libc::c_char> =
        envp.iter().map(|pair| pair.as_ptr().cast_mut()).collect();
    envp_ptrs.push(std::ptr::null_mut());
    let mut pid: libc::pid_t = 0;
    // SAFETY: path, argv and envp are NUL-terminated and live for the call;
    // attr and actions are initialized.
    check(unsafe {
        libc::posix_spawn(
            &mut pid,
            path.as_ptr(),
            &setup.actions,
            &setup.attr,
            argv_ptrs.as_ptr(),
            envp_ptrs.as_ptr(),
        )
    })?;
    drop(plan);
    let [stdin, stdout, stderr] = parents;
    Ok(Child::from_pid(
        pid,
        stdin.map(ChildStdin::from),
        stdout.map(ChildStdout::from),
        stderr.map(ChildStderr::from),
    ))
}

/// Where a child descriptor comes from.
enum Source {
    /// `/dev/null`, opened in the child.
    DevNull,
    /// This process's descriptor of the target's number.
    Same,
    /// A path opened read-write in the child (`Command::open_stdin_path`).
    Open(CString),
    /// A copy of the child's descriptor 0 (after `Open` on 0).
    DupZero,
    /// This descriptor (dropped after the spawn).
    Fd(OwnedFd),
}

/// The attr and file actions, destroyed on every return.
struct Setup {
    attr: libc::posix_spawnattr_t,
    actions: libc::posix_spawn_file_actions_t,
}

impl Setup {
    fn new() -> io::Result<Self> {
        let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
        let mut actions: libc::posix_spawn_file_actions_t = std::ptr::null_mut();
        // SAFETY: init writes the opaque handles.
        check(unsafe { libc::posix_spawnattr_init(&mut attr) })?;
        // SAFETY: as above.
        if let Err(error) = check(unsafe { libc::posix_spawn_file_actions_init(&mut actions) }) {
            // SAFETY: initialized just above.
            unsafe { libc::posix_spawnattr_destroy(&mut attr) };
            return Err(error);
        }
        Ok(Self { attr, actions })
    }
}

impl Drop for Setup {
    fn drop(&mut self) {
        // SAFETY: both were initialized in `new`.
        unsafe {
            libc::posix_spawn_file_actions_destroy(&mut self.actions);
            libc::posix_spawnattr_destroy(&mut self.attr);
        }
    }
}

/// The child's environment: this process's (unless cleared) with the
/// builder's changes, sorted.
fn child_env(command: &Command) -> Vec<(OsString, OsString)> {
    let mut env: std::collections::BTreeMap<OsString, OsString> =
        if command.env_clear { Default::default() } else { std::env::vars_os().collect() };
    for (key, value) in &command.env {
        match value {
            Some(value) => env.insert(key.clone(), value.clone()),
            None => env.remove(key),
        };
    }
    env.into_iter().collect()
}

/// The program's path: as given when it holds a `/`, else the first
/// executable file of that name in a `PATH`, as std: the child's when the
/// builder set or removed `PATH` or kept this process's environment, else
/// (an `env_clear` that set no `PATH`) this process's; the system default
/// when neither has one.
fn resolve(
    program: &OsStr,
    command: &Command,
    env: &[(OsString, OsString)],
) -> io::Result<PathBuf> {
    if program.as_bytes().contains(&b'/') {
        return Ok(PathBuf::from(program));
    }
    let child_path = env.iter().find(|(key, _)| key == "PATH").map(|(_, value)| value.clone());
    let path_was_set = command.env.keys().any(|key| key == "PATH");
    let path =
        if path_was_set || !command.env_clear { child_path } else { std::env::var_os("PATH") }
            .unwrap_or_else(|| OsString::from("/usr/bin:/bin:/usr/sbin:/sbin"));
    for dir in std::env::split_paths(&path) {
        let dir = if dir.as_os_str().is_empty() { PathBuf::from(".") } else { dir };
        let candidate = dir.join(program);
        let Ok(name) = c_string(candidate.as_os_str()) else { continue };
        // SAFETY: access reads a NUL-terminated path.
        if candidate.is_file() && unsafe { libc::access(name.as_ptr(), libc::X_OK) } == 0 {
            return Ok(candidate);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("{} not found in PATH", program.to_string_lossy()),
    ))
}

/// A pipe whose two ends are close-on-exec (this crate's spawns pass neither
/// by accident; the flag guards spawns that do not use it).
fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: pipe fills two descriptors.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: two new descriptors this function owns.
    let ends = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    for fd in [&ends.0, &ends.1] {
        // SAFETY: F_SETFD on a descriptor this function owns.
        if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(ends)
}

/// A close-on-exec copy of `fd` numbered `floor` or more.
fn dup_above(fd: &OwnedFd, floor: RawFd) -> io::Result<OwnedFd> {
    // SAFETY: F_DUPFD_CLOEXEC returns a new descriptor or -1.
    let copy = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, floor) };
    if copy < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a new descriptor this function owns.
    Ok(unsafe { OwnedFd::from_raw_fd(copy) })
}

fn c_string(value: &OsStr) -> io::Result<CString> {
    CString::new(value.as_bytes()).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidInput, "a NUL byte in a program, argument or variable")
    })
}

fn check(code: libc::c_int) -> io::Result<()> {
    if code == 0 { Ok(()) } else { Err(io::Error::from_raw_os_error(code)) }
}

#[cfg(test)]
mod daemon_spawn {
    use std::io::Read;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

    use crate::Command;

    /// A descriptor that already sits at the number the child should get it
    /// at, close-on-exec (as every descriptor the daemon owns is), still
    /// reaches the child (finding 2 of PL-daemon's review: `adddup2(fd, fd)`
    /// keeps close-on-exec on macOS, and CLOEXEC_DEFAULT then closes it).
    #[test]
    fn a_descriptor_already_at_its_target_number_reaches_the_child() {
        const AT: i32 = 777;
        let mut fds = [0; 2];
        // SAFETY: pipe fills two descriptors.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // SAFETY: two new descriptors the test owns.
        let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        // SAFETY: dup2 onto a number no other test uses; F_SETFD on it.
        let at = unsafe {
            assert_eq!(libc::dup2(write.as_raw_fd(), AT), AT);
            assert_eq!(libc::fcntl(AT, libc::F_SETFD, libc::FD_CLOEXEC), 0);
            OwnedFd::from_raw_fd(AT)
        };
        drop(write);
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "echo at-777 >&777"]);
        // Placed directly: `inherit_fd` would duplicate it to another number.
        command.inherit.push((at, AT));
        let mut child = command.spawn().unwrap();
        drop(command);
        assert!(child.wait().unwrap().success(), "the child could not write to 777");
        let mut got = String::new();
        std::fs::File::from(read).read_to_string(&mut got).unwrap();
        assert_eq!(got, "at-777\n");
    }

    /// A child that exited before `wait_timeout` registered its kqueue event
    /// (a zombie: `EV_ADD` fails with ESRCH) is seen at once and reaped, not
    /// waited on until the limit (finding 1 of PL-daemon's review).
    #[test]
    fn a_child_that_exited_before_the_registration_is_seen_at_once() {
        let mut child = Command::new("/usr/bin/true").spawn().unwrap();
        let pid = child.id() as libc::pid_t;
        // Block until it exited, without reaping it (WNOWAIT): a zombie.
        // SAFETY: zeroed siginfo is valid output storage for waitid.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: waitid writes one siginfo for this child.
        assert_eq!(
            unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid as libc::id_t,
                    &mut info,
                    libc::WEXITED | libc::WNOWAIT,
                )
            },
            0
        );
        let started = std::time::Instant::now();
        crate::child::exit_event_within(pid, std::time::Duration::from_secs(30)).unwrap();
        assert!(
            started.elapsed() < std::time::Duration::from_secs(5),
            "waited {:?} for a child that had exited",
            started.elapsed()
        );
        assert!(child.try_wait().unwrap().expect("reaped after the event").success());
    }
}
