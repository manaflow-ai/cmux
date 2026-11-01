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
//! export's WORK once the Mac merged it back).
//!
//! When WORK is `since_work` (HEAD, the index and the working tree are as
//! the seed left them) the answer is `unchanged` and no bundle is written.
//! Ignored files never go (`add -A` skips them), nor do untracked secrets or
//! nested repositories.
//!
//! The answer, once the job is done (`git.seed.status`): `{head_ref, head,
//! index, work, stash, unchanged, bundle_bytes, left_out}`.

use std::path::PathBuf;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};

use super::git::{Credential, Failure, Git};
use super::job::{Failed, Job};
use super::params::check_sha;
use super::snapshot::{self, Snapshot};
use super::{SeedRefusal, place};
use crate::fs_ops::Roots;

#[derive(Deserialize)]
struct Wire {
    folder: String,
    since_work: String,
    since_head: String,
    bundle: String,
}

/// A checked export request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExportParams {
    pub folder: String,
    pub since_work: String,
    pub since_head: String,
    pub bundle: String,
}

impl ExportParams {
    pub fn parse(params: &Value) -> Result<Self, SeedRefusal> {
        let wire: Wire = serde_json::from_value(params.clone())
            .map_err(|error| SeedRefusal::bad_request(format!("invalid params: {error}")))?;
        check_sha("since_work", &wire.since_work)?;
        check_sha("since_head", &wire.since_head)?;
        Ok(Self {
            folder: wire.folder,
            since_work: wire.since_work,
            since_head: wire.since_head,
            bundle: wire.bundle,
        })
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

    pub fn run(self) -> Result<(), Failed> {
        place::recheck(&self.folder).map_err(|refusal| failed(refusal.code, refusal.message))?;
        let wrap = |failure: Failure| {
            let code = if failure.disk_full() { "seed.disk_full" } else { "seed.export_failed" };
            failed(code, failure.message())
        };
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
        let snapshot =
            Snapshot::take(&self.git, &Credential::Anonymous, &self.folder).map_err(wrap)?;
        let commit = |tree: &str, parent: &str, message: &str| {
            snapshot::commit(&self.git, &Credential::Anonymous, &self.folder, tree, parent, message)
        };
        let index = commit(&snapshot.index, &head, snapshot::INDEX_MESSAGE).map_err(wrap)?;
        let work = commit(&snapshot.work, &index, snapshot::WORK_MESSAGE).map_err(wrap)?;
        let stash = self.read(&["rev-parse", "--verify", "--quiet", "refs/stash^{commit}"]);
        // Unchanged only when WORK and the stash are the record's whose WORK
        // is `since_work` (the last seed or export): a stash-only change
        // still needs its objects sent.
        let unchanged = work == self.params.since_work && stash == self.recorded_stash();
        let mut bundle_bytes = 0;
        if !unchanged {
            self.record(&head, &index, &work, stash.as_deref()).map_err(wrap)?;
            bundle_bytes = self.bundle(stash.is_some())?;
        }
        let answer = json!({
            "head_ref": head_ref,
            "head": head,
            "index": index,
            "work": work,
            "stash": stash,
            "unchanged": unchanged,
            "bundle_bytes": bundle_bytes,
            "left_out": snapshot.left_out,
        });
        if let Value::Object(fields) = answer {
            self.job.exported(fields);
        }
        Ok(())
    }

    /// The stash of the folder's record (`refs/cmux-seed/*` or
    /// `refs/cmux-back/*`) whose WORK is `since_work`; None when there is
    /// none. No record also counts as no stash, and a stash then is a change.
    fn recorded_stash(&self) -> Option<String> {
        let record = ["refs/cmux-seed", "refs/cmux-back"].into_iter().find(|record| {
            self.read(&["rev-parse", "--verify", "--quiet", &format!("{record}/work")]).as_deref()
                == Some(self.params.since_work.as_str())
        })?;
        self.read(&["rev-parse", "--verify", "--quiet", &format!("{record}/stash")])
    }

    /// `refs/cmux-back/*` name exactly this export's commits.
    fn record(
        &self,
        head: &str,
        index: &str,
        work: &str,
        stash: Option<&str>,
    ) -> Result<(), Failure> {
        for (name, sha) in
            [("head", Some(head)), ("index", Some(index)), ("work", Some(work)), ("stash", stash)]
        {
            let reference = format!("refs/cmux-back/{name}");
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
        for name in ["head", "index", "work"] {
            args.push(format!("refs/cmux-back/{name}"));
        }
        if with_stash {
            args.push("refs/cmux-back/stash".into());
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
