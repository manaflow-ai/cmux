//! `git.push`: pushes the current (or a named) branch's commit to a branch
//! of the same name on a remote, as the user would with `git push` in a
//! terminal, with their credential helper, SSH agent and pre-push hook. It
//! never force-pushes (the refspec has no `+` and no force flag is passed)
//! and never waits for a password: a remote that needs one the helper cannot
//! give fails with `auth_failed`.
//!
//! The remote is the given one, else where `git push` would go (the
//! branch's `pushRemote`, `remote.pushDefault`, the branch's upstream remote),
//! else `origin`; it must be a configured remote, never a URL, and one
//! without its own push refspecs or mirroring. The exact commit read (and
//! checked against `expected_head`) is what is pushed; the attempt journal
//! keeps it, so a retry after a lost reply pushes that commit again (a
//! no-op the remote reports as up to date) even when the branch moved. With
//! `set_upstream` (the default when the branch has no upstream) the branch
//! then tracks what was pushed.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::Repository;
use super::checkpoint::ledger;
use super::journal::Journal;
use super::mutation::{Target, active_hooks, key, output_extra, refused, run_failed};
use super::user_run::{UserGit, UserRun, deadline};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "git.push";
/// git's exit code for `fatal:` errors: connection, credentials, protocol.
const FATAL_EXIT: i32 = 128;

/// A started push, as the journal keeps it.
#[derive(Debug, Serialize, Deserialize)]
struct Attempt {
    branch: String,
    tip: String,
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let key = key(request);
    let deadline = deadline();
    let target = Target::resolve(mux, request, OPERATION)?;
    let fingerprint = target.fingerprint(request);
    target.exclusive(OPERATION, || {
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let repository = &target.repository;
        let git = UserGit { root: &repository.root, deadline };
        let journal = Journal::open(mux, &target.identity(), &key, OPERATION)?;
        let attempt = match journal.attempt::<Attempt>(&fingerprint) {
            Some(attempt) => attempt,
            None => {
                let attempt = read_tip(repository, &request.fields)?;
                journal.start(&fingerprint, &attempt)?;
                attempt
            }
        };
        match push(repository, &git, &request.fields, &attempt) {
            Ok(value) => {
                let reply = ledger::commit(mux, &key, OPERATION, &fingerprint, &value, false)?;
                journal.finish();
                Ok(reply)
            }
            Err(error) => {
                // A push stopped by the deadline may have reached the
                // remote: its retry pushes the same commit.
                if error.details["reason"] != "timed_out" {
                    journal.finish();
                }
                Err(error)
            }
        }
    })
}

/// The branch and the commit to push, checked against `expected_head`.
fn read_tip(
    repository: &Repository,
    fields: &Map<String, Value>,
) -> Result<Attempt, ResourceError> {
    let text = |name: &str| fields.get(name).and_then(Value::as_str).map(str::to_string);
    let branch = match text("branch") {
        Some(branch) => {
            valid_branch(repository, &branch)?;
            branch
        }
        None => current_branch(repository).ok_or_else(|| {
            refused(OPERATION, "detached_head", "HEAD is not on a branch", Value::Null)
        })?,
    };
    let Some(tip) = repository.commit(&format!("refs/heads/{branch}")) else {
        let message = format!("the branch {branch} has no commit");
        return Err(refused(OPERATION, "branch_not_found", message, json!({"branch": branch})));
    };
    if let Some(expected) = text("expected_head")
        && expected != tip
    {
        let message = "the branch moved since the caller read it";
        let extra = json!({"expected_head": expected, "head": tip});
        return Err(refused(OPERATION, "head_moved", message, extra));
    }
    Ok(Attempt { branch, tip })
}

