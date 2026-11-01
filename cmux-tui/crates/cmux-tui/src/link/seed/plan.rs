//! The Mac side of `git-seed-v1` (design/cloud.md, "Getting the project
//! onto the machine"): decides whether a folder can be seeded from its
//! GitHub remote and builds the one bundle of what the remote lacks.
//!
//! The bundle carries `refs/cmux-seed/head` (HEAD), `refs/cmux-seed/index`
//! (a commit of the staged tree, parent HEAD), `refs/cmux-seed/work` (a
//! commit of the working tree with untracked files that are not ignored,
//! less the secrets [`secrets`] names, parent the index commit) and
//! `refs/cmux-seed/stash` when there is a stash, with `^BASE` as its one
//! prerequisite. Git leaves out of the bundle any seed ref whose commit
//! the machine already has (HEAD when it is the base; in a delta seed,
//! an unchanged HEAD or index); the params always name every commit.
//!
//! A delta seed ([`plan_since`]) sends only what changed after an earlier
//! seed, with that seed's work and head commits as the prerequisites.
//!
//! The person's index, working tree and refs never change: the index and
//! work commits are built through a copy of the index, and the bundle is
//! made from a scratch bare repository that borrows the repository's
//! objects through alternates, so the seed refs live only there. The seed's
//! blobs, trees and commits are written to the repository's object store
//! unreferenced, as `git stash create` does: a later delta seed builds on
//! them, and gc prunes them in time ([`FallbackCode::NoPrevious`]).

use std::os::unix::fs::DirBuilderExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};

use super::{git, github, secrets};

/// The `git.seed.start` params, less `folder` and `bundle` (the remote
/// paths the caller fills in).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SeedParams {
    /// `https://github.com/OWNER/NAME.git`.
    pub url: String,
    /// `OWNER/NAME`.
    pub repo: String,
    /// The commit the machine clones at; the bundle's prerequisite.
    pub base: String,
    /// `refs/heads/NAME`, or None when HEAD is detached.
    pub head_ref: Option<String>,
    pub head: String,
    pub index: String,
    pub work: String,
    pub stash: Option<String>,
    /// The sparse-checkout patterns, when sparse checkout is on.
    pub sparse: Option<String>,
    /// Whether a `.gitattributes` names `filter=lfs`.
    pub lfs: bool,
    /// The previous seed's work commit for a delta seed ([`plan_since`]),
    /// else None.
    pub since: Option<String>,
}

/// An untracked file left out of the work commit, and why in plain words.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Skipped {
    pub path: String,
    pub why: String,
}

/// A submodule and the commit checked out in it (the recorded one when it
/// is not checked out).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Submodule {
    pub path: String,
    pub commit: String,
}

/// A plan the machine can seed from, with its bundle written.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Planned {
    pub params: SeedParams,
    pub skipped: Vec<Skipped>,
    pub submodules: Vec<Submodule>,
    /// Bases to try, best first: the merge-base with the upstream, the
    /// merge-base with the remote's default branch, that branch's tip.
    /// When the machine answers `seed.base_missing`, re-plan with the
    /// next one through [`plan_with_base`].
    pub bases: Vec<String>,
    /// Bytes of the bundle; 0 when [`Self::unchanged`] (no bundle is
    /// written then).
    pub bundle_bytes: u64,
    /// A delta seed found HEAD, the index and the working tree as the
    /// previous seed left them: nothing to send.
    pub unchanged: bool,
}

/// The commits an earlier seed of this folder sent ([`plan_since`]).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviousSeed {
    pub head: String,
    pub index: String,
    pub work: String,
}

/// Why a folder takes the streamed copy instead of a seed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FallbackCode {
    /// Not inside a git working copy (or a bare repository).
    NotGit,
    /// Inside a working copy, but not its top folder.
    NotTop,
    /// The repository has no commit yet.
    NoCommit,
    /// The repository has no remote.
    NoRemote,
    /// Several remotes, no upstream and none called `origin`.
    AmbiguousRemote,
    /// The chosen remote is not a GitHub repository.
    NotGithub,
    /// No commit this Mac has is known to be on the remote.
    NoBase,
    /// The index has unresolved merge conflicts.
    Unmerged,
    /// A submodule has commits not on its remote, or uncommitted changes.
    SubmoduleLocalWork,
    /// A delta seed's previous commits are not in this repository (a gc
    /// dropped them, or they came from another one).
    NoPrevious,
    /// git failed in a way the plan did not expect.
    GitFailed,
}

