//! `git.seed.export {folder, since_work, since_head, bundle}`: the way back
//! of a seed (leo-workspace `design/cloud.md`, "Getting the project onto the
//! machine", rule 6). The machine makes INDEX and WORK commits of the
//! folder as it is now, exactly as the Mac's seed plan makes them
//! ([`super::snapshot`]: the same trees, fixed identity and date), and
//! writes one bundle at `bundle` with `refs/cmux-back/{head,index,work}`
//! (and `stash` when there is one) and the prerequisites `^since_work` and
//! `^since_head`, so it holds only what changed since. The Mac fetches it
//! into a quarantine and merges it three ways.
//!
//! The commits are also recorded in the folder as `refs/cmux-back/*`: they
//! stay out of gc, and a later delta seed may build on them (`since` is the
//! export's WORK once the Mac merged it back). The Mac merges an export only
//! when nothing conflicts, so until it does its base is still `since`: when
//! `since` was the back record this export replaces, that record moves to
//! `refs/cmux-base/*` ([`BASE_RECORD`]), so a retry from it after a conflict
//! still has its commits and its stash to compare with (and a delta seed
//! still builds on it). Only the Mac's base and the newest export are kept;
//! the seed's own `refs/cmux-seed/*` stays as the seed left it.
//!
//! When WORK is `since_work` (HEAD, the index and the working tree are as
//! the seed left them) the answer is `unchanged` and no bundle is written.
//! Ignored files never go (`add -A` skips them), nor do untracked secrets or
//! nested repositories.
//!
//! The answer, once the job is done (`git.seed.status`): `{head_ref, head,
//! index, work, stash, unchanged, bundle_bytes, left_out}`.
//!
//! `{folder, bundle, move: "upstream" | "seed" | "since" | "check", since_work?, since_head?}` is a
//! move's export (Move to another Cloud machine, VM to VM): the folder's state for a
//! second machine, never for a Mac to merge back, so it leaves the folder's seed records
//! (`refs/cmux-back`, `refs/cmux-base`, `refs/cmux-seed`) as they are and names its commits
//! `refs/cmux-move/*` instead ([`MOVE_RECORD`]). Any clone exports, seed or not. Its base:
//!
//! - `upstream`: the tip the folder's branch tracks (`@{upstream}`), else the remote's
//!   default branch (`refs/remotes/origin/HEAD`). A commit GitHub has, so the second
//!   machine clones the history from GitHub and gets only this bundle on top: a folder
//!   that started on a Cloud machine moves as git, not file by file.
//! - `seed`: the folder's own seed (`refs/cmux-seed`), for a machine that still has the
//!   folder as that seed left it (a chat moving back to the machine it came from).
//! - `since`: `since_work` and `since_head`, the move's own last export (its frozen pass).
//! - `check`: `since_work` and `since_head` of a record the folder keeps, only to ask whether
//!   the folder is still as that record left it (a chat moving back when the machine it is on
//!   has nothing to send): the answer's `unchanged`. Nothing is recorded and no bundle is
//!   written.
//!
//! The URL is the remote the folder's branch tracks (`branch.<name>.remote`), else `origin`.
//!
//! A move's answer adds `since_head`, `since_work` (the base it used) and `url`, the
//! remote's URL as configured (`remote.<name>.url`, no `insteadOf`).

use std::path::PathBuf;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::git::{Credential, Failure, Git};

/// The back record a Mac may still be on (module docs).
pub(super) const BASE_RECORD: &str = "refs/cmux-base";
/// A move's export (module docs): the same length as `refs/cmux-back`, so the Mac renames
/// a bundle's refs in its header alone.
pub(super) const MOVE_RECORD: &str = "refs/cmux-move";
/// The records an export's or a delta seed's `since` may be, newest first: a seed's, and a
/// move's last export (a chat moving back to the machine it came from; only a move's own
/// export reads that one).
pub(super) const DELTA_RECORDS: [&str; 4] =
    ["refs/cmux-back", BASE_RECORD, "refs/cmux-seed", MOVE_RECORD];