fn push(
    repository: &Repository,
    git: &UserGit<'_>,
    fields: &Map<String, Value>,
    attempt: &Attempt,
) -> Result<Value, ResourceError> {
    let Attempt { branch, tip } = attempt;
    let remotes = config_lines(git, &["remote"]);
    let config = |name: String| config_lines(git, &["config", "--get", &name]).pop();
    let upstream_remote = config(format!("branch.{branch}.remote"));
    let remote = fields
        .get("remote")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| config(format!("branch.{branch}.pushRemote")))
        .or_else(|| config("remote.pushDefault".to_string()))
        .or_else(|| upstream_remote.clone())
        .unwrap_or_else(|| "origin".to_string());
    if !remotes.contains(&remote) {
        let message = if remotes.is_empty() {
            "the repository has no remote to push to".to_string()
        } else {
            format!("there is no remote named {remote}")
        };
        return Err(refused(OPERATION, "no_remote", message, json!({"remote": remote})));
    }
    refuse_special_remote(git, &remote)?;
    let destination = format!("refs/heads/{branch}");
    let tracked = upstream_remote.is_some() && config(format!("branch.{branch}.merge")).is_some();
    let set_upstream = fields.get("set_upstream").and_then(Value::as_bool).unwrap_or(!tracked);
    let refspec = format!("{tip}:{destination}");
    let command = ["push", "--porcelain", "--", remote.as_str(), refspec.as_str()];
    let run = git.run(&command).map_err(|failure| run_failed(OPERATION, &failure))?;
    let stdout = String::from_utf8_lossy(&run.stdout).into_owned();
    let suffix = format!(":{destination}");
    let line = stdout
        .lines()
        .find(|line| line.split('\t').nth(1).is_some_and(|spec| spec.ends_with(&suffix)));
    let Some(line) = line.filter(|line| run.success && !line.starts_with('!')) else {
        return Err(classified(&git.for_classification(), line, &run));
    };
    let mut parts = line.split('\t');
    let flag = parts.next().unwrap_or_default();
    let summary = parts.nth(1).unwrap_or_default();
    let created_upstream = set_upstream && track(git, branch, &remote, &destination)?;
    let mut value = json!({
        "root": repository.root.to_string_lossy(),
        "remote": remote,
        "branch": branch,
        "upstream": format!("{remote}/{branch}"),
        "pushed_commit": tip,
        "created_upstream": created_upstream,
        "up_to_date": flag == "=",
    });
    if let Some((previous, _)) = summary.split_once("..")
        && let Some(previous) = repository.commit(previous)
    {
        value["previous_remote_commit"] = json!(previous);
    }
    Ok(value)
}

/// Refuses a remote whose config changes what a push sends: its own push
/// refspecs, or mirroring.
fn refuse_special_remote(git: &UserGit<'_>, remote: &str) -> Result<(), ResourceError> {
    let refspecs = config_lines(git, &["config", "--get-all", &format!("remote.{remote}.push")]);
    if !refspecs.is_empty() {
        let message = format!("remote {remote} has its own push refspecs; push it in a terminal");
        let extra = json!({"remote": remote, "refspecs": refspecs});
        return Err(refused(OPERATION, "push_refspec_configured", message, extra));
    }
    let mirror =
        config_lines(git, &["config", "--type=bool", "--get", &format!("remote.{remote}.mirror")]);
    if mirror.first().is_some_and(|value| value == "true") {
        let message = format!("remote {remote} is a mirror; push it in a terminal");
        return Err(refused(OPERATION, "mirror_remote", message, json!({"remote": remote})));
    }
    Ok(())
}

/// Refuses a branch name git would not accept, so it never reaches a
/// refspec.
fn valid_branch(repository: &Repository, branch: &str) -> Result<(), ResourceError> {
    let reference = format!("refs/heads/{branch}");
    let valid = !branch.starts_with('-')
        && repository.run(&["check-ref-format", reference.as_str()], 1024).is_ok();
    if valid {
        return Ok(());
    }
    Err(ResourceError::validation_invalid(
        Some("branch"),
        format!("{branch:?} is not a branch name"),
    ))
}

fn current_branch(repository: &Repository) -> Option<String> {
    let output = repository.run(&["symbolic-ref", "--quiet", "--short", "HEAD"], 4096).ok()?;
    let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!branch.is_empty()).then_some(branch)
}

