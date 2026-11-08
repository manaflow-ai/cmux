//! Part of `Hub`; see `hub/mod.rs`. Building an approved plan somewhere other than its own chat
//! (Leo, 2026-11-08: "esp valuable things that people would think \"wow this is awesome\""):
//! the plan approval card's Build here, Build in a new worktree, and Build on two agents and
//! compare (`server/plan_build.rs` serves the methods).
//!
//! - `here` answers the plan approval with its allow, as Approve plan does.
//! - `worktree` and `compare` start sub-sessions of the plan's chat (`subsessions.rs`), each in a
//!   new git worktree (`subsession_worktree.rs`), with the plan as its first prompt: one in the
//!   chat's harness, or one per harness (the chat's and the other of Claude and Codex unless the
//!   caller names them). Only once one started is the approval answered, with its reject, so the
//!   plan's own chat stops instead of building it too and stays free. A start the sub-session
//!   limits refuse leaves the card waiting, and says why.
//! - The plan text is the pending ask's own (`pending_plan`): a caller never supplies it.
//! - Each build is tagged [`BUILD_TAG`] with its build id, so `compare` and `keep` find a
//!   build's sessions after a restart. The plan's chat gets a `mux` record of kind
//!   [`RECORD_KIND`]: `{event: "started", buildId, target, permissionId, builds, failed}` once,
//!   and `{event: "kept", buildId, keptSessionId, archived}` when one is kept.
//! - `compare` reads each build's change against where its branch left its base (`git merge-base`)
//!   in its worktree: committed and uncommitted, untracked files counted whole, off the runtime
//!   with git that runs nothing the repository names (`subsession_worktree::git_by`).
//! - `keep` archives every other build's chat (the `archived` tag, as the sidebar's Archive). Its
//!   worktree and branch stay: worktree care archives a quiet worktree before it removes one
//!   (`worktree_care.rs`), so no unpushed work is deleted here.

use super::{Hub, Session};
use crate::rpc::RpcError;
use crate::store::SessionStatus;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The `mux` record kind on the plan's chat.
pub const RECORD_KIND: &str = "plan_build";
/// The tag on each build's session: its build id.
pub const BUILD_TAG: &str = "planBuild";
/// The tag on the kept build: when it was kept.
pub const KEPT_TAG: &str = "planBuildKept";
/// The tag on each build: the branch its worktree was made from.
pub const BASE_TAG: &str = "planBuildBase";
/// The tag the chat lists hide a session by (`server/requests.rs` `ARCHIVED_TAG`).
pub(crate) const ARCHIVED_TAG: &str = "archived";
/// Most harnesses one compare starts: the card offers two.
pub const MAX_COMPARE: usize = 3;
/// Most files a build's change lists; its totals count them all.
const MAX_FILES: usize = 200;
/// The longest one build's git read takes before it is given up.
const GIT_LIMIT: Duration = Duration::from_secs(10);
/// An untracked file larger than this counts as one line: its lines are not read.
const MAX_UNTRACKED_BYTES: u64 = 1 << 20;

/// Where an approved plan is built.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Here,
    Worktree,
    Compare,
}

impl Target {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "here" => Some(Self::Here),
            "worktree" => Some(Self::Worktree),
            "compare" => Some(Self::Compare),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Here => "here",
            Self::Worktree => "worktree",
            Self::Compare => "compare",
        }
    }
}

fn refused(reason: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message.into()).with_data(json!({"reason": reason}))
}

