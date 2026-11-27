//! The Mac side of `git-seed-v1` (design/cloud.md, "Getting the project
//! onto the machine"): decides whether a folder can be seeded from its
//! GitHub remote and builds the one bundle of what the remote lacks.
//!
//! The bundle carries `refs/cmux-seed/head` (HEAD), `refs/cmux-seed/index`
//! (a commit of the staged tree, parent HEAD), `refs/cmux-seed/work` (a
//! commit of the working tree with untracked files that are not ignored,
//! less the secrets [`secrets`] names, heavy folders and big files past a cap (each
//! named in `skipped`), parent the index commit) and
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

use super::super::sync_cli;
use super::{git, github, secrets};
use crate::link::sync_cli::skips;

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
    /// For display: a name that is not UTF-8 is shown lossily.
    pub path: String,
    pub why: String,
    /// git's raw name, which is what the plan leaves out (a lossy spelling
    /// of a name that is not UTF-8 would match nothing).
    #[serde(skip)]
    pub raw: Vec<u8>,
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
    /// A delta seed found HEAD, the index, the working tree and refs/stash as
    /// the previous seed left them: nothing to send.
    pub unchanged: bool,
    /// The `.gitattributes` files (from the top, `/`-separated) that name `filter=lfs`;
    /// [`SeedParams::lfs`] is whether there is one. A head-first seed reads where they are:
    /// only one that can reach the head's files keeps the seed from opening at its head
    /// (`seed_cli::asks_head_first`).
    #[serde(skip)]
    pub lfs_attributes: Vec<String>,
    /// The LFS pointers in the work commit and whether this Mac holds their content; empty
    /// unless `CMUX_SEED_LFS=1` ([`super::lfs::enabled`]).
    #[serde(skip)]
    pub lfs_files: Vec<super::lfs::LfsFile>,
}

/// The commits an earlier seed of this folder sent ([`plan_since`]).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviousSeed {
    pub head: String,
    pub index: String,
    pub work: String,
    /// Stash at the previous accepted seed (None means refs/stash was absent).
    pub stash: Option<String>,
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
    /// A submodule is at a commit not on its remote, or has none checked out
    /// (its uncommitted changes alone stay on this Mac, named).
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

