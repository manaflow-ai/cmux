//! The steps of one seed: clone or fetch, make sure of the base, apply the
//! bundle, check out HEAD, stage INDEX, restore WORK and the stash, then
//! submodules and LFS. Every network step tries the machine's GitHub paths
//! in order; a later step keeps the path that worked.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::git::{Credential, Failure, Git};
use super::job::{Failed, Job, Phase};
use super::params::StartParams;
use super::{SeedRefusal, worktree};

/// The refspec of the Mac's bundle.
const SEED_REFSPEC: &str = "+refs/cmux-seed/*:refs/cmux-seed/*";

/// Refuses a folder that holds something other than this repository: a
/// non-empty folder without `.git`, or a clone of another remote.
pub fn check_folder(git: &Git, folder: &Path, url: &str) -> Result<(), SeedRefusal> {
    let not_empty =
        |message: &str| SeedRefusal { code: "seed.folder_not_empty", message: message.into() };
    if std::fs::symlink_metadata(folder.join(".git")).is_ok_and(|meta| meta.is_dir()) {
        return if origin_url(git, folder).as_deref() == Some(url) {
            Ok(())
        } else {
            Err(not_empty("the folder holds another repository"))
        };
    }
    match std::fs::read_dir(folder) {
        Ok(mut entries) if entries.next().is_some() => {
            Err(not_empty("the folder exists and is not empty"))
        }
        _ => Ok(()),
    }
}

/// `remote.origin.url` as configured (never rewritten by `insteadOf`).
fn origin_url(git: &Git, folder: &Path) -> Option<String> {
    let out = git
        .quiet(
            Some(folder),
            &Credential::Anonymous,
            &["config", "--local", "--get", "remote.origin.url"],
        )
        .ok()?;
    Some(String::from_utf8_lossy(&out).trim().to_owned())
}

pub struct Seed {
    job: Arc<Job>,
    params: StartParams,
    folder: PathBuf,
    bundle: PathBuf,
    git: Git,
    credentials: Vec<Credential>,
    /// The path that worked last (the first one until one has).
    chosen: Credential,
}

impl Seed {
    pub fn new(
        job: Arc<Job>,
        params: StartParams,
        folder: PathBuf,
        bundle: PathBuf,
        git: Git,
        credentials: Vec<Credential>,
    ) -> Self {
        let chosen = credentials.first().cloned().unwrap_or(Credential::Anonymous);
        Self { job, params, folder, bundle, git, credentials, chosen }
    }

    pub fn run(mut self) -> Result<(), Failed> {
        let Some(since) = self.params.since.clone() else {
            self.clone_or_fetch()?;
            self.base()?;
            self.apply_bundle()?;
            self.checkout()?;
            self.submodules(None)?;
            self.lfs(None)?;
            let _ = std::fs::remove_file(&self.bundle);
            return Ok(());
        };
        // A delta seed: no clone and no network for the base.
        self.job.enter(Phase::Bundle);
        self.check_delta(&since)?;
        self.apply_bundle()?;
        self.checkout_delta(&since)?;
        let changed = self.changed_paths(&since)?;
        self.submodules(Some(&changed))?;
        self.lfs(Some(&changed))?;
        // The bundle has been applied; it is not needed again.
        let _ = std::fs::remove_file(&self.bundle);
        Ok(())
    }

    fn folder_str(&self) -> String {
        self.folder.display().to_string()
    }

    /// `git ARGS` in the folder with the chosen path.
    fn git(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
        self.git.quiet(Some(&self.folder), &self.chosen, args)
    }

    /// `git ARGS` (in `cwd`) with each GitHub path until one works.
    /// `between` runs after each failed try.
    fn net(
        &mut self,
        cwd: Option<&Path>,
        args: &[&str],
        between: &mut dyn FnMut(),
    ) -> Result<(), Vec<Failure>> {
        let mut failures = Vec::new();
        for credential in self.credentials.clone() {
            let job = self.job.clone();
            match self.git.run(cwd, &credential, args, &mut |line| job.progress(line)) {
                Ok(_) => {
                    self.chosen = credential;
                    return Ok(());
                }
                Err(failure) => {
                    let full = failure.disk_full();
                    failures.push(failure);
                    between();
                    if full {
                        break;
                    }
                }
            }
        }
        Err(failures)
    }