use super::job::{Failed, Job};
use super::params::check_sha;
use super::snapshot::{self, Snapshot};
use super::{SeedRefusal, place};
use crate::fs_ops::Roots;

#[derive(Deserialize)]
struct Wire {
    folder: String,
    #[serde(default)]
    since_work: Option<String>,
    #[serde(default)]
    since_head: Option<String>,
    bundle: String,
    #[serde(default, rename = "move")]
    move_from: Option<String>,
}

/// A move's base (module docs).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MoveFrom {
    Upstream,
    Seed,
    Since,
    Check,
}

/// A checked export request. A move's `since_*` are empty until [`Export::run`] finds
/// its base (`upstream`, `seed`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExportParams {
    pub folder: String,
    pub since_work: String,
    pub since_head: String,
    pub bundle: String,
    pub move_from: Option<MoveFrom>,
}

impl ExportParams {
    pub fn parse(params: &Value) -> Result<Self, SeedRefusal> {
        let wire: Wire = serde_json::from_value(params.clone())
            .map_err(|error| SeedRefusal::bad_request(format!("invalid params: {error}")))?;
        let move_from = match wire.move_from.as_deref() {
            None => None,
            Some("upstream") => Some(MoveFrom::Upstream),
            Some("seed") => Some(MoveFrom::Seed),
            Some("since") => Some(MoveFrom::Since),
            Some("check") => Some(MoveFrom::Check),
            Some(other) => {
                return Err(SeedRefusal::bad_request(format!("unknown move base {other}")));
            }
        };
        // Only a move's own last export names its commits; the others find theirs.
        let named = matches!(move_from, None | Some(MoveFrom::Since | MoveFrom::Check));
        let (since_work, since_head) = match (wire.since_work, wire.since_head) {
            (Some(work), Some(head)) if named => {
                check_sha("since_work", &work)?;
                check_sha("since_head", &head)?;
                (work, head)
            }
            (None, None) if !named => (String::new(), String::new()),
            _ if named => {
                return Err(SeedRefusal::bad_request("since_work and since_head are needed"));
            }
            _ => {
                return Err(SeedRefusal::bad_request(
                    "a move from its upstream or its seed names no since commits",
                ));
            }
        };
        Ok(Self { folder: wire.folder, since_work, since_head, bundle: wire.bundle, move_from })
    }

    /// What makes a retry the same job, with the folder.
    pub fn retry_key(&self) -> String {
        format!("export {self:?}")
    }
}

pub struct Export {
    job: Arc<Job>,
    params: ExportParams,
    folder: PathBuf,
    roots: Roots,
    git: Git,
}

impl Export {
    pub fn new(
        job: Arc<Job>,
        params: ExportParams,
        folder: PathBuf,
        roots: Roots,
        git: Git,
    ) -> Self {
        Self { job, params, folder, roots, git }
    }

    /// `git ARGS` in the folder. An export needs no network: no GitHub path.
    fn git(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
        self.git.quiet(Some(&self.folder), &Credential::Anonymous, args)
    }

    fn read(&self, args: &[&str]) -> Option<String> {
        self.git(args)
            .ok()
            .map(|out| String::from_utf8_lossy(&out).trim().to_owned())
            .filter(|text| !text.is_empty())
    }