/// Whether [`plan`] would seed `folder` rather than fall back to the copy, read from git alone
/// (no bundle, no commit written): a start's estimate before any machine (`sync_cli::estimate`).
/// The machine may still refuse the seed (`seed.needs_github`); the copy then goes as estimated.
pub fn seedable(folder: &Path) -> Result<(), Fallback> {
    let repo = Repo::open(folder)?;
    if repo.bases().is_empty() {
        return Err(Fallback::new(FallbackCode::NoBase, "no commit is known to be on the remote"));
    }
    Ok(())
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
/// and stash are as `previous` left them, the answer is [`Planned::unchanged`]
/// and no bundle is written.
pub fn plan_since(
    folder: &Path,
    out_bundle: &Path,
    previous: &PreviousSeed,
) -> Result<Planned, Fallback> {
    let repo = Repo::open(folder)?;
    let ids = [&previous.head, &previous.index, &previous.work];
    repo.check_seed_commits(&ids, "previous")?;
    build(&repo, out_bundle, &Since::Previous(previous), Vec::new())
}

/// The seed `recorded` (one this Mac sent before) again, from this repository's object store
/// alone: no INDEX or WORK commit of the folder as it is now, nothing read from its working tree
/// and nothing written to it, its index or its refs. The bundle carries `recorded`'s commits as
/// `refs/cmux-seed/*` with `^BASE`, BASE the best base of `recorded.head`. Move to another
/// Cloud machine seeds the second machine with it (`seed_cli::hop`), so both hold the seed
/// Bring Back Local merges against.
pub fn plan_recorded(
    folder: &Path,
    out_bundle: &Path,
    recorded: &PreviousSeed,
) -> Result<Planned, Fallback> {
    let mut repo = Repo::open(folder)?;
    let mut ids = vec![&recorded.head, &recorded.index, &recorded.work];
    ids.extend(recorded.stash.as_ref());
    repo.check_seed_commits(&ids, "recorded")?;
    // The bases of the recorded HEAD, not of whatever this Mac checked out since.
    repo.head = recorded.head.clone();
    let bases = repo.bases();
    let Some(base) = bases.first().cloned() else {
        return Err(Fallback::new(
            FallbackCode::NoBase,
            format!("no commit on {} is known to share history with the seed", repo.remote),
        ));
    };
    let scratch = Scratch::new()?;
    let store = scratch.0.join("store.git");
    git::output(git::at(&scratch.0).args(["init", "-q", "--bare", "--template="]).arg(&store))
        .map_err(|error| failed("making the scratch repository", error))?;
    borrow_objects(&repo, &store)?;
    let mut refs = vec![
        ("refs/cmux-seed/head", recorded.head.as_str()),
        ("refs/cmux-seed/index", recorded.index.as_str()),
        ("refs/cmux-seed/work", recorded.work.as_str()),
    ];
    if let Some(stash) = &recorded.stash {
        refs.push(("refs/cmux-seed/stash", stash.as_str()));
    }
    name_refs(&store, &refs)?;
    let mut bundle = git::bare(&store);
    bundle.args(["bundle", "create", "-q"]).arg(out_bundle);
    bundle.args(refs.iter().map(|(name, _)| *name)).arg(format!("^{base}"));
    run(&mut bundle, "making the bundle")?;
    let bundle_bytes = std::fs::metadata(out_bundle)
        .map_err(|error| failed("reading the bundle", error.to_string()))?
        .len();
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
    let listed = listed.split(|byte| *byte == 0).filter(|path| !path.is_empty());
    let lfs_attributes = lfs_attributes(&repo, listed, &[]);
    Ok(Planned {
        params: SeedParams {
            url: repo.github.url(),
            repo: repo.github.slug(),
            base,
            head_ref: repo.head_ref,
            head: recorded.head.clone(),
            index: recorded.index.clone(),
            work: recorded.work.clone(),
            stash: recorded.stash.clone(),
            sparse: None,
            lfs: !lfs_attributes.is_empty(),
            since: None,
        },
        skipped: Vec::new(),
        submodules: Vec::new(),
        bases,
        bundle_bytes,
        unchanged: false,
        lfs_attributes,
        lfs_files: Vec::new(),
    })
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
    paths: GitPaths,
    /// Whether `core.sparseCheckout` is on.
    sparse_checkout: bool,
    /// Read once, on first use ([`Self::refs`]).
    refs: std::cell::OnceCell<Refs>,
}

/// The paths inside the git dir the plan reads (`--git-path`, absolute).
struct GitPaths {
    objects: PathBuf,
    shallow: PathBuf,
    index: PathBuf,
    sparse_checkout: PathBuf,
    lfs: PathBuf,
}

/// The `--git-path` names [`GitPaths`] holds, in its order.
const GIT_PATHS: [&str; 5] = ["objects", "shallow", "index", "info/sparse-checkout", "lfs"];

/// The commits of the refs the bases and the stash come from, read in one git.
struct Refs {
    /// [`Repo::upstream`]'s commit.
    upstream: Option<String>,
    /// The remote's default branch: the first of its HEAD, main and master.
    default_tip: Option<String>,
    stash: Option<String>,
}

impl Repo {
    fn open(folder: &Path) -> Result<Self, Fallback> {
        // One rev-parse for what took one git each: the top, the git paths the plan reads,
        // HEAD's commit and its branch (`HEAD` when detached). When it fails, the questions
        // one at a time tell which fallback it is.
        let mut ask = git::at(folder);
        ask.args(["rev-parse", "--show-toplevel", "--path-format=absolute"]);
        for name in GIT_PATHS {
            ask.args(["--git-path", name]);
        }
        // `--symbolic-full-name` holds for every name after it, so HEAD's commit comes first.
        ask.args(["HEAD^{commit}", "--symbolic-full-name", "HEAD", "--"]);
        let answer = git::text(&mut ask).map_err(|error| why_not(folder, error))?;
        let mut lines = answer.lines();
        let mut line = || lines.next().filter(|line| !line.is_empty()).map(str::to_owned);
        let top = line();
        let mut paths = GIT_PATHS.map(|_| line().map(PathBuf::from));
        let head = line().filter(|head| head.bytes().all(|byte| byte.is_ascii_hexdigit()));
        let symbolic = line();
        let (Some(top), Some(head), Some(symbolic)) = (top, head, symbolic) else {
            return Err(failed("reading the repository", format!("rev-parse answered {answer:?}")));
        };
        let mut path = |at: usize| {
            paths
                .get_mut(at)
                .and_then(Option::take)
                .ok_or_else(|| failed("finding the git dir", answer.clone()))
        };
        let paths = GitPaths {
            objects: path(0)?,
            shallow: path(1)?,
            index: path(2)?,
            sparse_checkout: path(3)?,
            lfs: path(4)?,
        };
        let top = PathBuf::from(top);
        if !same_folder(folder, &top) {
            return Err(Fallback::new(
                FallbackCode::NotTop,
                format!("{} is inside the git working copy at {}", folder.display(), top.display()),
            ));
        }
        let head_ref = (symbolic != "HEAD").then_some(symbolic);
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
        let config = Config::read(&top);
        let github = remote_repo(&top, &remote, config.url(&remote))?;
        let sparse_checkout = config.sparse_checkout(&top);
        Ok(Self {
            top,
            head,
            head_ref,
            remote,
            upstream: tracked.map(|(_, upstream)| upstream),
            github,
            paths,
            sparse_checkout,
            refs: std::cell::OnceCell::new(),
        })
    }

    /// [`Refs`], read on first use: a folder that falls back before its bases never asks.
    fn refs(&self) -> &Refs {
        self.refs.get_or_init(|| {
            let remote = &self.remote;
            let default = [
                format!("refs/remotes/{remote}/HEAD"),
                format!("refs/remotes/{remote}/main"),
                format!("refs/remotes/{remote}/master"),
            ];
            let mut names: Vec<&str> = default.iter().map(String::as_str).collect();
            names.push("refs/stash");
            names.extend(self.upstream.as_deref());
            let mut found = self.commits_of(names.iter().copied()).into_iter();
            let default: Vec<Option<String>> = found.by_ref().take(3).collect();
            let default_tip = default.into_iter().flatten().next();
            let stash = found.next().flatten();
            let upstream = found.next().flatten();
            Refs { upstream, default_tip, stash }
        })
    }

    /// Check only the valid prefix so the first bad or missing id keeps its original fallback.
    fn check_seed_commits(&self, ids: &[&String], seed: &str) -> Result<(), Fallback> {
        let names = ids.iter().map(|id| id.as_str()).take_while(|id| {
            (4..=64).contains(&id.len()) && id.bytes().all(|byte| byte.is_ascii_hexdigit())
        });
        let mut found = self.commits_of(names).into_iter();
        for id in ids {
            if found.next().flatten().as_deref() != Some(id.as_str()) {
                return Err(Fallback::new(
                    FallbackCode::NoPrevious,
                    format!("the {seed} seed's commit {id} is not in this repository"),
                ));
            }
        }
        Ok(())
    }

    /// The commit each of `names` names, None for one that names none: one
    /// `cat-file --batch-check` for what `rev-parse --verify` answered one name at a time.
    fn commits_of<'a>(&self, names: impl Iterator<Item = &'a str>) -> Vec<Option<String>> {
        let mut input = String::new();
        let mut asked = 0;
        for name in names {
            input.push_str(name);
            input.push_str("^{commit}\n");
            asked += 1;
        }
        if input.is_empty() {
            return Vec::new();
        }
        let answer = git::output_fed(
            git::at(&self.top).args(["cat-file", "--batch-check=%(objectname)"]),
            input.as_bytes(),
        )
        .unwrap_or_default();
        // One line each: the commit, or `NAME missing` (or `ambiguous`).
        let answer = String::from_utf8_lossy(&answer);
        let mut lines = answer.lines();
        (0..asked)
            .map(|_| lines.next().filter(|line| line.bytes().all(|byte| byte.is_ascii_hexdigit())))
            .map(|line| line.filter(|line| !line.is_empty()).map(str::to_owned))
            .collect()
    }

    /// [`Planned::bases`], with duplicates left out.
    fn bases(&self) -> Vec<String> {
        let mut bases = Vec::new();
        let refs = self.refs();
        let upstream_base = refs.upstream.as_deref().and_then(|upstream| self.merge_base(upstream));
        bases.extend(upstream_base.clone());
        // A branch with no upstream (or a fetch refspec of one branch, so no
        // default branch here) is still seeded when the remote has HEAD or an
        // ancestor of it on any branch this Mac fetched.
        bases.extend(self.nearest_on_remote());
        if let Some(tip) = refs.default_tip.clone() {
            // Tracking the default branch (the usual case): its merge-base is already known.
            if refs.upstream.as_ref() == Some(&tip) {
                bases.extend(upstream_base);
            } else {
                bases.extend(self.merge_base(&tip));
            }
            bases.push(tip);
        }
        let mut seen = std::collections::HashSet::new();
        bases.retain(|base| seen.insert(base.clone()));
        bases
    }

    /// The newest commit of HEAD's history that a remote-tracking branch of
    /// [`Self::remote`] has: HEAD itself when it is pushed (the bundle then
    /// carries only the uncommitted state), else the first commit where
    /// HEAD's own commits meet what the remote has. None when no fetched
    /// branch of the remote shares HEAD's history.
    fn nearest_on_remote(&self) -> Option<String> {
        let remotes = format!("--remotes={}", self.remote);
        // One walk of HEAD's own commits: none means HEAD is on the remote.
        let own = git::text(git::at(&self.top).args([
            "rev-list",
            "--boundary",
            self.head.as_str(),
            "--not",
            remotes.as_str(),
        ]))
        .ok()?;
        if own.trim().is_empty() {
            // With no remote branch nothing is excluded and HEAD's whole
            // history is listed, so an empty list means one of them has HEAD.
            return Some(self.head.clone());
        }
        // `-SHA` lines are the boundary: commits the remote has, parents of
        // HEAD's own; the first is the newest the walk met.
        own.lines().find_map(|line| line.strip_prefix('-')).map(str::to_owned)
    }

    fn merge_base(&self, other: &str) -> Option<String> {
        git::optional(git::at(&self.top).args(["merge-base", self.head.as_str(), other]))
    }
}

