//! Every linked worktree of the repositories under some folders, and what
//! is in it. Read only: git reads run confined (`cmux-git`) and never take
//! an optional lock, so a scan never rewrites an index and never makes a
//! worktree look used.

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_git::Repository;
use cmux_git::run::Override;
use serde::{Deserialize, Serialize};

pub use crate::finished_memo::FinishedMemo;
use crate::git::{self, is_object_id, records};

/// Ignored folders that only hold what a build or an install made, by name
/// at any depth, with the files one of which must sit beside it (none: the
/// name alone says it): removed without being archived. Anything else
/// ignored (a `.env`, a notes folder, a `target/` with no `Cargo.toml`
/// beside it, generated sources) is ignored data and is archived.
pub const BUILD_OUTPUT: &[(&str, &[&str])] = &[
    ("node_modules", &["package.json"]),
    ("target", &["Cargo.toml"]),
    (".build", &["Package.swift"]),
    ("DerivedData", &[]),
    (".next", &["package.json"]),
    (".turbo", &["package.json", "turbo.json"]),
    (".nuxt", &["package.json"]),
    (".svelte-kit", &["package.json"]),
    (".parcel-cache", &["package.json"]),
    (".vite", &["package.json"]),
    (".zig-cache", &["build.zig"]),
    ("zig-cache", &["build.zig"]),
    ("zig-out", &["build.zig"]),
    ("__pycache__", &[]),
    (".pytest_cache", &[]),
    (".mypy_cache", &[]),
    (".ruff_cache", &[]),
    (".gradle", &["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
    ("Pods", &["Podfile"]),
];

/// The most bytes of untracked and ignored data an archive takes into git;
/// a worktree with more is kept, with that as its reason.
pub const MAX_ARCHIVED_DATA: u64 = 512 << 20;
/// The most changed files whose times are read for the last activity.
const MAX_STATS: usize = 4000;
/// How long the walk of one worktree's ignored data may take.
const DATA_WALK: Duration = Duration::from_secs(15);

/// A repository and its linked worktrees.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Repo {
    /// The common git folder every worktree shares.
    pub common_dir: PathBuf,
    /// The main checkout; `None` for a bare repository.
    pub main_root: Option<PathBuf>,
    pub worktrees: Vec<Worktree>,
    #[serde(skip)]
    pub(crate) overrides: Vec<Override>,
    /// The bases `finished` compares with.
    #[serde(skip)]
    pub(crate) bases: Vec<String>,
    #[serde(skip)]
    pub(crate) finished: Arc<FinishedMemo>,
}

/// One linked worktree.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub path: PathBuf,
    pub branch: Option<String>,
    pub head: Option<String>,
    /// `git worktree lock`ed: never touched.
    pub locked: bool,
    /// Its folder is gone; `git worktree prune` forgets it.
    pub prunable: bool,
    /// What is in it, or why it could not be read.
    pub facts: Result<Facts, String>,
}

/// What a worktree holds and when it was last used.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Facts {
    /// Its private git folder (`<common>/worktrees/<name>`).
    pub git_dir: PathBuf,
    /// A rebase, merge, cherry-pick, revert, am or bisect is under way.
    pub operation: Option<String>,
    /// Tracked paths that differ from HEAD (staged or not).
    pub changed: u32,
    /// Untracked files, relative to the worktree.
    pub untracked: Vec<String>,
    /// Commits on HEAD that no remote-tracking ref has.
    pub unpushed: u32,
    /// The repository has remote-tracking refs at all.
    pub has_remotes: bool,
    /// Why HEAD's work is already on a base branch, if it is.
    pub finished: Option<String>,
    /// Milliseconds since the epoch of the last sign of use: HEAD's newest
    /// reflog entry, the index, the top folder, a changed file.
    pub last_activity_ms: u64,
    /// Ignored folders and files that are build output (relative).
    pub build_output: Vec<String>,
    /// Ignored entries that are not build output (relative): archived.
    pub ignored_data: Vec<String>,
    /// Bytes of the untracked files and ignored data an archive would take.
    pub archived_bytes: u64,
    /// A reason no archive can keep everything (a nested repository, a
    /// changed submodule, too much data): the worktree is kept.
    pub unarchivable: Option<String>,
    /// Sparse-checkout patterns, when the worktree checks out sparsely.
    pub sparse: Option<Sparse>,
    /// Populated submodules (relative paths).
    pub submodules: Vec<String>,
}

