//! A pull request's failing checks or unresolved review comments, as a message for its chat's
//! agent (`_acpmux/pr_feedback`, the Changes row's "Fix failing checks" and "Send review
//! comments", and `acpmux pr-feedback`). The answer's `draft` goes into the composer as typed
//! text: nothing here sends it.
//!
//! - Only the reds that are the branch's own: a check that also fails at the base branch's tip
//!   is left out and counted (`classify.rs`, the classifier the app's Changes row dims them by).
//! - Each own red of an Actions job gets its first failed step and the end of its log, where it
//!   failed (`draft::log_tail`): at most `MAX_LOGS` jobs, two REST reads each, kept on disk once
//!   the job finished (a finished job's log does not change).
//! - Everything else is one GraphQL read (head and base rollups and the review threads), kept
//!   `FRESH_S` for whoever asks next, so both menu items, a second window and the CLI cost one.
//! - It shares `acpmux pr-wait`'s per-machine state (`cli/pr_wait.rs`), never a second poller:
//!   the same folder and key, the key's lock while it reads, and the same rate-limit pause. A
//!   limit pr-wait's poller hit holds this read back until the reset, and a limit this read hits
//!   pauses the poller too. It reads only when asked, and never loops.

mod classify;
mod draft;
#[cfg(test)]
mod tests;

use crate::acpmux_mcp::pr::{self, Target};
use crate::cli::pr_wait::{self, Ctx, Keep};
use cmux_file_lock::{FileLock, Kind as LockKind, LockError};
use draft::{Comment, Pr, Red, Thread};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long one GraphQL answer serves the next ask.
const FRESH_S: u64 = 20;
/// Own reds whose job log is read; the rest are named with their link.
const MAX_LOGS: usize = 5;
/// The whole read's bound, under the page's request timeout.
const DEADLINE: Duration = Duration::from_secs(50);
/// How long an ask waits for another one reading the same pull request.
const LOCK_WAIT: Duration = Duration::from_secs(20);
/// Job tails older than this are removed when a new one is kept.
const JOB_KEEP_S: u64 = 7 * 24 * 3600;

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum Kind {
    /// The failing checks of the branch's own.
    Checks,
    /// The unresolved review threads.
    Comments,
}

impl Kind {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "checks" => Some(Self::Checks),
            "comments" => Some(Self::Comments),
            _ => None,
        }
    }
    fn as_str(self) -> &'static str {
        match self {
            Self::Checks => "checks",
            Self::Comments => "comments",
        }
    }
}

const CONTEXTS: &str = "contexts(first: 100) { nodes { __typename \
... on CheckRun { databaseId name status conclusion \
checkSuite { workflowRun { databaseId event workflow { databaseId name } } } } \
... on StatusContext { context state description } } }";

fn query() -> String {
    format!(
        "query($owner: String!, $name: String!, $number: Int!) {{ repository(owner: $owner, name: $name) \
{{ pullRequest(number: $number) {{ url number state headRefOid baseRefName \
commits(last: 1) {{ nodes {{ commit {{ statusCheckRollup {{ {CONTEXTS} }} }} }} }} \
baseRef {{ target {{ ... on Commit {{ statusCheckRollup {{ {CONTEXTS} }} }} }} }} \
reviewThreads(first: 100) {{ nodes {{ isResolved isOutdated path line originalLine \
comments(first: 20) {{ nodes {{ author {{ login }} body url }} }} }} }} }} }} }}"
    )
}

/// The context the hub and the CLI read with: pr-wait's folder and the `gh` on PATH.
pub fn ctx() -> Result<Ctx, String> {
    Ok(Ctx { dir: pr_wait::state_dir().map_err(|e| e.to_string())?, gh: "gh".into() })
}

/// `OWNER/REPO` of `cwd`'s origin.
fn repo_of_folder(cwd: Option<&Path>) -> Option<String> {
    let mut git = cmux_process::Command::new("git");
    if let Some(cwd) = cwd {
        git.arg("-C").arg(cwd);
    }
    let out = git
        .args(["config", "--get", "remote.origin.url"])
        .stderr(cmux_process::Stdio::null())
        .output()
        .ok()?;
    pr_wait::repo_of_remote(&String::from_utf8_lossy(&out.stdout))
}

/// What a failed `gh` said, shortened, with the limit's reset when it was one.
fn gh_error(stderr: &str) -> String {
    format!("gh: {}", stderr.lines().last().unwrap_or(stderr).trim())
}

