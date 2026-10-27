//! Bubblewrap mount/namespace plan. Not wired to remote spawns until G2.
//! This layer alone is insufficient: the seccomp supervisor and network
//! proxy must also be installed before a remote command may run.
//! Linux remote spawns stay refused until G2 installs all enforcement layers.
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
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::fs;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let root =
                std::env::temp_dir().join(format!("acpmux-bwrap-test-{}", uuid::Uuid::now_v7()));
            fs::create_dir(&root).unwrap();
            Self(fs::canonicalize(root).unwrap())
        }

        fn paths(&self) -> Paths {
            Paths {
                cwd: self.0.join("home/session with spaces"),
                tmp: self.0.join("spawn-tmp"),
                home: self.0.join("home"),
                claude_tmp_project: self.0.join("claude-scratch/session"),
                claude_project: self.0.join("home/.claude/projects/session"),
            }
        }

        /// Stops after creating the fixed four writable roots and memory.
        fn create_paths(&self) -> Paths {
            let p = self.paths();
            for dir in [&p.cwd, &p.tmp, &p.claude_tmp_project, &p.claude_project] {
                fs::create_dir_all(dir).unwrap();
            }
            fs::create_dir(p.claude_project.join("memory")).unwrap();
            p
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|s| (*s).to_owned()).collect()
    }

    fn optional_skip(reason: &Unavailable, required: bool) -> bool {
        !required
            && matches!(reason, Unavailable::NotInstalled | Unavailable::UserNamespacesRestricted)
    }

    /// The child-side loop ends after the finite source descriptor list.
    fn inherit_fds(child: &mut tokio::process::Command, fds: &[OwnedFd]) {
        let raw: Vec<_> = fds.iter().map(AsRawFd::as_raw_fd).collect();
        // SAFETY: only async-signal-safe fcntl calls run before exec; the caller
        // retains ownership of the live descriptors until spawn returns.
        unsafe {
            child.pre_exec(move || {
                for fd in &raw {
                    if libc::fcntl(*fd, libc::F_SETFD, 0) == -1 {
                        return Err(io::Error::last_os_error());
                    }
                }
                Ok(())
            });
        }
    }

    #[test]
    fn plan_refuses_bind_mounts_under_each_writable_root() {
        let fixture = Fixture::new();
        let paths = fixture.create_paths();
        for root in [&paths.cwd, &paths.tmp, &paths.claude_tmp_project, &paths.claude_project] {
            // The source is separate from memory and read denials, so only
            // the writable-folder mount check can reject this alias.
            let point = root.join("cache");
            let encode = |p: &Path| p.to_str().unwrap().replace(' ', "\\040");
            let info = format!(
                "1 0 8:1 / / rw - ext4 root rw\n2 1 8:1 {} {} rw - ext4 root rw\n",
                encode(&root.join(".git/hooks")),
                encode(&point)
            );
            let error =
                plan_with_mount_id(&paths, &[], &info, &strings(&["true"]), |_| Ok(1)).unwrap_err();
            assert!(
                error.contains(&format!(
                    "{} is also visible at {}",
                    root.join(".git/hooks").display(),
                    point.display()
                )),
                "{error}"
            );
        }
    }

    #[test]
    fn plan_refuses_memory_alias() {
        let fixture = Fixture::new();
        let paths = fixture.create_paths();
        let memory = paths.claude_project.join("memory");
        let info = format!(
            "1 0 8:1 / / rw - ext4 root rw\n2 1 8:1 {} /alias rw - ext4 root rw\n",
            memory.display()
        );
        let error =
            plan_with_mount_id(&paths, &[], &info, &strings(&["true"]), |_| Ok(1)).unwrap_err();
        assert!(error.contains("also visible at /alias"), "{error}");
    }

    fn real_probe() -> bool {
        match probe(Path::new("/usr/bin/bwrap")) {
            Ok(()) => true,
            Err(reason) => {
                assert!(
                    optional_skip(&reason, std::env::var_os("ACPMUX_REQUIRE_BWRAP").is_some()),
                    "{reason}"
                );
                eprintln!("skipped: {reason}");
                false
            }
        }
    }

    #[test]
    fn regression_home_rebuild_omits_absent_and_nested_denies() {
        use std::os::unix::fs::symlink;
        let f = Fixture::new();
        let p = f.create_paths();
        fs::create_dir_all(p.home.join(".ssh/aws")).unwrap();
        symlink(".ssh/aws", p.home.join(".aws")).unwrap();
        symlink("absent-target", p.home.join("ordinary-link")).unwrap();
        fs::write(p.home.join(".claude/settings.json"), "{}").unwrap();
        let resolved_claude = home::resolve_missing(&p.home.join(".claude")).unwrap();
        assert_eq!(resolved_claude, fs::canonicalize(p.home.join(".claude")).unwrap());
        assert!(!resolved_claude.to_string_lossy().ends_with('/'));
        let (denied, outside) =
            denied_paths(&p.home, &[p.home.join(".ssh"), p.home.join(".aws")]).unwrap();
        assert!(outside.is_empty());
        let (view, _fds) = home_view(&p.home, &denied).unwrap();
        let home = p.home.to_str().unwrap();
        let claude = p.home.join(".claude").to_str().unwrap().to_owned();
        assert!(view.windows(2).any(|w| w == ["--tmpfs", home]), "view={view:?} denied={denied:?}");
        assert!(
            view.windows(2).any(|w| w == ["--tmpfs", &claude]),
            "view={view:?} denied={denied:?}"
        );
        assert!(
            !view.iter().any(|a| a.ends_with("/.ssh")
                || a.ends_with("/.ssh/aws")
                || a.ends_with("/.aws")
                || a.ends_with("/.credentials.json")),
            "view={view:?} denied={denied:?}"
        );
        assert!(
            view.windows(3).any(|w| w
                == ["--symlink", "absent-target", p.home.join("ordinary-link").to_str().unwrap()]),
            "view={view:?} denied={denied:?}"
        );
        let mounts: Vec<_> = view.windows(2).filter(|w| w[0] == "--tmpfs").map(|w| &w[1]).collect();
        assert_eq!(
            mounts.len(),
            mounts.iter().collect::<BTreeSet<_>>().len(),
            "view={view:?} denied={denied:?}"
        );
        let (args, _fds) = plan_with_mount_id(
            &p,
            &[],
            "1 0 8:1 / / rw - ext4 root rw\n",
            &strings(&["true"]),
            |_| Ok(1),
        )
        .unwrap();
        let rebuilt = args.iter().position(|s| s == "--tmpfs").unwrap();
        let writable = args.iter().position(|s| s == "--bind-fd").unwrap();
        assert!(
            rebuilt < writable,
            "HOME must be rebuilt before writable roots return: view={args:?} denied={denied:?}"
        );
    }

    #[test]
    fn regression_external_secret_symlink_is_refused() {
        let f = Fixture::new();
        let p = f.create_paths();
        fs::write(f.0.join("secret"), "credential").unwrap();
        std::os::unix::fs::symlink(f.0.join("secret"), p.home.join(".netrc")).unwrap();
        let error = denied_paths(&p.home, &[p.home.join(".netrc")]).unwrap_err();
        assert!(error.contains("outside HOME"), "{error}");
    }

    /// Both the ready handshake and child lifetime end at a 20-second
    /// deadline; kill_on_drop stops the child if either deadline expires.
    #[tokio::test]
    async fn regression_real_bwrap_hides_credentials_created_during_session() {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        if !real_probe() {
            return;
        }
        let f = Fixture::new();
        let p = f.create_paths();
        fs::create_dir_all(p.home.join(".ssh/aws")).unwrap();
        std::os::unix::fs::symlink(".ssh/aws", p.home.join(".aws")).unwrap();
        let credential = p.home.join(".claude/.credentials.json");
        let script = "echo ready; read -r go; if [ -e \"$1\" ]; then echo 'late credential visible' >&2; exit 49; fi";
        let command =
            strings(&["/bin/sh", "-c", script, "late-secret", credential.to_str().unwrap()]);
        let (args, fds) = plan(
            &p,
            &[p.home.join(".ssh"), p.home.join(".aws")],
            &fs::read_to_string("/proc/self/mountinfo").unwrap(),
            &command,
        )
        .unwrap();
        let mut command = tokio::process::Command::new("/usr/bin/bwrap");
        inherit_fds(&mut command, &fds);
        let mut child = command
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut ready = String::new();
        tokio::time::timeout(Duration::from_secs(20), stdout.read_line(&mut ready))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(ready, "ready\n");
        fs::write(credential, "credential-created-after-sandbox-start").unwrap();
        child.stdin.take().unwrap().write_all(b"go\n").await.unwrap();
        let output = tokio::time::timeout(Duration::from_secs(20), child.wait_with_output())
            .await
            .unwrap()
            .unwrap();
        assert!(
            output.status.success(),
            "{}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        eprintln!("passed: credentials created during a session stay hidden");
    }

    fn profile_read_denies(p: &Paths) -> Vec<PathBuf> {
        let params = [
            ("CWD".into(), p.cwd.clone()),
            ("TMPDIR".into(), p.tmp.clone()),
            ("HOME".into(), p.home.clone()),
            ("CLAUDE_TMP_PROJECT".into(), p.claude_tmp_project.clone()),
            ("CLAUDE_PROJECT".into(), p.claude_project.clone()),
        ]
        .into_iter()
        .collect();
        let policy = crate::linux_sandbox::rules::WritePolicy::from_profile(
            crate::hub::remote_sandbox::PROFILE,
            &params,
        )
        .unwrap();
        policy.read_denies()
    }

    #[test]
    fn outside_ancestor_policy_checks_ownership_and_all_parents() {
        let path = Path::new("/Library/nested/Keychains");
        for exists in [false, true] {
            for (ancestor, owned, writable) in [
                ("/Library/nested", true, false), // user-owned 0555: chmod is possible
                ("/Library", false, true),
                ("/", true, false),
            ] {
                let result = validate_outside(path, |p| {
                    Ok(if p == path && !exists {
                        None
                    } else {
                        Some((
                            p == Path::new(ancestor) && owned,
                            p == Path::new(ancestor) && writable,
                            false,
                        ))
                    })
                });
                let error = result.unwrap_err();
                assert!(
                    error.contains(path.to_str().unwrap()) && error.contains(ancestor),
                    "{error}"
                );
                assert!(
                    error.contains(if owned {
                        "owned by this user"
                    } else {
                        "writable by this user"
                    }),
                    "{error}"
                );
            }
            // All existing ancestors are root-owned 0755, including /.
            assert!(
                validate_outside(path, |p| Ok(if p == path && !exists {
                    None
                } else {
                    Some((false, false, false))
                }))
                .is_ok()
            );
        }
        // A missing intermediate ancestor must not stop the walk to /Library.
        assert!(
            validate_outside(path, |p| Ok(if p.starts_with("/Library/nested") {
                None
            } else {
                Some((p == Path::new("/Library"), false, false))
            }))
            .is_err()
        );
    }

    #[test]
    fn outside_symlink_components_are_refused_without_following() {
        let path = Path::new("/Library/Keychains");
        for link in [Path::new("/Library"), path] {
            let error = validate_outside(path, |component| {
                // /Library may point at /srv/user/library, even while that
                // target is absent. A leaf symlink must also be refused.
                assert!(!component.starts_with(link) || component == link);
                Ok(Some((false, false, component == link)))
            })
            .unwrap_err();
            assert_eq!(
                error,
                format!("{} passes through the symlink {}", path.display(), link.display())
            );
        }
    }

    #[test]
    fn absent_system_keychains_are_skipped() {
        assert!(!Path::new("/Library/Keychains").exists(), "runner must lack macOS keychains");
        assert!(
            outside_view(&[PathBuf::from("/Library/Keychains")], Path::new("/home/test"))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn outside_denials_mask_existing_and_refuse_absent_writable_names() {
        let f = Fixture::new();
        let p = f.create_paths();
        let directory = p.home.join("keychains");
        let file = p.home.join("credential");
        fs::create_dir(&directory).unwrap();
        fs::write(&file, "secret").unwrap();
        let args = outside_view(&[directory.clone(), file.clone()], &p.home).unwrap();
        assert_eq!(
            args,
            strings(&[
                "--tmpfs",
                directory.to_str().unwrap(),
                "--remount-ro",
                directory.to_str().unwrap(),
                "--ro-bind",
                "/dev/null",
                file.to_str().unwrap()
            ])
        );
        let error = outside_view(&[f.0.join("missing")], &p.home).unwrap_err();
        assert!(error.contains("owned by this user"), "{error}");
        let outside = f.0.join("existing-secret");
        fs::write(&outside, "secret").unwrap();
        let error = outside_view(&[outside], &p.home).unwrap_err();
        assert!(error.contains("present") && error.contains("be replaced"), "{error}");
    }

    #[test]
    fn argv_exact_mount_order_and_only_four_writable_host_binds() {
        let f = Fixture::new();
        let p = f.create_paths();
        let view = strings(&[
            "--tmpfs",
            p.home.to_str().unwrap(),
            "--remount-ro",
            p.home.to_str().unwrap(),
        ]);
        let command = strings(&["/usr/bin/acpmux", "__remote-sandbox-init", "--", "a b", "--bind"]);
        let (args, fds) = bwrap_args(&p, (view, Vec::new()), &command).unwrap();
        assert_eq!(fds.len(), 5);
        let mut expected: Vec<String> = "--new-session --die-with-parent --unshare-user --unshare-pid --unshare-ipc --unshare-net --unshare-uts --unshare-cgroup-try --disable-userns --ro-bind / / --dev /dev --proc /proc".split_whitespace().map(str::to_owned).collect();
        expected.extend(
            ["--tmpfs", p.home.to_str().unwrap(), "--remount-ro", p.home.to_str().unwrap()]
                .into_iter()
                .map(str::to_owned),
        );
        for path in [&p.cwd, &p.tmp, &p.claude_tmp_project, &p.claude_project] {
            expected
                .extend(["--bind-fd", "fd", path.to_str().unwrap()].into_iter().map(str::to_owned));
        }
        expected.extend(
            ["--ro-bind-fd", "fd", p.claude_project.join("memory").to_str().unwrap()]
                .into_iter()
                .map(str::to_owned),
        );
        expected.extend(
            ["--chdir", p.cwd.to_str().unwrap(), "--cap-drop", "ALL", "--"]
                .into_iter()
                .map(str::to_owned),
        );
        expected.extend(command);
        let mut normalized = args.clone();
        for index in 1..normalized.len() {
            if matches!(normalized[index - 1].as_str(), "--bind-fd" | "--ro-bind-fd") {
                normalized[index] = "fd".into();
            }
        }
        assert_eq!(normalized, expected);
        assert!(args.windows(2).filter(|w| w[0] == "--bind-fd").count() == 4);
        assert!(args.windows(2).any(|w| w[0] == "--ro-bind-fd"));
        use std::os::unix::ffi::OsStringExt;
        let mut invalid = p;
        invalid.cwd = std::ffi::OsString::from_vec(b"/invalid-\xff".to_vec()).into();
        assert!(matches!(
            bwrap_args(&invalid, (Vec::new(), Vec::new()), &strings(&["true"])),
            Err(error) if error == "sandbox paths must be UTF-8"
        ));
    }

    /// The canned-case loop stops at the end of this fixed table.
    #[test]
    fn probe_classification_is_pure_and_fail_closed() {
        assert_eq!(classify(Some(0), ""), Ok(()));
        assert_eq!(classify(Some(0), "a harmless warning"), Ok(()));
        for stderr in [
            "bwrap: setting up uid map: Permission denied",
            "bwrap: No permissions to create new namespace",
            "bwrap: Creating new namespace failed: Operation not permitted",
        ] {
            assert_eq!(classify(Some(1), stderr), Err(Unavailable::UserNamespacesRestricted));
        }
        for stderr in [
            "bwrap: Unknown option --bind-fd",
            "bwrap: Unknown option --ro-bind-fd",
            "bwrap: Unknown option --disable-userns",
            "bwrap: unrecognized option '--disable-userns'",
        ] {
            assert_eq!(classify(Some(1), stderr), Err(Unavailable::TooOld));
        }
        for stderr in
            ["bwrap: Unknown option --unrelated", "bwrap: Can't mount /: Permission denied\n"]
        {
            assert_eq!(classify(Some(1), stderr), Err(Unavailable::Other(stderr.trim().into())));
        }
        assert!(matches!(classify(Some(1), ""), Err(Unavailable::Other(_))));
        assert!(matches!(classify(None, ""), Err(Unavailable::Other(_))));
    }

    #[test]
    fn missing_probe_executable_is_not_installed() {
        let fixture = Fixture::new();
        assert_eq!(probe(&fixture.0.join("absent-bwrap")), Err(Unavailable::NotInstalled));
    }

    /// The child ends on completion or is killed at the 20-second deadline.
    #[tokio::test]
    async fn home_bind_survives_source_symlink_swap() {
        if !real_probe() {
            return;
        }
        let f = Fixture::new();
        let p = f.create_paths();
        let allowed = p.home.join("allowed");
        let secret = p.home.join(".ssh");
        fs::create_dir(&allowed).unwrap();
        fs::create_dir(&secret).unwrap();
        fs::write(allowed.join("marker"), "safe-before-swap").unwrap();
        fs::write(secret.join("marker"), "denied-marker").unwrap();
        let command =
            strings(&["/bin/sh", "-c", "cat -- \"$1/marker\"", "swap", allowed.to_str().unwrap()]);
        let (args, fds) = plan(
            &p,
            std::slice::from_ref(&secret),
            &fs::read_to_string("/proc/self/mountinfo").unwrap(),
            &command,
        )
        .unwrap();
        fs::rename(&allowed, f.0.join("held-allowed")).unwrap();
        std::os::unix::fs::symlink(&secret, &allowed).unwrap();
        let mut child = tokio::process::Command::new("/usr/bin/bwrap");
        inherit_fds(&mut child, &fds);
        child.args(args).kill_on_drop(true);
        let output =
            tokio::time::timeout(Duration::from_secs(20), child.output()).await.unwrap().unwrap();
        assert!(
            output.status.success(),
            "{}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(!String::from_utf8_lossy(&output.stdout).contains("denied-marker"));
        assert_eq!(output.stdout, b"safe-before-swap");
        eprintln!("passed: HOME bind keeps its pinned source after a symlink swap");
    }

    #[test]
    fn regression_denied_resolution_stays_pinned_across_ancestor_swap() {
        use std::os::unix::fs::symlink;
        let f = Fixture::new();
        let p = f.create_paths();
        let codex = p.home.join(".codex");
        let saved = p.home.join(".codex.saved");
        fs::create_dir(&codex).unwrap();
        fs::write(codex.join("auth.json"), "credential").unwrap();
        let denied_path = codex.join("auth.json");
        let snapshot = denied_paths_pinned(&p.home, std::slice::from_ref(&denied_path)).unwrap();
        assert!(snapshot.outside.is_empty());
        fs::rename(&codex, &saved).unwrap();
        symlink(".codex.saved", &codex).unwrap();
        let error = home_view_pinned(&p.home, &snapshot.inside, Some(&snapshot)).unwrap_err();
        assert!(
            error.contains("denied path resolution changed")
                || error.contains("HOME ancestor changed"),
            "{error}"
        );
    }

    #[test]
    fn real_home_planner_uses_the_runner_home() {
        let f = Fixture::new();
        let mut p = f.create_paths();
        p.home = PathBuf::from(std::env::var_os("HOME").expect("HOME is set on the runner"));
        let (args, _fds) = plan(
            &p,
            &profile_read_denies(&p),
            &fs::read_to_string("/proc/self/mountinfo").unwrap(),
            &strings(&["true"]),
        )
        .expect("HOME planner accepts the runner filesystem");
        assert!(args.iter().any(|arg| arg == "--tmpfs"));
    }

    /// The hook runs twice for one child; the fixture removes all swapped files.
    fn check_home_enumeration_swap(swap_parent: bool) {
        let f = Fixture::new();
        let p = f.create_paths();
        let child = p.home.join(".claude/settings.json");
        fs::write(&child, "safe").unwrap();
        let replaced = if swap_parent { child.parent().unwrap().to_owned() } else { child.clone() };
        let held = f.0.join("held");
        let replacement = f.0.join("replacement");
        if swap_parent {
            fs::create_dir(&replacement).unwrap();
            fs::write(replacement.join("settings.json"), "secret").unwrap();
        } else {
            fs::write(&replacement, "secret").unwrap();
        }
        let snapshot = denied_paths_pinned(&p.home, &[]).unwrap();
        let mut swapped = false;
        let result =
            home::rebuild(&p.home, &snapshot.inside, Some(&snapshot), &mut |path, before| {
                if path != child {
                    return;
                }
                if before {
                    fs::rename(&replaced, &held).unwrap();
                    fs::rename(&replacement, &replaced).unwrap();
                    swapped = true;
                } else {
                    fs::rename(&replaced, &replacement).unwrap();
                    fs::rename(&held, &replaced).unwrap();
                }
            });
        assert!(swapped, "enumeration/open hook was not reached");
        match result {
            Err(error) => assert!(error.contains("changed"), "unexpected refusal: {error}"),
            Ok((args, _fds)) => {
                let bind = args
                    .windows(3)
                    .find(|w| w[0] == "--ro-bind-fd" && w[2] == child.to_str().unwrap())
                    .unwrap();
                assert_eq!(fs::read(format!("/proc/self/fd/{}", bind[1])).unwrap(), b"safe");
            }
        }
    }

    #[test]
    fn regression_home_child_swap_between_stat_and_open() {
        check_home_enumeration_swap(false);
    }

    #[test]
    fn regression_home_parent_swap_between_stat_and_open() {
        check_home_enumeration_swap(true);
    }

    #[test]
    fn regression_home_child_identity_is_captured_at_enumeration() {
        let f = Fixture::new();
        let p = f.create_paths();
        let public = p.home.join("public");
        let secret = p.home.join("secret");
        fs::write(&public, "public").unwrap();
        fs::write(&secret, "secret").unwrap();
        let snapshot = denied_paths_pinned(&p.home, &[]).unwrap();
        let mut swapped = false;
        let result =
            home::rebuild(&p.home, &snapshot.inside, Some(&snapshot), &mut |path, before| {
                if path == p.home && !before && !swapped {
                    fs::rename(&public, f.0.join("public-held")).unwrap();
                    fs::rename(&secret, &public).unwrap();
                    fs::rename(f.0.join("public-held"), &secret).unwrap();
                    swapped = true;
                } else if path == public && !before && swapped {
                    fs::rename(&public, f.0.join("public-held")).unwrap();
                    fs::rename(&secret, &public).unwrap();
                    fs::rename(f.0.join("public-held"), &secret).unwrap();
                }
            });
        if swapped {
            fs::rename(&public, f.0.join("public-held")).unwrap();
            fs::rename(&secret, &public).unwrap();
            fs::rename(f.0.join("public-held"), &secret).unwrap();
        }
        assert!(swapped, "enumeration swap hook was not reached");
        assert!(result.is_err(), "child identity race was accepted");
    }

    /// The child is killed on the 20-second deadline. Shell loops exhaust
    /// finite /proc snapshots and network tables; no background jobs are made.
    #[tokio::test]
    async fn real_bwrap_isolates_mounts_processes_and_network() {
        let bwrap = Path::new("/usr/bin/bwrap");
        if !real_probe() {
            return;
        }
        eprintln!("running: real bwrap isolation test ({})", bwrap.display());
        let fixture = Fixture::new();
        let p = fixture.create_paths();
        let outside = fixture.0.join("outside");
        fs::write(&outside, "unchanged").unwrap();
        let secret = p.home.join(".netrc");
        const FILE_MARKER: &str = "acpmux-file-secret-marker";
        const DIRECTORY_MARKER: &str = ".acpmux-directory-secret-marker";
        fs::write(&secret, FILE_MARKER).unwrap();
        let secrets = p.home.join(".ssh");
        fs::create_dir(&secrets).unwrap();
        fs::write(secrets.join(DIRECTORY_MARKER), DIRECTORY_MARKER).unwrap();
        let memory = p.claude_project.join("memory/keep");
        fs::write(&memory, "unchanged").unwrap();
        let host_pid_ns = fs::read_link("/proc/self/ns/pid").unwrap();
        let host_net_ns = fs::read_link("/proc/self/ns/net").unwrap();
        let script = r#"
set -eu
outside=$1; secret=$2; secrets=$3; tmp=$4; scratch=$5; project=$6; host_pid_ns=$7; host_net_ns=$8
file_marker=$9; directory_marker=${10}
fail() { code=$1; shift; printf 'check %s: %s\n' "$code" "$*" >&2; exit "$code"; }
# A nodev /dev/null mask can deny the open instead of returning EOF.
# Capture stdout even on failure, so partial disclosure cannot pass.
check_hidden_read() {
    content=$(cat -- "$1" 2>/dev/null) || :
    case "$content" in *"$2"*) fail "$3" "masked read path=$1 exposed marker; content=<$content>";; esac
    case "$content" in '') ;; *) fail "$4" "masked read path=$1 returned content=<$content>";; esac
}
if (printf changed > "$outside") 2>/dev/null; then
    fail 10 "outside write succeeded: path=$outside"
fi
printf inside > ./inside || fail 11 "cwd write failed: status=$? path=./inside"
printf temp > "$tmp/inside" || fail 12 "temp write failed: status=$? path=$tmp/inside"
printf scratch > "$scratch/inside" || fail 13 "scratch write failed: status=$? path=$scratch/inside"
printf transcript > "$project/inside" || fail 14 "transcript write failed: status=$? path=$project/inside"
if (printf changed > "$project/memory/keep") 2>/dev/null; then
    fail 15 "memory write succeeded: path=$project/memory/keep"
fi
check_hidden_read "$secret" "$file_marker" 16 17
check_hidden_read "$secrets/$directory_marker" "$directory_marker" 18 19
listing=$(ls -A -- "$secrets" 2>/dev/null) || :
case "$listing" in *"$directory_marker"*) fail 20 "masked directory exposed marker: listing=<$listing>";; esac
case "$listing" in '') ;; *) fail 21 "masked directory returned entries: listing=<$listing>";; esac
if [ -e "$secrets/$directory_marker" ]; then
    fail 22 "masked entry exists: path=$secrets/$directory_marker listing=<$listing>"
