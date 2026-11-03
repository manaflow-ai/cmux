//! The worktree a sub-session can start in (`start_session` with
//! `worktree: true`, `hub/subsessions.rs`): a new git worktree of the
//! folder's repository, laid out as the app's `git.worktree.create` lays one
//! out (`cmux-tui-core` `git_ops/worktree.rs`), so its Apply and Remove work
//! on it. acpmux does not depend on that crate, and that one runs the user's
//! worktree hooks on purpose; this one runs git in the daemon, outside the
//! agent's sandbox, on a repository the agent can write, so it runs nothing
//! that repository names.
//!
//! The worktree is added without a checkout, and its files are written by a
//! throwaway git directory that borrows the repository's objects but none of
//! its config, nor the user's: no filter, hook, fsmonitor, transport,
//! credential helper or lazy fetch can come from what the agent wrote, and
//! a change the agent makes to that config meanwhile changes nothing. The
//! files are as committed (a Git LFS file stays its pointer); the child's own
//! git, in its sandbox, uses the repository's config from then on.
//!
//! A partial clone (`--filter=blob:none`) may lack some of the commit's
//! files, e.g. when it was cloned without a checkout or checks out sparsely.
//! Those, and only those, are fetched first from its promisor remote's URL,
//! by git reading the user's and system's config but not the repository's,
//! and only over the file, git, http, https and ssh transports.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::Instant;

/// A worktree [`make_worktree`] made.
#[derive(Clone)]
pub struct Worktree {
    pub root: PathBuf,
    pub branch: String,
    pub base: String,
    /// The folder the child starts in: the started-from folder's place in the worktree.
    pub cwd: PathBuf,
    /// The device and inode of `root` as [`make_worktree`] opened it right after git added it
    /// (unix): [`verify_made`] proves the folder at `root` later is still that one.
    pub root_pin: Option<crate::cwd_pin::CwdPin>,
    /// `root`, held open from before git filled it (unix): its inode is never another folder's
    /// while this lives, so `root_pin` names this folder only.
    pub root_held: Option<std::sync::Arc<std::fs::File>>,
}

/// No automatic maintenance or gc: run from the throwaway git directory,
/// whose refs reach none of the repository's objects, it would prune them
/// (the user's unpushed work).
const NO_MAINTENANCE: [&str; 4] = ["-c", "maintenance.auto=false", "-c", "gc.auto=0"];

/// The folder git runs in: `path`, or (unix) the very folder `held` was opened on, wherever
/// `path` leads now: a sub-session's checked folder (`hub/subsession_guard.rs`), so a folder
/// renamed or a link swapped after its check never has a worktree made from it.
#[derive(Clone, Copy)]
pub struct Dir<'a> {
    path: &'a Path,
    #[cfg(unix)]
    held: Option<&'a std::fs::File>,
}

impl<'a> Dir<'a> {
    /// The folder `held` holds (unix; `path` names it in messages), else `path`.
    pub fn held(path: &'a Path, held: Option<&'a std::fs::File>) -> Self {
        #[cfg(not(unix))]
        let _ = held;
        Self {
            path,
            #[cfg(unix)]
            held,
        }
    }
}

impl<'a> From<&'a Path> for Dir<'a> {
    fn from(path: &'a Path) -> Self {
        Self::held(path, None)
    }
}

impl<'a> From<&'a PathBuf> for Dir<'a> {
    fn from(path: &'a PathBuf) -> Self {
        Self::held(path, None)
    }
}

/// Git that runs nothing from the repository at `dir`: no hooks, fsmonitor,
/// submodule recursion, credential helper, system config, network transport
/// or lazy fetch of a partial clone.
fn hardened(dir: Dir<'_>) -> Command {
    let mut cmd = Command::new("git");
    #[cfg(unix)]
    if let Some(held) = dir.held {
        use std::os::fd::AsRawFd;
        use std::os::unix::process::CommandExt;
        let fd = held.as_raw_fd();
        // SAFETY: runs in the child between fork and exec, after any `current_dir`; fchdir(2)
        // is async-signal-safe and allocates nothing. `held` outlives the spawn (borrowed).
        unsafe {
            cmd.pre_exec(move || {
                if libc::fchdir(fd) == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
            });
        }
    }
    #[cfg(unix)]
    let at = if dir.held.is_some() { Path::new(".") } else { dir.path };
    #[cfg(not(unix))]
    let at = dir.path;
    cmd.arg("-C")
        .arg(at)
        .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        .args(["-c", "submodule.recurse=false", "-c", "credential.helper="])
        .args(NO_MAINTENANCE)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .env("GIT_ALLOW_PROTOCOL", "none")
        .env("GIT_SSH_COMMAND", "false")
        .env("GIT_LFS_SKIP_SMUDGE", "1")
        .env("LC_ALL", "C");
    cmd
}

fn run(cmd: Command, args: &[&str]) -> Result<String, String> {
    run_by(cmd, args, None)
}

/// [`run`], its process group killed at `by` (`hub/worktree_care/revive.rs`).
fn run_by(mut cmd: Command, args: &[&str], by: Option<Instant>) -> Result<String, String> {
    cmd.args(args);
    let out = output_by(cmd, None, by)?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("git {} failed: {}", args.join(" "), err.trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn git<'a>(dir: impl Into<Dir<'a>>, args: &[&str]) -> Result<String, String> {
    run(hardened(dir.into()), args)
}

/// Git that runs nothing from the repository at `dir` ([`hardened`]), ended at `by`.
pub(crate) fn git_by(dir: &Path, args: &[&str], by: Instant) -> Result<String, String> {
    run_by(hardened(dir.into()), args, Some(by))
}

/// `cmd`'s output, `input` on its stdin. With `by`, it runs in a process group of its own,
/// killed whole at `by` (a filter or helper it started that hangs goes with it).
fn output_by(
    mut cmd: Command,
    input: Option<Vec<u8>>,
    by: Option<Instant>,
) -> Result<Output, String> {
    use std::io::{Read, Write};
    if by.is_some_and(|by| Instant::now() >= by) {
        return Err("git did not finish in time".into());
    }
    #[cfg(unix)]
    if by.is_some() {
        std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    }
    cmd.stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() });
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| format!("git did not run: {e}"))?;
    // Written from a thread: git may answer before it reads it all.
    let stdin = child
        .stdin
        .take()
        .zip(input)
        .map(|(mut stdin, input)| std::thread::spawn(move || stdin.write_all(&input)));
    let Some(by) = by else {
        let out = child.wait_with_output().map_err(|e| format!("git did not run: {e}"));
        if let Some(Err(e)) = stdin.and_then(|w| w.join().ok()) {
            return Err(e.to_string());
        }
        return out;
    };
    let (tx, rx) = std::sync::mpsc::channel();
    for (is_stdout, pipe) in [
        (true, child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>)),
        (false, child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>)),
    ] {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut got = Vec::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_end(&mut got);
            }
            let _ = tx.send((is_stdout, got));
        });
    }
    drop(tx);
    let stop = |child: &mut std::process::Child| {
        #[cfg(unix)]
        unsafe {
            libc::killpg(child.id() as i32, libc::SIGKILL);
        }
        let _ = child.kill();
        let _ = child.wait();
    };
    let status = match wait_timeout::ChildExt::wait_timeout(
        &mut child,
        by.saturating_duration_since(Instant::now()),
    ) {
        Ok(Some(status)) => status,
        result => {
            stop(&mut child);
            return Err(format!("git did not finish in time: {result:?}"));
        }
    };
    let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
    for _ in 0..2 {
        match rx.recv_timeout(by.saturating_duration_since(Instant::now())) {
            Ok((true, bytes)) => stdout = bytes,
            Ok((false, bytes)) => stderr = bytes,
            Err(_) => {
                stop(&mut child);
                return Err("git output did not close in time".into());
            }
        }
    }

    Ok(Output { status, stdout, stderr })
}

