//! The clone from a warm mirror on this machine: Cloud "Add repository" and a fresh seed.
//!
//! A clone used to bring every commit and tree of the remote from GitHub on every add, and
//! then the checked-out commit's files: the second chat that adds the same repository paid
//! the whole clone again. The machine now keeps one mirror per remote, the same one AutoCloud
//! start keeps (`acpmux` `auto_session/import/mirror.rs`, the same folder and name):
//!
//! - **The mirror.** One bare, blobless (`--filter=blob:none`) clone per remote, under
//!   `~/Projects/auto/.cmux-git-mirrors/<sha256(remote)[..8] as hex>.git`. The first add makes
//!   it, every later add fetches what is new into it (a few KB).
//! - **The commit's files.** The blobs of the commit the clone checks out are fetched into
//!   the mirror in one batch (git's own promisor fetch), so the next add at that commit
//!   downloads none.
//! - **The folder.** A new repository that borrows the mirror's objects through
//!   `objects/info/alternates` (nothing is copied), with the refs, `origin`, the default
//!   branch and the blobless partial-clone config a `git clone --filter=blob:none
//!   --no-checkout` gives it. An old file a command asks for later comes from `origin` as it
//!   did; commits made there are the folder's own objects.
//!
//! **Access.** The mirror is shared by every add on the machine, and it holds what any of
//! them could read. An add borrows it only after its own fetch into the mirror, with its own
//! GitHub paths, succeeded: GitHub let this caller read the repository just now. When that
//! fetch fails the mirror is not touched further and the add clones as before, so a private
//! repository's objects never reach a caller GitHub refused (the clone reports the refusal).
//!
//! The mirror never prunes (`gc.auto 0`, `gc.pruneExpire never`): folders borrow its objects.
//! Anything that fails here leaves the add to the direct blobless clone it always had (the
//! job notes `seed.mirror.fallback`), and `CMUX_SEED_MIRROR=off` turns the mirror off. The
//! status answer says `mirror`: `hit` (an existing mirror was borrowed), `miss` (none was
//! there, or borrowing failed) or `off`.

use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_file_lock::{FileLock, Kind};
use sha2::{Digest as _, Sha256};

use super::{Failure, Seed, clean_folder};

/// `root` made and canonical.
fn mirrors_root(root: &Path) -> Option<PathBuf> {
    std::fs::create_dir_all(root).ok()?;
    root.canonicalize().ok()
}

/// The mirrors' folder, beside AutoCloud's chat folders (`acpmux` `machine.rs::chats_root`).
const MIRRORS: &str = "Projects/auto/.cmux-git-mirrors";

/// How long an add waits for another add of the same remote to finish with the mirror
/// before it clones directly. The holder may be making the mirror (a whole blobless clone of a
/// large remote: minutes), and waiting for it is cheaper than a crowd of direct clones, so this
/// bounds only a holder that never finishes.
const LOCK_WAIT: Duration = Duration::from_secs(30 * 60);

/// The file beside a mirror whose mtime says when an add last fetched into it.
fn stamp_of(mirror: &Path) -> PathBuf {
    mirror.with_extension("fetched")
}

/// Whether the mirror was fetched into at or after `since` (by another add this one waited for).
fn fetched_since(mirror: &Path, since: std::time::SystemTime) -> bool {
    std::fs::metadata(stamp_of(mirror)).and_then(|meta| meta.modified()).is_ok_and(|at| at >= since)
}

fn stamp(mirror: &Path) {
    let _ = std::fs::write(stamp_of(mirror), b"");
}

/// The machine's mirrors folder, unless `CMUX_SEED_MIRROR=off` or there is no home.
#[must_use]
pub fn default_root() -> Option<PathBuf> {
    root_for(std::env::var("CMUX_SEED_MIRROR").ok().as_deref(), std::env::var_os("HOME"))
}

