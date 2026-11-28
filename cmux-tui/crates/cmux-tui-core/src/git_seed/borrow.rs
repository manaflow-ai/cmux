//! A warm mirror's objects instead of a carry or a clone, and the promisor sources a fresh
//! folder fetches what it lacks from.
//!
//! A machine that keeps a mirror of the repository (`wt`'s blobless bare mirror) holds the
//! base's commit, tree and blobs already, so a fresh folder needs none of them copied: `git init`,
//! the mirror's object store in `objects/info/alternates` (as `git clone --shared` does), and the
//! base checked whole through it. Nothing is read from GitHub or uploaded by the sender; the only
//! bytes written are the checkout's files. The mirror is used only when its `origin` is this
//! repository (alternates to another repository break fetches) and the base with every object
//! of its tree is in it, checked with `rev-list --missing=print` (no lazy fetch).
//!
//! The folder is a partial clone of `origin` (`blob:none`, as the mirror is), so an old blob
//! comes on demand; the mirror's `origin/<branch>` comes along so the branch tracks it. An object
//! the mirror drops later (it prunes only what no ref reaches; `wt` never does) is fetched again
//! from `origin`; `git repack -a -d` and removing the alternates file make the folder its own.
//!
//! [`StartParams::promisors`] names where a fresh folder (borrowed or carried) fetches what it
//! lacks, in order: git tries the `promisor` remotes in config order with the one
//! `extensions.partialClone` names last, so each source becomes a remote in list order
//! (`origin` for the forge, `cmux-promisor-N` for a local repository) and the last one is
//! `extensions.partialClone`. A local source whose `origin` is another repository is skipped.
//!
//! A seed borrows only when asked: its own `mirror` param, or [`MIRRORS_ENV`]
//! (`CMUX_SEED_MIRRORS=ROOT`, the daemon's environment) naming a folder that holds
//! `ROOT/OWNER/NAME.git` for the seed's repository (`wt`'s `~/Projects/.wt-mirrors` on a fleet
//! machine). With the env unset, [`DEFAULT_MIRRORS`] (`/opt/cmux/mirrors`, where a machine image
//! bakes its mirrors) is looked in; a machine with no mirror there seeds exactly as before.
//!
//! A clone-only seed (a Cloud chat opened with a folder: no bundle, no base) borrows too
//! ([`Seed::borrow_clone`]): the folder borrows the mirror's objects, then fetches from `origin`
//! only what the mirror lacks (git counts the mirror's refs as objects it has), so a mirror baked
//! days ago still saves all but the newest commits' bytes. A fetch that fails clones as before.
//!
//! Every failure leaves the folder as it was and the seed carries or clones as before; the
//! job's status notes `borrowed` or `borrow_failed`.
//!
//! `git.seed.borrowable` (`git-seed-borrow-v1`, [`borrowable`]) answers the same question
//! before a seed starts, so a sender skips building and uploading its carry pack for a
//! machine that will borrow anyway: the same mirror, the same repository check and the same
//! `rev-list --missing=print` of the base, with nothing written and nothing fetched.

use std::path::{Path, PathBuf};
use std::time::Instant;

use super::super::SeedRefusal;
use super::super::git::{Credential, Git};
use super::super::params::{check_local_path, check_sha, check_url};
use super::{Failure, Seed, check_folder, clean_folder, place, same_github_repo};
use crate::fs_ops::Roots;

/// A local repository's object store and config: a bare repository or a checkout's `.git`.
struct Local {
    objects: PathBuf,
    config: PathBuf,
}

impl Local {
    fn at(path: &str) -> Option<Self> {
        let path = Path::new(path);
        [path.to_path_buf(), path.join(".git")].into_iter().find_map(|git_dir| {
            let objects = git_dir.join("objects");
            let config = git_dir.join("config");
            if !(objects.join("pack").is_dir() && config.is_file()) {
                return None;
            }
            Some(Self { objects: objects.canonicalize().ok()?, config })
        })
    }
}

/// `CMUX_SEED_MIRRORS` on this machine: a folder of warm mirrors laid out as `wt` keeps them
/// (`OWNER/NAME.git`). A seed without its own `mirror` borrows the one for its repository there,
/// when there is one. Unset (the default): only a `mirror` param borrows.
pub const MIRRORS_ENV: &str = "CMUX_SEED_MIRRORS";