impl FallbackCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotGit => "not_git",
            Self::NotTop => "not_top",
            Self::NoCommit => "no_commit",
            Self::NoRemote => "no_remote",
            Self::AmbiguousRemote => "ambiguous_remote",
            Self::NotGithub => "not_github",
            Self::NoBase => "no_base",
            Self::Unmerged => "unmerged",
            Self::SubmoduleLocalWork => "submodule_local_work",
            Self::NoPrevious => "no_previous",
            Self::GitFailed => "git_failed",
        }
    }
}

/// The folder takes the copy: [`FallbackCode`] and why in plain words.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Fallback {
    pub code: FallbackCode,
    pub why: String,
}

impl Fallback {
    fn new(code: FallbackCode, why: impl Into<String>) -> Self {
        Self { code, why: why.into() }
    }
}

fn failed(what: &str, error: String) -> Fallback {
    Fallback::new(FallbackCode::GitFailed, format!("{what}: {error}"))
}

/// Plans a seed of the working copy at `folder` from its best base and
/// writes the bundle to `out_bundle`.
pub fn plan(folder: &Path, out_bundle: &Path) -> Result<Planned, Fallback> {
    let repo = Repo::open(folder)?;
    let bases = repo.bases();
    let Some(base) = bases.first().cloned() else {
        return Err(Fallback::new(
            FallbackCode::NoBase,
            format!(
                "no commit on {} is known to share history with this folder's HEAD",
                repo.remote
            ),
        ));
    };
    build(&repo, out_bundle, &Since::Base(&base), bases)
}

/// [`plan`] from `base` (one of [`Planned::bases`], after the machine
/// found the remote lacks the first).
pub fn plan_with_base(folder: &Path, out_bundle: &Path, base: &str) -> Result<Planned, Fallback> {
    let repo = Repo::open(folder)?;
    if !(4..=64).contains(&base.len()) || !base.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(Fallback::new(FallbackCode::NoBase, format!("{base:?} is not a commit id")));
    }
    let Some(base) = git::optional(git::at(&repo.top).args([
        "rev-parse",
        "--verify",
        "-q",
        format!("{base}^{{commit}}").as_str(),
    ])) else {
        return Err(Fallback::new(
            FallbackCode::NoBase,
            format!("this Mac does not have commit {base}"),
        ));
    };
    let bases = repo.bases();
    build(&repo, out_bundle, &Since::Base(&base), bases)
}

/// A delta seed after `previous` (a seed the machine already applied):
/// the same refs, with `previous.work` and `previous.head` as the
/// prerequisites, so the bundle holds only what changed since.
/// [`SeedParams::base`] and [`SeedParams::since`] are `previous.work`;
/// [`Planned::bases`] is empty. When HEAD, the index and the working tree
/// are as `previous` left them, the answer is [`Planned::unchanged`] and
/// no bundle is written. The stash is carried but not compared.
pub fn plan_since(
    folder: &Path,
    out_bundle: &Path,
    previous: &PreviousSeed,
) -> Result<Planned, Fallback> {
    let repo = Repo::open(folder)?;
    for id in [&previous.head, &previous.index, &previous.work] {
        let hex = (4..=64).contains(&id.len()) && id.bytes().all(|byte| byte.is_ascii_hexdigit());
        if !hex || repo.commit(id).as_deref() != Some(id.as_str()) {
            return Err(Fallback::new(
                FallbackCode::NoPrevious,
                format!("the previous seed's commit {id} is not in this repository"),
            ));
        }
    }
    build(&repo, out_bundle, &Since::Previous(previous), Vec::new())
}