/// Which fallback a folder takes when [`Repo::open`]'s one rev-parse failed (`error`), asked
/// in the order a person fixes them: no working copy, not its top, no commit.
fn why_not(folder: &Path, error: String) -> Fallback {
    let shown = folder.display();
    let Ok(top) = git::text(git::at(folder).args(["rev-parse", "--show-toplevel"])) else {
        return Fallback::new(FallbackCode::NotGit, format!("{shown} is not a git working copy"));
    };
    let top = PathBuf::from(top);
    if !same_folder(folder, &top) {
        return Fallback::new(
            FallbackCode::NotTop,
            format!("{shown} is inside the git working copy at {}", top.display()),
        );
    }
    if git::optional(git::at(&top).args(["rev-parse", "--verify", "-q", "HEAD^{commit}"])).is_none()
    {
        return Fallback::new(FallbackCode::NoCommit, "the repository has no commit yet");
    }
    failed("reading the repository", error)
}

fn same_folder(folder: &Path, top: &Path) -> bool {
    match (std::fs::canonicalize(folder), std::fs::canonicalize(top)) {
        (Ok(folder), Ok(top)) => folder == top,
        _ => false,
    }
}

/// The config the plan reads, from one `git config --get-regexp`: each remote's URL as
/// configured and `core.sparseCheckout`.
struct Config(Vec<(String, Option<String>)>);