    fn clone_or_fetch(&mut self) -> Result<(), Failed> {
        let folder = self.folder.clone();
        if std::fs::symlink_metadata(folder.join(".git")).is_ok_and(|meta| meta.is_dir()) {
            check_folder(&self.git, &folder, &self.params.url)
                .map_err(|refusal| failed(refusal.code, refusal.message))?;
            self.job.enter(Phase::Fetch);
            // A fetch that fails is not the end: the base may be here already.
            if let Err(failures) =
                self.net(Some(&folder), &["fetch", "--progress", "origin"], &mut || {})
                && failures.iter().any(Failure::disk_full)
            {
                return Err(classify(&failures, "seed.clone_failed"));
            }
            return Ok(());
        }
        check_folder(&self.git, &folder, &self.params.url)
            .map_err(|refusal| failed(refusal.code, refusal.message))?;
        let existed = folder.exists();
        let url = self.params.url.clone();
        let target = self.folder_str();
        let args: [&str; 7] =
            ["clone", "--progress", "--filter=blob:none", "--no-checkout", "--", &url, &target];
        // A clone cut short is removed before the next path tries.
        let mut clean = || clean_folder(&folder, existed);
        self.net(None, &args, &mut clean)
            .map_err(|failures| classify(&failures, "seed.clone_failed"))
    }

    /// A delta seed builds on this folder's last seed: same remote, its WORK
    /// is `since`, and nothing changed on the machine since (HEAD, the index
    /// and the working tree with untracked files are still that seed's).
    fn check_delta(&self, since: &str) -> Result<(), Failed> {
        let mismatch = |error: &str| failed("seed.since_mismatch", error);
        let is_clone =
            std::fs::symlink_metadata(self.folder.join(".git")).is_ok_and(|meta| meta.is_dir());
        if !is_clone
            || origin_url(&self.git, &self.folder).as_deref() != Some(self.params.url.as_str())
        {
            return Err(mismatch("the folder is not a seed of this repository"));
        }
        let read = |reference: &str| {
            self.git(&["rev-parse", "--verify", "--quiet", reference])
                .ok()
                .map(|out| String::from_utf8_lossy(&out).trim().to_owned())
        };
        if read("refs/cmux-seed/work^{commit}").as_deref() != Some(since) {
            return Err(mismatch("the folder's last seed is not `since`"));
        }
        let (Some(head), Some(index)) =
            (read("refs/cmux-seed/head^{commit}"), read("refs/cmux-seed/index^{tree}"))
        else {
            return Err(mismatch("the folder's last seed is incomplete"));
        };
        let changed = |error: &str| failed("seed.machine_changed", error);
        if read("HEAD^{commit}").as_deref() != Some(head.as_str()) {
            return Err(changed("HEAD moved on the machine since the last seed"));
        }
        let work = read(&format!("{since}^{{tree}}")).unwrap_or_default();
        let snapshot = Snapshot::take(&self.git, &self.chosen, &self.folder)
            .map_err(|failure| step_failed(&failure, "seed.checkout_failed"))?;
        if snapshot.index != index {
            return Err(changed("the index changed on the machine since the last seed"));
        }
        if snapshot.work != work {
            return Err(changed("files changed on the machine since the last seed"));
        }
        Ok(())
    }

    /// The paths WORK changed since `since`.
    fn changed_paths(&self, since: &str) -> Result<Vec<u8>, Failed> {
        self.git(&["diff-tree", "-r", "-z", "--no-renames", since, &self.params.work])
            .map_err(|failure| step_failed(&failure, "seed.checkout_failed"))
    }

    fn has_commit(&self, sha: &str) -> bool {
        self.git(&["cat-file", "-e", &format!("{sha}^{{commit}}")]).is_ok()
    }

    fn base(&mut self) -> Result<(), Failed> {
        self.job.enter(Phase::Fetch);
        if self.has_commit(&self.params.base) {
            return Ok(());
        }
        let folder = self.folder.clone();
        let base = self.params.base.clone();
        let fetched =
            self.net(Some(&folder), &["fetch", "--progress", "origin", &base], &mut || {});
        if self.has_commit(&base) {
            return Ok(());
        }
        match fetched {
            Err(failures) if failures.iter().any(Failure::disk_full) => {
                Err(classify(&failures, "seed.base_missing"))
            }
            _ => Err(failed("seed.base_missing", "the remote does not have the base commit")),
        }
    }