/// A worktree's sparse checkout.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sparse {
    pub cone: bool,
    pub patterns: Vec<String>,
}

impl Facts {
    /// Nothing lives only here: no change, no untracked file, no ignored
    /// data and no commit a remote lacks.
    pub fn is_clean_and_pushed(&self) -> bool {
        self.changed == 0
            && self.untracked.is_empty()
            && self.ignored_data.is_empty()
            && self.unpushed == 0
            && self.has_remotes
    }
}

/// The repositories at or one level under each of `roots`, plus those of
/// `extra` folders (session folders), each once.
pub fn repositories(roots: &[PathBuf], extra: &[PathBuf]) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    for root in roots {
        candidates.push(root.clone());
        if let Ok(entries) = std::fs::read_dir(root) {
            let mut children: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
            children.sort();
            candidates.extend(children);
        }
    }
    candidates.extend(extra.iter().cloned());
    let mut seen = HashSet::new();
    let mut found = Vec::new();
    for folder in candidates {
        if !folder.join(".git").exists() && !extra.contains(&folder) {
            continue;
        }
        let Some(common) = common_dir(&folder) else { continue };
        if seen.insert(common.clone()) {
            found.push(common);
        }
    }
    found
}

/// The common git folder of the repository `folder` is in.
fn common_dir(folder: &Path) -> Option<PathBuf> {
    if !folder.is_dir() {
        return None;
    }
    let out =
        git::try_line(folder, &[], &["rev-parse", "--path-format=absolute", "--git-common-dir"])?;
    std::fs::canonicalize(out).ok()
}

/// Reads a repository's linked worktrees and their facts.
pub fn scan(common_dir: &Path, bases: &[String]) -> Result<Repo, String> {
    scan_with_memo(common_dir, bases, Arc::clone(&FINISHED))
}

/// Reads a repository using the supplied finished-answer memo. The memo is
/// shared by all repositories in one cleanup pass and may persist answers.
pub fn scan_with_memo(
    common_dir: &Path,
    bases: &[String],
    finished: Arc<FinishedMemo>,
) -> Result<Repo, String> {
    let main_root = cmux_git::main_root(common_dir).map(Path::to_path_buf);
    let anchor = main_root.clone().unwrap_or_else(|| common_dir.to_path_buf());
    let overrides = cmux_git::filter_overrides(&anchor).map_err(|f| f.reason())?;
    let listing = git::read(&anchor, &overrides, &["worktree", "list", "--porcelain", "-z"])?;
    // More bases than the default branch: `git config --add worktreeCare.base origin/<b>`.
    let mut bases = bases.to_vec();
    if let Ok(out) = git::read(&anchor, &overrides, &["config", "--get-all", "worktreeCare.base"]) {
        bases.extend(String::from_utf8_lossy(&out).lines().map(str::to_string));
    }
    let mut worktrees = Vec::new();
    for (index, entry) in parse_worktree_list(&listing).into_iter().enumerate() {
        // The first entry is the main worktree (or the bare repository),
        // whatever its git folder is named.
        if index == 0
            || main_root.as_deref().is_some_and(|main| same_path(main, &entry.path))
            || entry.bare
            || same_path(common_dir, &entry.path)
        {
            continue;
        }
        worktrees.push(worktree(entry, common_dir, &overrides, &bases, &finished));
    }
    Ok(Repo {
        common_dir: common_dir.to_path_buf(),
        main_root,
        worktrees,
        overrides,
        bases,
        finished,
    })
}