/// What the machine already has.
enum Since<'a> {
    Base(&'a str),
    Previous(&'a PreviousSeed),
}

/// The working copy as the plan sees it.
struct Repo {
    top: PathBuf,
    head: String,
    head_ref: Option<String>,
    remote: String,
    /// HEAD's upstream (`refs/remotes/...`) when it is on [`Self::remote`].
    upstream: Option<String>,
    github: github::GithubRepo,
}

impl Repo {
    fn open(folder: &Path) -> Result<Self, Fallback> {
        let shown = folder.display();
        let top =
            git::text(git::at(folder).args(["rev-parse", "--show-toplevel"])).map_err(|_| {
                Fallback::new(FallbackCode::NotGit, format!("{shown} is not a git working copy"))
            })?;
        let top = PathBuf::from(top);
        let same = match (std::fs::canonicalize(folder), std::fs::canonicalize(&top)) {
            (Ok(folder), Ok(top)) => folder == top,
            _ => false,
        };
        if !same {
            return Err(Fallback::new(
                FallbackCode::NotTop,
                format!("{shown} is inside the git working copy at {}", top.display()),
            ));
        }
        let Some(head) =
            git::optional(git::at(&top).args(["rev-parse", "--verify", "-q", "HEAD^{commit}"]))
        else {
            return Err(Fallback::new(FallbackCode::NoCommit, "the repository has no commit yet"));
        };
        let head_ref = git::optional(git::at(&top).args(["symbolic-ref", "-q", "HEAD"]));
        let remotes: Vec<String> = git::text(git::at(&top).arg("remote"))
            .map_err(|error| failed("listing remotes", error))?
            .lines()
            .map(str::to_string)
            .collect();
        if remotes.is_empty() {
            return Err(Fallback::new(FallbackCode::NoRemote, "the repository has no remote"));
        }
        let tracked = head_ref.as_deref().and_then(|head_ref| upstream_of(&top, head_ref));
        let tracked = tracked.filter(|(remote, _)| remotes.contains(remote));
        let remote = if let Some((remote, _)) = &tracked {
            remote.clone()
        } else if remotes.iter().any(|remote| remote == "origin") {
            "origin".to_string()
        } else if let [only] = remotes.as_slice() {
            only.clone()
        } else {
            return Err(Fallback::new(
                FallbackCode::AmbiguousRemote,
                format!(
                    "the repository has {} remotes, none is origin and the branch tracks none",
                    remotes.len()
                ),
            ));
        };
        let github = remote_repo(&top, &remote)?;
        Ok(Self {
            top,
            head,
            head_ref,
            remote,
            upstream: tracked.map(|(_, upstream)| upstream),
            github,
        })
    }

    /// [`Planned::bases`], with duplicates left out.
    fn bases(&self) -> Vec<String> {
        let mut bases = Vec::new();
        if let Some(upstream) = self.upstream.as_deref().and_then(|name| self.commit(name)) {
            bases.extend(self.merge_base(&upstream));
        }
        let remote = &self.remote;
        let default = [
            format!("refs/remotes/{remote}/HEAD"),
            format!("refs/remotes/{remote}/main"),
            format!("refs/remotes/{remote}/master"),
        ]
        .iter()
        .find_map(|name| self.commit(name));
        if let Some(tip) = default {
            bases.extend(self.merge_base(&tip));
            bases.push(tip);
        }
        let mut seen = std::collections::HashSet::new();
        bases.retain(|base| seen.insert(base.clone()));
        bases
    }

    fn commit(&self, name: &str) -> Option<String> {
        git::optional(git::at(&self.top).args([
            "rev-parse",
            "--verify",
            "-q",
            format!("{name}^{{commit}}").as_str(),
        ]))
    }

    fn merge_base(&self, other: &str) -> Option<String> {
        git::optional(git::at(&self.top).args(["merge-base", self.head.as_str(), other]))
    }

    /// An absolute path inside the repository's git dir (`--git-path`).
    fn git_path(&self, name: &str) -> Result<PathBuf, Fallback> {
        git::text(git::at(&self.top).args([
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            name,
        ]))
        .map(PathBuf::from)
        .map_err(|error| failed("finding the git dir", error))
    }
}

/// The remote and full upstream ref `head_ref` tracks, if any.
fn upstream_of(top: &Path, head_ref: &str) -> Option<(String, String)> {
    let line = git::optional(git::at(top).args([
        "for-each-ref",
        "--format=%(upstream:remotename)%09%(upstream)",
        "--",
        head_ref,
    ]))?;
    let (remote, upstream) = line.split_once('\t')?;
    (!remote.is_empty() && upstream.starts_with("refs/remotes/"))
        .then(|| (remote.to_string(), upstream.to_string()))
}

/// The GitHub repository `remote` points at. The configured URL is tried
/// first (a `url.*.insteadOf` rewrite may point elsewhere for fetches),
/// then the rewritten one (a shorthand that rewrites to GitHub).
fn remote_repo(top: &Path, remote: &str) -> Result<github::GithubRepo, Fallback> {
    let raw = git::optional(git::at(top).args([
        "config",
        "--get",
        format!("remote.{remote}.url").as_str(),
    ]));
    let rewritten = git::optional(git::at(top).args(["remote", "get-url", remote]));
    for url in [&raw, &rewritten].into_iter().flatten() {
        if let Some(repo) = github::parse(url) {
            return Ok(repo);
        }
    }
    let shown = raw.or(rewritten).map_or_else(|| "no URL".to_string(), |url| github::redact(&url));
    Err(Fallback::new(
        FallbackCode::NotGithub,
        format!("the remote {remote} is {shown}, not a GitHub repository"),
    ))
}

/// A scratch folder, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Result<Self, Fallback> {
        let parent = std::env::temp_dir();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        for attempt in 0..32 {
            let path = parent.join(format!("cmux-seed-{}-{nanos}-{attempt}", std::process::id()));
            match std::fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => {
                    return Err(failed("making a scratch folder", error.to_string()));
                }
            }
        }
        Err(failed("making a scratch folder", "every name was taken".to_string()))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The fixed identity and date of the index and work commits, so the same