/// Adds a worktree of the repository whose common git directory is `common` at `root` (`add`:
/// `git worktree add --no-checkout`'s arguments) and writes `commit`'s files into it as
/// [`make_worktree`] does: no config of the repository's runs (no filter, hook or helper).
/// Each git call ends at `by`. Removed again when its files cannot be written.
pub(crate) fn add_without_config(
    common: &Path,
    add: &[&str],
    root: &Path,
    commit: &str,
    by: Instant,
) -> Result<(), String> {
    let git = |args: &[&str]| git_by(common, args, by);
    let path = ["rev-parse", "--path-format=absolute", "--git-path", "objects"];
    let objects = PathBuf::from(git(&path)?);
    let format = git(&["rev-parse", "--show-object-format"])?;
    // Fill a sibling first: timeout or failed checkout must never expose a partial cwd.
    let staged = root.with_file_name(format!(".acpmux-revive-{}", uuid::Uuid::now_v7()));
    let (destination, stage) = (root.to_string_lossy(), staged.to_string_lossy());
    let args: Vec<&str> = ["worktree", "add", "--no-checkout"]
        .into_iter()
        .chain(add.iter().map(|arg| if *arg == destination { stage.as_ref() } else { *arg }))
        .collect();
    git(&args)?;
    let filled = git_by(&staged, &["rev-parse", "HEAD"], by)
        .and_then(|actual| {
            (actual == commit).then_some(()).ok_or_else(|| "branch advanced during recovery".into())
        })
        .and_then(|()| {
            check_out_without_config(&objects, &format, staged.as_path().into(), commit, Some(by))
        })
        .and_then(|()| git_by(&staged, &["read-tree", commit], by).map(drop))
        .and_then(|()| git_by(&staged, &["rev-parse", "HEAD"], by))
        .and_then(|actual| {
            (actual == commit).then_some(()).ok_or_else(|| "branch advanced during recovery".into())
        })
        .and_then(|()| git(&["worktree", "move", &stage, &destination]).map(drop))
        .and_then(|()| {
            if root.join(staged.file_name().unwrap_or_default()).exists()
                || !root.join(".git").is_file()
            {
                Err("worktree destination changed during recovery".into())
            } else {
                Ok(())
            }
        });
    if filled.is_err() {
        let cleanup_by = Instant::now() + std::time::Duration::from_secs(5);
        let nested = root.join(staged.file_name().unwrap_or_default());
        for path in [&staged, &nested] {
            let _ = git_by(
                common,
                &["worktree", "remove", "--force", &path.to_string_lossy()],
                cleanup_by,
            );
        }
    }
    filled
}

/// Writes `commit`'s files into `root` with a throwaway git directory next
/// to nothing of the repository's but its objects (`objects`): no config of
/// the repository's, the user's or the system's is read.
fn check_out_without_config(
    objects: &Path,
    format: &str,
    root: Dir<'_>,
    commit: &str,
    by: Option<Instant>,
) -> Result<(), String> {
    let scratch = std::env::temp_dir().join(format!("acpmux-wt-{}", uuid::Uuid::now_v7()));
    let result: Result<(), String> = (|| {
        let info = scratch.join("objects/info");
        std::fs::create_dir_all(&info).map_err(|e| format!("{}: {e}", info.display()))?;
        std::fs::create_dir_all(scratch.join("refs")).map_err(|e| e.to_string())?;
        std::fs::write(scratch.join("HEAD"), format!("{commit}\n")).map_err(|e| e.to_string())?;
        // Only what reading its objects needs: the format version and hash.
        let config = if format == "sha1" {
            "[core]\n\trepositoryformatversion = 0\n".to_owned()
        } else {
            format!(
                "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tobjectFormat = {format}\n"
            )
        };
        std::fs::write(scratch.join("config"), config).map_err(|e| e.to_string())?;
        std::fs::write(info.join("alternates"), format!("{}\n", objects.display()))
            .map_err(|e| e.to_string())?;
        fetch_missing(objects, &scratch, root, commit, by)?;
        // A held folder is the work tree itself (git runs in it, `-C .`), never its path.
        #[cfg(unix)]
        let work_tree = if root.held.is_some() { Path::new(".") } else { root.path };
        #[cfg(not(unix))]
        let work_tree = root.path;
        let isolated = || {
            let mut cmd = hardened(root);
            cmd.env("GIT_DIR", &scratch)
                .env("GIT_WORK_TREE", work_tree)
                .env("GIT_INDEX_FILE", scratch.join("index"))
                .env("GIT_CONFIG_GLOBAL", "/dev/null");
            cmd
        };
        run_by(isolated(), &["read-tree", commit], by)?;
        run_by(isolated(), &["checkout-index", "--all", "--force"], by)?;
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(&scratch);
    result
}

/// The objects of `commit`'s tree that the repository's object store
/// (`objects`) lacks, as a partial clone can.
fn missing_objects(
    scratch: &Path,
    root: Dir<'_>,
    commit: &str,
    by: Option<Instant>,
) -> Result<Vec<String>, String> {
    let mut cmd = hardened(root);
    cmd.env("GIT_DIR", scratch).env("GIT_CONFIG_GLOBAL", "/dev/null");
    let tree = format!("{commit}^{{tree}}");
    let listed =
        run_by(cmd, &["rev-list", "--objects", "--missing=print", "--no-object-names", &tree], by)?;
    Ok(listed.lines().filter_map(|l| l.strip_prefix('?')).map(str::to_owned).collect())
}

/// The URL of the promisor remote of the partial clone whose worktree
/// `root` is, as its config names it (read, never run).
fn promisor_url(root: Dir<'_>, by: Option<Instant>) -> Option<String> {
    let git = |dir: Dir<'_>, args: &[&str]| run_by(hardened(dir), args, by);
    let listed =
        git(root, &["config", "--get-regexp", r"^remote\..*\.promisor$"]).unwrap_or_default();
    let named = listed.lines().find_map(|l| {
        let (key, value) = l.split_once(' ')?;
        (value == "true").then(|| key.strip_prefix("remote.")?.strip_suffix(".promisor"))?
    });
    let name = named
        .map(str::to_owned)
        .or_else(|| git(root, &["config", "extensions.partialClone"]).ok())?;
    git(root, &["config", &format!("remote.{name}.url")]).ok().filter(|u| !u.is_empty())
}

/// Fetches the objects of `commit`'s tree that a partial clone lacks into
/// its object store (`objects`), from its promisor remote, through the
/// config-less git directory `scratch`: the repository's config (its
/// transports, helpers, `insteadOf`, upload-pack) is not read, the user's
/// and the system's are (their credential helpers), and only the file, git,
/// http, https and ssh transports may run. Nothing missing, nothing fetched.
fn fetch_missing(
    objects: &Path,
    scratch: &Path,
    root: Dir<'_>,
    commit: &str,
    by: Option<Instant>,
) -> Result<(), String> {
    let missing = missing_objects(scratch, root, commit, by)?;
    if missing.is_empty() {
        return Ok(());
    }
    let url = promisor_url(root, by).ok_or_else(|| {
        format!(
            "{} of the commit's objects are missing and no promisor remote has them",
            missing.len()
        )
    })?;
    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(scratch)
        .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        .args(["-c", "submodule.recurse=false", "-c", "fetch.negotiationAlgorithm=noop"])
        .args(NO_MAINTENANCE)
        .args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no"])
        .args(["--no-auto-maintenance", "--no-write-commit-graph"])
        .args(["--stdin", "--", &url])
        .env("GIT_DIR", scratch)
        .env("GIT_OBJECT_DIRECTORY", objects)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .env("GIT_ALLOW_PROTOCOL", "file:git:http:https:ssh")
        .env("LC_ALL", "C");
    let out = output_by(cmd, Some(missing.join("\n").into_bytes()), by)?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("fetching the partial clone's missing files failed: {}", err.trim()));
    }
    Ok(())
}