/// One worktree of `repo` read again now, for a decision about to act.
pub fn rescan(repo: &Repo, path: &Path) -> Result<Worktree, String> {
    let anchor = repo.main_root.clone().unwrap_or_else(|| repo.common_dir.clone());
    let listing = git::read(&anchor, &repo.overrides, &["worktree", "list", "--porcelain", "-z"])?;
    let entry = parse_worktree_list(&listing)
        .into_iter()
        .skip(1)
        .find(|entry| same_path(&entry.path, path))
        .ok_or_else(|| format!("{} is no longer a worktree", path.display()))?;
    Ok(worktree(entry, &repo.common_dir, &repo.overrides, &repo.bases, &repo.finished))
}

fn worktree(
    entry: ListEntry,
    common_dir: &Path,
    overrides: &[Override],
    bases: &[String],
    finished_memo: &FinishedMemo,
) -> Worktree {
    let facts = if entry.prunable || !entry.path.is_dir() {
        Err("its folder is gone".to_string())
    } else {
        facts(&entry, common_dir, overrides, bases, finished_memo)
    };
    Worktree {
        path: entry.path,
        branch: entry.branch,
        head: entry.head,
        locked: entry.locked,
        prunable: entry.prunable,
        facts,
    }
}

fn same_path(a: &Path, b: &Path) -> bool {
    a == b
        || match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
            (Ok(a), Ok(b)) => a == b,
            _ => false,
        }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ListEntry {
    pub path: PathBuf,
    pub head: Option<String>,
    pub branch: Option<String>,
    pub bare: bool,
    pub locked: bool,
    pub prunable: bool,
}

/// `git worktree list --porcelain -z`: attribute records, an empty record
/// between worktrees.
pub(crate) fn parse_worktree_list(bytes: &[u8]) -> Vec<ListEntry> {
    let mut entries = Vec::new();
    let mut current: Option<ListEntry> = None;
    for record in bytes.split(|b| *b == 0) {
        let text = String::from_utf8_lossy(record);
        if text.is_empty() {
            entries.extend(current.take());
            continue;
        }
        let (key, value) = text.split_once(' ').unwrap_or((&text, ""));
        if key == "worktree" {
            entries.extend(current.take());
            current = Some(ListEntry { path: PathBuf::from(value), ..ListEntry::default() });
            continue;
        }
        let Some(entry) = current.as_mut() else { continue };
        match key {
            "HEAD" if is_object_id(value) => entry.head = Some(value.to_string()),
            "branch" => entry.branch = value.strip_prefix("refs/heads/").map(str::to_string),
            "bare" => entry.bare = true,
            "locked" => entry.locked = true,
            "prunable" => entry.prunable = true,
            _ => {}
        }
    }
    entries.extend(current);
    entries
}