/// Where a machine image keeps its baked mirrors (`OWNER/NAME.git`), read when [`MIRRORS_ENV`]
/// is unset. Nothing there (every machine today): only a `mirror` param borrows.
pub const DEFAULT_MIRRORS: &str = "/opt/cmux/mirrors";

fn configured_mirror(url: &str) -> Option<String> {
    let root = std::env::var(MIRRORS_ENV).unwrap_or_else(|_| DEFAULT_MIRRORS.to_owned());
    mirror_under(&root, url)
}

/// The mirror of `url` (`https://github.com/OWNER/NAME.git`, checked) under `root`, when it is
/// a folder.
pub(crate) fn mirror_under(root: &str, url: &str) -> Option<String> {
    if !root.starts_with('/') {
        return None;
    }
    let repo = url.strip_prefix("https://github.com/")?.strip_suffix(".git")?;
    let mirror = format!("{}/{repo}.git", root.trim_end_matches('/'));
    Path::new(&mirror).is_dir().then_some(mirror)
}

/// `git.seed.borrowable`'s params: the seed's folder, repository and base, and its own
/// `mirror` when it names one (as [`StartParams::mirror`](super::super::params::StartParams)).
/// Unknown fields are ignored: a newer sender may ask with more.
#[derive(serde::Deserialize)]
struct Asked {
    folder: String,
    url: String,
    repo: String,
    base: String,
    #[serde(default)]
    mirror: Option<String>,
}

/// Whether a fresh seed of `folder` at `base` would borrow a warm mirror here ([`Seed::borrow_in`]):
/// `{"borrow": true}`, or `{"borrow": false, "why": STEP}` with the first check that failed
/// (`folder`: it holds a repository already; `no_mirror`; `other_repo`: the mirror's `origin`
/// is another repository; `no_base`; `lacks_objects`: some object of the base's tree is not
/// in it). Reads only: a `false` costs the sender nothing but this answer.
pub(in crate::git_seed) fn borrowable(
    git: &Git,
    roots: &Roots,
    params: &serde_json::Value,
) -> Result<serde_json::Value, SeedRefusal> {
    let asked: Asked = serde_json::from_value(params.clone())
        .map_err(|error| SeedRefusal::bad_request(format!("invalid params: {error}")))?;
    check_url(&asked.url, &asked.repo)?;
    check_sha("base", &asked.base)?;
    if let Some(mirror) = &asked.mirror {
        check_local_path("mirror", mirror)?;
    }
    let folder = place::folder(roots, &asked.folder)?;
    let no = |why: &str| Ok(serde_json::json!({ "borrow": false, "why": why }));
    if std::fs::symlink_metadata(folder.join(".git")).is_ok() {
        return no("folder");
    }
    let Some(mirror) = asked.mirror.clone().or_else(|| configured_mirror(&asked.url)) else {
        return no("no_mirror");
    };
    let Some(local) = Local::at(&mirror) else { return no("no_mirror") };
    let config = local.config.display().to_string();
    let origin = git.quiet(
        None,
        &Credential::Anonymous,
        &["config", "--file", &config, "--get", "remote.origin.url"],
    );
    if !origin.is_ok_and(|url| same_github_repo(String::from_utf8_lossy(&url).trim(), &asked.url)) {
        return no("other_repo");
    }
    let git_dir = local.objects.parent().map(Path::to_path_buf).unwrap_or_default();
    let commit = format!("{}^{{commit}}", asked.base);
    // A promisor mirror would fetch an object it lacks; this answer reads only.
    let lazy = [("GIT_NO_LAZY_FETCH", std::ffi::OsStr::new("1"))];
    let anonymous = Credential::Anonymous;
    let verify = ["cat-file", "-e", commit.as_str()];
    if git.run_env(Some(&git_dir), &anonymous, &verify, &lazy, &mut |_| {}).is_err() {
        return no("no_base");
    }
    let list = ["rev-list", "--objects", "--no-walk", "--missing=print", asked.base.as_str()];
    match git.run_env(Some(&git_dir), &anonymous, &list, &lazy, &mut |_| {}) {
        Ok(out) if !out.split(|byte| *byte == b'\n').any(|line| line.starts_with(b"?")) => {
            Ok(serde_json::json!({ "borrow": true }))
        }
        _ => no("lacks_objects"),
    }
}

