//! Bubblewrap mount/namespace plan for Linux remote spawns.
//! This layer alone is insufficient: the seccomp supervisor and network
//! proxy must also be installed before a remote command may run.
#![allow(dead_code)] // Staged API: G1/G2 supply the production callers.

use std::ffi::CString;
use std::fmt;
use std::fs;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;
use wait_timeout::ChildExt;

/// HOME-relative Linux additions; the shared deny list comes from Seatbelt.
pub(crate) const LINUX_READ_DENIES: &[&str] = &[
    ".local/share/keyrings",
    ".password-store",
    ".mozilla",
    ".config/google-chrome",
    ".config/chromium",
    ".config/BraveSoftware",
    ".pki",
    ".claude/.credentials.json",
];

mod aliases;
mod home;
#[cfg(test)]
use home::{denied_paths, home_view};
use home::{denied_paths_pinned, home_view_pinned};

/// Canonical absolute UTF-8 paths, validated and created by the caller.
/// `claude_project/memory` must already exist, too.
#[derive(Debug, Clone)]
pub(crate) struct Paths {
    pub(crate) cwd: PathBuf,
    pub(crate) tmp: PathBuf,
    pub(crate) home: PathBuf,
    pub(crate) claude_tmp_project: PathBuf,
    pub(crate) claude_project: PathBuf,
}

/// The argv and source descriptors needed to invoke bubblewrap.
///
/// Callers must keep the descriptors alive until bwrap has started and clear
/// `FD_CLOEXEC` before spawning it (G1 does this in `pre_exec`).
pub(crate) type BwrapPlan = (Vec<String>, Vec<OwnedFd>);

/// Build bubblewrap argv and open every bind source with `openat2`.
/// The loop ends after four writable roots. Supplied masks are applied first.
fn bwrap_args(
    paths: &Paths,
    home_view: BwrapPlan,
    cmd_prefix: &[String],
) -> Result<BwrapPlan, String> {
    let (home_args, mut fds) = home_view;
    let mut out: Vec<String> = "--new-session --die-with-parent --unshare-user --unshare-pid --unshare-ipc --unshare-net --unshare-uts --unshare-cgroup-try --disable-userns --ro-bind / / --dev /dev --proc /proc"
        .split_whitespace().map(str::to_owned).collect();
    out.extend(home_args);
    for path in [&paths.cwd, &paths.tmp, &paths.claude_tmp_project, &paths.claude_project] {
        let path_text = path_arg(path)?;
        let fd = open_bind_source(path)?;
        out.extend(["--bind-fd".into(), fd.as_raw_fd().to_string(), path_text]);
        fds.push(fd);
    }
    let memory_path = paths.claude_project.join("memory");
    let memory = path_arg(&memory_path)?;
    let fd = open_bind_source(&memory_path)?;
    out.extend(["--ro-bind-fd".into(), fd.as_raw_fd().to_string(), memory]);
    fds.push(fd);
    out.extend([
        "--chdir".into(),
        path_arg(&paths.cwd)?,
        "--cap-drop".into(),
        "ALL".into(),
        "--".into(),
    ]);
    out.extend_from_slice(cmd_prefix);
    Ok((out, fds))
}

/// Fail closed on invalid caller data; lossy conversion could mask a
/// different path or grant writes to a different directory.
fn path_arg(path: &Path) -> Result<String, String> {
    if !path.is_absolute() {
        return Err(format!("sandbox path is not absolute: {}", path.display()));
    }
    if path.components().any(|c| c == std::path::Component::ParentDir) {
        return Err(format!("sandbox path contains ..: {}", path.display()));
    }
    path.to_str().map(str::to_owned).ok_or_else(|| "sandbox paths must be UTF-8".to_owned())
}