fi
if (printf changed > "$secrets/new") 2>/dev/null; then
    fail 23 "masked directory write succeeded: path=$secrets/new"
fi
self_pid_ns=$(readlink /proc/self/ns/pid 2>&1) || fail 24 "self PID namespace readlink failed: status=$? output=<$self_pid_ns>"
case "$self_pid_ns" in '') fail 25 "self PID namespace empty: observed=<$self_pid_ns>";; esac
if [ "$self_pid_ns" = "$host_pid_ns" ]; then
    fail 26 "PID namespace not isolated: sandbox=<$self_pid_ns> host=<$host_pid_ns>"
fi
init_pid_ns=$(readlink /proc/1/ns/pid 2>&1) || fail 27 "PID 1 namespace readlink failed: status=$? output=<$init_pid_ns>"
case "$init_pid_ns" in '') fail 28 "PID 1 namespace empty: observed=<$init_pid_ns>";; esac
if [ "$init_pid_ns" != "$self_pid_ns" ]; then
    fail 29 "PID namespace mismatch: PID1=<$init_pid_ns> self=<$self_pid_ns>"
fi
count=0; entries=
for entry in /proc/[0-9]*; do count=$((count + 1)); entries="$entries $entry"; done
if [ "$count" -gt 4 ]; then
    fail 30 "too many visible processes: count=$count entries=<$entries>"