impl Config {
    fn read(top: &Path) -> Self {
        // Nothing set exits 1, like `config --get` did for each.
        let listed = git::output(git::at(top).args([
            "config",
            "-z",
            "--get-regexp",
            r"^(remote\..*\.url|core\.sparsecheckout)$",
        ]))
        .unwrap_or_default();
        // `KEY\nVALUE\0`, or `KEY\0` for a key with no value.
        let entries = listed
            .split(|byte| *byte == 0)
            .filter(|entry| !entry.is_empty())
            .map(|entry| {
                let entry = String::from_utf8_lossy(entry);
                match entry.split_once('\n') {
                    Some((key, value)) => (key.to_owned(), Some(value.to_owned())),
                    None => (entry.into_owned(), None),
                }
            })
            .collect();
        Self(entries)
    }

    /// The last value of `key`, as `config --get` answers: `Some(None)` for a key with no value.
    fn last(&self, key: &str) -> Option<Option<&str>> {
        self.0.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.as_deref())
    }

    /// `remote.REMOTE.url` as configured (no `insteadOf` rewrite); None when unset or empty.
    fn url(&self, remote: &str) -> Option<String> {
        let url = self.last(&format!("remote.{remote}.url"))??;
        (!url.is_empty()).then(|| url.to_owned())
    }

    /// `core.sparseCheckout` as `config --bool` reads it; a value that is no boolean is off.
    fn sparse_checkout(&self, top: &Path) -> bool {
        match self.last("core.sparsecheckout") {
            None => false,
            Some(None) => true,
            Some(Some(value)) => match value.to_ascii_lowercase().as_str() {
                "true" | "yes" | "on" => true,
                "false" | "no" | "off" | "" => false,
                // Git owns the numeric syntax and its bounds.
                _ => {
                    git::optional(git::at(top).args(["config", "--bool", "core.sparseCheckout"]))
                        .as_deref()
                        == Some("true")
                }
            },
        }
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

/// The GitHub repository `remote` points at. The configured URL (`raw`) is tried
/// first (a `url.*.insteadOf` rewrite may point elsewhere for fetches),
/// then the rewritten one (a shorthand that rewrites to GitHub).
fn remote_repo(
    top: &Path,
    remote: &str,
    raw: Option<String>,
) -> Result<github::GithubRepo, Fallback> {
    if let Some(repo) = raw.as_deref().and_then(github::parse) {
        return Ok(repo);
    }
    let rewritten = git::optional(git::at(top).args(["remote", "get-url", remote]));
    if let Some(repo) = rewritten.as_deref().and_then(github::parse) {
        return Ok(repo);
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

/// The working copy at `folder` as a seed would send it now: HEAD and its
/// branch, and the INDEX and WORK commits [`plan`] would make (written to
/// the repository's object store, unreferenced). `cmux link seed pull`
/// compares them with the seed's.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Current {
    pub head_ref: Option<String>,
    pub head: String,
    pub index: String,
    pub work: String,
}

pub(crate) fn current(folder: &Path) -> Result<Current, Fallback> {
    let repo = Repo::open(folder)?;
    let scratch = Scratch::new()?;
    let made = commits(&repo, &scratch)?;
    Ok(Current { head_ref: repo.head_ref, head: repo.head, index: made.index, work: made.work })
}

/// The INDEX and WORK commits of a seed, and what WORK left out.
struct Commits {
    index: String,
    work: String,
    skipped: Vec<Skipped>,
    sparse: Option<String>,
    /// `ls-files -z --others --exclude-standard`, as [`untracked_left_out`] read it.
    untracked: Vec<u8>,
}

fn build(
    repo: &Repo,
    out_bundle: &Path,
    since: &Since<'_>,
    bases: Vec<String>,
) -> Result<Planned, Fallback> {
    let (submodules, submodule_work, staged) = submodules(repo)?;
    let scratch = Scratch::new()?;
    let Commits { index: index_commit, work: work_commit, mut skipped, sparse, untracked } =
        commits(repo, &scratch)?;
    let store = scratch.0.join("store.git");
    git::output(git::at(&scratch.0).args(["init", "-q", "--bare", "--template="]).arg(&store))
        .map_err(|error| failed("making the scratch repository", error))?;
    borrow_objects(repo, &store)?;
    let stash = repo.refs().stash.clone();
    let lfs_attributes = lfs_attributes(repo, attribute_files(&staged, &untracked), &skipped);
    skipped.extend(submodule_work);
    let lfs_files = if super::lfs::enabled() {
        super::lfs::scan(&repo.top, &repo.paths.lfs, &work_commit)
    } else {
        Vec::new()
    };
    skipped.extend(super::lfs::skipped(&lfs_files));

    let mut refs = vec![
        ("refs/cmux-seed/head", repo.head.as_str()),
        ("refs/cmux-seed/index", index_commit.as_str()),
        ("refs/cmux-seed/work", work_commit.as_str()),
    ];
    if let Some(stash) = &stash {
        refs.push(("refs/cmux-seed/stash", stash.as_str()));
    }
    // WORK's parents are INDEX and HEAD. The stash ref is independent of all three.
    let (base, unchanged) = match since {
        Since::Base(base) => ((*base).to_string(), false),
        Since::Previous(previous) => {
            (previous.work.clone(), previous.work == work_commit && previous.stash == stash)
        }
    };
    // A stash-only deletion has no new Git object. Git refuses an empty bundle,
    // so carry a tiny synthetic commit, excluded from the destination's seed record.
    // WORK remains stable: the next unchanged delta stays a zero-byte send.
    let stash_clear_marker = if let Since::Previous(previous) = since
        && previous.stash.is_some()
        && stash.is_none()
        && previous.work == work_commit
    {
        let tree =
            git::text(git::at(&repo.top).args(["rev-parse", &format!("{work_commit}^{{tree}}")]))
                .map_err(|error| failed("reading the work tree", error))?;
        Some(commit(repo, &tree, &previous.work, "cmux seed stash cleared")?)
    } else {
        None
    };
    if let Some(marker) = &stash_clear_marker {
        refs.push(("refs/cmux-seed/stash-cleared", marker.as_str()));
    }
    let mut bundle_bytes = 0;
    if !unchanged {
        name_refs(&store, &refs)?;
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
            lfs: !lfs_attributes.is_empty(),
            since,
        },
        skipped,
        submodules,
        bases,
        bundle_bytes,
        unchanged,
        lfs_attributes,
        lfs_files,
    })
}