fn facts(
    entry: &ListEntry,
    common_dir: &Path,
    overrides: &[Override],
    bases: &[String],
    finished_memo: &FinishedMemo,
) -> Result<Facts, String> {
    let root = &entry.path;
    let git_dir = PathBuf::from(git::line(root, overrides, &["rev-parse", "--absolute-git-dir"])?);
    let mut facts = Facts { git_dir: git_dir.clone(), ..Facts::default() };
    facts.operation = operation(&git_dir);
    if git::try_line(root, overrides, &["rev-parse", "--verify", "--quiet", "HEAD"]).is_none() {
        // No commit to restore it on.
        facts.unarchivable = Some("it has no commit yet".to_string());
    }

    // Tracked changes and untracked files, every untracked file listed.
    let status = git::read(
        root,
        overrides,
        &["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=none"],
    )?;
    let mut changed_paths = Vec::new();
    let mut fields = records(&status).peekable();
    while let Some(record) = fields.next() {
        let text = String::from_utf8_lossy(record);
        match text.as_bytes().first() {
            Some(b'1') => {
                changed_paths.push(nth_field(&text, 8));
                submodule_change(&text, 8, &mut facts);
            }
            // A rename or copy is followed by its original path.
            Some(b'2') => {
                changed_paths.push(nth_field(&text, 9));
                submodule_change(&text, 9, &mut facts);
                fields.next();
            }
            Some(b'u') => changed_paths.push(nth_field(&text, 10)),
            Some(b'?') => {
                let path = text[2..].to_string();
                if path.ends_with('/') {
                    // `-uall` lists files; a folder is a nested repository,
                    // which `git add` would keep as a bare gitlink.
                    facts.unarchivable.get_or_insert(format!("nested repository {path}"));
                }
                facts.untracked.push(path);
            }
            _ => {}
        }
    }
    facts.changed = u32::try_from(changed_paths.len()).unwrap_or(u32::MAX);
    hidden_changes(root, overrides, &mut facts)?;

    // Ignored entries, a fully ignored folder as one entry.
    let ignored = git::read(
        root,
        overrides,
        &["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"],
    )?;
    for record in records(&ignored) {
        let path = String::from_utf8_lossy(record).into_owned();
        if is_build_output_at(root, &path) {
            facts.build_output.push(path);
        } else {
            facts.ignored_data.push(path);
        }
    }

    // Commits only here, and whether the work is on a base already.
    let remotes = git::read(root, overrides, &["for-each-ref", "--count=1", "refs/remotes/"])?;
    facts.has_remotes = !remotes.is_empty();
    if let Some(head) = &entry.head {
        let count =
            git::line(root, overrides, &["rev-list", "--count", "HEAD", "--not", "--remotes"])?;
        facts.unpushed = count.parse().unwrap_or(u32::MAX);
        facts.finished =
            finished(root, head, &common_dir.join("objects"), overrides, bases, finished_memo);
    }

    facts.sparse = sparse(root, overrides, &git_dir);
    facts.submodules = match populated_submodules(root, overrides) {
        Ok(submodules) => submodules,
        Err(error) => {
            facts.unarchivable.get_or_insert(format!("its submodules cannot be read ({error})"));
            Vec::new()
        }
    };
    for submodule in &facts.submodules {
        if let Some(why) = submodule_only_here(&root.join(submodule)) {
            facts.unarchivable.get_or_insert(format!("submodule {submodule} {why}"));
        }
    }

    // What an archive would take into git.
    let deadline = Instant::now() + DATA_WALK;
    let (bytes, nested) =
        data_bytes(root, facts.untracked.iter().chain(&facts.ignored_data), deadline);
    facts.archived_bytes = bytes;
    if let Some(nested) = nested {
        facts.unarchivable.get_or_insert(format!("nested repository {nested}"));
    }
    if bytes > MAX_ARCHIVED_DATA {
        facts.unarchivable.get_or_insert(format!(
            "{} MiB of untracked and ignored data (archives take at most {} MiB)",
            bytes >> 20,
            MAX_ARCHIVED_DATA >> 20
        ));
    }

    facts.last_activity_ms =
        last_activity(root, &git_dir, changed_paths.iter().chain(&facts.untracked));
    Ok(facts)
}

/// Whether an ignored path (relative to `root`) is build output: it, or a
/// folder it is in, has a build output name and one of its marker files
/// beside it.
pub fn is_build_output_at(root: &Path, path: &str) -> bool {
    let parts: Vec<&str> = path.trim_end_matches('/').split('/').collect();
    (0..parts.len()).any(|index| {
        let Some((_, markers)) = BUILD_OUTPUT.iter().find(|(name, _)| *name == parts[index]) else {
            return false;
        };
        let parent = parts[..index].iter().fold(root.to_path_buf(), |dir, part| dir.join(part));
        markers.is_empty() || markers.iter().any(|marker| parent.join(marker).exists())
    })
}

/// Tracked files `git status` does not show: an `assume-unchanged` entry,
/// or a `skip-worktree` one whose file is on disk (outside a sparse
/// checkout's patterns, it is not). Their edits would go unarchived, so
/// such a worktree is kept.
fn hidden_changes(root: &Path, overrides: &[Override], facts: &mut Facts) -> Result<(), String> {
    let listing = git::read(root, overrides, &["ls-files", "-v", "-z"])?;
    for record in records(&listing) {
        let text = String::from_utf8_lossy(record);
        let Some((tag, path)) = text.split_once(' ') else { continue };
        let assumed = tag.chars().next().is_some_and(|c| c.is_ascii_lowercase());
        let skipped = tag == "S" && std::fs::symlink_metadata(root.join(path)).is_ok();
        if assumed || skipped {
            let flag = if assumed { "assume-unchanged" } else { "skip-worktree" };
            facts.unarchivable.get_or_insert(format!("{path} is marked {flag}"));
            return Ok(());
        }
    }
    Ok(())
}