    fn apply_bundle(&mut self) -> Result<(), Failed> {
        self.job.enter(Phase::Bundle);
        let bundle = self.bundle.display().to_string();
        let invalid = |failure: Failure| step_failed(&failure, "seed.bundle_invalid");
        self.git(&["bundle", "verify", &bundle]).map_err(invalid)?;
        // A bundle is a local file: the one place a seed reads the file
        // transport.
        self.git(&[
            "-c",
            "protocol.file.allow=always",
            "-c",
            "transfer.fsckObjects=true",
            "fetch",
            "--no-tags",
            "--no-write-fetch-head",
            &bundle,
            SEED_REFSPEC,
        ])
        .map_err(invalid)?;
        let heads = self.git(&["bundle", "list-heads", &bundle]).map_err(invalid)?;
        let heads = String::from_utf8_lossy(&heads).into_owned();
        // Every commit the seed names is here now, and a seed ref the
        // bundle carried names the same commit as the request.
        let mut named = vec![
            ("head", self.params.head.clone()),
            ("index", self.params.index.clone()),
            ("work", self.params.work.clone()),
        ];
        if let Some(stash) = &self.params.stash {
            named.push(("stash", stash.clone()));
        }
        for (name, sha) in named {
            if !self.has_commit(&sha) {
                return Err(failed(
                    "seed.bundle_invalid",
                    format!("the bundle lacks the {name} commit"),
                ));
            }
            let reference = format!("refs/cmux-seed/{name}");
            let carried = heads.lines().find_map(|line| {
                line.split_once(' ').filter(|(_, name)| *name == reference).map(|(sha, _)| sha)
            });
            if carried.is_some_and(|carried| carried != sha) {
                return Err(failed(
                    "seed.bundle_invalid",
                    format!("the bundle's {name} is not the requested commit"),
                ));
            }
            // The record a later delta seed checks: exactly this seed.
            self.git(&["update-ref", &reference, &sha]).map_err(invalid)?;
        }
        if self.params.stash.is_none()
            && self.git(&["rev-parse", "--verify", "--quiet", "refs/cmux-seed/stash"]).is_ok()
        {
            self.git(&["update-ref", "-d", "refs/cmux-seed/stash"]).map_err(invalid)?;
        }
        Ok(())
    }

    fn checkout(&mut self) -> Result<(), Failed> {
        self.job.enter(Phase::Checkout);
        let wrap = |failure: Failure| step_failed(&failure, "seed.checkout_failed");
        worktree::configure(&self.git, &self.chosen, &self.folder, self.params.sparse.as_deref())
            .map_err(wrap)?;
        let head = self.params.head.clone();
        match self.params.branch.clone() {
            Some(branch) => {
                self.git(&["checkout", "--quiet", "--force", "-B", &branch, &head, "--"])
                    .map_err(wrap)?;
            }
            None => {
                self.git(&["checkout", "--quiet", "--force", "--detach", &head, "--"])
                    .map_err(wrap)?;
            }
        }
        self.track_upstream().map_err(wrap)?;
        // Untracked files a previous seed of this folder left (ignored ones,
        // such as a rebuilt node_modules, stay).
        self.git(&["clean", "-f", "-d", "-q"]).map_err(wrap)?;
        // The working tree becomes WORK (tracked files WORK lacks go).
        let work = self.params.work.clone();
        self.git(&["read-tree", "--reset", "-u", &work]).map_err(wrap)?;
        self.finish_checkout()
    }

    /// A delta seed: the working tree moves from `since` to WORK (edits,
    /// adds and deletes, the previous seed's untracked files included),
    /// HEAD moves to the new head, then INDEX and the stash as in a full
    /// seed. Ignored files stay.
    fn checkout_delta(&mut self, since: &str) -> Result<(), Failed> {
        self.job.enter(Phase::Checkout);
        let wrap = |failure: Failure| step_failed(&failure, "seed.checkout_failed");
        worktree::configure(&self.git, &self.chosen, &self.folder, self.params.sparse.as_deref())
            .map_err(wrap)?;
        let work = self.params.work.clone();
        let head = self.params.head.clone();
        self.git(&["read-tree", "--reset", since]).map_err(wrap)?;
        // The stat data read-tree left empty; a path that differs stays
        // listed and is not an error.
        let _ = self.git(&["update-index", "-q", "--refresh"]);
        self.git(&["read-tree", "-m", "-u", since, &work]).map_err(wrap)?;
        match self.params.branch.clone() {
            Some(branch) => {
                let reference = format!("refs/heads/{branch}");
                self.git(&["update-ref", "-m", "cmux seed", &reference, &head]).map_err(wrap)?;
                self.git(&["symbolic-ref", "HEAD", &reference]).map_err(wrap)?;
            }
            None => {
                self.git(&["update-ref", "--no-deref", "-m", "cmux seed", "HEAD", &head])
                    .map_err(wrap)?;
            }
        }
        self.track_upstream().map_err(wrap)?;
        self.finish_checkout()
    }