    pub fn run(mut self) -> Result<(), Failed> {
        place::recheck(&self.folder).map_err(|refusal| failed(refusal.code, refusal.message))?;
        let wrap = |failure: Failure| {
            let code = if failure.disk_full() { "seed.disk_full" } else { "seed.export_failed" };
            failed(code, failure.message())
        };
        let mut url = None;
        match self.params.move_from {
            // Only a seed's folder exports. `since` need not be its newest
            // record: an export the Mac could not merge (a conflict) moved the
            // back record, and the Mac pulls again from its own base.
            None => {
                if self
                    .read(&["rev-parse", "--verify", "--quiet", "refs/cmux-seed/work^{commit}"])
                    .is_none()
                {
                    return Err(failed("seed.since_mismatch", "the folder is not a seed"));
                }
            }
            // A move: any clone, from a base it finds or is given (module docs).
            Some(from) => {
                let (head, work, remote) = self.move_base(from)?;
                self.params.since_head = head;
                self.params.since_work = work;
                url = Some(self.remote_url(&remote).ok_or_else(|| {
                    failed("seed.no_upstream", format!("the folder has no remote {remote}"))
                })?);
            }
        }
        let recorded_stash = self.record_of_since().and_then(|record| {
            self.read(&["rev-parse", "--verify", "--quiet", &format!("{record}/stash")])
        });
        for (name, sha) in
            [("since_work", &self.params.since_work), ("since_head", &self.params.since_head)]
        {
            if self.git(&["cat-file", "-e", &format!("{sha}^{{commit}}")]).is_err() {
                return Err(failed(
                    "seed.since_mismatch",
                    format!("the folder does not have the {name} commit"),
                ));
            }
        }
        let head = self
            .read(&["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
            .ok_or_else(|| failed("seed.export_failed", "the folder has no commit checked out"))?;
        let head_ref = self.read(&["symbolic-ref", "-q", "HEAD"]);
        // Work inside a submodule leaves its gitlink as it is: it would read
        // as unchanged. Refused, as the Mac's plan refuses it on the way up.
        if let Some(path) = self.dirty_submodule().map_err(wrap)? {
            return Err(failed(
                "seed.submodule_local_work",
                format!("submodule {path} has uncommitted changes on the machine"),
            ));
        }
        let snapshot =
            Snapshot::take(&self.git, &Credential::Anonymous, &self.folder).map_err(wrap)?;
        let commit = |tree: &str, parent: &str, message: &str| {
            snapshot::commit(&self.git, &Credential::Anonymous, &self.folder, tree, parent, message)
        };
        let index = commit(&snapshot.index, &head, snapshot::INDEX_MESSAGE).map_err(wrap)?;
        let work = commit(&snapshot.work, &index, snapshot::WORK_MESSAGE).map_err(wrap)?;
        let stash = self.read(&["rev-parse", "--verify", "--quiet", "refs/stash^{commit}"]);
        // Unchanged only when WORK and the stash are the record's: a
        // stash-only change still needs its objects sent.
        let same_work = work == self.params.since_work;
        let mut unchanged = same_work && stash == recorded_stash;
        let mut bundle_bytes = 0;
        let checking = self.params.move_from == Some(MoveFrom::Check);
        if !unchanged && !checking {
            self.record(&head, &index, &work, stash.as_deref()).map_err(wrap)?;
            // Only the stash went: the record moved, but no object is new.
            if same_work && stash.is_none() {
                unchanged = true;
            } else {
                bundle_bytes = self.bundle(stash.is_some())?;
            }
        }
        let mut answer = json!({
            "head_ref": head_ref,
            "head": head,
            "index": index,
            "work": work,
            "stash": stash,
            "unchanged": unchanged,
            "bundle_bytes": bundle_bytes,
            "left_out": snapshot.left_out,
        });
        if let (Some(url), Value::Object(fields)) = (url, &mut answer) {
            fields.insert("url".into(), json!(url));
            fields.insert("since_head".into(), json!(self.params.since_head));
            fields.insert("since_work".into(), json!(self.params.since_work));
        }
        if let Value::Object(fields) = answer {
            self.job.exported(fields);
        }
        Ok(())
    }

    /// A move's base (module docs): its HEAD and WORK commits, and the remote it is on.
    fn move_base(&self, from: MoveFrom) -> Result<(String, String, String), Failed> {
        let commit = |reference: &str| {
            self.read(&["rev-parse", "--verify", "--quiet", &format!("{reference}^{{commit}}")])
        };
        let none = |why: &str| failed("seed.no_upstream", why.to_owned());
        match from {
            MoveFrom::Upstream => {
                let tracked =
                    self.tracked_remote().and_then(|remote| Some((commit("@{upstream}")?, remote)));
                let (tip, remote) = match tracked {
                    Some(tracked) => tracked,
                    None => (
                        commit("refs/remotes/origin/HEAD").ok_or_else(|| {
                            none("the folder's branch tracks nothing on a remote")
                        })?,
                        "origin".to_owned(),
                    ),
                };
                // The tip is both: nothing GitHub has goes in the bundle.
                Ok((tip.clone(), tip, remote))
            }
            MoveFrom::Seed => {
                let (Some(head), Some(work)) =
                    (commit("refs/cmux-seed/head"), commit("refs/cmux-seed/work"))
                else {
                    return Err(failed("seed.since_mismatch", "the folder is not a seed"));
                };
                Ok((head, work, self.remote()))
            }
            MoveFrom::Since | MoveFrom::Check => {
                Ok((self.params.since_head.clone(), self.params.since_work.clone(), self.remote()))
            }
        }
    }

    /// The remote the checked-out branch tracks (`branch.<name>.remote`), if any.
    fn tracked_remote(&self) -> Option<String> {
        let branch = self
            .read(&["symbolic-ref", "-q", "HEAD"])
            .and_then(|name| name.strip_prefix("refs/heads/").map(str::to_owned))?;
        self.read(&["config", "--get", &format!("branch.{branch}.remote")])
            .filter(|remote| remote != ".")
    }

    /// The move's remote: the tracked one, else `origin` (module docs).
    fn remote(&self) -> String {
        self.tracked_remote().unwrap_or_else(|| "origin".to_owned())
    }

    /// `remote.<name>.url` as configured: never rewritten by `insteadOf`.
    fn remote_url(&self, remote: &str) -> Option<String> {
        self.read(&["config", "--get", &format!("remote.{remote}.url")])
    }

    /// Where this export names its commits: a move's own record, else the back record.
    fn record_name(&self) -> &'static str {
        if self.params.move_from.is_some() { MOVE_RECORD } else { "refs/cmux-back" }
    }

    /// The folder's record (`refs/cmux-back`, the newer, before
    /// `refs/cmux-seed`) whose WORK is `since_work` and whose HEAD is
    /// `since_head`; None when neither is (then a stash counts as a
    /// change).
    fn record_of_since(&self) -> Option<&'static str> {
        let moving = self.params.move_from.is_some();
        DELTA_RECORDS.into_iter().filter(|record| moving || *record != MOVE_RECORD).find(|record| {
            let read = |name: &str| {
                self.read(&[
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    &format!("{record}/{name}^{{commit}}"),
                ])
            };
            read("work").as_deref() == Some(self.params.since_work.as_str())
                && read("head").as_deref() == Some(self.params.since_head.as_str())
        })
    }