/// tree on the same HEAD always gives the same commit.
const SEED_NAME: &str = "cmux seed";
const SEED_EMAIL: &str = "seed@cmux.invalid";
const SEED_DATE: &str = "946684800 +0000";

fn build(
    repo: &Repo,
    out_bundle: &Path,
    since: &Since<'_>,
    bases: Vec<String>,
) -> Result<Planned, Fallback> {
    let submodules = submodules(repo)?;
    let scratch = Scratch::new()?;
    let store = scratch.0.join("store.git");
    git::output(git::at(&scratch.0).args(["init", "-q", "--bare", "--template="]).arg(&store))
        .map_err(|error| failed("making the scratch repository", error))?;
    let objects = repo.git_path("objects")?;
    std::fs::create_dir_all(store.join("objects/info"))
        .map_err(|error| failed("making the scratch object store", error.to_string()))?;
    write(&store.join("objects/info/alternates"), format!("{}\n", objects.display()))?;
    // A shallow clone's grafts, so walks stop where this Mac's history does.
    let shallow = repo.git_path("shallow")?;
    if shallow.is_file() {
        std::fs::copy(shallow, store.join("shallow"))
            .map_err(|error| failed("copying the shallow list", error.to_string()))?;
    }
    let index = scratch.0.join("index");
    let real_index = repo.git_path("index")?;
    if real_index.is_file() {
        std::fs::copy(real_index, &index)
            .map_err(|error| failed("copying the index", error.to_string()))?;
    } else {
        run(repo.scratch_git(&index).args(["read-tree", repo.head.as_str()]), "reading HEAD")?;
    }

    let index_tree = repo.write_tree(&index)?;
    let index_commit = commit(repo, &index_tree, &repo.head, "cmux seed index")?;

    let skipped = untracked_left_out(repo)?;
    let sparse = sparse_patterns(repo)?;
    // In a sparse checkout `--sparse` also takes untracked files outside
    // the patterns; entries git keeps out of the working tree stay as they
    // are either way.
    let sparse_flag: &[&str] = if sparse.is_some() { &["--sparse"] } else { &[] };
    run(repo.scratch_git(&index).args(["add", "-A"]).args(sparse_flag), "adding the working tree")?;
    if !skipped.is_empty() {
        let list = scratch.0.join("left-out");
        let mut paths = Vec::new();
        for item in &skipped {
            paths.extend_from_slice(item.path.trim_end_matches('/').as_bytes());
            paths.push(0);
        }
        write(&list, paths)?;
        run(
            repo.scratch_git(&index)
                .env("GIT_LITERAL_PATHSPECS", "1")
                .args([
                    "rm",
                    "--cached",
                    "-r",
                    "-f",
                    "-q",
                    "--ignore-unmatch",
                    "--pathspec-file-nul",
                ])
                .args(sparse_flag)
                .arg(format!("--pathspec-from-file={}", list.display())),
            "leaving out secrets",
        )?;
    }
    let work_tree = repo.write_tree(&index)?;
    let work_commit = commit(repo, &work_tree, &index_commit, "cmux seed work")?;

    let stash = repo.commit("refs/stash");
    let lfs = uses_lfs(repo, &skipped);

    let mut refs = vec![
        ("refs/cmux-seed/head", repo.head.as_str()),
        ("refs/cmux-seed/index", index_commit.as_str()),
        ("refs/cmux-seed/work", work_commit.as_str()),
    ];
    if let Some(stash) = &stash {
        refs.push(("refs/cmux-seed/stash", stash.as_str()));
    }
    // The work commit's parents are the index commit and HEAD, so the same
    // work sha means all three are as the previous seed left them.
    let (base, unchanged) = match since {
        Since::Base(base) => ((*base).to_string(), false),
        Since::Previous(previous) => (previous.work.clone(), previous.work == work_commit),
    };
    let mut bundle_bytes = 0;
    if !unchanged {
        for (name, id) in &refs {
            run(git::bare(&store).args(["update-ref", *name, *id]), "naming the seed commits")?;
        }
        let mut bundle = git::bare(&store);
        bundle.args(["bundle", "create", "-q"]).arg(out_bundle);
        bundle.args(refs.iter().map(|(name, _)| *name));
        match since {
            Since::Base(base) => {
                bundle.arg(format!("^{base}"));
            }
            Since::Previous(previous) => {
                bundle.arg(format!("^{}", previous.work)).arg(format!("^{}", previous.head));
                // The new commits are siblings of the previous ones, not
                // descendants, so git would not look inside the previous
                // trees and would send every unchanged file again. Their
                // trees, excluded too, keep it to what changed.
                for id in [&previous.head, &previous.index, &previous.work] {
                    bundle.arg(format!("^{id}^{{tree}}"));
                }
            }
        }
        run(&mut bundle, "making the bundle")?;
        bundle_bytes = std::fs::metadata(out_bundle)
            .map_err(|error| failed("reading the bundle", error.to_string()))?
            .len();
    }
    let since = match since {
        Since::Base(_) => None,
        Since::Previous(previous) => Some(previous.work.clone()),
    };

    Ok(Planned {
        params: SeedParams {
            url: repo.github.url(),
            repo: repo.github.slug(),
            base,
            head_ref: repo.head_ref.clone(),
            head: repo.head.clone(),
            index: index_commit,
            work: work_commit,
            stash,
            sparse,
            lfs,
            since,
        },
        skipped,
        submodules,
        bases,
        bundle_bytes,
        unchanged,
    })
}