/// Open a bind source without following a final or magic link, then verify
/// that the kernel's fd view still names the expected canonical path.
fn open_bind_source(path: &Path) -> Result<OwnedFd, String> {
    let text = path_arg(path)?;
    let canonical = fs::canonicalize(path)
        .map_err(|e| format!("cannot canonicalize bind source {text}: {e}"))?;
    let c_path = CString::new(text.as_bytes()).map_err(|_| format!("path contains NUL: {text}"))?;
    let how = OpenHow {
        flags: (libc::O_PATH | libc::O_CLOEXEC) as u64,
        mode: 0,
        resolve: (RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS) as u64,
    };
    // SAFETY: the path and open_how point to live NUL-terminated/read-only data.
    let raw = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            libc::AT_FDCWD,
            c_path.as_ptr(),
            &how,
            std::mem::size_of::<OpenHow>(),
        )
    } as RawFd;
    if raw < 0 {
        return Err(format!("cannot open bind source {text}: {}", io::Error::last_os_error()));
    }
    // SAFETY: openat2 returned a new owned descriptor.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let actual = fs::read_link(format!("/proc/self/fd/{raw}"))
        .map_err(|e| format!("cannot inspect bind source {text}: {e}"))?;
    if actual != canonical {
        return Err(format!(
            "bind source changed: expected {}, got {}",
            canonical.display(),
            actual.display()
        ));
    }
    Ok(fd)
}

#[repr(C)]
struct OpenHow {
    flags: u64,
    mode: u64,
    resolve: u64,
}

const RESOLVE_NO_MAGICLINKS: u32 = 0x02;
const RESOLVE_NO_SYMLINKS: u32 = 0x04;

/// (Owned by this uid, writable by this uid, is a symlink).
type OutsideStat = (bool, bool, bool);

/// Inspect ownership and effective writability for the real uid. Errors refuse.
fn outside_stat(path: &Path) -> Result<Option<OutsideStat>, String> {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("cannot inspect {}: {e}", path.display())),
    };
    if meta.is_symlink() {
        return Ok(Some((false, false, true)));
    }
    let text = path_arg(path)?;
    let c_path = CString::new(text.as_bytes()).map_err(|_| format!("path contains NUL: {text}"))?;
    // SAFETY: c_path is NUL-terminated; getuid has no preconditions.
    let (owned, result) =
        unsafe { (meta.uid() == libc::getuid(), libc::access(c_path.as_ptr(), libc::W_OK)) };
    if result == 0 {
        return Ok(Some((owned, true, false)));
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::EACCES | libc::EROFS) => Ok(Some((owned, false, false))),
        _ => Err(format!("cannot inspect write access to {text}: {error}")),
    }
}

/// Pure lstat policy: visit / through the leaf, refusing symlinks before any
/// descendant inspection. Then check ancestor ownership and writability.
/// Both loops end after the finite lexical component list.
fn validate_outside(
    path: &Path,
    mut stat: impl FnMut(&Path) -> Result<Option<OutsideStat>, String>,
) -> Result<(), String> {
    let mut entries = Vec::new();
    for component in path.ancestors().collect::<Vec<_>>().into_iter().rev() {
        let info = stat(component)?;
        if matches!(info, Some((_, _, true))) {
            return Err(format!(
                "{} passes through the symlink {}",
                path.display(),
                component.display()
            ));
        }
        if component == Path::new("/") && info.is_none() {
            return Err("cannot inspect filesystem root".into());
        }
        entries.push((component, info));
    }
    let state =
        if entries.last().is_some_and(|(_, info)| info.is_none()) { "absent" } else { "present" };
    for (ancestor, info) in entries.into_iter().rev().skip(1) {
        let Some((owned, writable, _)) = info else {
            continue;
        };
        if owned || writable {
            let reason = if owned { "owned by this user" } else { "writable by this user" };
            let consequence = if state == "absent" { "appear" } else { "be replaced" };
            return Err(format!(
                "{} is {state}, but {} is {reason}, so it could {consequence} during the session",
                path.display(),
                ancestor.display()
            ));
        }
    }
    Ok(())
}