fi

# The host's sysfs mount describes its network namespace. Use only the
# per-reader /proc view here; loaded modules may create fallback devices.
self_net_ns=$(readlink /proc/self/ns/net 2>&1) || fail 31 "network namespace readlink failed: status=$? output=<$self_net_ns>"
case "$self_net_ns" in '') fail 32 "network namespace empty: observed=<$self_net_ns>";; esac
if [ "$self_net_ns" = "$host_net_ns" ]; then
    fail 33 "network namespace not isolated: sandbox=<$self_net_ns> host=<$host_net_ns>"
fi
net_data=$(cat /proc/self/net/dev 2>&1) || fail 34 "network interface table read failed: status=$? output=<$net_data>"
bad_iface=$(printf '%s\n' "$net_data" | awk -F: '/:/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 !~ /^(lo|tunl0|gre0|gretap0|erspan0|ip_vti0|ip6_vti0|sit0|ip6tnl0|ip6gre0)$/) print $0 }') || fail 35 "interface inspection failed: status=$? data=<$net_data>"
case "$bad_iface" in '') ;; *) fail 36 "unexpected interface: observed=<$bad_iface> all=<$net_data>";; esac

ipv6_data=$(cat /proc/self/net/if_inet6 2>&1) || fail 37 "IPv6 address table read failed: status=$? output=<$ipv6_data>"
bad_ipv6=$(printf '%s\n' "$ipv6_data" | awk 'NF && (NF != 6 || $1 != "00000000000000000000000000000001") { print $0 }') || fail 38 "IPv6 address inspection failed: status=$? data=<$ipv6_data>"
case "$bad_ipv6" in '') ;; *) fail 39 "non-loopback IPv6 address: observed=<$bad_ipv6> all=<$ipv6_data>";; esac