/// [`default_root`] for a given switch and home.
pub(crate) fn root_for(switch: Option<&str>, home: Option<std::ffi::OsString>) -> Option<PathBuf> {
    if switch.is_some_and(|value| value.trim().eq_ignore_ascii_case("off")) {
        return None;
    }
    let home = PathBuf::from(home.filter(|home| !home.is_empty())?);
    home.is_absolute().then(|| home.join(MIRRORS))
}

/// The mirror's file name for `remote`: the same as AutoCloud's.
pub(crate) fn key(remote: &str) -> String {
    Sha256::digest(remote.as_bytes()).iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// What the attempt to borrow came to.
enum Borrow {
    /// The folder borrows the mirror; it was there before this add (`true`) or made by it.
    Done(bool),
    /// This caller's own fetch into the mirror failed: nothing was borrowed.
    Unproven,
    /// Something else failed (the step that did).
    Failed(&'static str),
}

impl Seed {
    /// Whether the folder (absent or empty) is now a repository borrowing the mirror of its
    /// remote. On `false` the folder is as it was and the caller clones as before.
    pub(super) fn borrow_mirror(&mut self) -> bool {
        let Some(root) = self.mirrors.clone() else {
            self.job.mirror("off");
            return false;
        };
        let folder = self.folder.clone();
        let existed = folder.exists();
        let started = Instant::now();
        let borrowed = self.attach(&root);
        super::super::git::count("mirror", started.elapsed());
        let stage = match borrowed {
            Borrow::Done(warm) => {
                self.job.mirror(if warm { "hit" } else { "miss" });
                return true;
            }
            Borrow::Unproven => "fetch",
            Borrow::Failed(stage) => stage,
        };
        clean_folder(&folder, existed);
        self.job.mirror("miss");
        self.job.note("seed.mirror.fallback");
        // The stage only: git's own words may name a URL.
        eprintln!("cmux-tui: seed.mirror.fallback at {stage}; cloning directly");
        false
    }

    fn attach(&mut self, root: &Path) -> Borrow {
        let Some(root) = mirrors_root(root) else { return Borrow::Failed("root") };
        let url = self.params.url.clone();
        let mut fill = |seed: &mut Self, mirror: &Path| match seed.mirror_target(mirror) {
            Some(commit) => seed.fill_mirror(mirror, &commit).map_err(|_| "fill"),
            None => Ok(()),
        };
        // Ready without the lock: the commit asked for resolves in the mirror, its files are
        // there, and the mirror's default branch (and the branch or tag asked for) is the
        // remote's own now.
        let mut ready = |seed: &mut Self, mirror: &Path| match seed.local_target(mirror) {
            Some(Some(commit)) => seed.filled(mirror, &commit),
            Some(None) => true,
            None => false,
        };
        let asks = self.fresh_asks();
        let warmed = self.warm_mirror(&root, &url, Some(&asks), &mut ready, &mut fill);
        let (mirror, warm) = match warmed {
            Ok(warmed) => warmed,
            Err(None) => return Borrow::Unproven,
            Err(Some(stage)) => return Borrow::Failed(stage),
        };
        match self.borrow_into(&mirror) {
            Ok(()) => Borrow::Done(warm),
            Err(_) => Borrow::Failed("folder"),
        }
    }

    /// The mirror of `url` under `root` (and whether it was there before), made or brought up
    /// to date with this caller's own reach of `url`, then `fill`ed, all under the mirror's
    /// lock; the lock is let go on return (the mirror only gains objects: it never prunes).
    /// `origin`: `url` is the seed's remote, not a submodule's. `Err(None)`: this caller's own
    /// reach failed (access not proven); `Err(Some(stage))`: something else did.
    ///
    /// A warm mirror that is already `ready` is borrowed without the lock: this caller's own
    /// `ls-remote` (its access, now) is the only network step, and the mirror only gains
    /// objects, so adds of one remote read it at once instead of taking turns (8 warm adds of
    /// cmux used to queue for minutes behind each other's fetches). `fresh`: the refs
    /// `ls-remote` asks for (the seed's remote) whose ids the mirror must hold already;
    /// `None` for a submodule, pinned by its gitlink.
    fn warm_mirror(
        &mut self,
        root: &Path,
        url: &str,
        fresh: Option<&[String]>,
        ready: &mut dyn FnMut(&mut Self, &Path) -> bool,
        fill: &mut dyn FnMut(&mut Self, &Path) -> Result<(), &'static str>,
    ) -> Result<(PathBuf, bool), Option<&'static str>> {
        let origin = fresh.is_some();
        let key = key(url);
        let mirror = root.join(format!("{key}.git"));
        if mirror.join("HEAD").is_file()
            && self.mirror_of(&mirror, url).is_ok()
            && ready(self, &mirror)
        {
            let asks = fresh.map_or_else(|| vec!["HEAD".to_owned()], <[String]>::to_vec);
            let mut args = vec!["ls-remote", "--quiet", "origin"];
            args.extend(asks.iter().map(String::as_str));
            // This caller's own reach failing is the locked path's failure too: access not
            // proven, nothing borrowed.
            let listed = self.net_listed(origin, &mirror, &args).ok_or(None)?;
            if !origin || self.mirror_holds(&mirror, &listed, &asks) {
                return Ok((mirror, true));
            }
        }
        // Before the wait: a fetch another add makes after this moment brings what this add
        // would have fetched itself.
        let asked = std::time::SystemTime::now();
        let _lock = lock(&root.join(format!("{key}.lock"))).ok_or(Some("lock"))?;
        let warm = mirror.join("HEAD").is_file();
        // The proof of access is this caller's own reach of the remote, now: a fetch into the
        // mirror, or, when an add it waited for fetched since it asked, `ls-remote` (one round
        // trip). A crowd of adds of one remote makes one fetch, not one each in turn.
        match (warm, warm && fetched_since(&mirror, asked)) {
            (true, true) => self.reach(&mirror, url, origin)?,
            (true, false) => self.refresh(&mirror, url, origin)?,
            (false, _) => self.make(root, &mirror, url, origin)?,
        }
        fill(self, &mirror).map_err(Some)?;
        Ok((mirror, warm))
    }

    /// A network step for the mirror of the seed's remote (`origin`: it records the path that
    /// reached it) or of a submodule's.
    fn net_for(
        &mut self,
        origin: bool,
        cwd: &Path,
        args: &[&str],
        between: &mut dyn FnMut(),
    ) -> Result<(), Option<&'static str>> {
        let ran = if origin {
            self.net_origin(Some(cwd), args, between)
        } else {
            self.net(Some(cwd), args, between)
        };
        ran.map_err(|_| None)
    }

    /// `Err(Some("origin"))` unless the mirror is `url`'s.
    fn mirror_of(&self, mirror: &Path, url: &str) -> Result<(), Option<&'static str>> {
        let origin = self.git.quiet(Some(mirror), &self.chosen, &["config", "remote.origin.url"]);
        let origin = origin.map(|out| String::from_utf8_lossy(&out).trim().to_owned()).ok();
        if origin.as_deref() == Some(url) { Ok(()) } else { Err(Some("origin")) }
    }

    /// The warm mirror brought up to date with this caller's paths.
    fn refresh(
        &mut self,
        mirror: &Path,
        url: &str,
        origin: bool,
    ) -> Result<(), Option<&'static str>> {
        self.mirror_of(mirror, url)?;
        let args = ["fetch", "--progress", "--prune", "--tags", "--filter=blob:none", "origin"];
        self.net_for(origin, mirror, &args, &mut || {})?;
        stamp(mirror);
        Ok(())
    }

    /// This caller reaches the remote with its own paths (`ls-remote origin HEAD`), the mirror
    /// fresh from another add's fetch.
    fn reach(
        &mut self,
        mirror: &Path,
        url: &str,
        origin: bool,
    ) -> Result<(), Option<&'static str>> {
        self.mirror_of(mirror, url)?;
        self.net_for(origin, mirror, &["ls-remote", "--quiet", "origin", "HEAD"], &mut || {})
    }

    /// `ls-remote`'s answer with this caller's own paths (the seed's remote: `origin`, the path
    /// that reached it is kept as [`Self::net_origin`] keeps it).
    fn net_listed(&mut self, origin: bool, mirror: &Path, args: &[&str]) -> Option<String> {
        for credential in self.credentials.clone() {
            if let Ok(out) = self.git.run(Some(mirror), &credential, args, &mut |_| {}) {
                self.chosen = credential;
                if origin {
                    self.reached = Some(self.chosen.clone());
                }
                return Some(String::from_utf8_lossy(&out).into_owned());
            }
        }
        None
    }

    /// Whether every ref of `asks` the remote listed has the same id in the mirror.
    fn mirror_holds(&self, mirror: &Path, listed: &str, asks: &[String]) -> bool {
        listed.lines().filter_map(|line| line.split_once('\t')).all(|(id, name)| {
            !asks.iter().any(|ask| ask == name)
                || self
                    .git
                    .quiet(Some(mirror), &self.chosen, &["rev-parse", "-q", "--verify", name])
                    .is_ok_and(|out| String::from_utf8_lossy(&out).trim() == id)
        })
    }

    /// The refs whose ids decide whether the mirror is current for this add: the remote's
    /// default branch, and the branch or tag asked for by name.
    fn fresh_asks(&self) -> Vec<String> {
        let mut asks = vec!["HEAD".to_owned()];
        if let Some(want) = self.want().filter(|want| want != "HEAD" && !is_hex_id(want)) {
            asks.push(format!("refs/heads/{want}"));
            asks.push(format!("refs/tags/{want}"));
        }
        asks
    }

    /// Whether every file of `commit` is in the mirror already.
    fn filled(&self, mirror: &Path, commit: &str) -> bool {
        let args = ["rev-list", "--objects", "--missing=print", "--no-walk", commit];
        self.git
            .quiet(Some(mirror), &self.chosen, &args)
            .is_ok_and(|out| !String::from_utf8_lossy(&out).lines().any(|l| l.starts_with('?')))
    }

    /// The mirror made aside with this caller's paths and renamed in: an add that sees the
    /// mirror sees a whole one.
    fn make(
        &mut self,
        root: &Path,
        mirror: &Path,
        url: &str,
        origin: bool,
    ) -> Result<(), Option<&'static str>> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let name = mirror.file_stem().map(|stem| stem.to_string_lossy().into_owned());
        let tmp =
            root.join(format!(".tmp-{}-{}-{nanos}", name.unwrap_or_default(), std::process::id()));
        let path = tmp.display().to_string();
        let args = ["clone", "--progress", "--bare", "--filter=blob:none", "--", url, &path];
        let remove = || {
            let _ = std::fs::remove_dir_all(&tmp);
        };
        let mut between = remove;
        if let Err(error) = self.net_for(origin, root, &args, &mut between) {
            remove();
            return Err(error);
        }
        let configured = [
            ["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"],
            ["config", "gc.auto", "0"],
            ["config", "gc.pruneExpire", "never"],
        ]
        .iter()
        .try_for_each(|args| self.git.quiet(Some(&tmp), &self.chosen, args).map(drop));
        if configured.is_err() {
            remove();
            return Err(Some("config"));
        }
        match std::fs::rename(&tmp, mirror) {
            Ok(()) => {
                stamp(mirror);
                Ok(())
            }
            // Another machine process (AutoCloud start) made it meanwhile; this caller's
            // clone proved its access all the same.
            Err(_) if mirror.join("HEAD").is_file() => {
                remove();
                Ok(())
            }
            Err(_) => {
                remove();
                Err(Some("rename"))
            }
        }
    }

    /// The submodules of the checked-out head a clone has not made yet, each cloned
    /// blobless from its own warm mirror under the same root (made, fetched into and filled
    /// with the submodule commit's files under the same lock and access rules as the
    /// remote's), so a second add downloads none of them again. A submodule whose mirror
    /// fails is left to the plain `submodule update` that follows, as before.
    pub(super) fn submodules_from_mirrors(&mut self) {
        let Some(root) = self.mirrors.clone().and_then(|root| mirrors_root(&root)) else { return };
        for (name, path, url) in self.submodules_listed() {
            if self.folder.join(".git/modules").join(&name).exists() {
                continue;
            }
            let Some(commit) = self.gitlink(&path) else { continue };
            let mut fill = |seed: &mut Self, mirror: &Path| {
                let commit = seed.commit_in(mirror, &commit).ok_or("commit")?;
                seed.fill_mirror(mirror, &commit).map_err(|_| "fill")
            };
            let mut ready = |seed: &mut Self, mirror: &Path| {
                seed.commit_of(mirror, &commit).is_some_and(|id| seed.filled(mirror, &id))
            };
            let stage = match self.warm_mirror(&root, &url, None, &mut ready, &mut fill) {
                Ok((mirror, _)) => {
                    let reference = mirror.display().to_string();
                    let folder = self.folder.clone();
                    let args = [
                        "submodule",
                        "update",
                        "--init",
                        "--progress",
                        "--filter=blob:none",
                        "--reference",
                        &reference,
                        "--",
                        &path,
                    ];
                    if self.net(Some(&folder), &args, &mut || {}).is_ok() {
                        continue;
                    }
                    "update"
                }
                Err(None) => "fetch",
                Err(Some(stage)) => stage,
            };
            self.job.note("seed.mirror.submodule_fallback");
            eprintln!("cmux-tui: seed.mirror.submodule_fallback at {stage}");
        }
    }

    /// `(name, path, url)` of each submodule `.gitmodules` names with a remote URL (a relative
    /// URL is left to `submodule update`).
    fn submodules_listed(&self) -> Vec<(String, String, String)> {
        let Ok(out) = self.git(&[
            "config",
            "-f",
            ".gitmodules",
            "--get-regexp",
            r"^submodule\..*\.(path|url)$",
        ]) else {
            return Vec::new();
        };
        let mut paths =
            std::collections::BTreeMap::<String, (Option<String>, Option<String>)>::new();
        for line in String::from_utf8_lossy(&out).lines() {
            let Some((key, value)) = line.split_once(' ') else { continue };
            let Some(rest) = key.strip_prefix("submodule.") else { continue };
            if let Some(name) = rest.strip_suffix(".path") {
                paths.entry(name.to_owned()).or_default().0 = Some(value.to_owned());
            } else if let Some(name) = rest.strip_suffix(".url") {
                paths.entry(name.to_owned()).or_default().1 = Some(value.to_owned());
            }
        }
        paths
            .into_iter()
            .filter_map(|(name, (path, url))| Some((name, path?, url?)))
            .filter(|(_, _, url)| url.contains("://"))
            .collect()
    }

    /// The commit the head records at submodule `path`.
    fn gitlink(&self, path: &str) -> Option<String> {
        let out = self.git(&["ls-tree", "HEAD", "--", path]).ok()?;
        let line = String::from_utf8_lossy(&out).trim().to_owned();
        let (meta, _) = line.split_once('\t')?;
        match meta.split_whitespace().collect::<Vec<_>>()[..] {
            ["160000", "commit", id] => Some(id.to_owned()),
            _ => None,
        }
    }

    /// `id` as a commit of the mirror, fetched by id when the mirror lacks it.
    fn commit_in(&mut self, mirror: &Path, id: &str) -> Option<String> {
        if let Some(commit) = self.commit_of(mirror, id) {
            return Some(commit);
        }
        if !is_hex_id(id) {
            return None;
        }
        let args = ["fetch", "--progress", "--no-tags", "--filter=blob:none", "origin", id];
        self.net(Some(mirror), &args, &mut || {}).ok()?;
        self.commit_of(mirror, id)
    }

    /// `name` as a commit of the mirror, with no fetch.
    fn commit_of(&self, mirror: &Path, name: &str) -> Option<String> {
        let name = format!("{name}^{{commit}}");
        self.git
            .quiet(Some(mirror), &self.chosen, &["rev-parse", "-q", "--verify", &name])
            .ok()
            .map(|out| String::from_utf8_lossy(&out).trim().to_owned())
            .filter(|id| !id.is_empty())
    }

    /// What the clone checks out: the branch, tag or commit asked for, `HEAD` (the remote's
    /// default branch) or a seed's base; `None` when a head-first seed fills its own way.
    fn want(&self) -> Option<String> {
        match &self.params.clone_only {
            Some(Some(git_ref)) => Some(git_ref.clone()),
            Some(None) => Some("HEAD".to_owned()),
            None if self.params.head_first.is_some() || self.params.base.is_empty() => None,
            None => Some(self.params.base.clone()),
        }
    }

    /// [`Self::mirror_target`] with no fetch: `None` when the mirror lacks the commit,
    /// `Some(None)` when there is nothing to fill.
    fn local_target(&self, mirror: &Path) -> Option<Option<String>> {
        let Some(want) = self.want() else { return Some(None) };
        if want != "HEAD" {
            for name in [format!("refs/heads/{want}"), format!("refs/tags/{want}")] {
                if let Some(commit) = self.commit_of(mirror, &name) {
                    return Some(Some(commit));
                }
            }
        }
        self.commit_of(mirror, &want).map(Some)
    }

    /// The commit whose files the clone will check out, in the mirror: the branch, tag or
    /// commit asked for (fetched into the mirror when it is a commit the mirror lacks), the
    /// remote's default branch, or a seed's base. A head-first seed fills its own way.
    fn mirror_target(&mut self, mirror: &Path) -> Option<String> {
        let want = self.want()?;
        for name in [format!("refs/heads/{want}"), format!("refs/tags/{want}")] {
            if want != "HEAD"
                && let Some(commit) = self.commit_of(mirror, &name)
            {
                return Some(commit);
            }
        }
        self.commit_in(mirror, &want)
    }

    /// The files of `commit` fetched into the mirror in one batch; the ones it has are
    /// skipped.
    fn fill_mirror(&mut self, mirror: &Path, commit: &str) -> Result<(), Vec<Failure>> {
        let listed = self
            .git
            .quiet(
                Some(mirror),
                &self.chosen,
                &["rev-list", "--objects", "--missing=print", "--no-walk", commit],
            )
            .map_err(|failure| vec![failure])?;
        let missing: String = String::from_utf8_lossy(&listed)
            .lines()
            .filter_map(|line| line.strip_prefix('?'))
            .flat_map(|id| [id, "\n"])
            .collect();
        if missing.is_empty() {
            return Ok(());
        }
        // git's own form for a promisor fetch by object id (`promisor-remote.c`): any id, no
        // negotiation, no FETCH_HEAD.
        let args = [
            "-c",
            "fetch.negotiationAlgorithm=noop",
            "fetch",
            "--progress",
            "--no-tags",
            "--no-write-fetch-head",
            "--recurse-submodules=no",
            "--filter=blob:none",
            "--stdin",
            "origin",
        ];
        let mut failures = Vec::new();
        for credential in self.credentials.clone() {
            let job = self.job.clone();
            let ran = self.git.run_input(
                Some(mirror),
                &credential,
                &args,
                missing.as_bytes(),
                &mut |line| job.progress(line),
            );
            match ran {
                Ok(_) => {
                    self.chosen = credential;
                    return Ok(());
                }
                Err(failure) => failures.push(failure),
            }
        }
        Err(failures)
    }

    /// The folder made a repository borrowing `mirror`, as `git clone --filter=blob:none
    /// --no-checkout` leaves one: `origin` and its branches and tags, the default branch
    /// checked out next.
    fn borrow_into(&self, mirror: &Path) -> Result<(), Failure> {
        let io = |what: &str, error: std::io::Error| Failure::of(format!("fatal: {what}: {error}"));
        let in_mirror = |args: &[&str]| {
            self.git
                .quiet(Some(mirror), &self.chosen, args)
                .map(|out| String::from_utf8_lossy(&out).trim().to_owned())
        };
        let format = in_mirror(&["rev-parse", "--show-object-format"])?;
        std::fs::create_dir_all(&self.folder).map_err(|error| io("the folder", error))?;
        let folder = self.folder_str();
        let object_format = format!("--object-format={format}");
        self.git.quiet(None, &self.chosen, &["init", "--quiet", &object_format, "--", &folder])?;
        self.git(&["remote", "add", "origin", &self.params.url])?;
        let info = self.folder.join(".git/objects/info");
        std::fs::create_dir_all(&info).map_err(|error| io("objects/info", error))?;
        std::fs::write(info.join("alternates"), format!("{}\n", mirror.join("objects").display()))
            .map_err(|error| io("alternates", error))?;
        for (key, value) in [
            ("core.repositoryformatversion", "1"),
            ("extensions.partialClone", "origin"),
            ("remote.origin.promisor", "true"),
            ("remote.origin.partialclonefilter", "blob:none"),
        ] {
            self.git(&["config", key, value])?;
        }
        let refs = in_mirror(&[
            "for-each-ref",
            "--format=%(objectname) %(refname)",
            "refs/heads/",
            "refs/tags/",
        ])?;
        let mut updates = String::new();
        for line in refs.lines() {
            let Some((id, name)) = line.split_once(' ') else { continue };
            if let Some(branch) = name.strip_prefix("refs/heads/") {
                updates.push_str(&format!("update refs/remotes/origin/{branch} {id}\n"));
            } else if name.starts_with("refs/tags/") {
                updates.push_str(&format!("update {name} {id}\n"));
            }
        }
        let folder_dir = self.folder.clone();
        self.git.run_input(
            Some(&folder_dir),
            &self.chosen,
            &["update-ref", "--stdin"],
            updates.as_bytes(),
            &mut |_| {},
        )?;
        let default = in_mirror(&["symbolic-ref", "-q", "HEAD"])?;
        let branch = default
            .strip_prefix("refs/heads/")
            .ok_or_else(|| Failure::of("fatal: the mirror has no default branch"))?;
        let tracking = format!("refs/remotes/origin/{branch}");
        let id = self.git(&["rev-parse", "-q", "--verify", &format!("{tracking}^{{commit}}")])?;
        let id = String::from_utf8_lossy(&id).trim().to_owned();
        self.git(&["symbolic-ref", "refs/remotes/origin/HEAD", &tracking])?;
        self.git(&["update-ref", &format!("refs/heads/{branch}"), &id])?;
        self.git(&["symbolic-ref", "HEAD", &format!("refs/heads/{branch}")])?;
        self.git(&["config", &format!("branch.{branch}.remote"), "origin"])?;
        self.git(&["config", &format!("branch.{branch}.merge"), &default])?;
        Ok(())
    }
}

/// Whether `id` is a whole object id (a commit asked for by id, fetched by id when missing).
fn is_hex_id(id: &str) -> bool {
    id.len() >= 40 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// The mirror's lock for this add, waited for at most [`LOCK_WAIT`]: adds of one remote take
/// turns making, fetching into and filling it (an add whose mirror is ready already takes no
/// lock); an add that waited for a fetch skips its own. An advisory lock
/// on its own open file, so threads of this daemon take turns too.
fn lock(path: &Path) -> Option<FileLock> {
    let file =
        OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path).ok()?;
    FileLock::take_within(file, Kind::Exclusive, LOCK_WAIT, Duration::from_millis(50)).ok()
}