/// The plan an ask approves, as the card reads it (webviews `direct.ts` `permissionPlan`): one
/// acpmux attached (`_meta.acpmux.plan.markdown`), else for Claude Code's ExitPlanMode or a
/// `switch_mode` ask its input's `plan`, else its text content. None for any other ask.
pub(crate) fn plan_of(request: &Value) -> Option<String> {
    let tool = request.get("toolCall")?;
    let text = |v: Option<&Value>| {
        v.and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty()).map(str::to_owned)
    };
    if let Some(attached) = text(tool.pointer("/_meta/acpmux/plan/markdown")) {
        return Some(attached);
    }
    let exit_plan = tool.pointer("/_meta/claude/tool").and_then(Value::as_str) == Some("ExitPlanMode");
    if !exit_plan && tool.get("kind").and_then(Value::as_str) != Some("switch_mode") {
        return None;
    }
    if let Some(input) = text(tool.pointer("/rawInput/plan")) {
        return Some(input);
    }
    let parts: Vec<&str> = tool
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|c| c.get("type").and_then(Value::as_str) == Some("content"))
        .filter_map(|c| c.pointer("/content/text").and_then(Value::as_str))
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .collect();
    Some(parts.join("\n\n")).filter(|t| !t.is_empty())
}

/// The first option of `kind` an ask offers.
pub(crate) fn option_of(request: &Value, kind: &str) -> Option<String> {
    request
        .get("options")?
        .as_array()?
        .iter()
        .find(|o| o.get("kind").and_then(Value::as_str) == Some(kind))
        .and_then(|o| o.get("optionId").and_then(Value::as_str))
        .map(str::to_owned)
}

/// The harnesses a compare runs when the caller names none: the chat's, then the other of
/// Claude and Codex.
pub(crate) fn compare_harnesses(chat: &str) -> Vec<String> {
    let other = if chat == "claude" || chat.starts_with("claude-") { "codex" } else { "claude" };
    vec![chat.to_owned(), other.to_owned()]
}

/// The first prompt of a build: the plan, and where the build runs.
pub(crate) fn build_prompt(plan: &str, chat_name: &str, target: Target) -> String {
    let compared = if target == Target::Compare {
        " Another agent builds the same plan in a worktree of its own; the person compares the two and keeps one."
    } else {
        ""
    };
    format!(
        "Build this plan, approved in the chat \"{chat_name}\". You work in a new git worktree on a branch of your own.{compared} Commit your work on that branch when it is done.\n\n{plan}"
    )
}

/// One build's change against its base: totals and the first [`MAX_FILES`] files.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Change {
    pub added: u64,
    pub removed: u64,
    pub files: Vec<(String, u64, u64)>,
    pub more: usize,
}

impl Change {
    fn push(&mut self, path: String, added: u64, removed: u64) {
        self.added += added;
        self.removed += removed;
        if self.files.len() < MAX_FILES {
            self.files.push((path, added, removed));
        } else {
            self.more += 1;
        }
    }

    fn to_value(&self) -> Value {
        let files: Vec<Value> = self
            .files
            .iter()
            .map(|(path, added, removed)| json!({"path": path, "added": added, "removed": removed}))
            .collect();
        json!({"added": self.added, "removed": self.removed, "files": files, "moreFiles": self.more})
    }
}

/// `git diff --numstat` lines into a change (a binary file's `-` counts as 0).
pub(crate) fn parse_numstat(text: &str, change: &mut Change) {
    for line in text.lines() {
        let mut parts = line.splitn(3, '\t');
        let (Some(a), Some(r), Some(path)) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        change.push(path.to_owned(), a.parse().unwrap_or(0), r.parse().unwrap_or(0));
    }
}

/// The change in the worktree at `root` since it left `base`: committed and uncommitted
/// against their merge base, then each untracked file's lines.
fn read_change(root: &Path, base: &str) -> Result<Change, String> {
    use crate::subsession_worktree::git_by;
    let by = Instant::now() + GIT_LIMIT;
    let from = git_by(root, &["merge-base", "HEAD", base], by)
        .or_else(|_| git_by(root, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], by))?;
    if from.is_empty() || from.starts_with('-') {
        return Err("no commit to compare against".into());
    }
    let mut change = Change::default();
    let numstat = git_by(root, &["diff", "--numstat", "--no-renames", &from, "--"], by)?;
    parse_numstat(&numstat, &mut change);
    let untracked = git_by(root, &["ls-files", "--others", "--exclude-standard", "-z"], by)?;
    for path in untracked.split('\0').filter(|p| !p.is_empty()) {
        let full = root.join(path);
        let lines = match std::fs::symlink_metadata(&full) {
            Ok(meta) if meta.is_file() && meta.len() <= MAX_UNTRACKED_BYTES => std::fs::read(&full)
                .map(|bytes| bytecount_lines(&bytes))
                .unwrap_or(0),
            Ok(_) => 1,
            Err(_) => 0,
        };
        change.push(path.to_owned(), lines, 0);
    }
    Ok(change)
}