/// The key's shared state says GitHub refused for a limit until a time still ahead.
fn paused(shared: &pr_wait::Shared, now: u64) -> Option<u64> {
    let limited = shared.error.as_deref().and_then(pr_wait::rate_limited).is_some();
    (limited && shared.retry_at > now).then_some(shared.retry_at)
}

struct Paths {
    state: PathBuf,
    lock: PathBuf,
    answer: PathBuf,
}

/// The newest GraphQL answer for the key, read now unless one younger than `FRESH_S` is kept.
fn read_pull(
    ctx: &Ctx,
    repo: &str,
    number: &str,
    paths: &Paths,
    deadline: Instant,
) -> Result<Value, String> {
    let kept = |now: u64| -> Option<Value> {
        let v: Value = serde_json::from_slice(&std::fs::read(&paths.answer).ok()?).ok()?;
        let at = v.get("at")?.as_u64()?;
        (now.saturating_sub(at) < FRESH_S).then(|| v.get("data").cloned()).flatten()
    };
    if let Some(data) = kept(pr_wait::now_s()) {
        return Ok(data);
    }
    let open = || {
        std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&paths.lock)
            .map_err(|e| e.to_string())
    };
    let wait_until = Instant::now() + LOCK_WAIT;
    let _held = loop {
        match FileLock::try_take(open()?, LockKind::Exclusive) {
            Ok(held) => break Some(held),
            Err(LockError::Busy(_)) if Instant::now() < wait_until => {
                std::thread::sleep(pr_wait::LOCK_BUSY_STEP);
                // Whoever holds it may be reading this very pull request.
                if let Some(data) = kept(pr_wait::now_s()) {
                    return Ok(data);
                }
            }
            // Past the wait, read without it: an answer late by one read beats none.
            Err(LockError::Busy(_)) => break None,
            Err(LockError::Io(e)) => return Err(e.to_string()),
        }
    };
    let now = pr_wait::now_s();
    if let Some(data) = kept(now) {
        return Ok(data);
    }
    let mut shared = pr_wait::read_shared(&paths.state);
    if let Some(at) = paused(&shared, now) {
        return Err(format!(
            "GitHub's rate limit is spent; acpmux reads again in {}s (shared with acpmux pr-wait)",
            at - now
        ));
    }
    let (owner, name) = repo.split_once('/').ok_or("repo must be OWNER/REPO")?;
    let q = query();
    let args = [
        "api",
        "graphql",
        "-f",
        &format!("query={q}"),
        "-F",
        &format!("owner={owner}"),
        "-F",
        &format!("name={name}"),
        "-F",
        &format!("number={number}"),
    ];
    match pr_wait::gh_keeping(ctx, &args, deadline, Keep::Head).map_err(|e| e.to_string())? {
        Ok(out) => {
            let v: Value = serde_json::from_slice(&out)
                .map_err(|e| format!("gh api graphql gave no JSON: {e}"))?;
            let data = v.get("data").cloned().unwrap_or(Value::Null);
            if data.pointer("/repository/pullRequest").is_none_or(Value::is_null) {
                let why =
                    v.pointer("/errors/0/message").and_then(Value::as_str).unwrap_or("not found");
                return Err(format!("{repo}#{number}: {why}"));
            }
            let kept = json!({"at": now, "data": data});
            let tmp = paths.answer.with_extension(format!("tmp{}", std::process::id()));
            if std::fs::write(&tmp, kept.to_string()).is_ok() {
                let _ = std::fs::rename(&tmp, &paths.answer);
            }
            Ok(data)
        }
        Err(stderr) => {
            if let Some(secondary) = pr_wait::rate_limited(&stderr) {
                // The poller's own rule: pause every reader of this key until the reset.
                shared.retry_at = if secondary {
                    now + 120
                } else {
                    pr_wait::limit_reset(ctx, deadline)
                        .map_or(now + pr_wait::LIMIT_FALLBACK_S, |r| r.max(now) + 5)
                };
                shared.error = Some(stderr.clone());
                let _ = pr_wait::write_shared(&paths.state, &shared);
            }
            Err(gh_error(&stderr))
        }
    }
}