impl Seed {
    /// Whether the folder is now a repository borrowing the mirror's objects at the base.
    pub(super) fn borrow_in(&mut self) -> bool {
        let mirror = self.params.mirror.clone().or_else(|| configured_mirror(&self.params.url));
        let Some(mirror) = mirror else { return false };
        if self.recheck().is_err()
            || std::fs::symlink_metadata(self.folder.join(".git")).is_ok()
            || check_folder(&self.git, &self.folder, &self.params.url).is_err()
        {
            return false;
        }
        let Some(local) = Local::at(&mirror).filter(|local| self.same_repo(local)) else {
            self.job.note("borrow_failed");
            return false;
        };
        self.job.enter(super::Phase::Clone);
        let existed = self.folder.exists();
        let started = Instant::now();
        match self.borrow(&local) {
            Ok(()) => {
                super::super::git::count("borrow", started.elapsed());
                self.job.note("borrowed");
                // The sender's pack, when it sent one too, is not needed.
                self.carry.take();
                if let Some(path) = &self.params.carry {
                    place::delete_upload(&self.roots, path);
                }
                true
            }
            Err(_) => {
                clean_folder(&self.folder, existed);
                self.job.note("borrow_failed");
                false
            }
        }
    }

    /// Clone only: whether the (absent or empty) folder is now a repository borrowing the
    /// mirror's objects, fetched from `origin` (only what the mirror lacks) with the remote's
    /// default branch as `HEAD`, as `git clone --no-checkout` leaves it. Otherwise the folder is
    /// as it was and the seed clones.
    pub(super) fn borrow_clone(&mut self) -> bool {
        let mirror = self.params.mirror.clone().or_else(|| configured_mirror(&self.params.url));
        let Some(mirror) = mirror else { return false };
        let Some(local) = Local::at(&mirror).filter(|local| self.same_repo(local)) else {
            self.job.note("borrow_failed");
            return false;
        };
        self.job.enter(super::Phase::Clone);
        let existed = self.folder.exists();
        let started = Instant::now();
        match self.link(&local).is_ok() && self.fetch_into_borrowed() {
            true => {
                super::super::git::count("borrow", started.elapsed());
                self.job.note("borrowed");
                true
            }
            false => {
                clean_folder(&self.folder, existed);
                self.job.note("borrow_failed");
                false
            }
        }
    }

    /// The fetch from `origin` and the default branch, as a clone sets them up.
    fn fetch_into_borrowed(&mut self) -> bool {
        let folder = self.folder.clone();
        let fetch = ["fetch", "--progress", "--tags", "origin"];
        if self.net_origin(Some(&folder), &fetch, &mut || {}).is_err()
            || self
                .net_origin(Some(&folder), &["remote", "set-head", "origin", "--auto"], &mut || {})
                .is_err()
        {
            return false;
        }
        let Ok(head) = self.git(&["symbolic-ref", "refs/remotes/origin/HEAD"]) else {
            return false;
        };
        let head = String::from_utf8_lossy(&head).trim().to_owned();
        let Some(branch) = head.strip_prefix("refs/remotes/origin/") else { return false };
        let local = format!("refs/heads/{branch}");
        [
            vec!["update-ref", "-m", "cmux seed: mirror", &local, &head],
            vec!["symbolic-ref", "HEAD", &local],
            vec!["config", &format!("branch.{branch}.remote"), "origin"],
            vec!["config", &format!("branch.{branch}.merge"), &local],
        ]
        .iter()
        .all(|args| self.git(args).is_ok())
    }

    /// Whether the local repository's `origin` is this seed's repository.
    fn same_repo(&self, local: &Local) -> bool {
        let config = local.config.display().to_string();
        let args = ["config", "--file", &config, "--get", "remote.origin.url"];
        self.git.quiet(None, &self.chosen, &args).is_ok_and(|url| {
            same_github_repo(String::from_utf8_lossy(&url).trim(), &self.params.url)
        })
    }