    /// The branch tracks `origin/<branch>` when the remote has it.
    fn track_upstream(&self) -> Result<(), Failure> {
        let Some(branch) = &self.params.branch else { return Ok(()) };
        let upstream = format!("refs/remotes/origin/{branch}");
        if self.git(&["rev-parse", "--verify", "--quiet", &upstream]).is_ok() {
            let to = format!("--set-upstream-to=origin/{branch}");
            self.git(&["branch", "--quiet", &to, branch])?;
        }
        Ok(())
    }

    /// The index becomes INDEX without touching the working tree; the
    /// sparse patterns and the stash follow.
    fn finish_checkout(&mut self) -> Result<(), Failed> {
        let wrap = |failure: Failure| step_failed(&failure, "seed.checkout_failed");
        let work = self.params.work.clone();
        let index = self.params.index.clone();
        self.git(&["read-tree", "--reset", &index]).map_err(wrap)?;
        if self.params.sparse.is_some() {
            self.git(&["sparse-checkout", "reapply"]).map_err(wrap)?;
            worktree::restore_untracked(&self.git, &self.chosen, &self.folder, &index, &work)
                .map_err(wrap)?;
        }
        match self.params.stash.clone() {
            Some(stash) => {
                self.git(&[
                    "update-ref",
                    "--create-reflog",
                    "-m",
                    "cmux seed",
                    "refs/stash",
                    &stash,
                ])
                .map_err(wrap)?;
            }
            None => {
                if self.git(&["rev-parse", "--verify", "--quiet", "refs/stash"]).is_ok() {
                    self.git(&["update-ref", "-d", "refs/stash"]).map_err(wrap)?;
                }
            }
        }
        Ok(())
    }

    /// `changed`: a delta seed's `diff-tree -z` of the two WORK trees; it
    /// needs the network only when a submodule commit or `.gitmodules`
    /// changed.
    fn submodules(&mut self, changed: Option<&[u8]>) -> Result<(), Failed> {
        if !self.folder.join(".gitmodules").is_file() {
            return Ok(());
        }
        if let Some(changed) = changed
            && !touches_submodules(changed)
        {
            return Ok(());
        }
        self.job.enter(Phase::Submodules);
        let folder = self.folder.clone();
        self.net(
            Some(&folder),
            &["submodule", "update", "--init", "--recursive", "--progress"],
            &mut || {},
        )
        .map_err(|failures| classify(&failures, "seed.checkout_failed"))
    }

    /// `changed`: as for [`Self::submodules`]; a delta seed pulls only the
    /// changed paths, and only when one of them is an LFS file.
    fn lfs(&mut self, changed: Option<&[u8]>) -> Result<(), Failed> {
        if !self.params.lfs {
            return Ok(());
        }
        let include = match changed {
            None => None,
            Some(changed) => {
                let paths = self.lfs_paths(changed);
                if paths.is_empty() {
                    return Ok(());
                }
                Some(paths.join(","))
            }
        };
        self.job.enter(Phase::Lfs);
        if self.git(&["lfs", "version"]).is_err() {
            self.job.note("lfs_unavailable");
            return Ok(());
        }
        // The filter config only (no hooks: hooks stay off on a seed).
        let folder = self.folder.clone();
        let installed = self.git(&["lfs", "install", "--local", "--skip-repo"]);
        let mut args = vec!["lfs", "pull"];
        if let Some(include) = &include {
            args.extend(["--include", include.as_str(), "--exclude", ""]);
        }
        let pulled = installed.is_ok() && self.net(Some(&folder), &args, &mut || {}).is_ok();
        if !pulled {
            self.job.note("lfs_failed");
        }
        Ok(())
    }
}

impl Seed {
    /// The changed paths (added or modified) whose `filter` attribute is lfs.
    fn lfs_paths(&self, changed: &[u8]) -> Vec<String> {
        let paths: Vec<String> = diff_entries(changed)
            .filter(|(status, _)| *status != "D")
            .filter_map(|(_, path)| std::str::from_utf8(path).ok().map(str::to_owned))
            // An lfs `--include` is a comma list of patterns.
            .filter(|path| {
                !path.contains(',')
                    && !path.contains('*')
                    && !path.contains('?')
                    && !path.contains('[')
            })
            .collect();
        paths
            .into_iter()
            .filter(|path| {
                self.git(&["check-attr", "filter", "--", path]).is_ok_and(|out| {
                    String::from_utf8_lossy(&out).trim_end().ends_with(": filter: lfs")
                })
            })
            .collect()
    }
}