    /// The first submodule (a gitlink in the index, checked out) with
    /// uncommitted changes or untracked files that are not ignored.
    fn dirty_submodule(&self) -> Result<Option<String>, Failure> {
        let staged = self.git(&["ls-files", "-z", "-s"])?;
        for entry in staged.split(|byte| *byte == 0).filter(|entry| !entry.is_empty()) {
            let entry = String::from_utf8_lossy(entry);
            let Some((meta, path)) = entry.split_once('\t') else { continue };
            if !meta.starts_with("160000 ") {
                continue;
            }
            let checkout = self.folder.join(path);
            if !checkout.join(".git").exists() {
                continue;
            }
            let status = self.git.quiet(
                Some(&checkout),
                &Credential::Anonymous,
                &["status", "--porcelain", "--ignore-submodules=none"],
            )?;
            if !status.is_empty() {
                return Ok(Some(path.to_owned()));
            }
        }
        Ok(None)
    }

    /// `refs/cmux-back/*` name exactly this export's commits; the Mac's base
    /// (`since`) stays recorded (module docs).
    fn record(
        &self,
        head: &str,
        index: &str,
        work: &str,
        stash: Option<&str>,
    ) -> Result<(), Failure> {
        if self.params.move_from.is_some() {
            // A move leaves the seed's records as they are (module docs).
            return self.set(
                MOVE_RECORD,
                [
                    ("head", Some(head)),
                    ("index", Some(index)),
                    ("work", Some(work)),
                    ("stash", stash),
                ],
            );
        }
        let read = |record: &str, name: &str| {
            self.read(&["rev-parse", "--verify", "--quiet", &format!("{record}/{name}")])
        };
        match self.record_of_since() {
            // The Mac is on the back record this one replaces: it moves.
            Some("refs/cmux-back") if read("refs/cmux-back", "work").as_deref() != Some(work) => {
                let names = ["head", "index", "work", "stash"];
                let kept = names.map(|name| read("refs/cmux-back", name));
                self.set(BASE_RECORD, names.into_iter().zip(kept.iter().map(Option::as_deref)))?;
            }
            // Already kept, or the back record stays the Mac's base.
            Some("refs/cmux-back" | BASE_RECORD) => {}
            // The Mac is on the seed (or nothing recorded): no other base.
            _ => {
                self.set(BASE_RECORD, ["head", "index", "work", "stash"].map(|name| (name, None)))?;
            }
        }
        self.set(
            "refs/cmux-back",
            [("head", Some(head)), ("index", Some(index)), ("work", Some(work)), ("stash", stash)],
        )
    }