/// Removes a worktree [`make_worktree`] made, and its branch.
pub fn remove_worktree(folder: Dir<'_>, worktree: &Worktree) {
    // A worktree this made is removed through its held folder, never by path: whatever took its
    // path (renamed in, a copy of its `.git` file), before or during the removal, is left alone.
    #[cfg(unix)]
    if let Some(held) = &worktree.root_held {
        // Its own registration, found through the held folder and held before anything is
        // emptied: the one it names, in this repository, pointing back at it.
        let registration = held_registration(folder, held, &worktree.root);
        if let Err(e) = empty_held(held) {
            tracing::warn!(root = %worktree.root.display(), "worktree not removed: {e}");
            return;
        }
        #[cfg(test)]
        before_path_removal(&worktree.root);
        // The made folder, emptied, stays at its path while its registration and branch go:
        // nothing can be recreated there meanwhile (worktree care refuses a path that exists).
        // Another folder at its path keeps everything it names.
        if crate::cwd_pin::CwdPin::of(&worktree.root) != worktree.root_pin {
            tracing::warn!(root = %worktree.root.display(), "worktree registration kept: another folder is at its path");
            return;
        }
        let Some(registration) = registration else {
            tracing::warn!(root = %worktree.root.display(), "worktree registration kept: not found as its own");
            return;
        };
        if let Err(e) = registration.remove() {
            tracing::warn!(registration = %registration.path.display(), "worktree registration kept: {e}");
            return;
        }
        if git(folder, &["branch", "-D", &worktree.branch]).is_ok() {
            let _ = git(
                folder,
                &["config", "--unset", &format!("branch.{}.cmuxBase", worktree.branch)],
            );
        }
        #[cfg(test)]
        before_root_rmdir(&worktree.root);
        // Last, and only an empty folder: one that took its place keeps its files.
        let _ = std::fs::remove_dir(&worktree.root);
        return;
    }
    let root = worktree.root.to_string_lossy();
    let _ = git(folder, &["worktree", "remove", "--force", &root]);
    let _ = git(folder, &["branch", "-D", &worktree.branch]);
    let _ = git(folder, &["config", "--unset", &format!("branch.{}.cmuxBase", worktree.branch)]);
}

/// The administrative folder the `.git` file in the open worktree folder `dir` names, read
/// through its handle; None when there is none.
#[cfg(unix)]
fn held_gitdir(dir: &std::fs::File) -> Option<PathBuf> {
    use std::io::Read;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `dir` is open for the call; the descriptor opened is owned at once.
    let fd = unsafe { libc::openat(dir.as_raw_fd(), c".git".as_ptr(), flags) };
    if fd < 0 {
        return None;
    }
    let mut text = String::new();
    std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) }).read_to_string(&mut text).ok()?;
    text.trim().strip_prefix("gitdir: ").map(PathBuf::from)
}

/// A worktree's own registration folder, held open with the `worktrees/` folder it is in.
#[cfg(unix)]
struct HeldRegistration {
    worktrees: std::fs::File,
    name: std::ffi::CString,
    dir: std::fs::File,
    /// Where it was when it was found (for what is said about it).
    path: PathBuf,
}

#[cfg(unix)]
impl HeldRegistration {
    /// Empties the folder held, then removes its name only if that is an empty folder: one that
    /// took its place (another registration) is left alone.
    fn remove(&self) -> std::io::Result<()> {
        use std::os::fd::AsRawFd;
        empty_held(&self.dir)?;
        #[cfg(test)]
        before_registration_removal(&self.path);
        // SAFETY: `worktrees` is open for the call.
        let removed = unsafe {
            libc::unlinkat(self.worktrees.as_raw_fd(), self.name.as_ptr(), libc::AT_REMOVEDIR)
        };
        if removed != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}

/// The registration the `.git` file in the held worktree folder `held` names, opened through
/// `folder`'s repository's `worktrees/` folder, when its `gitdir` points back at `root`.
#[cfg(unix)]
fn held_registration(
    folder: Dir<'_>,
    held: &std::fs::File,
    root: &Path,
) -> Option<HeldRegistration> {
    use std::io::Read;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    let admin = held_gitdir(held)?;
    let common = ["rev-parse", "--path-format=absolute", "--git-common-dir"];
    let worktrees = std::fs::canonicalize(git(folder, &common).ok()?).ok()?.join("worktrees");
    // A relative one is relative to the folder its file is in (`worktree.useRelativePaths`).
    let admin = std::fs::canonicalize(root.join(admin)).ok()?;
    if admin.parent() != Some(worktrees.as_path()) {
        return None;
    }
    let path = admin.clone();
    let name = std::ffi::CString::new(admin.file_name()?.as_bytes()).ok()?;
    let worktrees = std::fs::File::open(&worktrees).ok()?;
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `worktrees` is open for the call; the descriptor opened is owned at once.
    let fd = unsafe { libc::openat(worktrees.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return None;
    }
    let dir = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let fd = unsafe { libc::openat(dir.as_raw_fd(), c"gitdir".as_ptr(), flags) };
    if fd < 0 {
        return None;
    }
    let mut gitdir = String::new();
    std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) }).read_to_string(&mut gitdir).ok()?;
    // Compared by its folder (resolved, as git may have spelled it through a link) and name.
    let spelled = |p: &Path| {
        let parent = p.parent().and_then(|d| std::fs::canonicalize(d).ok());
        (parent, p.file_name().map(std::ffi::OsStr::to_owned))
    };
    let git = path.join(gitdir.trim());
    let points_back = git.file_name() == Some(std::ffi::OsStr::new(".git"))
        && git.parent().is_some_and(|r| spelled(r) == spelled(root));
    points_back.then_some(HeldRegistration { worktrees, name, dir, path })
}

/// Removes everything in the open folder `dir` through its handle (`openat`/`unlinkat`, never a
/// path, links not followed), leaving it empty.
#[cfg(unix)]
fn empty_held(dir: &std::fs::File) -> std::io::Result<()> {
    use std::ffi::{CStr, CString};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let names: Vec<CString> = {
        // SAFETY: a close-on-exec copy of an open descriptor (no child spawned meanwhile
        // inherits it); fdopendir owns the copy and closedir closes it.
        let fd = unsafe { libc::fcntl(dir.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        #[cfg(test)]
        after_dup(fd);
        let stream = unsafe { libc::fdopendir(fd) };
        if stream.is_null() {
            let e = std::io::Error::last_os_error();
            unsafe { libc::close(fd) };
            return Err(e);
        }
        let mut names = Vec::new();
        // SAFETY: `stream` is open until closedir; each entry is read before the next readdir.
        unsafe {
            libc::rewinddir(stream);
            loop {
                let entry = libc::readdir(stream);
                if entry.is_null() {
                    break;
                }
                let name = CStr::from_ptr((*entry).d_name.as_ptr());
                if name.to_bytes() != b"." && name.to_bytes() != b".." {
                    names.push(name.to_owned());
                }
            }
            libc::closedir(stream);
        }
        names
    };
    let at = dir.as_raw_fd();
    for name in names {
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: `at` is open for the call; a descriptor opened here is owned at once.
        let child = unsafe { libc::openat(at, name.as_ptr(), flags) };
        let removed = if child >= 0 {
            let child = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(child) });
            empty_held(&child)?;
            unsafe { libc::unlinkat(at, name.as_ptr(), libc::AT_REMOVEDIR) }
        } else {
            unsafe { libc::unlinkat(at, name.as_ptr(), 0) }
        };
        if removed != 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Lowercase ASCII letters and digits, every other run one `-`, at most 48
/// characters: `git_ops/worktree.rs`'s names.
pub fn slug(text: &str) -> String {
    let mut slug = String::new();
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c.to_ascii_lowercase());
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
        if slug.len() >= 48 {
            break;
        }
    }
    slug.trim_end_matches('-').to_owned()
}