/// Makes `branch` track `destination` on `remote`, as `--set-upstream`
/// would; `true` when that changed its upstream.
fn track(
    git: &UserGit<'_>,
    branch: &str,
    remote: &str,
    destination: &str,
) -> Result<bool, ResourceError> {
    let settings = [
        (format!("branch.{branch}.remote"), remote),
        (format!("branch.{branch}.merge"), destination),
    ];
    let mut changed = false;
    for (name, value) in &settings {
        if config_lines(git, &["config", "--get", name]).pop().as_deref() == Some(*value) {
            continue;
        }
        let run = git
            .run(&["config", name.as_str(), *value])
            .map_err(|failure| run_failed(OPERATION, &failure))?;
        if !run.success {
            let message = "the push succeeded, but the branch's upstream could not be set";
            return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
        }
        changed = true;
    }
    Ok(changed)
}

/// Non-empty output lines of a git query in the user's environment, so
/// their config (includes, conditional includes) applies.
fn config_lines(git: &UserGit<'_>, arguments: &[&str]) -> Vec<String> {
    let Ok(run) = git.run(arguments) else { return Vec::new() };
    if !run.success {
        return Vec::new();
    }
    String::from_utf8_lossy(&run.stdout)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect()
}

/// A failed push's machine reason. The remote's verdict on the ref comes
/// first. Without one, a push that ended without git's fatal exit while a
/// pre-push hook is installed was refused by the hook, whatever it printed;
/// otherwise git's own `fatal:`, `ssh:` and `remote:` lines (and ssh's
/// known refusals) say whether credentials or the network failed.
fn classified(git: &UserGit<'_>, line: Option<&str>, run: &UserRun) -> ResourceError {
    let summary = line.and_then(|line| line.split('\t').nth(2)).unwrap_or_default();
    let output = run.output();
    let rejected = line.is_some_and(|line| line.starts_with('!'));
    let diagnostics = run
        .stderr
        .lines()
        .map(str::trim)
        .filter(|line| {
            ["fatal:", "ssh:", "remote:"].iter().any(|prefix| line.starts_with(prefix))
                || line.contains("Permission denied (")
                || line.starts_with("Host key verification failed")
        })
        .map(str::to_lowercase)
        .collect::<Vec<_>>()
        .join("\n");
    let mentions = |patterns: &[&str]| patterns.iter().any(|pattern| diagnostics.contains(pattern));
    let (reason, message) = if rejected
        && (summary.contains("non-fast-forward")
            || summary.contains("fetch first")
            || summary.contains("stale info"))
    {
        ("rejected_non_fast_forward", "the remote has commits this branch does not; pull first")
    } else if rejected {
        ("rejected_by_remote", "the remote refused the push")
    } else if line.is_none()
        && run.code != Some(FATAL_EXIT)
        && !active_hooks(git, &["pre-push"]).is_empty()
    {
        ("hook_failed", "the pre-push hook refused the push; its output says why")
    } else if mentions(&[
        "authentication failed",
        "permission denied",
        "could not read username",
        "could not read password",
        "terminal prompts disabled",
        "host key verification failed",
        "invalid username or password",
        "returned error: 401",
        "returned error: 403",
    ]) {
        ("auth_failed", "the remote did not accept the credentials git has")
    } else if mentions(&[
        "could not resolve host",
        "could not resolve hostname",
        "connection refused",
        "connection timed out",
        "operation timed out",
        "network is unreachable",
        "no route to host",
        "failed to connect",
        "connection reset",
        "unable to access",
    ]) {
        ("network_failed", "the remote could not be reached")
    } else {
        ("git_failed", "git did not push; its output says why")
    };
    let mut extra = output_extra(&format!("{summary}\n{output}"));
    if !summary.is_empty() {
        extra["ref_status"] = json!(summary);
    }
    refused(OPERATION, reason, message, extra)
}