/// Lines in a file: newlines, and one more when the last line has none.
fn bytecount_lines(bytes: &[u8]) -> u64 {
    let newlines = bytes.iter().filter(|b| **b == b'\n').count() as u64;
    newlines + u64::from(bytes.last().is_some_and(|b| *b != b'\n'))
}

/// The status a build shows: working while its harness runs a turn or waits on an answer.
fn build_status(status: SessionStatus) -> &'static str {
    match status {
        SessionStatus::Running | SessionStatus::Waiting => "working",
        SessionStatus::Disconnected => "failed",
        SessionStatus::Closed => "closed",
        SessionStatus::Idle | SessionStatus::Ready => "done",
    }
}

impl Hub {
    /// The plan of `session`'s pending ask `permission_id`, with the ask itself.
    pub(crate) fn pending_plan(
        &self,
        session: &Session,
        permission_id: &str,
    ) -> Result<(String, Value), RpcError> {
        let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        let pending = state.pending.get(permission_id).ok_or_else(|| {
            refused("plan_build.not_pending", "that plan approval is no longer waiting for an answer")
        })?;
        let plan = plan_of(&pending.request)
            .ok_or_else(|| refused("plan_build.not_plan", "that ask is not a plan approval"))?;
        Ok((plan, pending.request.clone()))
    }

    /// The sessions of build `build_id` started from `parent`, oldest first.
    fn plan_builds(&self, parent: &str, build_id: &str) -> Vec<Arc<Session>> {
        let mut builds: Vec<(u64, Arc<Session>)> = self
            .sessions()
            .into_iter()
            .filter_map(|s| {
                let m = s.meta.lock().unwrap_or_else(|e| e.into_inner());
                let ours = m.subsession.as_ref().is_some_and(|l| l.started_by == parent)
                    && m.tags.get(BUILD_TAG).is_some_and(|t| t.value == build_id);
                let created = m.created_at;
                drop(m);
                ours.then_some((created, s))
            })
            .collect();
        builds.sort_by_key(|(created, _)| *created);
        builds.into_iter().map(|(_, s)| s).collect()
    }

    /// Starts the builds of `plan` from `parent` (`worktree`: one, `compare`: one per harness),
    /// each tagged with `build_id`. The starts that failed come back as `{harness, error}`.
    pub(crate) async fn start_plan_builds(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        plan: &str,
        target: Target,
        harnesses: &[String],
        build_id: &str,
        local: bool,
    ) -> (Vec<Value>, Vec<Value>) {
        let chat = parent.meta();
        let prompt = build_prompt(plan, &chat.name, target);
        let mut started = Vec::new();
        let mut failed = Vec::new();
        for harness in harnesses {
            let name = match target {
                Target::Compare => format!("build-{harness}"),
                _ => "build-plan".to_owned(),
            };
            let req = super::subsessions::StartRequest {
                prompt: prompt.clone(),
                name: Some(name),
                harness: Some(harness.clone()),
                model: None,
                effort: None,
                cwd: None,
                worktree: true,
                fork: false,
                force_admit: false,
                local,
            };
            match self.start_subsession(parent, req).await {
                Ok(reply) => {
                    let id = reply["sessionId"].as_str().unwrap_or_default().to_owned();
                    if let Ok(child) = self.resolve(&id) {
                        let mut set = serde_json::Map::new();
                        set.insert(BUILD_TAG.into(), Value::String(build_id.to_owned()));
                        if let Some(base) = reply.pointer("/worktree/base").and_then(Value::as_str) {
                            set.insert(BASE_TAG.into(), Value::String(base.to_owned()));
                        }
                        if let Err(e) = self.set_tags_answered(&child, Some(&set), &[], None) {
                            tracing::warn!(session = %id, error = %e.message, "plan build tag");
                        }
                    }
                    started.push(json!({
                        "sessionId": id,
                        "name": reply.get("name"),
                        "shortName": reply.get("shortName"),
                        "harness": reply.get("harness"),
                        "worktree": reply.get("worktree"),
                    }));
                }
                Err(e) => failed.push(json!({
                    "harness": harness,
                    "error": e.message,
                    "reason": e.data.as_ref().and_then(|d| d.get("reason")).cloned(),
                })),
            }
        }
        (started, failed)
    }