/// Snapshot existing explicit denials. A1b replaces HOME masks with a rebuilt
/// view so absent credentials stay hidden too. Iteration ends after `paths`.
/// Outside HOME, every ancestor must be owned by another uid and unwritable.
/// A nodev /dev/null mask may fail reads with EACCES instead of returning EOF.
fn outside_view(paths: &[PathBuf], home: &Path) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for path in paths {
        let text = path_arg(path)?;
        if !path.starts_with(home) {
            validate_outside(path, outside_stat)?;
        }
        let meta = match fs::symlink_metadata(path) {
            Ok(meta) => meta,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => return Err(format!("cannot inspect denied path {text}: {e}")),
        };
        if meta.is_dir() {
            out.extend(["--tmpfs".into(), text.clone(), "--remount-ro".into(), text]);
        } else {
            out.extend(["--ro-bind".into(), "/dev/null".into(), text]);
        }
    }
    Ok(out)
}

/// Caller supplies explicit denied paths parsed by `rules::WritePolicy`.
/// The returned descriptors must be inherited by bwrap with CLOEXEC cleared.
/// Caller supplies fresh mountinfo; mount IDs are resolved here in the keeper.
/// Validation loops stop after the fixed roots and supplied deny list.
pub(crate) fn plan(
    paths: &Paths,
    read_denies: &[PathBuf],
    mountinfo: &str,
    cmd_prefix: &[String],
) -> Result<BwrapPlan, String> {
    plan_with_mount_id(paths, read_denies, mountinfo, cmd_prefix, aliases::resolved_mount_id)
}

fn plan_with_mount_id(
    paths: &Paths,
    read_denies: &[PathBuf],
    mountinfo: &str,
    cmd_prefix: &[String],
    mut mount_id: impl FnMut(&Path) -> Result<u64, String>,
) -> Result<BwrapPlan, String> {
    // Refuse automount triggers before resolving any guarded path.
    let preflight = aliases::guarded_aliases(&[], mountinfo);
    if !preflight.is_empty() {
        return Err(preflight.join("; "));
    }
    let memory = paths.claude_project.join("memory");
    let writable = [&paths.cwd, &paths.tmp, &paths.claude_tmp_project, &paths.claude_project];
    for path in [&paths.home, &memory].into_iter().chain(writable) {
        path_arg(path)?;
        if fs::canonicalize(path).map_err(|e| e.to_string())? != *path {
            return Err(format!("noncanonical sandbox path: {}", path.display()));
        }
    }
    let snapshot = denied_paths_pinned(&paths.home, read_denies)?;
    let denied = &snapshot.inside;
    let outside = &snapshot.outside;
    for root in writable {
        if denied.iter().chain(outside.iter()).any(|d| root.starts_with(d) || d.starts_with(root)) {
            return Err(format!("writable root overlaps read denial: {}", root.display()));
        }
    }
    let mut protected = vec![memory];
    for path in denied.iter().chain(outside.iter()) {
        match fs::canonicalize(path) {
            Ok(target) => {
                protected.push(path.clone());
                protected.push(target);
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => protected.push(path.clone()),
            Err(e) => return Err(format!("cannot inspect {}: {e}", path.display())),
        }
    }
    let mut trees = Vec::new();
    for path in &protected {
        trees.push((path.as_path(), mount_id(path)?, false));
    }
    for path in writable {
        trees.push((path.as_path(), mount_id(path)?, true));
    }
    let aliases = aliases::guarded_aliases(&trees, mountinfo);
    if !aliases.is_empty() {
        return Err(aliases.join("; "));
    }
    let mut home = home_view_pinned(&paths.home, denied, Some(&snapshot))?;
    let outside = outside_view(outside, &paths.home)?;
    home.0.splice(0..0, outside);
    bwrap_args(paths, home, cmd_prefix)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Unavailable {
    NotInstalled,
    TooOld,
    UserNamespacesRestricted,
    Other(String),
}

impl fmt::Display for Unavailable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::NotInstalled => "bwrap not installed (Debian/Ubuntu: apt install bubblewrap)",
            Self::TooOld => "bwrap older than 0.9 (missing --disable-userns/--bind-fd/--ro-bind-fd)",
            Self::UserNamespacesRestricted => "unprivileged user namespaces are restricted (kernel.apparmor_restrict_unprivileged_userns=1) and /usr/bin/bwrap has no AppArmor profile; install it: Ubuntu's apparmor package ships /etc/apparmor.d/bwrap-userns-restrict",
            Self::Other(stderr) => stderr,
        })
    }
}