/// An Actions check run's workflow run and job ids (a check run's id is its job's). None for a
/// commit status or another app's check, which has no job log. Ids, not `detailsUrl`: the link is
/// built from them, and a broker that allows only some GraphQL fields still answers.
fn actions_job(check: &Value) -> Option<(i64, i64)> {
    let run = check.pointer("/checkSuite/workflowRun/databaseId")?.as_i64()?;
    let id = check.get("databaseId")?.as_i64()?;
    Some((run, id))
}

/// A job's first failed step and its log's end: kept on disk once the job finished.
fn job_tail(
    ctx: &Ctx,
    repo: &str,
    id: i64,
    deadline: Instant,
) -> Result<(Option<String>, String), String> {
    let dir = ctx.dir.join("jobs");
    let file = dir.join(format!("{}__{id}.json", pr_wait::key(repo, "").trim_end_matches('_')));
    if let Some(v) =
        std::fs::read(&file).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())
    {
        let step = v.get("step").and_then(Value::as_str).map(str::to_owned);
        if let Some(tail) = v.get("tail").and_then(Value::as_str) {
            return Ok((step, tail.to_owned()));
        }
    }
    let job_path = format!("repos/{repo}/actions/jobs/{id}");
    let job: Value = match pr_wait::gh_keeping(ctx, &["api", &job_path], deadline, Keep::Head)
        .map_err(|e| e.to_string())?
    {
        Ok(out) => serde_json::from_slice(&out).map_err(|e| e.to_string())?,
        Err(stderr) => return Err(gh_error(&stderr)),
    };
    let step = job.get("steps").and_then(Value::as_array).and_then(|steps| {
        steps
            .iter()
            .find(|s| s.get("conclusion").and_then(Value::as_str) == Some("failure"))
            .and_then(|s| s.get("name").and_then(Value::as_str).map(str::to_owned))
    });
    let log_path = format!("{job_path}/logs");
    let log = match pr_wait::gh_keeping(ctx, &["api", &log_path], deadline, Keep::Tail)
        .map_err(|e| e.to_string())?
    {
        Ok(out) => String::from_utf8_lossy(&out).into_owned(),
        Err(stderr) => return Err(gh_error(&stderr)),
    };
    let tail = draft::log_tail(&log);
    if job.get("status").and_then(Value::as_str) == Some("completed") {
        keep_job(&dir, &file, &json!({"step": step, "tail": tail}));
    }
    Ok((step, tail))
}

