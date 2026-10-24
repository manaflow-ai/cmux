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
    let path = resolve(&command.program, &env)?;
    let argv0 = command.arg0.clone().unwrap_or_else(|| command.program.clone());
    let argv: Vec<CString> =
        std::iter::once(&argv0).chain(&command.args).map(c_string).collect::<io::Result<_>>()?;
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
    let streams = [command.stdin.take(), command.stdout.take(), command.stderr.take()];
    for (target, stream) in streams.into_iter().enumerate() {
        let target = target as RawFd;
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
    // A source whose number is another action's target would be replaced
    // before its own dup2: move it above every target first.
    let targets: BTreeSet<RawFd> = plan.iter().map(|(_, target)| *target).collect();
    let floor = targets.iter().max().map_or(3, |max| max + 1);
    for (source, target) in &mut plan {
        if let Source::Fd(fd) = source
            && fd.as_raw_fd() != *target
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
                // dup2 onto itself keeps close-on-exec, which
                // CLOEXEC_DEFAULT turns into a close: inherit it instead.
                Source::Fd(fd) if fd.as_raw_fd() == *target => {
                    posix_spawn_file_actions_addinherit_np(&mut setup.actions, *target)
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
/// executable file of that name in the child's `PATH` (as std and execvp).
fn resolve(program: &OsStr, env: &[(OsString, OsString)]) -> io::Result<PathBuf> {
    if program.as_bytes().contains(&b'/') {
        return Ok(PathBuf::from(program));
    }
    let path = env.iter().find(|(key, _)| key == "PATH").map_or_else(
        || OsString::from("/usr/bin:/bin:/usr/sbin:/sbin"),
        |(_, value)| value.clone(),
    );
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