/// Classify a completed probe; `None` means the child died by signal.
fn classify(status: Option<i32>, stderr: &str) -> Result<(), Unavailable> {
    if status == Some(0) {
        return Ok(());
    }
    let stderr = stderr.trim();
    let lower = stderr.to_ascii_lowercase();
    if (lower.contains("--disable-userns")
        || lower.contains("--bind-fd")
        || lower.contains("--ro-bind-fd"))
        && (lower.contains("unknown option") || lower.contains("unrecognized option"))
    {
        return Err(Unavailable::TooOld);
    }
    if lower.contains("no permissions to create new namespace")
        || ((lower.contains("setting up uid map") || lower.contains("creating new namespace"))
            && (lower.contains("permission denied") || lower.contains("operation not permitted")))
    {
        return Err(Unavailable::UserNamespacesRestricted);
    }
    Err(Unavailable::Other(if stderr.is_empty() {
        match status {
            Some(code) => format!("bwrap probe failed (exit status {code}, no stderr)"),
            None => "bwrap probe terminated by signal (no stderr)".into(),
        }
    } else {
        stderr.to_owned()
    }))
}

/// Stop after the probe exits or 10 seconds elapse; kill and reap on timeout
/// or wait failure. Stderr reads end at EOF, WouldBlock, or 16 KiB: even an
/// inherited stderr writer cannot hold the probe open after its child exits.
pub(crate) fn probe(bwrap: &Path) -> Result<(), Unavailable> {
    let probe_root = fs::File::open("/")
        .map_err(|e| Unavailable::Other(format!("bwrap probe could not open /: {e}")))?;
    let probe_readonly = probe_root
        .try_clone()
        .map_err(|e| Unavailable::Other(format!("bwrap probe could not duplicate /: {e}")))?;
    let mut child = Command::new(bwrap)
        .args("--unshare-user --unshare-net --disable-userns --ro-bind / / --bind-fd 0 /tmp --ro-bind-fd 1 /var true".split_whitespace())
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .current_dir("/")
        .stdin(Stdio::from(probe_root))
        .stdout(Stdio::from(probe_readonly))
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            if e.kind() == io::ErrorKind::NotFound {
                Unavailable::NotInstalled
            } else {
                Unavailable::Other(format!("bwrap probe did not start: {e}"))
            }
        })?;
    let status = match child.wait_timeout(Duration::from_secs(10)) {
        Ok(Some(status)) => status,
        result => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Unavailable::Other(match result {
                Err(e) => format!("bwrap probe wait failed: {e}"),
                _ => "bwrap probe did not finish in 10 s".into(),
            }));
        }
    };
    let Some(stderr) = child.stderr.take() else {
        return Err(Unavailable::Other("bwrap probe stderr pipe unavailable".into()));
    };
    // SAFETY: stderr owns a live pipe fd. F_SETFL changes only its status flags.
    if unsafe { libc::fcntl(stderr.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } == -1 {
        return Err(Unavailable::Other(format!("bwrap stderr: {}", io::Error::last_os_error())));
    }
    let mut bytes = Vec::new();
    if let Err(e) = stderr.take(16 * 1024).read_to_end(&mut bytes)
        && e.kind() != io::ErrorKind::WouldBlock
    {
        return Err(Unavailable::Other(format!("bwrap stderr: {e}")));
    }
    classify(status.code(), &String::from_utf8_lossy(&bytes))
}

#[cfg(test)]
mod tests;