fib_data=$(cat /proc/self/net/fib_trie 2>&1) || fail 40 "IPv4 address table read failed: status=$? output=<$fib_data>"
# Each leaf address precedes its /prefix scope/type line. Only LOCAL
# entries are assigned addresses; UNICAST/BROADCAST entries are not.
bad_ipv4=$(printf '%s\n' "$fib_data" | awk '/\|--/ { address=$2 } $NF == "LOCAL" && address !~ /^127\.[0-9]+\.[0-9]+\.[0-9]+$/ { print "address=<" address "> " $0 }') || fail 41 "IPv4 LOCAL address inspection failed: status=$? data=<$fib_data>"
case "$bad_ipv4" in '') ;; *) fail 42 "non-loopback IPv4 LOCAL address: observed=<$bad_ipv4> all=<$fib_data>";; esac

route_data=$(cat /proc/self/net/route 2>&1) || fail 43 "IPv4 route table read failed: status=$? output=<$route_data>"
bad_route=$(printf '%s\n' "$route_data" | awk 'NR > 1 && NF { print $0 }') || fail 44 "IPv4 route inspection failed: status=$? data=<$route_data>"
case "$bad_route" in '') ;; *) fail 45 "unexpected IPv4 route: observed=<$bad_route> all=<$route_data>";; esac
ipv6_route_data=$(cat /proc/self/net/ipv6_route 2>&1) || fail 46 "IPv6 route table read failed: status=$? output=<$ipv6_route_data>"
bad_ipv6_route=$(printf '%s\n' "$ipv6_route_data" | awk 'NF && (NF != 10 || $10 != "lo") { print $0 }') || fail 47 "IPv6 route inspection failed: status=$? data=<$ipv6_route_data>"
case "$bad_ipv6_route" in '') ;; *) fail 48 "non-loopback IPv6 route: observed=<$bad_ipv6_route> all=<$ipv6_route_data>";; esac
"#;
        let mut command = strings(&["/bin/sh", "-c", script, "acpmux-bwrap-test"]);
        command.extend(
            [
                &outside,
                &secret,
                &secrets,
                &p.tmp,
                &p.claude_tmp_project,
                &p.claude_project,
                &host_pid_ns,
                &host_net_ns,
            ]
            .into_iter()
            .map(|path| path.to_str().unwrap().to_owned()),
        );
        command.extend([FILE_MARKER.to_owned(), DIRECTORY_MARKER.to_owned()]);
        let (args, fds) = plan(
            &p,
            &profile_read_denies(&p),
            &fs::read_to_string("/proc/self/mountinfo").unwrap(),
            &command,
        )
        .unwrap();
        let mut child = tokio::process::Command::new(bwrap);
        inherit_fds(&mut child, &fds);
        child
            .args(args)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true);
        let output = tokio::time::timeout(std::time::Duration::from_secs(20), child.output())
            .await
            .expect("bwrap test exceeded 20 seconds")
            .unwrap();
        assert!(
            output.status.success(),
            "status {}; stderr: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(fs::read_to_string(outside).unwrap(), "unchanged");
        assert_eq!(fs::read_to_string(memory).unwrap(), "unchanged");
        assert_eq!(fs::read_to_string(p.cwd.join("inside")).unwrap(), "inside");
        eprintln!("passed: real bwrap mount, PID, and network isolation");
    }
}
