//! Bubblewrap mount/namespace plan. Not wired to remote spawns until G2.
//! This layer alone is insufficient: the seccomp supervisor and network
//! proxy must also be installed before a remote command may run.
#![allow(dead_code)] // Staged API: G1/G2 supply the production callers.

use std::collections::BTreeSet;
use std::ffi::{CString, OsStr, OsString};
use std::fmt;
use std::fs;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;
use wait_timeout::ChildExt;

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

/// The argv and source descriptors needed to invoke bubblewrap.
///
/// Callers must keep the descriptors alive until bwrap has started and clear
/// `FD_CLOEXEC` before spawning it (G1 does this in `pre_exec`).
pub(crate) type BwrapPlan = (Vec<String>, Vec<OwnedFd>);

/// Build bubblewrap argv and open every bind source with `openat2`.
/// The loop ends after four writable roots. HOME is rebuilt first.
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
        return Err(format!("bind source changed: expected {}, got {}", canonical.display(), actual.display()));
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

/// Read a symlink through its already-open parent directory, avoiding a
/// pathname race between the directory snapshot and the emitted `--symlink`.
fn read_link_at(parent: RawFd, name: &OsStr) -> Result<OsString, String> {
    let c_name = CString::new(name.as_bytes()).map_err(|_| "symlink name contains NUL".to_owned())?;
    let mut bytes = vec![0_u8; libc::PATH_MAX as usize];
    // SAFETY: the fd and C string are valid; the output buffer is writable.
    let len = unsafe {
        libc::readlinkat(parent, c_name.as_ptr(), bytes.as_mut_ptr().cast(), bytes.len())
    };
    if len < 0 {
        return Err(format!("cannot read symlink {}: {}", name.to_string_lossy(), io::Error::last_os_error()));
    }
    bytes.truncate(len as usize);
    Ok(OsString::from_vec(bytes))
}

/// Resolve existing symlinks even when a final component is absent. The
/// loop stops at the first existing ancestor (at worst /); errors refuse.
fn resolve_missing(path: &Path) -> Result<PathBuf, String> {
    let mut ancestor = path.to_owned();
    loop {
        match fs::canonicalize(&ancestor) {
            Ok(root) => {
                let rest = path.strip_prefix(&ancestor).map_err(|e| e.to_string())?;
                return Ok(if rest.as_os_str().is_empty() { root } else { root.join(rest) });
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                if !ancestor.pop() {
                    return Err(format!("cannot resolve {}: {e}", path.display()));
                }
            }
            Err(e) => return Err(format!("cannot resolve {}: {e}", path.display())),
        }
    }
}

/// Both lexical and canonical HOME names stay denied. Existing paths outside
/// HOME are returned for direct masks; absent paths under an unwritable
/// ancestor are skipped because this uid cannot create them later.
fn denied_paths(
    home: &Path,
    read_denies: &[PathBuf],
) -> Result<(BTreeSet<PathBuf>, Vec<PathBuf>), String> {
    let mut inside = BTreeSet::new();
    let mut outside = BTreeSet::new();
    for path in read_denies.iter().cloned().chain(LINUX_READ_DENIES.iter().map(|p| home.join(p))) {
        path_arg(&path)?;
        let resolved = resolve_missing(&path)?;
        if path.starts_with(home) {
            if !resolved.starts_with(home) {
                return Err(format!(
                    "denied path {} resolves outside HOME: {}",
                    path.display(),
                    resolved.display()
                ));
            }
            inside.insert(path);
            if resolved != home {
                inside.insert(resolved);
            }
            continue;
        }
        if resolved.starts_with(home) {
            inside.insert(resolved);
            continue;
        }
        match fs::symlink_metadata(&path) {
            Ok(_) => {
                outside.insert(path);
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let ancestor = first_existing_ancestor(&path);
                if !is_writable_by_uid(&ancestor)? {
                    continue;
                }
                return Err(format!(
                    "denied path {} is absent under writable ancestor {}",
                    path.display(),
                    ancestor.display()
                ));
            }
            Err(e) => return Err(format!("cannot inspect {}: {e}", path.display())),
        }
    }
    Ok((inside, outside.into_iter().collect()))
}