/// What lives only in a populated submodule's own repository, which goes
/// with the worktree's git folder: commits no remote has, stashes, ignored
/// data. `None` when it holds nothing of its own; a submodule that cannot
/// be read holds something, as far as cleanup knows.
fn submodule_only_here(dir: &Path) -> Option<String> {
    let unreadable = |error: String| Some(format!("cannot be read ({error})"));
    match git::line(dir, &[], &["rev-list", "--count", "--all", "--not", "--remotes"]) {
        Ok(count) if count == "0" => {}
        Ok(_) => return Some("has commits no remote has".to_string()),
        Err(error) => return unreadable(error),
    }
    match git::line(dir, &[], &["stash", "list"]) {
        Ok(list) if list.is_empty() => {}
        Ok(_) => return Some("has stashes".to_string()),
        Err(error) => return unreadable(error),
    }
    let ignored = match git::read(
        dir,
        &[],
        &["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"],
    ) {
        Ok(ignored) => ignored,
        Err(error) => return unreadable(error),
    };
    records(&ignored)
        .map(|r| String::from_utf8_lossy(r).into_owned())
        .find(|path| !is_build_output_at(dir, path))
        .map(|path| format!("has ignored data {path}"))
}

/// The path of a `--porcelain=v2` record whose path is field `index`
/// (0-based, space-separated; the path itself may hold spaces).
fn nth_field(text: &str, index: usize) -> String {
    text.splitn(index + 1, ' ').nth(index).unwrap_or_default().to_string()
}

/// A changed submodule (`S` in the record's submodule field) is refused:
/// its own work would go with the worktree.
fn submodule_change(text: &str, path_field: usize, facts: &mut Facts) {
    let submodule = text.split(' ').nth(2).unwrap_or("N...");
    if submodule.starts_with('S') {
        let path = nth_field(text, path_field);
        facts.unarchivable.get_or_insert(format!("submodule {path} has changes"));
    }
}

fn operation(git_dir: &Path) -> Option<String> {
    [
        ("rebase-merge", "rebase"),
        ("rebase-apply", "rebase"),
        ("MERGE_HEAD", "merge"),
        ("CHERRY_PICK_HEAD", "cherry-pick"),
        ("REVERT_HEAD", "revert"),
        ("BISECT_LOG", "bisect"),
    ]
    .into_iter()
    .find(|(file, _)| git_dir.join(file).exists())
    .map(|(_, name)| name.to_string())
}

/// How HEAD's work is on a base: in it, or merged into it changing nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) enum Finish {
    InBase,
    Squashed,
}

/// [`finished`]'s answer for a worktree's (HEAD, base) pair of commits.
/// Both are content-addressed, so in one worktree a pair's answer does not
/// change, and a pass asks again about every worktree while most HEADs and
/// bases have not moved since the last: on a machine with hundreds of
/// worktrees of a big repository, a `merge-tree` each kept git busy for
/// half an hour a pass. Keyed by the worktree too (its config may merge
/// differently), and never used in a repository with replacement refs or
/// grafts, which change history without changing ids.
static FINISHED: LazyLock<Arc<FinishedMemo>> = LazyLock::new(|| Arc::new(FinishedMemo::memory()));

static MERGE_TREE: LazyLock<Mutex<()>> = LazyLock::new(Mutex::default);
/// A branch larger than this is not worth attempting a memory-heavy merge.
pub const MAX_SQUASH_COMMITS: u64 = 128;
/// Linux memory ceiling (`RLIMIT_DATA`) for one merge-tree child. Other
/// platforms retain the deadline and serialization without an unsupported
/// OS limit.
pub const MERGE_TREE_MEMORY: u64 = 768 << 20;