    /// Points `record/<name>` at each sha, deleting the ones with none.
    fn set<'a>(
        &self,
        record: &str,
        refs: impl IntoIterator<Item = (&'a str, Option<&'a str>)>,
    ) -> Result<(), Failure> {
        for (name, sha) in refs {
            let reference = format!("{record}/{name}");
            match sha {
                Some(sha) => {
                    self.git(&["update-ref", &reference, sha])?;
                }
                None => {
                    if self.git(&["rev-parse", "--verify", "--quiet", &reference]).is_ok() {
                        self.git(&["update-ref", "-d", &reference])?;
                    }
                }
            }
        }
        Ok(())
    }

    /// Makes the bundle in a private folder, then writes it at the
    /// requested path. Its size.
    fn bundle(&self, with_stash: bool) -> Result<u64, Failed> {
        let refused = |refusal: SeedRefusal| failed(refusal.code, refusal.message);
        let scratch = place::Scratch::new(&self.job_id()).map_err(refused)?;
        let made = scratch.0.join("back.bundle");
        let made_arg = made.display().to_string();
        let mut args: Vec<String> = vec!["bundle".into(), "create".into(), "-q".into(), made_arg];
        let record = self.record_name();
        for name in ["head", "index", "work"] {
            args.push(format!("{record}/{name}"));
        }
        if with_stash {
            args.push(format!("{record}/stash"));
        }
        let (since_work, since_head) = (&self.params.since_work, &self.params.since_head);
        args.push(format!("^{since_work}"));
        args.push(format!("^{since_head}"));
        // The new INDEX and WORK are siblings of the seed's, not
        // descendants: without their trees excluded too, git would send
        // every unchanged file again.
        let mut trees = vec![since_work.clone(), since_head.clone()];
        if let Some(parent) =
            self.read(&["rev-parse", "--verify", "--quiet", &format!("{since_work}^1")])
        {
            trees.push(parent);
        }
        for commit in trees {
            args.push(format!("^{commit}^{{tree}}"));
        }
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        self.git(&args).map_err(|failure| {
            let code = if failure.disk_full() { "seed.disk_full" } else { "seed.export_failed" };
            failed(code, failure.message())
        })?;
        place::write_output(&self.roots, &self.params.bundle, &made).map_err(refused)
    }

    fn job_id(&self) -> String {
        self.job.id().to_owned()
    }
}

fn failed(code: &'static str, error: impl Into<String>) -> Failed {
    Failed { code, error: error.into(), install_url: None }
}
