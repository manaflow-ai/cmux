//! Starting one role process (server.md 5.1): program resolution and
//! checks, a cleared environment, its own process group, output into the
//! ring log, and the notify descriptor.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::Sender;

use cmux_server_core::role_spec::{Program, Readiness, RoleSpec};

use super::RolePaths;
use super::log::{LOG_FILE_BYTES, LOG_FILES, RingLog, log_path};
use super::supervisor::Msg;

/// The descriptor number of the notify pipe in the child.
pub const NOTIFY_FD: i32 = 3;
/// `PATH` for roles: no user or relative entries.
const ROLE_PATH: &str = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
/// Inherited variables (everything else is cleared).
const INHERITED: &[&str] = &["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"];

/// The program path for `spec`, checked: the canonical path (symlinks
/// resolved) must be a regular file, and it and every folder up to `/` must
/// belong to the user or root and be writable by no one else (a root-owned
/// sticky folder such as `/tmp` is allowed). The caller execs that path.
pub fn resolve(spec: &RoleSpec, paths: &RolePaths) -> Result<PathBuf, String> {
    let path = match &spec.program {
        Program::Store(name) => paths.store_bin.join(name),
        Program::Path(path) => PathBuf::from(path),
    };
    let path = std::fs::canonicalize(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    check_owner(&path, true)?;
    for dir in path.ancestors().skip(1) {
        check_owner(dir, false)?;
    }
    Ok(path)
}

#[cfg(unix)]
fn check_owner(path: &Path, file: bool) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if file && !meta.is_file() {
        return Err(format!("{} is not a regular file", path.display()));
    }
    // SAFETY: geteuid has no preconditions.
    let me = unsafe { libc::geteuid() };
    if meta.uid() != me && meta.uid() != 0 {
        return Err(format!("{} belongs to another user", path.display()));
    }
    let sticky_root_dir = !file && meta.uid() == 0 && meta.mode() & 0o1000 != 0;
    if meta.mode() & 0o022 != 0 && !sticky_root_dir {
        return Err(format!("{} is writable by group or others", path.display()));
    }
    Ok(())
}

#[cfg(not(unix))]
fn check_owner(_path: &Path, _file: bool) -> Result<(), String> {
    Err("process roles need a Unix host".to_owned())
}

/// The full environment of a role process.
pub fn environment(
    spec: &RoleSpec,
    paths: &RolePaths,
    inherited: impl Fn(&str) -> Option<String>,
) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    for key in INHERITED {
        if let Some(value) = inherited(key) {
            env.insert((*key).to_owned(), value);
        }
    }
    env.insert("PATH".to_owned(), ROLE_PATH.to_owned());
    env.extend(spec.env.clone());
    env.insert("CMUX_ROLE_NAME".to_owned(), spec.name.clone());
    let dir = paths.role_dir(&spec.name);
    env.insert("CMUX_ROLE_STATE_DIR".to_owned(), dir.display().to_string());
    env.insert("CMUX_ROLE_LOG_DIR".to_owned(), paths.log_dir().display().to_string());
    if spec.ready == Readiness::Notify {
        env.insert("CMUX_ROLE_NOTIFY_FD".to_owned(), NOTIFY_FD.to_string());
    }
    env
}

