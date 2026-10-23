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
}

/// No automatic maintenance or gc: run from the throwaway git directory,
/// whose refs reach none of the repository's objects, it would prune them
/// (the user's unpushed work).
const NO_MAINTENANCE: [&str; 4] = ["-c", "maintenance.auto=false", "-c", "gc.auto=0"];

/// Git that runs nothing from the repository at `dir`: no hooks, fsmonitor,
/// submodule recursion, credential helper, system config, network transport
/// or lazy fetch of a partial clone.
fn hardened(dir: &Path) -> Command {
    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(dir)
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

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    run(hardened(dir), args)
}

/// Git that runs nothing from the repository at `dir` ([`hardened`]), ended at `by`.
pub(crate) fn git_by(dir: &Path, args: &[&str], by: Instant) -> Result<String, String> {
    run_by(hardened(dir), args, Some(by))
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
    let filled = check_out_without_config(&objects, &format, &staged, commit, Some(by))
        .and_then(|()| git_by(&staged, &["read-tree", commit], by).map(drop))
        .and_then(|()| git(&["worktree", "move", &stage, &destination]).map(drop));
    if filled.is_err() {
        let cleanup_by = Instant::now() + std::time::Duration::from_secs(5);
        let _ = git_by(common, &["worktree", "remove", "--force", &stage], cleanup_by);
    }
    filled
}

/// Writes `commit`'s files into `root` with a throwaway git directory next
/// to nothing of the repository's but its objects (`objects`): no config of
/// the repository's, the user's or the system's is read.
fn check_out_without_config(
    objects: &Path,
    format: &str,
    root: &Path,
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
        let isolated = || {
            let mut cmd = hardened(root);
            cmd.env("GIT_DIR", &scratch)
                .env("GIT_WORK_TREE", root)
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
    root: &Path,
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
fn promisor_url(root: &Path, by: Option<Instant>) -> Option<String> {
    let git = |dir: &Path, args: &[&str]| run_by(hardened(dir), args, by);
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
    root: &Path,
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
pub fn remove_worktree(folder: &Path, worktree: &Worktree) {
    let root = worktree.root.to_string_lossy();
    let _ = git(folder, &["worktree", "remove", "--force", &root]);
    let _ = git(folder, &["branch", "-D", &worktree.branch]);
    let _ = git(folder, &["config", "--unset", &format!("branch.{}.cmuxBase", worktree.branch)]);
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
pub fn make_worktree(folder: &Path, title: &str) -> Result<Worktree, String> {
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

fn layout(folder: &Path, home: &Path) -> Result<Layout, String> {
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
    folder: &Path,
    layout: &Layout,
    mut made: Worktree,
    commit: &str,
    kept_branch: bool,
) -> Result<Worktree, String> {
    // Its files without the repository's config; then its index, which
    // `read-tree` (no `-u`) writes from the objects alone.
    let root = made.root.clone();
    let filled = check_out_without_config(&layout.objects, &layout.format, &root, commit, None)
        .and_then(|()| git(&root, &["read-tree", commit]).map(drop))
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
fn make_worktree_under(folder: &Path, title: &str, home: &Path) -> Result<Worktree, String> {
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
        let branch = format!("cmux/{chosen}");
        let add =
            ["worktree", "add", "--no-checkout", "-b", &branch, &root.to_string_lossy(), &commit];
        match git(folder, &add) {
            Ok(_) => {}
            Err(e) if taken(&e) => continue,
            Err(e) => return Err(e),
        }
        let made = Worktree { root: root.clone(), branch, base: base.clone(), cwd: root };
        return fill(folder, &layout, made, &commit, false);
    }
    Err(format!("every worktree name from {name} to {name}-99 is taken"))
}

/// The current branch, else `commit` (detached, or a name that reads as an option).
fn current_base(folder: &Path, commit: &str) -> String {
    git(folder, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .ok()
        .filter(|b| !b.is_empty() && !b.starts_with('-'))
        .unwrap_or_else(|| commit.to_owned())
}

fn has_branch(folder: &Path, name: &str) -> bool {
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
    let layout = layout(folder, home)?;
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
            let worktree = Worktree { root: root.clone(), branch, base, cwd };
            return Ok(Ensured { worktree, reused: Some("worktree") });
        }
        std::fs::create_dir_all(&layout.parent)
            .map_err(|e| format!("{}: {e}", layout.parent.display()))?;
        let path = root.to_string_lossy().into_owned();
        let (added, commit, base, reused) = if has_branch(folder, &chosen) {
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
                .unwrap_or_else(|| current_base(folder, &commit));
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
        let made = Worktree { root: root.clone(), branch: branch.clone(), base, cwd: root.clone() };
        let worktree = fill(folder, &layout, made, &commit, reused.is_some())?;
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