/// A new worktree of `folder`'s repository at `~/.cmux/worktrees/<project>/<name>`
/// on a new branch `cmux/<name>` from the current branch (else HEAD), its
/// base recorded as `branch.<branch>.cmuxBase`, as `git.worktree.create`
/// makes one. A taken name gets the next free suffix.
pub fn make_worktree(folder: Dir<'_>, title: &str) -> Result<Worktree, String> {
    make_worktree_under(folder, title, &home()?)
}

fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| "no home folder for worktrees".into())
}

/// Where a repository's worktrees go and what filling one needs.
struct Layout {
    objects: PathBuf,
    /// The started-from folder's place in the repository (`rev-parse --show-prefix`).
    prefix: String,
    format: String,
    /// `~/.cmux/worktrees/<project>`.
    parent: PathBuf,
}

fn layout(folder: Dir<'_>, home: &Path) -> Result<Layout, String> {
    let common =
        PathBuf::from(git(folder, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?);
    let objects = PathBuf::from(git(
        folder,
        &["rev-parse", "--path-format=absolute", "--git-path", "objects"],
    )?);
    let prefix = git(folder, &["rev-parse", "--show-prefix"])?;
    let format = git(folder, &["rev-parse", "--show-object-format"])?;
    let main = if common.file_name().is_some_and(|n| n == ".git") {
        common.parent().map(Path::to_path_buf)
    } else {
        None
    };
    let project = main
        .as_deref()
        .unwrap_or(&common)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let project = Some(slug(project.strip_suffix(".git").unwrap_or(&project)))
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "repository".into());
    // The app's `git.worktree.create` root (`git_ops/worktree.rs`), so its
    // Apply and Remove find these: the person's worktrees, not build state.
    let parent = cmux_git::worktree_root::worktree_root(home)
        .map_err(|e| format!("cannot prepare ~/.cmux/worktrees: {e}"))?
        .join(project);
    Ok(Layout { objects, prefix, format, parent })
}

/// Fills the worktree git just added at `made.root` with `commit`'s files
/// and index and records its base; removes it when that fails, and its
/// branch too unless `kept_branch` (the branch was there before).
fn fill(
    folder: Dir<'_>,
    layout: &Layout,
    mut made: Worktree,
    commit: &str,
    kept_branch: bool,
) -> Result<Worktree, String> {
    // Its files without the repository's config; then its index, which
    // `read-tree` (no `-u`) writes from the objects alone.
    let root = made.root.clone();
    // Through the folder made (held), never its path: a link put there writes nothing elsewhere.
    let held = made.root_held.clone();
    let at = Dir::held(&root, held.as_deref());
    let filled = check_out_without_config(&layout.objects, &layout.format, at, commit, None)
        .and_then(|()| git(at, &["read-tree", commit]).map(drop))
        .and_then(|()| {
            git(folder, &["config", &format!("branch.{}.cmuxBase", made.branch), &made.base])
                .map(drop)
        });
    if let Err(e) = filled {
        if kept_branch {
            let _ = git(folder, &["worktree", "remove", "--force", &root.to_string_lossy()]);
        } else {
            remove_worktree(folder, &made);
        }
        return Err(e);
    }
    // The started-from folder exists in the worktree only once its
    // files are checked out.
    if !layout.prefix.is_empty() && root.join(&layout.prefix).is_dir() {
        made.cwd = root.join(&layout.prefix);
    }
    Ok(made)
}

/// [`make_worktree`] with `home` as the home folder.
fn make_worktree_under(folder: Dir<'_>, title: &str, home: &Path) -> Result<Worktree, String> {
    let layout = layout(folder, home)?;
    let parent = layout.parent.clone();
    // The commit is resolved once; a branch name that reads as an option
    // (`-x`) is recorded as that commit instead.
    let commit = git(folder, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])?;
    let base = current_base(folder, &commit);
    let name = Some(slug(title)).filter(|n| !n.is_empty()).unwrap_or_else(|| "task".into());
    let free = |candidate: &str| !parent.join(candidate).exists() && !has_branch(folder, candidate);
    std::fs::create_dir_all(&parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    // Another start may take a free name before this one adds it: git then
    // says it already exists, and the next name is tried.
    for chosen in std::iter::once(name.clone()).chain((2..=99).map(|n| format!("{name}-{n}"))) {
        if !free(&chosen) {
            continue;
        }
        let root = parent.join(&chosen);
        // Held while it is added and filled, as `ensure_worktree` holds it.
        let lock = name_lock(&root);
        let _held = lock.lock().unwrap_or_else(|e| e.into_inner());
        // The worktree's folder is made here, empty, and its identity read before git fills it
        // (git adds into an empty folder): the folder at its path afterwards must be this one,
        // whatever took the path while git ran.
        match std::fs::create_dir(&root) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("{}: {e}", root.display())),
        }
        // Held from here: its inode stays this folder's for as long as the worktree is in use.
        #[cfg(unix)]
        let (root_pin, root_held) = {
            use std::os::unix::fs::MetadataExt;
            let held =
                std::fs::File::open(&root).map_err(|e| format!("{}: {e}", root.display()))?;
            let m = held.metadata().map_err(|e| format!("{}: {e}", root.display()))?;
            let pin = crate::cwd_pin::CwdPin { dev: m.dev(), ino: m.ino() };
            (Some(pin), Some(std::sync::Arc::new(held)))
        };
        #[cfg(not(unix))]
        let (root_pin, root_held) = (None, None);
        let branch = format!("cmux/{chosen}");
        let add =
            ["worktree", "add", "--no-checkout", "-b", &branch, &root.to_string_lossy(), &commit];
        if let Err(e) = git(folder, &add) {
            // Only an empty folder goes: never one something else filled.
            let _ = std::fs::remove_dir(&root);
            if taken(&e) {
                continue;
            }
            return Err(e);
        }
        #[cfg(test)]
        after_add(&root);
        let made = Worktree {
            root: root.clone(),
            branch,
            base: base.clone(),
            cwd: root,
            root_pin,
            root_held,
        };
        return fill(folder, &layout, made, &commit, false);
    }
    Err(format!("every worktree name from {name} to {name}-99 is taken"))
}

#[cfg(test)]
thread_local! {
    /// Runs once on the next worktree [`make_worktree_under`] adds, right after `git worktree add`.
    static AFTER_ADD: std::cell::RefCell<Option<Box<dyn FnOnce(&Path)>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
thread_local! {
    /// Runs once on the next [`verify_made`], right after it checks the folder at `made.root`.
    static AFTER_ROOT_CHECK: std::cell::RefCell<Option<Box<dyn FnOnce(&Path)>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn after_root_check(root: &Path) {
    if let Some(f) = AFTER_ROOT_CHECK.with(|h| h.borrow_mut().take()) {
        f(root);
    }
}

#[cfg(test)]
thread_local! {
    /// Runs once on the next [`remove_worktree`], right before anything is removed by path.
    static BEFORE_PATH_REMOVAL: std::cell::RefCell<Option<Box<dyn FnOnce(&Path)>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn before_path_removal(root: &Path) {
    if let Some(f) = BEFORE_PATH_REMOVAL.with(|h| h.borrow_mut().take()) {
        f(root);
    }
}

#[cfg(test)]
thread_local! {
    /// Runs once on the next descriptor [`empty_held`] duplicates, right after it does.
    static AFTER_DUP: std::cell::RefCell<Option<Box<dyn FnOnce(i32)>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(all(test, unix))]
fn after_dup(fd: i32) {
    if let Some(f) = AFTER_DUP.with(|h| h.borrow_mut().take()) {
        f(fd);
    }
}

#[cfg(test)]
thread_local! {
    /// Runs once on the next registration [`remove_worktree`] removes, right before its folder
    /// is removed by name.
    static BEFORE_REGISTRATION_REMOVAL: std::cell::RefCell<Option<Box<dyn FnOnce(&Path)>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(all(test, unix))]
fn before_registration_removal(admin: &Path) {
    if let Some(f) = BEFORE_REGISTRATION_REMOVAL.with(|h| h.borrow_mut().take()) {
        f(admin);
    }
}

#[cfg(test)]
thread_local! {
    /// Runs once on the next [`remove_worktree`], right before it removes its emptied root.
    static BEFORE_ROOT_RMDIR: std::cell::RefCell<Option<Box<dyn FnOnce(&Path)>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(all(test, unix))]
fn before_root_rmdir(root: &Path) {
    if let Some(f) = BEFORE_ROOT_RMDIR.with(|h| h.borrow_mut().take()) {
        f(root);
    }
}

#[cfg(test)]
fn after_add(root: &Path) {
    if let Some(f) = AFTER_ADD.with(|h| h.borrow_mut().take()) {
        f(root);
    }
}

/// The identity of the folder `up` levels above the open folder `start`, walked by its handle
/// (`..` of each), never by path; None when one cannot be opened.
#[cfg(unix)]
fn ancestor_pin(start: &std::fs::File, up: usize) -> Option<crate::cwd_pin::CwdPin> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::fs::MetadataExt;
    let mut dir: Option<std::fs::File> = None;
    for _ in 0..up {
        let from = dir.as_ref().unwrap_or(start).as_raw_fd();
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC;
        // SAFETY: `from` is an open directory for the call; the new descriptor is owned below.
        let fd = unsafe { libc::openat(from, c"..".as_ptr(), flags) };
        if fd < 0 {
            return None;
        }
        // SAFETY: `fd` was just opened and nothing else owns it.
        dir = Some(std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) }));
    }
    let m = dir.as_ref().unwrap_or(start).metadata().ok()?;
    Some(crate::cwd_pin::CwdPin { dev: m.dev(), ino: m.ino() })
}