fn first_existing_ancestor(path: &Path) -> PathBuf {
    let mut ancestor = path.to_owned();
    while !ancestor.exists() {
        if !ancestor.pop() {
            return PathBuf::from("/");
        }
    }
    ancestor
}

fn is_writable_by_uid(path: &Path) -> Result<bool, String> {
    let text = path_arg(path)?;
    let c_path = CString::new(text.as_bytes()).map_err(|_| format!("path contains NUL: {text}"))?;
    // SAFETY: c_path is a valid NUL-terminated path.
    let result = unsafe { libc::access(c_path.as_ptr(), libc::W_OK) };
    if result == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(code) if matches!(code, libc::EACCES | libc::ENOENT | libc::EROFS) => Ok(false),
        _ => Err(format!("cannot inspect write access to {text}: {error}")),
    }
}

/// Rebuild denied ancestors; new host entries remain invisible (stricter than Seatbelt).
fn home_view(home: &Path, denied: &BTreeSet<PathBuf>) -> Result<BwrapPlan, String> {
    // Keep the built-in Linux deny set local to this rebuild as a second
    // boundary: callers cannot accidentally omit Claude's credential.
    let mut denied_owned = denied.clone();
    for path in LINUX_READ_DENIES.iter().map(|p| home.join(p)) {
        denied_owned.insert(path.clone());
        denied_owned.insert(resolve_missing(&path)?);
    }
    let denied = &denied_owned;
    let mut dirs = BTreeSet::from([home.to_owned()]);
    // Include every denied name: an ancestor is rebuilt even when another
    // denial makes its leaf redundant, so Linux additions (including Claude's
    // credential) can never be forgotten by the caller.
    for path in denied {
        for parent in path.ancestors().skip(1).take_while(|p| p.starts_with(home)) {
            let parent = resolve_missing(parent)?;
            if !parent.starts_with(home) {
                return Err(format!("ancestor outside HOME: {}", parent.display()));
            }
            if !denied.iter().any(|d| parent.starts_with(d)) {
                dirs.insert(parent);
            }
        }
    }
    let mut out = Vec::new();
    let mut fds = Vec::new();
    for dir in &dirs {
        out.extend(["--tmpfs".into(), path_arg(dir)?]);
        let parent_fd = match open_bind_source(dir) {
            Ok(fd) => fd,
            Err(_error) if !dir.exists() => continue,
            Err(error) => return Err(error),
        };
        let children = match fs::read_dir(dir) {
            Ok(entries) => {
                entries.map(|e| e.map(|e| e.path())).collect::<io::Result<BTreeSet<_>>>()
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(BTreeSet::new()),
            Err(e) => Err(e),
        }
        .map_err(|e| format!("cannot snapshot {}: {e}", dir.display()))?;
        if children.len() > 512 {
            return Err(format!("HOME rebuild directory {} has more than 512 entries", dir.display()));
        }
        for child in children {
            if denied.iter().any(|d| child.starts_with(d)) || dirs.contains(&child) {
                continue;
            }
            let meta = fs::symlink_metadata(&child).map_err(|e| e.to_string())?;
            if meta.is_symlink() {
                let target = read_link_at(parent_fd.as_raw_fd(), &child.file_name())?;
                let target = target.to_str().ok_or("symlink target must be UTF-8")?;
                out.extend(["--symlink".into(), target.into(), path_arg(&child)?]);
            } else {
                let child_text = path_arg(&child)?;
                let fd = open_bind_source(&child)?;
                out.extend(["--ro-bind-fd".into(), fd.as_raw_fd().to_string(), child_text]);
                fds.push(fd);
            }
        }
    }
    // Seal only after every descendant mountpoint and symlink exists.
    for dir in dirs.iter().rev() {
        out.extend(["--remount-ro".into(), path_arg(dir)?]);
    }
    Ok((out, fds))
}

/// Mask existing denied paths outside HOME. Missing paths under an unwritable
/// ancestor are omitted by `denied_paths`; no host path is followed here.
fn outside_view(paths: &[PathBuf]) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for path in paths {
        let text = path_arg(path)?;
        let meta = fs::symlink_metadata(path)
            .map_err(|e| format!("cannot inspect outside denied path {text}: {e}"))?;
        if meta.is_dir() {
            out.extend(["--tmpfs".into(), text.clone(), "--remount-ro".into(), text]);
        } else {
            out.extend(["--ro-bind".into(), "/dev/null".into(), text]);
        }
    }
    Ok(out)
}