    fn borrow(&self, local: &Local) -> Result<(), Failure> {
        self.link(local)?;
        let mirror_dir = local.objects.parent().map(Path::to_path_buf).unwrap_or_default();
        let base = &self.params.base;
        let missing = self.git(&["rev-list", "--objects", "--no-walk", "--missing=print", base])?;
        if let Some(line) = missing.split(|byte| *byte == b'\n').find(|line| line.starts_with(b"?"))
        {
            return Err(Failure::of(format!(
                "fatal: the mirror lacks {}",
                String::from_utf8_lossy(line)
            )));
        }
        if !self.has_commit(base) {
            return Err(Failure::of("fatal: the mirror lacks the base commit"));
        }
        // The branch's upstream as the mirror last saw it, so it tracks `origin/<branch>`.
        if let Some(branch) = &self.params.branch {
            let upstream = format!("refs/remotes/origin/{branch}");
            let verify = format!("{upstream}^{{commit}}");
            let git_dir_arg = format!("--git-dir={}", mirror_dir.display());
            if let Ok(sha) = self.git.quiet(
                None,
                &self.chosen,
                &[&git_dir_arg, "rev-parse", "--verify", "--quiet", &verify],
            ) {
                let sha = String::from_utf8_lossy(&sha).trim().to_owned();
                if super::super::params::check_sha("upstream", &sha).is_ok()
                    && self.has_commit(&sha)
                {
                    self.git(&["update-ref", "-m", "cmux seed: mirror", &upstream, &sha])?;
                }
            }
        }
        Ok(())
    }

    /// The folder made a repository whose objects are the mirror's (alternates, its shallow
    /// boundary) and whose `origin` (or the named promisors) fetch what it lacks.
    fn link(&self, local: &Local) -> Result<(), Failure> {
        let io = |what: &str, error: std::io::Error| Failure::of(format!("fatal: {what}: {error}"));
        std::fs::create_dir_all(&self.folder).map_err(|error| io("the folder", error))?;
        self.init()?;
        let git_dir = self.folder.join(".git");
        let objects = local.objects.display().to_string();
        std::fs::write(git_dir.join("objects/info/alternates"), format!("{objects}\n"))
            .map_err(|error| io("the alternates file", error))?;
        // A shallow mirror's boundary is this folder's too: history ends where its objects do.
        let mirror_dir = local.objects.parent().map(Path::to_path_buf).unwrap_or_default();
        if let Ok(shallow) = std::fs::read(mirror_dir.join("shallow")) {
            std::fs::write(git_dir.join("shallow"), shallow)
                .map_err(|error| io("the shallow file", error))?;
        }
        // The forge is a promisor unless the caller named other sources only.
        self.add_remotes(true)
    }

    /// `git init` of the folder, in the base's object format.
    pub(super) fn init(&self) -> Result<(), Failure> {
        let folder = self.folder_str();
        let mut init = vec!["init", "--quiet"];
        if self.params.base.len() == 64 {
            init.push("--object-format=sha256");
        }
        init.extend(["--", folder.as_str()]);
        self.git.quiet(None, &self.chosen, &init)?;
        Ok(())
    }

    /// `origin` and the promisor sources, as remotes in the order git tries them. `forge`: with
    /// no sources named, `origin` is the one promisor (a borrowed folder); otherwise none is (a
    /// carried folder, as before).
    pub(super) fn add_remotes(&self, forge: bool) -> Result<(), Failure> {
        let url = self.params.url.clone();
        let sources: Vec<String> = match (&self.params.promisors[..], forge) {
            ([], true) => vec![url.clone()],
            (sources, _) => sources.to_vec(),
        };
        let mut names = Vec::new();
        for (at, source) in sources.iter().enumerate() {
            let name = if *source == url {
                "origin".to_owned()
            } else if Local::at(source).is_some_and(|local| self.same_repo(&local)) {
                format!("cmux-promisor-{at}")
            } else {
                self.job.note("promisor_skipped");
                continue;
            };
            self.git(&["remote", "add", "--", &name, source])?;
            self.git(&["config", &format!("remote.{name}.promisor"), "true"])?;
            self.git(&["config", &format!("remote.{name}.partialclonefilter"), "blob:none"])?;
            names.push(name);
        }
        if !names.iter().any(|name| name == "origin") {
            self.git(&["remote", "add", "origin", &url])?;
        }
        if let Some(last) = names.last() {
            // git tries the `extensions.partialClone` remote after the other promisors.
            self.git(&["config", "core.repositoryformatversion", "1"])?;
            self.git(&["config", "extensions.partialClone", last])?;
        }
        Ok(())
    }
}