/// `(status, path)` of each entry of a `diff-tree -r -z` listing.
fn diff_entries(listing: &[u8]) -> impl Iterator<Item = (&str, &[u8])> {
    let mut fields = listing.split(|byte| *byte == 0).filter(|field| !field.is_empty());
    std::iter::from_fn(move || {
        let meta = fields.next()?;
        let path = fields.next()?;
        let meta = std::str::from_utf8(meta).unwrap_or("");
        let status = meta.rsplit(' ').next().unwrap_or("");
        let mode_new = meta.trim_start_matches(':').split(' ').nth(1).unwrap_or("");
        let mode_old = meta.trim_start_matches(':').split(' ').next().unwrap_or("");
        let gitlink = mode_new == "160000" || mode_old == "160000";
        Some((if gitlink { "S" } else { status }, path))
    })
}

/// True when a `diff-tree -z` listing changes a submodule or `.gitmodules`.
fn touches_submodules(listing: &[u8]) -> bool {
    diff_entries(listing).any(|(status, path)| status == "S" || path == b".gitmodules".as_slice())
}

/// What the folder holds now, as trees: its index, and its working tree
/// with untracked files that are not ignored (built in a copy of the index,
/// so the real one is not touched).
struct Snapshot {
    index: String,
    work: String,
}

impl Snapshot {
    fn take(git: &Git, credential: &Credential, folder: &Path) -> Result<Self, Failure> {
        let git_dir = String::from_utf8_lossy(&git.quiet(
            Some(folder),
            credential,
            &["rev-parse", "--absolute-git-dir"],
        )?)
        .trim()
        .to_owned();
        let real = Path::new(&git_dir).join("index");
        let copy = Path::new(&git_dir).join(format!("cmux-seed-index-{}", std::process::id()));
        let result = (|| -> Result<Self, Failure> {
            std::fs::copy(&real, &copy).map_err(|error| Failure::of(format!("fatal: {error}")))?;
            let tree = |git: &Git| -> Result<String, Failure> {
                let out = git.run_in(
                    Some(folder),
                    credential,
                    &["write-tree"],
                    Some(copy.as_path()),
                    &mut |_| {},
                )?;
                Ok(String::from_utf8_lossy(&out).trim().to_owned())
            };
            let index = tree(git)?;
            git.run_in(
                Some(folder),
                credential,
                &["add", "-A", "--sparse"],
                Some(copy.as_path()),
                &mut |_| {},
            )?;
            let work = tree(git)?;
            Ok(Self { index, work })
        })();
        let _ = std::fs::remove_file(&copy);
        result
    }
}

fn failed(code: &'static str, error: impl Into<String>) -> Failed {
    Failed { code, error: error.into(), install_url: None }
}

/// One failed local step: a full disk, else `code`.
fn step_failed(failure: &Failure, code: &'static str) -> Failed {
    let code = if failure.disk_full() { "seed.disk_full" } else { code };
    failed(code, failure.message())
}

/// The failures of every GitHub path of a network step: a full disk, else
/// GitHub refusing every path (`seed.needs_github`, with the App's install
/// link when one was named), else `code`.
fn classify(failures: &[Failure], code: &'static str) -> Failed {
    let last = failures.last().cloned().unwrap_or_default();
    if let Some(full) = failures.iter().find(|failure| failure.disk_full()) {
        return failed("seed.disk_full", full.message());
    }
    if failures.iter().any(Failure::auth) {
        return Failed {
            code: "seed.needs_github",
            error: "the repository needs GitHub access this machine does not have (private, not found, or the cmux GitHub App is not installed)".into(),
            install_url: failures.iter().find_map(Failure::install_url),
        };
    }
    failed(code, last.message())
}

/// Removes what a failed clone left: the folder when the clone made it,
/// else its contents.
fn clean_folder(folder: &Path, existed: bool) {
    if !existed {
        let _ = std::fs::remove_dir_all(folder);
        return;
    }
    if let Ok(entries) = std::fs::read_dir(folder) {
        for entry in entries.flatten() {
            let path = entry.path();
            let _ = if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                std::fs::remove_dir_all(&path)
            } else {
                std::fs::remove_file(&path)
            };
        }
    }
}