/// Ok when `at` (a folder held open in the new worktree, its sub-session's start folder) is in the
/// very worktree [`make_worktree`] made of `source`'s repository: the folder at `made.root` is the
/// one git added (`root_pin`), `at` is inside it (its top level), it shares `source`'s repository,
/// and it is on `made.branch`. Else a folder that took the worktree's place after it was made
/// (renamed in, a copied `.git` file) would be checked as if it were acpmux's own.
pub fn verify_made(source: Dir<'_>, made: &Worktree, at: Dir<'_>) -> Result<(), String> {
    let moved = |what: &str| {
        Err(format!("{} is not the worktree that was made: {what}", made.root.display()))
    };
    let canonical = |p: &str| std::fs::canonicalize(p).ok();
    // Off unix there is no identity to compare (`CwdPin`); the git checks below still hold.
    if cfg!(unix)
        && (made.root_pin.is_none() || crate::cwd_pin::CwdPin::of(&made.root) != made.root_pin)
    {
        return moved("another folder is at its path");
    }
    #[cfg(test)]
    after_root_check(&made.root);
    // The held start folder itself, not whatever is at a path now: the folder as many levels up
    // from it as made.cwd is below made.root must be the folder made.
    #[cfg(unix)]
    {
        let up = match made.cwd.strip_prefix(&made.root) {
            Ok(rest) => rest.components().count(),
            Err(_) => return moved("its start folder is outside it"),
        };
        let held = match at.held {
            Some(held) => ancestor_pin(held, up),
            None => std::fs::File::open(at.path).ok().and_then(|f| ancestor_pin(&f, up)),
        };
        if held.is_none() || held != made.root_pin {
            return moved("the start folder is not in the folder that was made");
        }
    }
    let top = git(at, &["rev-parse", "--path-format=absolute", "--show-toplevel"])?;
    if canonical(&top) != std::fs::canonicalize(&made.root).ok() {
        return moved("the start folder is not inside it");
    }
    let common = ["rev-parse", "--path-format=absolute", "--git-common-dir"];
    if canonical(&git(at, &common)?) != canonical(&git(source, &common)?) {
        return moved("it belongs to another repository");
    }
    let head = git(at, &["symbolic-ref", "--quiet", "HEAD"])?;
    if head != format!("refs/heads/{}", made.branch) {
        return moved("it is on another branch");
    }
    Ok(())
}

/// The current branch, else `commit` (detached, or a name that reads as an option).
fn current_base(folder: Dir<'_>, commit: &str) -> String {
    git(folder, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .ok()
        .filter(|b| !b.is_empty() && !b.starts_with('-'))
        .unwrap_or_else(|| commit.to_owned())
}

fn has_branch(folder: Dir<'_>, name: &str) -> bool {
    git(folder, &["rev-parse", "--verify", "--quiet", &format!("refs/heads/cmux/{name}")]).is_ok()
}

/// Git refused an add because another start took that path or branch first.
fn checked_out_elsewhere(error: &str) -> bool {
    error.contains("is already checked out") || error.contains("is already used by worktree")
}

fn taken(error: &str) -> bool {
    error.contains("already exists") || error.contains("is already checked out")
}

/// What [`ensure_worktree`] found or made.
pub struct Ensured {
    pub worktree: Worktree,
    /// `worktree` (it was there), `branch` (its branch was, the folder is
    /// new) or None (both are new).
    pub reused: Option<&'static str>,
}

/// The worktree named `name` of `folder`'s repository, made when missing:
/// `~/.cmux/worktrees/<project>/<slug>` on `cmux/<slug>` as [`make_worktree`]
/// lays one out, but never a suffixed copy. A worktree already there is
/// used as it is; a branch already there gets a new worktree; else a new
/// branch starts at `base` (a ref or commit; default the current branch).
/// Running it again with the same name gives the same worktree, so a
/// launcher that runs twice does not make two.
pub fn ensure_worktree(folder: &Path, name: &str, base: Option<&str>) -> Result<Ensured, String> {
    ensure_worktree_under(folder, name, base, &home()?)
}

type Lock = std::sync::Arc<std::sync::Mutex<()>>;

/// One add or ensure at a time per worktree folder in this process: git lists a
/// `--no-checkout` worktree before its files are written, so a second
/// launcher of the same name must not find it half filled.
fn name_lock(root: &Path) -> Lock {
    static LOCKS: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<PathBuf, Lock>>> =
        std::sync::OnceLock::new();
    let mut locks = LOCKS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
    locks.entry(root.to_path_buf()).or_default().clone()
}

fn ensure_worktree_under(
    folder: &Path,
    name: &str,
    base: Option<&str>,
    home: &Path,
) -> Result<Ensured, String> {
    let chosen = slug(name);
    if chosen.is_empty() {
        return Err(format!("{name:?} has no letters or digits to name a worktree"));
    }
    if base.is_some_and(|b| b.is_empty() || b.starts_with('-')) {
        return Err("the base must be a ref or commit, not an option".into());
    }
    let layout = layout(folder.into(), home)?;
    let root = layout.parent.join(&chosen);
    let branch = format!("cmux/{chosen}");
    let lock = name_lock(&root);
    let _held = lock.lock().unwrap_or_else(|e| e.into_inner());
    // A second pass covers another process adding it meanwhile.
    for _ in 0..2 {
        if root.exists() {
            let listed = listed_worktree(folder, &root).ok_or_else(|| {
                format!("{} exists but is not a worktree of this repository", root.display())
            })?;
            let branch = listed.unwrap_or_else(|| branch.clone());
            let base =
                git(folder, &["config", &format!("branch.{branch}.cmuxBase")]).unwrap_or_default();
            let cwd = Some(root.join(&layout.prefix))
                .filter(|c| !layout.prefix.is_empty() && c.is_dir())
                .unwrap_or_else(|| root.clone());
            let worktree =
                Worktree { root: root.clone(), branch, base, cwd, root_pin: None, root_held: None };
            return Ok(Ensured { worktree, reused: Some("worktree") });
        }
        std::fs::create_dir_all(&layout.parent)
            .map_err(|e| format!("{}: {e}", layout.parent.display()))?;
        let path = root.to_string_lossy().into_owned();
        let (added, commit, base, reused) = if has_branch(folder.into(), &chosen) {
            let commit = git(
                folder,
                &["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}^{{commit}}")],
            )?;
            let base = git(folder, &["config", &format!("branch.{branch}.cmuxBase")])
                .unwrap_or_else(|_| commit.clone());
            let added = git(folder, &["worktree", "add", "--no-checkout", &path, &branch]);
            (added, commit, base, Some("branch"))
        } else {
            let commit = match base {
                Some(b) => {
                    git(folder, &["rev-parse", "--verify", "--quiet", &format!("{b}^{{commit}}")])
                        .map_err(|_| format!("no commit {b:?} in {}", folder.display()))?
                }
                None => git(folder, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])?,
            };
            let label = base
                .filter(|b| *b != "HEAD")
                .map(str::to_owned)
                .unwrap_or_else(|| current_base(folder.into(), &commit));
            let added =
                git(folder, &["worktree", "add", "--no-checkout", "-b", &branch, &path, &commit]);
            (added, commit, label, None)
        };
        match added {
            Ok(_) => {}
            // Its branch in another folder: no rerun fixes that, so git's
            // words (which name the folder) are the error.
            Err(e) if checked_out_elsewhere(&e) => {
                return Err(format!("{branch} is checked out in another worktree: {e}"));
            }
            Err(e) if taken(&e) => continue,
            Err(e) => return Err(e),
        }
        let made = Worktree {
            root: root.clone(),
            branch: branch.clone(),
            base,
            cwd: root.clone(),
            root_pin: None,
            root_held: None,
        };
        let worktree = fill(folder.into(), &layout, made, &commit, reused.is_some())?;
        return Ok(Ensured { worktree, reused });
    }
    Err(format!("{} was added and removed while this ran; run it again", root.display()))
}