/// Starts `spec`: returns the child; helper threads report its output,
/// notifications and exit to `tx`. The caller reaps the child after the
/// exit message (the waiter does not reap, so the process group id stays
/// reserved until the supervisor has seen the exit).
#[cfg(unix)]
pub fn start(spec: &RoleSpec, paths: &RolePaths, tx: &Sender<Msg>) -> Result<Child, String> {
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt;

    let program = resolve(spec, paths)?;
    let dir = paths.role_dir(&spec.name);
    cmux_server::fsx::ensure_dir(&dir, 0o700).map_err(|e| e.to_string())?;
    cmux_server::fsx::ensure_dir(&paths.log_dir(), 0o700).map_err(|e| e.to_string())?;
    let mut log = RingLog::open(log_path(&paths.log_dir(), &spec.name), LOG_FILE_BYTES, LOG_FILES)
        .map_err(|e| format!("log: {e}"))?;
    let (out_r, out_w) = std::io::pipe().map_err(|e| e.to_string())?;
    let err_w = out_w.try_clone().map_err(|e| e.to_string())?;
    let notify = match spec.ready {
        Readiness::Notify => Some(std::io::pipe().map_err(|e| e.to_string())?),
        Readiness::Started => None,
    };
    let mut command = Command::new(&program);
    command
        .args(&spec.args)
        .env_clear()
        .envs(environment(spec, paths, |k| std::env::var(k).ok()))
        .current_dir(&dir)
        .stdin(Stdio::null())
        .stdout(out_w)
        .stderr(err_w)
        .process_group(0);
    if let Some((_, notify_w)) = &notify {
        let fd = notify_w.as_raw_fd();
        // SAFETY: only async-signal-safe calls (dup2, fcntl) between fork
        // and exec. dup2 onto NOTIFY_FD clears close-on-exec there.
        unsafe {
            command.pre_exec(move || {
                if fd == NOTIFY_FD {
                    let flags = libc::fcntl(fd, libc::F_GETFD);
                    if flags < 0 || libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                } else if libc::dup2(fd, NOTIFY_FD) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    let child = command.spawn().map_err(|e| format!("{}: {e}", program.display()))?;
    // The command holds the write ends; drop them so EOF follows the child.
    drop(command);
    let name = spec.name.clone();
    let pid = child.id();
    std::thread::Builder::new()
        .name(format!("role-{name}-log"))
        .spawn(move || {
            let mut reader = BufReader::new(out_r);
            let mut line = Vec::new();
            while read_line_capped(&mut reader, &mut line, LOG_LINE_MAX).is_ok_and(|n| n > 0) {
                if !line.ends_with(b"\n") {
                    line.push(b'\n');
                }
                // A full disk drops lines; the role keeps running.
                let _ = log.write_line(&line);
                line.clear();
            }
        })
        .map_err(|e| e.to_string())?;
    if let Some((notify_r, notify_w)) = notify {
        drop(notify_w);
        let tx = tx.clone();
        let name = name.clone();
        std::thread::Builder::new()
            .name(format!("role-{name}-notify"))
            .spawn(move || read_notify(notify_r, &name, pid, &tx))
            .map_err(|e| e.to_string())?;
    }
    watch_exit(&name, pid, tx);
    Ok(child)
}

/// Starts the thread that reports `pid`'s exit (without reaping it).
#[cfg(unix)]
pub fn watch_exit(name: &str, pid: u32, tx: &Sender<Msg>) {
    let tx = tx.clone();
    let name = name.to_owned();
    let spawned = std::thread::Builder::new().name(format!("role-{name}-wait")).spawn({
        let tx = tx.clone();
        let name = name.clone();
        move || {
            wait_exit(pid);
            let _ = tx.send(Msg::Gone { name, pid });
        }
    });
    if spawned.is_err() {
        // No thread: report at once; the supervisor's `try_wait` decides.
        let _ = tx.send(Msg::Gone { name, pid });
    }
}

#[cfg(not(unix))]
pub fn watch_exit(_name: &str, _pid: u32, _tx: &Sender<Msg>) {}

/// Longest log line and notify line kept; the rest of a longer line is
/// read and dropped.
const LOG_LINE_MAX: usize = 64 * 1024;
const NOTIFY_LINE_MAX: usize = 4096;

/// `read_until(b'\n')` that keeps at most `max` bytes of the line. Returns
/// the bytes consumed (0 at EOF).
fn read_line_capped(
    reader: &mut impl BufRead,
    line: &mut Vec<u8>,
    max: usize,
) -> std::io::Result<usize> {
    let mut consumed = 0;
    loop {
        let buf = reader.fill_buf()?;
        if buf.is_empty() {
            return Ok(consumed);
        }
        let (take, done) = match buf.iter().position(|b| *b == b'\n') {
            Some(i) => (i + 1, true),
            None => (buf.len(), false),
        };
        let room = max.saturating_sub(line.len()).min(take);
        line.extend_from_slice(&buf[..room]);
        reader.consume(take);
        consumed += take;
        if done {
            return Ok(consumed);
        }
    }
}

#[cfg(not(unix))]
pub fn start(_spec: &RoleSpec, _paths: &RolePaths, _tx: &Sender<Msg>) -> Result<Child, String> {
    Err("process roles need a Unix host".to_owned())
}

/// `READY=1` and `STATUS=<text>` lines, at most 4 KiB each (longer lines
/// are cut, bytes that are not UTF-8 replaced). The reader stays open for
/// the role's life, so a status write never meets a closed pipe.
fn read_notify(pipe: std::io::PipeReader, name: &str, pid: u32, tx: &Sender<Msg>) {
    let mut reader = BufReader::new(pipe);
    let mut line = Vec::new();
    while read_line_capped(&mut reader, &mut line, NOTIFY_LINE_MAX).is_ok_and(|n| n > 0) {
        let decoded = String::from_utf8_lossy(&line).into_owned();
        let text = decoded.trim_end_matches(['\n', '\r']);
        let msg = if text == "READY=1" {
            Some(Msg::Ready { name: name.to_owned(), pid })
        } else {
            text.strip_prefix("STATUS=").map(|status| Msg::Status {
                name: name.to_owned(),
                pid,
                text: status.chars().take(4096).collect(),
            })
        };
        // The supervisor is gone: keep draining so the role never gets SIGPIPE.
        if let Some(msg) = msg {
            let _ = tx.send(msg);
        }
        line.clear();
    }
}

/// Blocks until `pid` has exited, without reaping it.
#[cfg(unix)]
fn wait_exit(pid: u32) {
    loop {
        // SAFETY: a zeroed siginfo_t is a valid out parameter.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: P_PID with our own child's pid; WNOWAIT leaves it a zombie.
        let rc = unsafe {
            libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT)
        };
        if rc == 0 || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_server_core::role_spec::RestartPolicy;
    use std::time::Duration;

    fn spec(program: Program) -> RoleSpec {
        RoleSpec {
            name: "chief".to_owned(),
            program,
            args: vec![],
            env: BTreeMap::from([("OPTCHAT_MODE".to_owned(), "host".to_owned())]),
            restart: RestartPolicy::Always,
            ready: Readiness::Notify,
            stop_grace: Duration::from_secs(10),
        }
    }

    #[test]
    fn environment_is_cleared_and_role_variables_win() {
        let paths = RolePaths { store_bin: "/s/bin".into(), state: "/st".into() };
        let mut s = spec(Program::Store("optchat-chief".to_owned()));
        s.env.insert("PATH".to_owned(), "/evil".to_owned());
        let env = environment(&s, &paths, |k| (k == "HOME").then(|| "/home/u".to_owned()));
        assert_eq!(env["HOME"], "/home/u");
        assert_eq!(env["OPTCHAT_MODE"], "host");
        assert_eq!(env["CMUX_ROLE_NAME"], "chief");
        assert_eq!(env["CMUX_ROLE_STATE_DIR"], "/st/roles/chief");
        assert_eq!(env["CMUX_ROLE_LOG_DIR"], "/st/logs/roles");
        assert_eq!(env["CMUX_ROLE_NOTIFY_FD"], "3");
        // A role may set its own PATH; nothing else leaks in.
        assert_eq!(env["PATH"], "/evil");
        assert!(!env.contains_key("SSH_AUTH_SOCK"));
    }

    #[cfg(unix)]
    #[test]
    fn resolve_refuses_writable_or_missing_programs() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        let prog = bin.join("optchat-chief");
        std::fs::write(&prog, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&prog, std::fs::Permissions::from_mode(0o755)).unwrap();
        let paths = RolePaths { store_bin: bin.clone(), state: dir.path().join("state") };
        let store = spec(Program::Store("optchat-chief".to_owned()));
        assert_eq!(resolve(&store, &paths).unwrap(), std::fs::canonicalize(&prog).unwrap());
        std::fs::set_permissions(&prog, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(resolve(&store, &paths).unwrap_err().contains("writable"));
        std::fs::set_permissions(&prog, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(resolve(&store, &paths).unwrap_err().contains("writable"));
        let missing = spec(Program::Path("/nonexistent/x".to_owned()));
        assert!(resolve(&missing, &paths).is_err());
        let not_file = spec(Program::Path(dir.path().display().to_string()));
        assert!(resolve(&not_file, &paths).is_err());
    }
}