impl Repo {
    /// git in the working copy with the scratch index.
    fn scratch_git(&self, index: &Path) -> Command {
        let mut command = git::at(&self.top);
        command.env("GIT_INDEX_FILE", index);
        command
    }

    fn write_tree(&self, index: &Path) -> Result<String, Fallback> {
        git::text(self.scratch_git(index).arg("write-tree")).map_err(|error| {
            if error.contains("unmerged") {
                Fallback::new(
                    FallbackCode::Unmerged,
                    "the index has unresolved merge conflicts; resolve them or the folder is copied",
                )
            } else {
                failed("writing a tree", error)
            }
        })
    }
}

fn commit(repo: &Repo, tree: &str, parent: &str, message: &str) -> Result<String, Fallback> {
    git::text(
        git::at(&repo.top)
            .env("GIT_AUTHOR_NAME", SEED_NAME)
            .env("GIT_AUTHOR_EMAIL", SEED_EMAIL)
            .env("GIT_AUTHOR_DATE", SEED_DATE)
            .env("GIT_COMMITTER_NAME", SEED_NAME)
            .env("GIT_COMMITTER_EMAIL", SEED_EMAIL)
            .env("GIT_COMMITTER_DATE", SEED_DATE)
            .args(["commit-tree", "--no-gpg-sign", "-p", parent, "-m", message, tree]),
    )
    .map_err(|error| failed("making a seed commit", error))
}

fn run(command: &mut Command, what: &str) -> Result<(), Fallback> {
    git::output(command).map(drop).map_err(|error| failed(what, error))
}