/// Nonblocking host-wide lock shared by daemon and standalone scans. Busy or
/// unreadable means unknown, never a remembered negative answer. The lock is
/// independent of the pass lock, which daemon callers already hold.
fn merge_tree_claim(dir: Option<&Path>) -> Option<std::fs::File> {
    let dir = dir.map(Path::to_path_buf).or_else(crate::Store::default_dir)?;
    std::fs::create_dir_all(&dir).ok()?;
    let mut options = std::fs::OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(dir.join(".merge-tree.lock")).ok()?;
    file.try_lock().ok()?;
    Some(file)
}

/// Whether history in this repository can differ from what its ids say:
/// replacement refs or a grafts file. Unreadable counts as yes.
fn rewritten_history(root: &Path, objects: &Path, overrides: &[Override]) -> bool {
    let grafts = objects.parent().map(|common| common.join("info/grafts"));
    // Only a grafts file known to be absent lets the memo in.
    let grafted = grafts.is_none_or(|path| match std::fs::symlink_metadata(path) {
        Err(error) => error.kind() != std::io::ErrorKind::NotFound,
        Ok(_) => true,
    });
    grafted
        || git::read(root, overrides, &["for-each-ref", "--count=1", "refs/replace/"])
            .map_or(true, |out| !out.is_empty())
}

/// Evidence that HEAD's work is on a base branch: HEAD is in it, or merging
/// HEAD into it changes nothing (a squash merge). `objects` is the
/// repository's object folder: the merge's trees go to a scratch folder,
/// never into it.
fn finished(
    root: &Path,
    head: &str,
    objects: &Path,
    overrides: &[Override],
    configured: &[String],
    memo_store: &FinishedMemo,
) -> Option<String> {
    let repository = Repository::open(root).ok()?;
    let mut bases: Vec<String> = Vec::new();
    if let Some((reference, _)) = repository.recorded_base() {
        bases.push(reference);
    }
    if let Some((reference, _)) = repository.default_branch() {
        bases.push(reference);
    }
    for base in configured {
        let reference =
            if base.starts_with("refs/") { base.clone() } else { format!("refs/remotes/{base}") };
        bases.push(reference);
    }
    let memo = !rewritten_history(root, objects, overrides);
    let mut seen = HashSet::new();
    for base in bases.into_iter().filter(|b| seen.insert(b.clone())) {
        let Some(base_commit) = git::try_line(
            root,
            overrides,
            &["rev-parse", "--verify", "--quiet", &format!("{base}^{{commit}}")],
        ) else {
            continue;
        };
        let answer = match memo.then(|| memo_store.remembered(root, head, &base_commit)).flatten() {
            Some(answer) => answer,
            None => {
                let Some(answer) = finish(
                    root,
                    head,
                    &base_commit,
                    objects,
                    overrides,
                    memo_store.lock_dir().as_deref(),
                ) else {
                    // Unreadable: asked again next time.
                    continue;
                };
                if memo {
                    memo_store.remember(root, head, &base_commit, answer);
                }
                answer
            }
        };
        let short = base.trim_start_matches("refs/remotes/").trim_start_matches("refs/heads/");
        match answer {
            Some(Finish::InBase) => return Some(format!("HEAD is in {short}")),
            Some(Finish::Squashed) => {
                return Some(format!("HEAD's changes are already in {short}"));
            }
            None => {}
        }
    }
    None
}

/// Whether `head`'s work is on `base` (both commit ids); `None` when the
/// trees could not be read.
fn finish(
    root: &Path,
    head: &str,
    base: &str,
    objects: &Path,
    overrides: &[Override],
    lock_dir: Option<&Path>,
) -> Option<Option<Finish>> {
    if git::read(root, overrides, &["merge-base", "--is-ancestor", head, base]).is_ok() {
        return Some(Some(Finish::InBase));
    }
    let base_tree = git::try_line(
        root,
        overrides,
        &["rev-parse", "--verify", "--quiet", &format!("{base}^{{tree}}")],
    )?;
    // A conflict (`Ok(None)`) is never the base's tree. A run that could
    // not finish, or failed saying why, is no answer: not remembered.
    let maximum = format!("--max-count={}", MAX_SQUASH_COMMITS + 1);
    let commits = git::try_line(
        root,
        overrides,
        &["rev-list", "--count", &maximum, &format!("{base}..{head}")],
    )?;
    if !within_squash_limit(&commits) {
        return None;
    }
    let _merge_guard = MERGE_TREE.try_lock().ok()?;
    let _host_guard = merge_tree_claim(lock_dir)?;
    let merged = git::read_scratch_objects(
        root,
        overrides,
        objects,
        &["merge-tree", "--write-tree", "--no-messages", base, head],
        MERGE_TREE_MEMORY,
    )
    .ok()?;
    let merged = merged
        .map(|out| String::from_utf8_lossy(&out).lines().next().unwrap_or_default().to_string());
    Some((merged.as_deref() == Some(base_tree.as_str())).then_some(Finish::Squashed))
}