/// Caller supplies explicit denied paths from `rules::read_denies`; Linux
/// additions are included here. The returned descriptors must be inherited by
/// bwrap with CLOEXEC cleared. No spawn is wired yet.
pub(crate) fn plan(
    paths: &Paths,
    read_denies: &[PathBuf],
    cmd_prefix: &[String],
) -> Result<BwrapPlan, String> {
    let memory = paths.claude_project.join("memory");
    let writable = [&paths.cwd, &paths.tmp, &paths.claude_tmp_project, &paths.claude_project];
    for path in [&paths.home, &memory].into_iter().chain(writable) {
        path_arg(path)?;
        if fs::canonicalize(path).map_err(|e| e.to_string())? != *path {
            return Err(format!("noncanonical sandbox path: {}", path.display()));
        }
    }
    let (denied, outside) = denied_paths(&paths.home, read_denies)?;
    // A later writable bind must never reintroduce a denied subtree.
    for root in writable {
        if denied.iter().any(|d| root.starts_with(d) || d.starts_with(root)) {
            return Err(format!("writable root overlaps read denial: {}", root.display()));
        }
    }
    let mut home = home_view(&paths.home, &denied)?;
    let outside = outside_view(&outside)?;
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
    let mut child = Command::new(bwrap)
        .args("--unshare-user --unshare-net --disable-userns --ro-bind / / --bind-fd 0 /tmp --ro-bind-fd 0 /var true".split_whitespace())
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .current_dir("/")
        .stdin(Stdio::from(probe_root))
        .stdout(Stdio::null())
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

    fn clear_fd_cloexec(fds: &[OwnedFd]) {
        for fd in fds {
            // SAFETY: each descriptor is owned by this test and remains alive
            // through child creation.
            assert_eq!(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, 0) }, 0);
        }
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
        let resolved_claude = resolve_missing(&p.home.join(".claude")).unwrap();
        assert_eq!(resolved_claude, fs::canonicalize(p.home.join(".claude")).unwrap());
        assert!(!resolved_claude.to_string_lossy().ends_with('/'));
        let (denied, outside) = denied_paths(&p.home, &[p.home.join(".ssh"), p.home.join(".aws")]).unwrap();
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
        let (args, _fds) = plan(&p, &[], &strings(&["true"])).unwrap();
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

    #[test]
    fn production_read_denies_allow_a_linux_plan() {
        let f = Fixture::new();
        let p = f.create_paths();
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
        let (args, _fds) = plan(&p, &policy.read_denies(), &strings(&["true"])).unwrap();
        assert!(args.windows(2).any(|w| w == ["--tmpfs", p.home.to_str().unwrap()]));
    }

    #[test]
    fn argv_exact_mount_order_and_only_four_writable_host_binds() {
        let f = Fixture::new();
        let p = f.create_paths();
        let view = strings(&["--tmpfs", p.home.to_str().unwrap(), "--remount-ro", p.home.to_str().unwrap()]);
        let command = strings(&["/usr/bin/acpmux", "__remote-sandbox-init", "--", "a b", "--bind"]);
        let (args, fds) = bwrap_args(&p, (view, Vec::new()), &command).unwrap();
        assert_eq!(fds.len(), 5);
        let mut expected: Vec<String> = "--new-session --die-with-parent --unshare-user --unshare-pid --unshare-ipc --unshare-net --unshare-uts --unshare-cgroup-try --disable-userns --ro-bind / / --dev /dev --proc /proc".split_whitespace().map(str::to_owned).collect();
        expected.extend(["--tmpfs", p.home.to_str().unwrap(), "--remount-ro", p.home.to_str().unwrap()].into_iter().map(str::to_owned));
        for path in [&p.cwd, &p.tmp, &p.claude_tmp_project, &p.claude_project] {
            expected.extend(["--bind-fd", "fd", path.to_str().unwrap()].into_iter().map(str::to_owned));
        }
        expected.extend(["--ro-bind-fd", "fd", p.claude_project.join("memory").to_str().unwrap()].into_iter().map(str::to_owned));
        expected.extend(["--chdir", p.cwd.to_str().unwrap(), "--cap-drop", "ALL", "--"].into_iter().map(str::to_owned));
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

    /// Stops after the fixed refusal-message table.
    #[test]
    fn refusal_messages_name_the_remedy() {
        for (reason, text) in [
            (
                Unavailable::NotInstalled,
                "bwrap not installed (Debian/Ubuntu: apt install bubblewrap)",
            ),
            (Unavailable::TooOld, "bwrap older than 0.9 (missing --disable-userns/--bind-fd/--ro-bind-fd)"),
            (
                Unavailable::UserNamespacesRestricted,
                "unprivileged user namespaces are restricted (kernel.apparmor_restrict_unprivileged_userns=1) and /usr/bin/bwrap has no AppArmor profile; install it: Ubuntu's apparmor package ships /etc/apparmor.d/bwrap-userns-restrict",
            ),
            (Unavailable::Other("diagnostic".into()), "diagnostic"),
        ] {
            assert_eq!(reason.to_string(), text);
        }
    }

    #[test]
    fn missing_probe_executable_is_not_installed() {
        let fixture = Fixture::new();
        assert_eq!(probe(&fixture.0.join("absent-bwrap")), Err(Unavailable::NotInstalled));
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
            &command,
        )
        .unwrap();
        clear_fd_cloexec(&fds);
        let mut child = tokio::process::Command::new("/usr/bin/bwrap")
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
net_data=$(cat /proc/net/dev 2>&1) || fail 34 "network interface table read failed: status=$? output=<$net_data>"
bad_iface=$(printf '%s\n' "$net_data" | awk -F: '/:/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 !~ /^(lo|tunl0|gre0|gretap0|erspan0|ip_vti0|ip6_vti0|sit0|ip6tnl0|ip6gre0)$/) print $0 }') || fail 35 "interface inspection failed: status=$? data=<$net_data>"
case "$bad_iface" in '') ;; *) fail 36 "unexpected interface: observed=<$bad_iface> all=<$net_data>";; esac