/// Writes one job's tail, and removes those older than `JOB_KEEP_S`.
fn keep_job(dir: &Path, file: &Path, v: &Value) {
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    if let Ok(entries) = std::fs::read_dir(dir) {
        let old = std::time::SystemTime::now() - Duration::from_secs(JOB_KEEP_S);
        for entry in entries.flatten() {
            if entry.metadata().and_then(|m| m.modified()).is_ok_and(|t| t < old) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    let _ = std::fs::write(file, v.to_string());
}

fn rollup<'a>(node: &'a Value, pointer: &str) -> &'a [Value] {
    node.pointer(pointer).and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

/// The reds of the branch's own, each with its step and log tail where one can be read.
fn reds(ctx: &Ctx, repo: &str, own: &[&Value], deadline: Instant) -> Vec<Red> {
    let mut logs = 0;
    own.iter()
        .map(|check| {
            let job = actions_job(check);
            let mut red = Red {
                name: classify::name(check),
                workflow: classify::workflow_name(check),
                url: job.map(|(run, id)| {
                    format!("https://github.com/{repo}/actions/runs/{run}/job/{id}")
                }),
                ..Red::default()
            };
            match job.map(|(_, id)| id) {
                Some(_) if logs >= MAX_LOGS => {
                    red.log_note = Some(format!("log not read: only the first {MAX_LOGS} are"));
                }
                Some(id) => {
                    logs += 1;
                    match job_tail(ctx, repo, id, deadline) {
                        Ok((step, tail)) => {
                            red.step = step;
                            red.log_tail = Some(tail);
                        }
                        Err(e) => red.log_note = Some(format!("log not read: {e}")),
                    }
                }
                None => {
                    let said = check.get("description").and_then(Value::as_str).unwrap_or_default();
                    red.log_note = Some(if said.is_empty() {
                        "no job log: not a GitHub Actions job".to_owned()
                    } else {
                        format!("it says: {said}")
                    });
                }
            }
            red
        })
        .collect()
}

fn threads(node: &Value) -> (Vec<Thread>, usize) {
    let all = rollup(node, "/reviewThreads/nodes");
    let resolved =
        all.iter().filter(|t| t.get("isResolved").and_then(Value::as_bool) == Some(true)).count();
    let open = all
        .iter()
        .filter(|t| t.get("isResolved").and_then(Value::as_bool) != Some(true))
        .map(|t| {
            let comments = rollup(t, "/comments/nodes");
            Thread {
                path: t.get("path").and_then(Value::as_str).map(str::to_owned),
                line: t
                    .get("line")
                    .and_then(Value::as_u64)
                    .or_else(|| t.get("originalLine").and_then(Value::as_u64)),
                url: comments
                    .first()
                    .and_then(|c| c.get("url"))
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                outdated: t.get("isOutdated").and_then(Value::as_bool) == Some(true),
                comments: comments
                    .iter()
                    .map(|c| Comment {
                        author: c
                            .pointer("/author/login")
                            .and_then(Value::as_str)
                            .unwrap_or("ghost")
                            .to_owned(),
                        body: c.get("body").and_then(Value::as_str).unwrap_or_default().to_owned(),
                    })
                    .collect(),
            }
        })
        .collect();
    (open, resolved)
}

/// The answer for `kind` from one GraphQL `pullRequest` node, the job tails read through `ctx`.
fn answer(ctx: &Ctx, repo: &str, node: &Value, kind: Kind, deadline: Instant) -> Value {
    let text = |k: &str| node.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let pr = Pr {
        repo: repo.to_owned(),
        number: node.get("number").and_then(Value::as_u64).unwrap_or_default(),
        head: text("headRefOid"),
        base: text("baseRefName"),
    };
    let mut out = json!({
        "kind": kind.as_str(),
        "pr": {"url": text("url"), "number": pr.number, "repo": repo, "head": pr.head, "base": pr.base,
               "state": text("state").to_lowercase()},
    });
    let (draft, detail) = match kind {
        Kind::Checks => {
            let head = rollup(node, "/commits/nodes/0/commit/statusCheckRollup/contexts/nodes");
            let base = rollup(node, "/baseRef/target/statusCheckRollup/contexts/nodes");
            let split = classify::split(head, base);
            let on_base: Vec<String> = split.on_base.iter().map(|c| classify::name(c)).collect();
            let own = reds(ctx, repo, &split.own, deadline);
            let draft = draft::checks(&pr, &own, &on_base, split.pending)
                .ok_or_else(|| draft::no_reds(&pr, &on_base, split.pending));
            (draft, json!({"own": own, "onBase": on_base, "pending": split.pending}))
        }
        Kind::Comments => {
            let (open, resolved) = threads(node);
            let draft = draft::comments(&pr, &open, resolved)
                .ok_or_else(|| draft::no_comments(&pr, resolved));
            (draft, json!({"threads": open, "resolved": resolved}))
        }
    };
    if let Some(obj) = out.as_object_mut() {
        let empty = draft.is_err();
        obj.insert("draft".into(), json!(draft.unwrap_or_else(|e| e)));
        obj.insert("empty".into(), json!(empty));
        obj.insert(kind.as_str().into(), detail);
    }
    out
}

/// Reads and answers, blocking: run it off the async runtime. `pr` is a number, `#number` or a
/// URL; `repo` (or the URL's, or `cwd`'s origin) names the repository.
pub fn fetch(
    ctx: &Ctx,
    cwd: Option<&Path>,
    pr: &str,
    repo: Option<&str>,
    kind: Kind,
) -> Result<Value, String> {
    let deadline = Instant::now() + DEADLINE;
    let Target { selector, repo: named } = pr::target(&json!({"pr": pr, "repo": repo}))?;
    let repo = named
        .or_else(|| repo_of_folder(cwd))
        .ok_or("no GitHub origin in the chat's folder: name the pull request by its URL")?;
    std::fs::create_dir_all(&ctx.dir).map_err(|e| format!("create {}: {e}", ctx.dir.display()))?;
    let key = pr_wait::key(&repo, &selector);
    let paths = Paths {
        state: ctx.dir.join(format!("{key}.json")),
        lock: ctx.dir.join(format!("{key}.lock")),
        answer: ctx.dir.join(format!("{key}.feedback.json")),
    };
    let data = read_pull(ctx, &repo, &selector, &paths, deadline)?;
    let node = data.pointer("/repository/pullRequest").cloned().unwrap_or(Value::Null);
    Ok(answer(ctx, &repo, &node, kind, deadline))
}