fn within_squash_limit(count: &str) -> bool {
    count.parse::<u64>().is_ok_and(|count| count <= MAX_SQUASH_COMMITS)
}

fn sparse(root: &Path, overrides: &[Override], git_dir: &Path) -> Option<Sparse> {
    let enabled = git::try_line(root, overrides, &["config", "--type=bool", "core.sparseCheckout"]);
    if enabled.as_deref() != Some("true") {
        return None;
    }
    let cone =
        git::try_line(root, overrides, &["config", "--type=bool", "core.sparseCheckoutCone"])
            .is_none_or(|value| value == "true");
    let text = std::fs::read_to_string(git_dir.join("info/sparse-checkout")).ok()?;
    let patterns = text.lines().map(str::to_string).filter(|line| !line.is_empty()).collect();
    Some(Sparse { cone, patterns })
}

fn populated_submodules(root: &Path, overrides: &[Override]) -> Result<Vec<String>, String> {
    if !root.join(".gitmodules").exists() {
        return Ok(Vec::new());
    }
    // Gitlinks in the index whose folder is a checkout.
    let out = git::read(root, overrides, &["ls-files", "-z", "--stage"])?;
    Ok(records(&out)
        .filter_map(|record| {
            let text = String::from_utf8_lossy(record);
            let (meta, path) = text.split_once('\t')?;
            meta.starts_with("160000").then(|| path.to_string())
        })
        .filter(|path| root.join(path).join(".git").exists())
        .collect())
}

/// The bytes of `entries` (relative files or folders under `root`), and
/// the first nested repository among them.
fn data_bytes<'a>(
    root: &Path,
    entries: impl Iterator<Item = &'a String>,
    deadline: Instant,
) -> (u64, Option<String>) {
    let mut total = 0u64;
    let mut nested = None;
    let mut stack: Vec<PathBuf> =
        entries.map(|entry| root.join(entry.trim_end_matches('/'))).collect();
    while let Some(path) = stack.pop() {
        if Instant::now() >= deadline {
            // Unknown is too much: refuse rather than archive blind.
            return (u64::MAX, nested);
        }
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if meta.is_dir() {
            if path.join(".git").exists() && nested.is_none() {
                nested = path.strip_prefix(root).ok().map(|p| p.display().to_string());
            }
            if let Ok(children) = std::fs::read_dir(&path) {
                stack.extend(children.flatten().map(|child| child.path()));
            }
        } else {
            total = total.saturating_add(meta.len());
        }
    }
    (total, nested)
}

/// The newest of HEAD's last reflog entry, the index, the top folder and
/// the changed files (`git gc` rewrites `logs/HEAD`, so its entry's own
/// time counts, not the file's).
fn last_activity<'a>(
    root: &Path,
    git_dir: &Path,
    changed: impl Iterator<Item = &'a String>,
) -> u64 {
    let mut newest = reflog_time(&git_dir.join("logs/HEAD")).unwrap_or(0);
    newest = newest.max(mtime_ms(&git_dir.join("index"))).max(mtime_ms(root));
    let mut seen = BTreeSet::new();
    for path in changed.take(MAX_STATS) {
        let path = root.join(path);
        newest = newest.max(mtime_ms(&path));
        if let Some(parent) = path.parent()
            && seen.insert(parent.to_path_buf())
        {
            newest = newest.max(mtime_ms(parent));
        }
    }
    newest
}