fn write(path: &Path, contents: impl AsRef<[u8]>) -> Result<(), Fallback> {
    std::fs::write(path, contents)
        .map_err(|error| failed(&format!("writing {}", path.display()), error.to_string()))
}

/// Untracked files that are not ignored but stay on this Mac: likely
/// secrets, and git repositories nested in the folder (not submodules).
fn untracked_left_out(repo: &Repo) -> Result<Vec<Skipped>, Fallback> {
    let listed =
        git::output(git::at(&repo.top).args(["ls-files", "-z", "--others", "--exclude-standard"]))
            .map_err(|error| failed("listing untracked files", error))?;
    let mut skipped = Vec::new();
    for raw in listed.split(|byte| *byte == 0).filter(|path| !path.is_empty()) {
        let path = String::from_utf8_lossy(raw).into_owned();
        let why = if path.ends_with('/') {
            Some("a separate git repository inside this folder (not a submodule)")
        } else {
            secrets::reason(&repo.top, raw)
        };
        if let Some(why) = why {
            skipped.push(Skipped { path, why: why.to_string() });
        }
    }
    Ok(skipped)
}

/// Each submodule with the commit checked out in it. One with a commit not
/// on its remote-tracking refs, or with uncommitted changes, is local work
/// this plan cannot seed yet.
fn submodules(repo: &Repo) -> Result<Vec<Submodule>, Fallback> {
    let staged = git::output(git::at(&repo.top).args(["ls-files", "-z", "-s"]))
        .map_err(|error| failed("listing the index", error))?;
    let mut found = Vec::new();
    for entry in staged.split(|byte| *byte == 0).filter(|entry| !entry.is_empty()) {
        let entry = String::from_utf8_lossy(entry);
        let Some((meta, path)) = entry.split_once('\t') else { continue };
        let mut fields = meta.split(' ');
        if fields.next() != Some("160000") {
            continue;
        }
        let recorded = fields.next().unwrap_or_default().to_string();
        let checkout = repo.top.join(path);
        if !checkout.join(".git").exists() {
            found.push(Submodule { path: path.to_string(), commit: recorded });
            continue;
        }
        let local_work = |why: String| {
            Fallback::new(FallbackCode::SubmoduleLocalWork, format!("submodule {path} {why}"))
        };
        let commit = git::optional(git::at(&checkout).args([
            "rev-parse",
            "--verify",
            "-q",
            "HEAD^{commit}",
        ]))
        .ok_or_else(|| local_work("has no commit checked out".to_string()))?;
        let dirty = git::text(git::at(&checkout).args(["status", "--porcelain"]))
            .map_err(|error| failed(&format!("reading submodule {path}"), error))?;
        if !dirty.is_empty() {
            return Err(local_work("has uncommitted changes".to_string()));
        }
        let on_remote = git::optional(git::at(&checkout).args([
            "for-each-ref",
            "--count=1",
            "--format=%(refname)",
            "--contains",
            commit.as_str(),
            "refs/remotes",
        ]));
        if on_remote.is_none() {
            return Err(local_work(format!("is at {commit}, which is not on its remote")));
        }
        found.push(Submodule { path: path.to_string(), commit });
    }
    Ok(found)
}

/// The sparse-checkout patterns when sparse checkout is on.
fn sparse_patterns(repo: &Repo) -> Result<Option<String>, Fallback> {
    let on = git::optional(git::at(&repo.top).args(["config", "--bool", "core.sparseCheckout"]));
    if on.as_deref() != Some("true") {
        return Ok(None);
    }
    let file = repo.git_path("info/sparse-checkout")?;
    Ok(Some(std::fs::read_to_string(file).unwrap_or_default()))
}

/// Whether any `.gitattributes` in the working tree (tracked, or untracked
/// and going) names `filter=lfs`.
fn uses_lfs(repo: &Repo, skipped: &[Skipped]) -> bool {
    let listed = git::output(git::at(&repo.top).args([
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--",
        ":(glob)**/.gitattributes",
    ]))
    .unwrap_or_default();
    listed
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .map(|path| String::from_utf8_lossy(path).into_owned())
        .filter(|path| !skipped.iter().any(|item| &item.path == path))
        .any(|path| {
            std::fs::read(repo.top.join(&path))
                .is_ok_and(|text| String::from_utf8_lossy(&text).contains("filter=lfs"))
        })
}