/// `root` as a worktree of `folder`'s repository: Some(its branch, None
/// when detached), None when the repository lists no worktree there.
fn listed_worktree(folder: &Path, root: &Path) -> Option<Option<String>> {
    let want = std::fs::canonicalize(root).ok()?;
    let listed = git(folder, &["worktree", "list", "--porcelain"]).ok()?;
    let mut found = false;
    for line in listed.lines() {
        if let Some(path) = line.strip_prefix("worktree ") {
            if found {
                return Some(None);
            }
            found = std::fs::canonicalize(path).is_ok_and(|p| p == want);
        } else if found && let Some(b) = line.strip_prefix("branch refs/heads/") {
            return Some(Some(b.to_owned()));
        }
    }
    found.then_some(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn git_output_deadline_covers_a_descendant_holding_the_pipe() {
        let mut command = Command::new("sh");
        command.args(["-c", "sleep 10 & exit 0"]);
        let by = Instant::now() + std::time::Duration::from_millis(200);
        let result = output_by(command, None, Some(by));
        assert!(result.is_err(), "a still-open output must time out: {result:?}");
        assert!(by.elapsed() < std::time::Duration::from_secs(5));
    }

    #[test]
    fn slug_matches_the_worktree_names() {
        assert_eq!(slug("Fix the flaky upload test!"), "fix-the-flaky-upload-test");
        assert_eq!(slug("  --  "), "");
        assert_eq!(slug(&"a".repeat(80)).len(), 48);
    }

    /// A scratch folder removed on drop.
    struct Scratch(PathBuf);

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn sh(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    /// A repository `proj` with commits `first` (on `main`) and `second`
    /// (on `next`), and a home folder beside it.
    fn repo() -> (Scratch, PathBuf, PathBuf) {
        let top = std::env::temp_dir().join(format!("acpmux-ensure-{}", uuid::Uuid::now_v7()));
        let (repo, home) = (top.join("proj"), top.join("home"));
        std::fs::create_dir_all(repo.join("sub")).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        sh(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("sub/a.txt"), "first\n").unwrap();
        sh(&repo, &["add", "."]);
        sh(&repo, &["commit", "-q", "-m", "first"]);
        sh(&repo, &["checkout", "-q", "-b", "next"]);
        std::fs::write(repo.join("sub/a.txt"), "second\n").unwrap();
        sh(&repo, &["commit", "-q", "-am", "second"]);
        sh(&repo, &["checkout", "-q", "main"]);
        (Scratch(top), repo, home)
    }

    /// Whether `dir`'s repository has branch `cmux/<name>`.
    fn branch_in(dir: &Path, name: &str) -> bool {
        let refname = format!("refs/heads/cmux/{name}");
        let status = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["rev-parse", "--verify", "--quiet", &refname])
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap()
            .status;
        status.success()
    }

    /// A sub-session's checked folder, held open, is renamed away and another repository takes
    /// its path before the worktree is made: the worktree is of the folder held, never of the
    /// one at its path now, and its removal leaves that one alone too.
    #[cfg(unix)]
    #[test]
    fn a_held_folder_makes_its_worktree_from_itself_wherever_its_path_leads() {
        let (scratch, repo, home) = repo();
        let held = std::fs::File::open(repo.join("sub")).unwrap();
        let moved = scratch.0.join("proj-moved");
        std::fs::rename(&repo, &moved).unwrap();
        std::fs::create_dir_all(repo.join("sub")).unwrap();
        sh(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("sub/a.txt"), "unchecked\n").unwrap();
        sh(&repo, &["add", "."]);
        sh(&repo, &["commit", "-q", "-m", "unchecked"]);

        let path = repo.join("sub");
        let at = Dir::held(&path, Some(&held));
        let made = make_worktree_under(at, "Task", &home).unwrap();
        assert_eq!(std::fs::read_to_string(made.cwd.join("a.txt")).unwrap(), "first\n");
        assert_eq!(sh(&moved, &["rev-parse", "cmux/task"]), sh(&moved, &["rev-parse", "main"]));
        assert!(!branch_in(&repo, "task"), "no branch in the repository now at the path");

        remove_worktree(at, &made);
        assert!(!made.root.exists(), "removed");
        assert!(!branch_in(&moved, "task"), "its branch removed from the folder held");
    }

    /// The worktree made is proven to be the one at its path; a folder renamed into its place
    /// (here with a copy of its `.git` file, so git takes it for the same worktree) is not.
    #[cfg(unix)]
    #[test]
    fn a_folder_that_took_a_made_worktrees_place_is_not_it() {
        let (scratch, repo, home) = repo();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let held = std::fs::File::open(&made.cwd).unwrap();
        let at = Dir::held(&made.cwd, Some(&held));
        assert_eq!(verify_made(repo.as_path().into(), &made, at), Ok(()));

        let impostor = scratch.0.join("impostor");
        std::fs::create_dir_all(&impostor).unwrap();
        std::fs::copy(made.root.join(".git"), impostor.join(".git")).unwrap();
        std::fs::rename(&made.root, scratch.0.join("made-moved")).unwrap();
        std::fs::rename(&impostor, &made.root).unwrap();
        let held = std::fs::File::open(&made.root).unwrap();
        let at = Dir::held(&made.root, Some(&held));
        let refused = verify_made(repo.as_path().into(), &made, at).unwrap_err();
        assert!(refused.contains("not the worktree that was made"), "{refused}");
    }

    /// A folder that takes the new worktree's place while git adds it (here as soon as it is
    /// added, with a copy of its `.git` file) is not the one made either.
    #[cfg(unix)]
    #[test]
    fn a_folder_that_took_the_worktrees_place_as_git_added_it_is_not_it() {
        let (scratch, repo, home) = repo();
        let at_scratch = scratch.0.clone();
        AFTER_ADD.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |root: &Path| {
                let impostor = at_scratch.join("impostor");
                std::fs::create_dir_all(&impostor).unwrap();
                std::fs::copy(root.join(".git"), impostor.join(".git")).unwrap();
                std::fs::rename(root, at_scratch.join("made-moved")).unwrap();
                std::fs::rename(&impostor, root).unwrap();
            }))
        });
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let held = std::fs::File::open(&made.cwd).unwrap();
        let at = Dir::held(&made.cwd, Some(&held));
        let refused = verify_made(repo.as_path().into(), &made, at).unwrap_err();
        assert!(refused.contains("not the worktree that was made"), "{refused}");
    }

    /// A held impostor is not the worktree made even while the made folder is put back at its
    /// path for the identity check and swapped out again before git looks: the held start
    /// folder itself must be in the folder made.
    #[cfg(unix)]
    #[test]
    fn a_held_impostor_is_refused_though_the_made_folder_is_back_at_its_path_for_a_moment() {
        let (scratch, repo, home) = repo();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let (aside, impostor) = (scratch.0.join("made-aside"), scratch.0.join("impostor"));
        std::fs::create_dir_all(&impostor).unwrap();
        std::fs::copy(made.root.join(".git"), impostor.join(".git")).unwrap();
        std::fs::rename(&made.root, &aside).unwrap();
        std::fs::rename(&impostor, &made.root).unwrap();
        let held = std::fs::File::open(&made.root).unwrap();
        // The made folder back at its path for the identity check...
        std::fs::rename(&made.root, &impostor).unwrap();
        std::fs::rename(&aside, &made.root).unwrap();
        let (moved_aside, moved_impostor) = (aside.clone(), impostor.clone());
        AFTER_ROOT_CHECK.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |root: &Path| {
                // ...and the impostor back before git looks.
                std::fs::rename(root, &moved_aside).unwrap();
                std::fs::rename(&moved_impostor, root).unwrap();
            }))
        });
        let at = Dir::held(&made.root, Some(&held));
        let refused = verify_made(repo.as_path().into(), &made, at).unwrap_err();
        assert!(refused.contains("not the worktree that was made"), "{refused}");
    }

    /// The folder made is held: one that takes its place after it is deleted never gets its
    /// inode (a file system reuses a freed one at once), so it is refused.
    #[cfg(unix)]
    #[test]
    fn a_folder_made_after_the_worktree_was_deleted_never_passes_for_it() {
        let (scratch, repo, home) = repo();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let git_file = std::fs::read(made.root.join(".git")).unwrap();
        let gone = scratch.0.join("gone");
        std::fs::rename(&made.root, &gone).unwrap();
        std::fs::remove_dir_all(&gone).unwrap();
        std::fs::create_dir(&made.root).unwrap();
        std::fs::write(made.root.join(".git"), git_file).unwrap();
        let held = std::fs::File::open(&made.root).unwrap();
        let at = Dir::held(&made.root, Some(&held));
        let refused = verify_made(repo.as_path().into(), &made, at).unwrap_err();
        assert!(refused.contains("not the worktree that was made"), "{refused}");
    }

    /// Removing a worktree whose path another folder took leaves that folder alone.
    #[cfg(unix)]
    #[test]
    fn removing_a_worktree_leaves_a_folder_that_took_its_place_alone() {
        let (scratch, repo, home) = repo();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let (aside, impostor) = (scratch.0.join("made-aside"), scratch.0.join("impostor"));
        std::fs::create_dir_all(&impostor).unwrap();
        std::fs::copy(made.root.join(".git"), impostor.join(".git")).unwrap();
        std::fs::write(impostor.join("sentinel"), "theirs\n").unwrap();
        std::fs::rename(&made.root, &aside).unwrap();
        std::fs::rename(&impostor, &made.root).unwrap();

        remove_worktree(repo.as_path().into(), &made);
        assert!(made.root.join("sentinel").exists(), "the folder at its path is not removed");
        assert!(branch_in(&repo, "task"), "its branch stays with its registration");
    }

    /// A folder that takes the worktree's place while it is being removed is left alone too:
    /// nothing is removed by path but an empty folder.
    #[cfg(unix)]
    #[test]
    fn a_folder_that_takes_the_worktrees_place_during_its_removal_is_left_alone() {
        let (scratch, repo, home) = repo();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let git_file = std::fs::read(made.root.join(".git")).unwrap();
        let (aside, impostor) = (scratch.0.join("made-aside"), scratch.0.join("impostor"));
        BEFORE_PATH_REMOVAL.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |root: &Path| {
                std::fs::create_dir_all(&impostor).unwrap();
                std::fs::write(impostor.join(".git"), git_file).unwrap();
                std::fs::write(impostor.join("sentinel"), "theirs\n").unwrap();
                std::fs::rename(root, &aside).unwrap();
                std::fs::rename(&impostor, root).unwrap();
            }))
        });
        remove_worktree(repo.as_path().into(), &made);
        assert!(made.root.join("sentinel").exists(), "the folder at its path is not removed");
        assert!(branch_in(&repo, "task"), "its branch stays with its registration");
    }

    /// Removing a worktree removes its own registration only: another worktree of the same
    /// repository whose folder is away for now keeps its own (its index, its HEAD).
    #[cfg(unix)]
    #[test]
    fn removing_a_worktree_keeps_another_worktrees_registration_while_its_folder_is_away() {
        let (scratch, repo, home) = repo();
        let other = scratch.0.join("other");
        sh(&repo, &["worktree", "add", "-q", "-b", "other", &other.to_string_lossy()]);
        std::fs::write(other.join("staged.txt"), "staged\n").unwrap();
        sh(&other, &["add", "staged.txt"]);
        let away = scratch.0.join("other-away");
        std::fs::rename(&other, &away).unwrap();

        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        remove_worktree(repo.as_path().into(), &made);
        assert!(!made.root.exists(), "removed");
        assert!(!branch_in(&repo, "task"), "its branch removed");

        std::fs::rename(&away, &other).unwrap();
        let staged = sh(&other, &["diff", "--cached", "--name-only"]);
        assert_eq!(staged.trim(), "staged.txt", "the other worktree keeps its index");
    }

    /// A registration that takes the removed worktree's registration's place while it is being
    /// removed is left alone, with its branch.
    #[cfg(unix)]
    #[test]
    fn a_registration_that_takes_the_removed_ones_place_is_left_alone() {
        let (scratch, repo, home) = repo();
        let other = scratch.0.join("other");
        sh(&repo, &["worktree", "add", "-q", "-b", "other", &other.to_string_lossy()]);
        let worktrees = std::fs::canonicalize(repo.join(".git/worktrees")).unwrap();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let aside = scratch.0.join("registration-aside");
        let others = worktrees.join("other");
        BEFORE_REGISTRATION_REMOVAL.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |admin: &Path| {
                std::fs::rename(admin, &aside).unwrap();
                std::fs::rename(&others, admin).unwrap();
            }))
        });
        remove_worktree(repo.as_path().into(), &made);
        let admin = worktrees.join(made.root.file_name().unwrap());
        assert!(admin.join("HEAD").exists(), "the registration that took its place stays");
        assert_ne!(sh(&repo, &["branch", "--list", "other"]), "", "its branch stays");
    }

    /// The emptied root stays at its path until its registration and branch are gone, so
    /// nothing is recreated there meanwhile; a folder that takes its place before it is removed
    /// keeps its files.
    #[cfg(unix)]
    #[test]
    fn the_emptied_root_holds_its_path_until_last_and_a_folder_that_takes_it_stays() {
        let (scratch, repo, home) = repo();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let git_file = std::fs::read(made.root.join(".git")).unwrap();
        let held_at_path = std::sync::Arc::new(std::sync::Mutex::new(None));
        let seen = held_at_path.clone();
        let (pin, aside) = (made.root_pin, scratch.0.join("emptied-aside"));
        BEFORE_ROOT_RMDIR.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |root: &Path| {
                *seen.lock().unwrap() = Some(crate::cwd_pin::CwdPin::of(root) == pin);
                std::fs::rename(root, &aside).unwrap();
                std::fs::create_dir(root).unwrap();
                std::fs::write(root.join(".git"), git_file).unwrap();
                std::fs::write(root.join("sentinel"), "theirs\n").unwrap();
            }))
        });
        remove_worktree(repo.as_path().into(), &made);
        assert_eq!(*held_at_path.lock().unwrap(), Some(true), "the made folder held its path");
        assert!(!branch_in(&repo, "task"), "its own branch removed");
        assert!(made.root.join("sentinel").exists(), "the folder that took its place stays");
    }

    /// A worktree whose `.git` file and registration name each other by relative paths (git's
    /// `worktree.useRelativePaths`) is removed whole too.
    #[cfg(unix)]
    #[test]
    fn a_worktree_registered_by_relative_paths_is_removed_whole() {
        let (_scratch, repo, home) = repo();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        let admin = std::fs::canonicalize(repo.join(".git/worktrees/task")).unwrap();
        let root = std::fs::canonicalize(&made.root).unwrap();
        let relative = |from: &Path, to: &Path| {
            let up = from.components().count() - 1;
            let mut p = PathBuf::from("../".repeat(up));
            p.push(to.strip_prefix("/").unwrap());
            p
        };
        let to_admin = relative(&root, &admin);
        std::fs::write(made.root.join(".git"), format!("gitdir: {}\n", to_admin.display()))
            .unwrap();
        let to_root = relative(&admin, &root.join(".git"));
        std::fs::write(admin.join("gitdir"), format!("{}\n", to_root.display())).unwrap();

        remove_worktree(repo.as_path().into(), &made);
        assert!(!made.root.exists(), "its folder removed");
        assert!(!admin.exists(), "its registration removed");
        assert!(!branch_in(&repo, "task"), "its branch removed");
    }

    /// A link put at the new worktree's path as git adds it never has the checkout written
    /// through it: the repository it leads to keeps its files and its index.
    #[cfg(unix)]
    #[test]
    fn a_link_at_the_worktrees_path_never_gets_the_checkout_written_through_it() {
        let (scratch, repo, home) = repo();
        let victim = scratch.0.join("victim");
        std::fs::create_dir_all(victim.join("sub")).unwrap();
        sh(&victim, &["init", "-q", "-b", "main"]);
        std::fs::write(victim.join("sub/a.txt"), "victim's own\n").unwrap();
        sh(&victim, &["add", "."]);
        sh(&victim, &["commit", "-q", "-m", "victim"]);
        let index = std::fs::read(victim.join(".git/index")).unwrap();
        let (aside, link_to) = (scratch.0.join("made-aside"), victim.clone());
        AFTER_ADD.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |root: &Path| {
                std::fs::rename(root, &aside).unwrap();
                std::os::unix::fs::symlink(&link_to, root).unwrap();
            }))
        });
        let _ = make_worktree_under(repo.as_path().into(), "Task", &home);
        assert_eq!(std::fs::read_to_string(victim.join("sub/a.txt")).unwrap(), "victim's own\n");
        assert_eq!(std::fs::read(victim.join(".git/index")).unwrap(), index, "its index untouched");
    }

    /// The descriptor removal reads a folder through never reaches a child another thread
    /// spawns meanwhile: it is close-on-exec from the moment it exists.
    #[cfg(unix)]
    #[test]
    fn the_descriptor_a_removal_reads_through_is_close_on_exec_at_once() {
        let (scratch, _repo, _home) = repo();
        let dir = scratch.0.join("to-empty");
        std::fs::create_dir_all(dir.join("a")).unwrap();
        let flags = std::sync::Arc::new(std::sync::Mutex::new(None));
        let seen = flags.clone();
        AFTER_DUP.with(|h| {
            *h.borrow_mut() = Some(Box::new(move |fd| {
                *seen.lock().unwrap() = Some(unsafe { libc::fcntl(fd, libc::F_GETFD) });
            }))
        });
        empty_held(&std::fs::File::open(&dir).unwrap()).unwrap();
        let flags = flags.lock().unwrap().expect("a descriptor was duplicated");
        assert_ne!(flags & libc::FD_CLOEXEC, 0, "close-on-exec");
    }

    /// Off unix there is no folder identity: an untouched worktree is proven by git alone.
    #[cfg(not(unix))]
    #[test]
    fn a_made_worktree_is_proven_by_git_alone_off_unix() {
        let (_scratch, repo, home) = repo();
        let made = make_worktree_under(repo.as_path().into(), "Task", &home).unwrap();
        assert_eq!(made.root_pin, None);
        let at = Dir::from(made.cwd.as_path());
        assert_eq!(verify_made(repo.as_path().into(), &made, at), Ok(()));
    }

    #[test]
    fn recovery_does_not_nest_a_worktree_in_a_reappeared_destination() {
        let (_scratch, repo, home) = repo();
        let root = home.join("reappeared");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("keep"), "user data").unwrap();
        let at = sh(&repo, &["rev-parse", "HEAD"]);
        let by = Instant::now() + std::time::Duration::from_secs(10);
        let result = add_without_config(
            &repo.join(".git"),
            &["--detach", root.to_str().unwrap(), &at],
            &root,
            &at,
            by,
        );
        assert!(result.is_err(), "destination appeared meanwhile: {result:?}");
        assert_eq!(std::fs::read_to_string(root.join("keep")).unwrap(), "user data");
        assert_eq!(std::fs::read_dir(root).unwrap().count(), 1, "no nested recovery tree");
    }

    #[test]
    fn a_named_worktree_is_made_once_and_then_found() {
        let (_scratch, repo, home) = repo();
        let made = ensure_worktree_under(&repo, "Lane One", Some("next"), &home).unwrap();
        assert_eq!(made.reused, None);
        let w = &made.worktree;
        assert_eq!(w.root, home.join(".cmux/worktrees/proj/lane-one"));
        assert_eq!(w.branch, "cmux/lane-one");
        assert_eq!(w.base, "next");
        assert_eq!(std::fs::read_to_string(w.root.join("sub/a.txt")).unwrap(), "second\n");
        assert_eq!(sh(&repo, &["rev-parse", "cmux/lane-one"]), sh(&repo, &["rev-parse", "next"]));

        // Again, from a subfolder and with another base: the same worktree, untouched.
        std::fs::write(w.root.join("sub/a.txt"), "edited\n").unwrap();
        let again =
            ensure_worktree_under(&repo.join("sub"), "Lane One", Some("main"), &home).unwrap();
        assert_eq!(again.reused, Some("worktree"));
        assert_eq!(again.worktree.root, w.root);
        assert_eq!(again.worktree.cwd, w.root.join("sub"));
        assert_eq!(again.worktree.base, "next");
        assert_eq!(std::fs::read_to_string(w.root.join("sub/a.txt")).unwrap(), "edited\n");

        // Its folder gone, its branch kept: a new folder on that branch.
        sh(&repo, &["worktree", "remove", "--force", &w.root.to_string_lossy()]);
        let back = ensure_worktree_under(&repo, "Lane One", None, &home).unwrap();
        assert_eq!(back.reused, Some("branch"));
        assert_eq!(back.worktree.branch, "cmux/lane-one");
        assert_eq!(std::fs::read_to_string(w.root.join("sub/a.txt")).unwrap(), "second\n");
    }

    #[test]
    fn a_named_worktree_refuses_what_it_cannot_reuse() {
        let (_scratch, repo, home) = repo();
        let squatter = home.join(".cmux/worktrees/proj/taken");
        std::fs::create_dir_all(&squatter).unwrap();
        let e = ensure_worktree_under(&repo, "taken", None, &home).err().unwrap();
        assert!(e.contains("is not a worktree of this repository"), "{e}");
        let e = ensure_worktree_under(&repo, "x", Some("no-such-ref"), &home).err().unwrap();
        assert!(e.contains("no commit"), "{e}");
        let e = ensure_worktree_under(&repo, "x", Some("--orphan"), &home).err().unwrap();
        assert!(e.contains("not an option"), "{e}");
        // Its branch checked out in another folder: said once, with that folder.
        let elsewhere = home.join("elsewhere");
        sh(&repo, &["worktree", "add", "-q", "-b", "cmux/y", &elsewhere.to_string_lossy()]);
        let e = ensure_worktree_under(&repo, "y", None, &home).err().unwrap();
        assert!(e.contains("checked out in another worktree") && e.contains("elsewhere"), "{e}");
        assert!(ensure_worktree_under(&repo, "//", None, &home).is_err());
    }
}