/// The time, in milliseconds, of the last entry of a reflog.
pub(crate) fn reflog_time(path: &Path) -> Option<u64> {
    let text = std::fs::read_to_string(path).ok()?;
    let line = text.lines().rev().find(|line| !line.trim().is_empty())?;
    let (identity, _) = line.split_once('\t').unwrap_or((line, ""));
    let mut parts = identity.rsplitn(3, ' ');
    let _zone = parts.next()?;
    let seconds: u64 = parts.next()?.parse().ok()?;
    Some(seconds.saturating_mul(1000))
}

pub(crate) fn mtime_ms(path: &Path) -> u64 {
    std::fs::symlink_metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

/// Milliseconds since the epoch now.
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod care_tests {
    use super::*;

    #[test]
    fn the_worktree_list_names_each_worktree_with_its_state() {
        let listing = b"worktree /r\0HEAD 1111111111111111111111111111111111111111\0branch refs/heads/main\0\0worktree /w/a\0HEAD 2222222222222222222222222222222222222222\0detached\0locked\0\0worktree /w/b\0HEAD 3333333333333333333333333333333333333333\0branch refs/heads/feat/x\0prunable gitdir file points to non-existent location\0\0";
        let entries = parse_worktree_list(listing);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].branch.as_deref(), Some("main"));
        assert!(entries[1].locked && entries[1].branch.is_none());
        assert!(entries[2].prunable);
        assert_eq!(entries[2].branch.as_deref(), Some("feat/x"));
    }

    #[test]
    fn build_output_needs_its_name_and_its_marker() {
        let root = crate::store::care_tests::scratch("markers");
        std::fs::create_dir_all(root.join("webviews")).unwrap();
        std::fs::write(root.join("webviews/package.json"), "{}").unwrap();
        std::fs::create_dir_all(root.join("cmux-tui")).unwrap();
        std::fs::write(root.join("cmux-tui/Cargo.toml"), "").unwrap();
        assert!(is_build_output_at(&root, "webviews/node_modules/"));
        assert!(is_build_output_at(&root, "cmux-tui/target/"));
        assert!(is_build_output_at(&root, "cmux-tui/target/debug/x"));
        assert!(is_build_output_at(&root, "a/b/__pycache__/"));
        assert!(!is_build_output_at(&root, "node_modules/"), "no package.json beside it");
        assert!(!is_build_output_at(&root, "docs/target/"), "a target/ that is not cargo's");
        assert!(!is_build_output_at(&root, ".env"));
        assert!(!is_build_output_at(&root, "webviews/src/generated/"));
        assert!(!is_build_output_at(&root, "targets.txt"));
    }

    #[test]
    fn the_reflog_time_is_the_last_entry_s() {
        let dir = crate::store::care_tests::scratch("reflog");
        let log = dir.join("HEAD");
        std::fs::write(
            &log,
            "0000 1111 A <a@b> 1700000000 +0000\tclone\n1111 2222 A <a@b> 1700000500 -0700\tcommit: x\n",
        )
        .unwrap();
        assert_eq!(reflog_time(&log), Some(1_700_000_500_000));
    }

    #[test]
    fn persisted_finished_answers_survive_a_restart() {
        let path = crate::store::care_tests::scratch("finished-memo").join("answers.json");
        let memo = FinishedMemo::load(path.clone());
        let root = Path::new("/worktrees/a");
        memo.remember(
            root,
            "1111111111111111111111111111111111111111",
            "2222222222222222222222222222222222222222",
            Some(Finish::Squashed),
        );
        memo.flush();
        drop(memo);
        let restarted = FinishedMemo::load(path);
        assert_eq!(
            restarted.remembered(
                root,
                "1111111111111111111111111111111111111111",
                "2222222222222222222222222222222222222222"
            ),
            Some(Some(Finish::Squashed))
        );
    }

    #[test]
    fn an_oversized_pair_skips_merge_tree() {
        assert!(within_squash_limit("128"));
        assert!(!within_squash_limit("129"));
        assert!(!within_squash_limit("not-a-count"));
    }
}