/// The INDEX commit (the staged tree on HEAD) and the WORK commit (the
/// working tree with untracked files that are not ignored, less
/// [`untracked_left_out`], on INDEX), built through a copy of the index in
/// `scratch`.
fn commits(repo: &Repo, scratch: &Scratch) -> Result<Commits, Fallback> {
    let index = scratch.0.join("index");
    let real_index = &repo.paths.index;
    if real_index.is_file() {
        std::fs::copy(real_index, &index)
            .map_err(|error| failed("copying the index", error.to_string()))?;
    } else {
        run(repo.scratch_git(&index).args(["read-tree", repo.head.as_str()]), "reading HEAD")?;
    }

    let index_tree = repo.write_tree(&index)?;
    let index_commit = commit(repo, &index_tree, &repo.head, "cmux seed index")?;

    let (skipped, untracked) = untracked_left_out(repo)?;
    let sparse = sparse_patterns(repo);
    // In a sparse checkout `--sparse` also takes untracked files outside
    // the patterns; entries git keeps out of the working tree stay as they
    // are either way.
    let sparse_flag: &[&str] = if sparse.is_some() { &["--sparse"] } else { &[] };
    if skipped.is_empty() {
        run(
            repo.scratch_git(&index).args(["add", "-A"]).args(sparse_flag),
            "adding the working tree",
        )?;
    } else {
        // Git add writes blobs to the repository's real object store even
        // with a scratch index. Removing a skipped secret from that index
        // afterwards leaves its unreferenced blob behind, where a fallback
        // whole-repository copy could send it to Cloud.
        //
        // Include everything except the skipped raw paths during the add.
        // NUL-delimited literal pathspecs preserve odd/non-UTF-8 names and
        // avoid treating characters such as '*' or '[' as patterns.
        let list = scratch.0.join("add-pathspecs");
        let mut paths = b".\0".to_vec();
        for item in &skipped {
            paths.extend_from_slice(b":(exclude,literal)");
            paths.extend_from_slice(item.raw.strip_suffix(b"/").unwrap_or(&item.raw));
            paths.push(0);
        }
        write(&list, paths)?;
        run(
            repo.scratch_git(&index)
                .args(["add", "-A", "--pathspec-file-nul"])
                .args(sparse_flag)
                .arg(format!("--pathspec-from-file={}", list.display())),
            "adding the working tree",
        )?;
    }
    if !skipped.is_empty() {
        let list = scratch.0.join("left-out");
        let mut paths = Vec::new();
        for item in &skipped {
            paths.extend_from_slice(item.raw.strip_suffix(b"/").unwrap_or(&item.raw));
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
    let work = commit(repo, &work_tree, &index_commit, "cmux seed work")?;
    Ok(Commits { index: index_commit, work, skipped, sparse, untracked })
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

/// The scratch bare repository at `store` borrows the repository's objects (alternates) and
/// its shallow list, so walks stop where this Mac's history does.
fn borrow_objects(repo: &Repo, store: &Path) -> Result<(), Fallback> {
    std::fs::create_dir_all(store.join("objects/info"))
        .map_err(|error| failed("making the scratch object store", error.to_string()))?;
    write(&store.join("objects/info/alternates"), format!("{}\n", repo.paths.objects.display()))?;
    if repo.paths.shallow.is_file() {
        std::fs::copy(&repo.paths.shallow, store.join("shallow"))
            .map_err(|error| failed("copying the shallow list", error.to_string()))?;
    }
    Ok(())
}

/// Points each of `refs` at its commit in the scratch repository at `store`, in one git.
fn name_refs(store: &Path, refs: &[(&str, &str)]) -> Result<(), Fallback> {
    let input: String = refs.iter().map(|(name, id)| format!("update {name} {id}\n")).collect();
    git::output_fed(git::bare(store).args(["update-ref", "--stdin"]), input.as_bytes())
        .map(drop)
        .map_err(|error| failed("naming the seed commits", error))
}

fn run(command: &mut Command, what: &str) -> Result<(), Fallback> {
    git::output(command).map(drop).map_err(|error| failed(what, error))
}

fn write(path: &Path, contents: impl AsRef<[u8]>) -> Result<(), Fallback> {
    std::fs::write(path, contents)
        .map_err(|error| failed(&format!("writing {}", path.display()), error.to_string()))
}

/// An untracked file bigger than this is a big one: it goes in the work
/// commit while it fits [`BIG_UNTRACKED_FILE_CAP`] and what is left of
/// [`BIG_UNTRACKED_TOTAL_CAP`] (RFD 0066 piece 4; it used to stay here).
const BIG_UNTRACKED: u64 = 5 * 1024 * 1024;

/// An untracked file bigger than this stays on this Mac, named with its
/// size: one checkpoint or dataset would outweigh the rest of the seed.
pub(crate) const BIG_UNTRACKED_FILE_CAP: u64 = 100_000_000;

/// The most bytes the big untracked files (over [`BIG_UNTRACKED`]) add to a
/// seed together; one that would pass it stays on this Mac, named.
pub(crate) const BIG_UNTRACKED_TOTAL_CAP: u64 = 1_000_000_000;

/// Untracked files that are not ignored but stay on this Mac: likely
/// secrets, git repositories nested in the folder (not submodules), heavy
/// folders the project rebuilds on the machine (one entry each, as a copy
/// names them) and big files past [`BIG_UNTRACKED_FILE_CAP`] or, in path
/// order, past what is left of [`BIG_UNTRACKED_TOTAL_CAP`].
/// The listing it read comes along, for [`attribute_files`].
fn untracked_left_out(repo: &Repo) -> Result<(Vec<Skipped>, Vec<u8>), Fallback> {
    use std::os::unix::ffi::OsStrExt as _;
    let listed =
        git::output(git::at(&repo.top).args(["ls-files", "-z", "--others", "--exclude-standard"]))
            .map_err(|error| failed("listing untracked files", error))?;
    let mut skipped = Vec::new();
    let mut heavy_named = std::collections::BTreeSet::new();
    let mut big_sent = 0_u64;
    for raw in listed.split(|byte| *byte == 0).filter(|path| !path.is_empty()) {
        let path = String::from_utf8_lossy(raw).into_owned();
        if let Some((folder, why)) =
            std::str::from_utf8(raw).ok().and_then(|name| sync_cli::heavy_folder(&repo.top, name))
        {
            if heavy_named.insert(folder.clone()) {
                skipped.push(Skipped {
                    raw: folder.clone().into_bytes(),
                    path: folder,
                    why: why.to_string(),
                });
            }
            continue;
        }
        let why = if path.ends_with('/') {
            Some("a separate git repository inside this folder (not a submodule)".to_string())
        } else if let Some(why) =
            // A plain copy's credential rule too (`.aws/credentials`, `.config/gh/hosts.yml`).
            secrets::reason(&repo.top, raw).or_else(|| skips::credential_text(&path))
        {
            Some(why.to_string())
        } else {
            std::fs::symlink_metadata(repo.top.join(std::ffi::OsStr::from_bytes(raw)))
                .ok()
                .filter(|meta| meta.is_file() && meta.len() > BIG_UNTRACKED)
                .and_then(|meta| big_left_here(meta.len(), &mut big_sent))
        };
        if let Some(why) = why {
            skipped.push(Skipped { path, why, raw: raw.to_vec() });
        }
    }
    Ok((skipped, listed))
}

/// Why a big untracked file of `len` bytes stays on this Mac, or None when
/// it goes (counted into `sent`, the big files' bytes so far).
pub(super) fn big_left_here(len: u64, sent: &mut u64) -> Option<String> {
    let size = sync_cli::bytes_text(len);
    if len > BIG_UNTRACKED_FILE_CAP {
        return Some(format!(
            "a big file ({size}) that stays on this Mac: over the seed's {} limit for one untracked file",
            sync_cli::bytes_text(BIG_UNTRACKED_FILE_CAP)
        ));
    }
    if sent.saturating_add(len) > BIG_UNTRACKED_TOTAL_CAP {
        return Some(format!(
            "a big file ({size}) that stays on this Mac: the seed already carries {} of big untracked files, its limit is {}",
            sync_cli::bytes_text(*sent),
            sync_cli::bytes_text(BIG_UNTRACKED_TOTAL_CAP)
        ));
    }
    *sent = sent.saturating_add(len);
    None
}

/// Each submodule with the commit checked out in it, and the submodules
/// whose uncommitted changes stay on this Mac (the machine gets the
/// commit). One whose commit is not on its remote-tracking refs is local
/// work this plan cannot seed: the machine could not fetch it. The `ls-files -z -s` it read
/// comes along, for [`attribute_files`].
fn submodules(repo: &Repo) -> Result<(Vec<Submodule>, Vec<Skipped>, Vec<u8>), Fallback> {
    let staged = git::output(git::at(&repo.top).args(["ls-files", "-z", "-s"]))
        .map_err(|error| failed("listing the index", error))?;
    let mut found = Vec::new();
    let mut left_here = Vec::new();
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
            let folder = format!("{path}/");
            left_here.push(Skipped {
                raw: folder.clone().into_bytes(),
                path: folder,
                why: "a submodule's uncommitted changes stay on this Mac".to_string(),
            });
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
    Ok((found, left_here, staged))
}

/// The sparse-checkout patterns when sparse checkout is on.
fn sparse_patterns(repo: &Repo) -> Option<String> {
    repo.sparse_checkout
        .then(|| std::fs::read_to_string(&repo.paths.sparse_checkout).unwrap_or_default())
}

/// The `.gitattributes` files among the untracked listing (`ls-files -z --others
/// --exclude-standard`) and the index (`ls-files -z -s`), in the order one
/// `ls-files --cached --others -- ':(glob)**/.gitattributes'` lists them: untracked first.
fn attribute_files<'a>(staged: &'a [u8], untracked: &'a [u8]) -> impl Iterator<Item = &'a [u8]> {
    let untracked = untracked.split(|byte| *byte == 0);
    // `MODE OID STAGE\tPATH`.
    let staged = staged
        .split(|byte| *byte == 0)
        .filter_map(|entry| entry.splitn(2, |byte| *byte == b'\t').nth(1));
    untracked
        .chain(staged)
        .filter(|path| *path == b".gitattributes".as_slice() || path.ends_with(b"/.gitattributes"))
}

/// The `.gitattributes` files in the working tree (tracked, or untracked and
/// going) that name `filter=lfs`, from the top, out of `listed`. The seed uses LFS when any does.
fn lfs_attributes<'a>(
    repo: &Repo,
    listed: impl Iterator<Item = &'a [u8]>,
    skipped: &[Skipped],
) -> Vec<String> {
    listed
        .filter(|path| !path.is_empty())
        .map(|path| String::from_utf8_lossy(path).into_owned())
        .filter(|path| !skipped.iter().any(|item| &item.path == path))
        .filter(|path| {
            std::fs::read(repo.top.join(path))
                .is_ok_and(|text| String::from_utf8_lossy(&text).contains("filter=lfs"))
        })
        .collect()
}