    /// Records a build on the plan's chat.
    pub(crate) fn record_plan_build(&self, parent: &Session, record: Value) {
        self.append(parent, "mux", RECORD_KIND, record);
    }

    /// `_acpmux/plan/compare`: each build of `build_id` with its status and its change.
    pub(crate) async fn plan_compare(
        &self,
        parent: &Session,
        build_id: &str,
    ) -> Result<Value, RpcError> {
        let builds = self.plan_builds(&parent.id, build_id);
        if builds.is_empty() {
            return Err(RpcError::not_found(format!("no plan build {build_id:?} in this chat")));
        }
        let mut rows = Vec::with_capacity(builds.len());
        let mut kept = Value::Null;
        for s in &builds {
            let m = s.meta();
            let archived = m.tags.contains_key(ARCHIVED_TAG);
            if m.tags.contains_key(KEPT_TAG) {
                kept = json!(s.id);
            }
            let (root, branch) = match &m.worktree {
                Some(w) => (w.root.clone(), w.branch.clone()),
                None => (m.cwd.clone(), None),
            };
            let base = m.tags.get(BASE_TAG).map(|t| t.value.clone());
            let mut row = json!({
                "sessionId": s.id,
                "name": m.name,
                "shortName": m.subsession.as_ref().map(|l| l.short_name.clone()),
                "harness": m.harness,
                "status": build_status(m.status),
                "archived": archived,
                "branch": branch,
                "base": base,
                "root": root,
            });
            let read = match base {
                Some(base) => {
                    let root: PathBuf = root.clone();
                    tokio::task::spawn_blocking(move || read_change(&root, &base))
                        .await
                        .unwrap_or_else(|e| Err(e.to_string()))
                }
                None => Err("this build has no base recorded".to_owned()),
            };
            match read {
                Ok(change) => {
                    if let Value::Object(fields) = change.to_value() {
                        for (k, v) in fields {
                            row.set(&k, v);
                        }
                    }
                }
                Err(error) => {
                    row.set("added", json!(0));
                    row.set("removed", json!(0));
                    row.set("files", json!([]));
                    row.set("error", json!(error));
                }
            }
            rows.push(row);
        }
        Ok(json!({"buildId": build_id, "keptSessionId": kept, "builds": rows}))
    }

    /// The builds of `build_id` other than `keep`, after checking `keep` is one of them.
    pub(crate) fn plan_keep_others(
        &self,
        parent: &Session,
        build_id: &str,
        keep: &str,
    ) -> Result<(Arc<Session>, Vec<Arc<Session>>), RpcError> {
        let builds = self.plan_builds(&parent.id, build_id);
        let kept = builds
            .iter()
            .find(|s| s.id == keep)
            .cloned()
            .ok_or_else(|| RpcError::invalid_params("keep must be one of this plan build's chats"))?;
        Ok((kept, builds.into_iter().filter(|s| s.id != keep).collect()))
    }
}

#[cfg(test)]
#[path = "plan_build_tests.rs"]
mod tests;