ipv6_data=$(cat /proc/net/if_inet6 2>&1) || fail 37 "IPv6 address table read failed: status=$? output=<$ipv6_data>"
bad_ipv6=$(printf '%s\n' "$ipv6_data" | awk 'NF && (NF != 6 || $1 != "00000000000000000000000000000001") { print $0 }') || fail 38 "IPv6 address inspection failed: status=$? data=<$ipv6_data>"
case "$bad_ipv6" in '') ;; *) fail 39 "non-loopback IPv6 address: observed=<$bad_ipv6> all=<$ipv6_data>";; esac

fib_data=$(cat /proc/net/fib_trie 2>&1) || fail 40 "IPv4 address table read failed: status=$? output=<$fib_data>"
# Each leaf address precedes its /prefix scope/type line. Only LOCAL
# entries are assigned addresses; UNICAST/BROADCAST entries are not.
bad_ipv4=$(printf '%s\n' "$fib_data" | awk '/\|--/ { address=$2 } $NF == "LOCAL" && address !~ /^127\.[0-9]+\.[0-9]+\.[0-9]+$/ { print "address=<" address "> " $0 }') || fail 41 "IPv4 LOCAL address inspection failed: status=$? data=<$fib_data>"
case "$bad_ipv4" in '') ;; *) fail 42 "non-loopback IPv4 LOCAL address: observed=<$bad_ipv4> all=<$fib_data>";; esac

route_data=$(cat /proc/net/route 2>&1) || fail 43 "IPv4 route table read failed: status=$? output=<$route_data>"
bad_route=$(printf '%s\n' "$route_data" | awk 'NR > 1 && NF { print $0 }') || fail 44 "IPv4 route inspection failed: status=$? data=<$route_data>"
case "$bad_route" in '') ;; *) fail 45 "unexpected IPv4 route: observed=<$bad_route> all=<$route_data>";; esac
ipv6_route_data=$(cat /proc/net/ipv6_route 2>&1) || fail 46 "IPv6 route table read failed: status=$? output=<$ipv6_route_data>"
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
            &[secrets, secret],
            &command,
        )
        .unwrap();
        clear_fd_cloexec(&fds);
        let mut child = tokio::process::Command::new(bwrap);
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
