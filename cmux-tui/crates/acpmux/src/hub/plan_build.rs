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
//! - Each build is recorded on the plan's chat ([`PlanBuildRecord`], its saved metadata), so
//!   `compare` and `keep` find a build's sessions, worktree root and base after a restart. That
//!   record is acpmux's alone: a build's agent can set its own chat's tags, never the record. The
//!   plan's chat also gets a `mux` record of kind
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
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The `mux` record kind on the plan's chat.
pub const RECORD_KIND: &str = "plan_build";
/// The tag on the kept build, for the chat lists only: which build is kept is the plan's own
/// record ([`PlanBuildRecord::kept`]), never a tag a chat's agent can set.
pub const KEPT_TAG: &str = "planBuildKept";
/// The tag the chat lists hide a session by (`server/requests.rs` `ARCHIVED_TAG`).
pub(crate) const ARCHIVED_TAG: &str = "archived";
/// Most harnesses one compare starts: the card offers two.
pub const MAX_COMPARE: usize = 3;
/// Most files a build's change lists; its totals count them all.
const MAX_FILES: usize = 200;
/// The longest one build's git read takes before it is given up.
const GIT_LIMIT: Duration = Duration::from_secs(10);

/// One plan build, kept on the plan's chat (`SessionMeta::plan_builds`) by acpmux alone: which
/// chats are its builds, and each one's worktree root and base as its start made them. Tags would
/// not do: a build's agent can set its own chat's tags (`_acpmux/tag`), and compare runs git in
/// the root it names.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanBuildRecord {
    pub build_id: String,
    pub builds: Vec<PlanBuildEntry>,
    /// The build kept (`_acpmux/plan/keep`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kept: Option<String>,
}

/// Whether a chat has no plan builds (`SessionMeta::plan_builds` is then left out).
pub(crate) fn no_records(records: &Arc<Vec<PlanBuildRecord>>) -> bool {
    records.is_empty()
}

/// One build of a [`PlanBuildRecord`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanBuildEntry {
    pub session_id: String,
    /// Its worktree's root, from the start (the chat's folder is the started-from folder's place
    /// in the worktree).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<PathBuf>,
    /// The branch its worktree was made from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
}

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

/// The plan approvals a build call is answering now, by `session:permission`: a second call for
/// the same approval is refused while the first starts its builds, so two clicks (or two
/// devices) never start two sets of worktrees.
static CLAIMS: std::sync::LazyLock<std::sync::Mutex<std::collections::HashSet<String>>> =
    std::sync::LazyLock::new(Default::default);

/// A build call's hold on one plan approval ([`claim`]), released when dropped.
#[derive(Debug)]
pub struct PlanClaim(String);

impl Drop for PlanClaim {
    fn drop(&mut self) {
        CLAIMS.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.0);
    }
}

/// Holds plan approval `permission_id` of `session_id` for one build call, or refuses
/// (`plan_build.in_progress`) while another call holds it.
pub fn claim(session_id: &str, permission_id: &str) -> Result<PlanClaim, RpcError> {
    let key = format!("{session_id}:{permission_id}");
    if !CLAIMS.lock().unwrap_or_else(|e| e.into_inner()).insert(key.clone()) {
        return Err(refused(
            "plan_build.in_progress",
            "another call is answering this plan build right now",
        ));
    }
    Ok(PlanClaim(key))
}

/// The plan an ask approves, as the card reads it (webviews `direct.ts` `permissionPlan`): one
/// acpmux attached (`_meta.acpmux.plan.markdown`), else for Claude Code's ExitPlanMode or a
/// `switch_mode` ask its input's `plan`, else its text content. None for any other ask.
pub(crate) fn plan_of(request: &Value) -> Option<String> {
    // ACP v2 may carry the call only as its subject, as the card reads it too.
    let subject = request
        .get("subject")
        .filter(|s| s.get("type").and_then(Value::as_str) == Some("tool_call"))
        .and_then(|s| s.get("toolCall"));
    let tool = request.get("toolCall").or(subject)?;
    let text = |v: Option<&Value>| {
        v.and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty()).map(str::to_owned)
    };
    if let Some(attached) = text(tool.pointer("/_meta/acpmux/plan/markdown")) {
        return Some(attached);
    }
    let exit_plan =
        tool.pointer("/_meta/claude/tool").and_then(Value::as_str) == Some("ExitPlanMode");
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

/// The change in the worktree at `root` since it left `base`: committed, uncommitted and
/// untracked, against their merge base, read with none of the repository's config
/// (`subsession_worktree::numstat_without_config`).
fn read_change(root: &Path, base: &str) -> Result<Change, String> {
    use crate::subsession_worktree::git_by;
    let by = Instant::now() + GIT_LIMIT;
    let from = git_by(root, &["merge-base", "HEAD", base], by)
        .or_else(|_| git_by(root, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], by))?;
    if from.is_empty() || from.starts_with('-') {
        return Err("no commit to compare against".into());
    }
    let mut change = Change::default();
    let numstat = crate::subsession_worktree::numstat_without_config(root, &from, by)?;
    parse_numstat(&numstat, &mut change);
    Ok(change)
}

/// The status a build shows: working while its harness runs a turn or waits on an answer, and
/// before its first turn ended (its first prompt may wait for a run slot of the parent). Once idle,
/// its last turn's own status (`last_turn.status`): done only for a completed turn, stopped
/// ("closed") for a cancelled one, else failed.
pub(crate) fn build_status(
    status: SessionStatus,
    last_turn: Option<&str>,
    waits_for_slot: bool,
) -> &'static str {
    match status {
        SessionStatus::Running | SessionStatus::Waiting => "working",
        SessionStatus::Disconnected => "failed",
        SessionStatus::Closed => "closed",
        SessionStatus::Idle | SessionStatus::Ready if waits_for_slot => "working",
        SessionStatus::Idle | SessionStatus::Ready => match last_turn {
            None => "working",
            Some("completed") => "done",
            Some("cancelled") => "closed",
            Some(_) => "failed",
        },
    }
}

impl Hub {
    /// Stops the plan's own turn `turn_id` once its approval was answered for a build elsewhere:
    /// a harness may take the rejected plan as a tool denial and plan on, or ask again. Only
    /// that turn: a later one the person started runs.
    pub async fn stop_plan_turn(self: &Arc<Self>, session: &Arc<Session>, turn_id: Option<&str>) {
        if let Some(turn_id) = turn_id {
            self.cancel_turn(session, turn_id).await;
        }
    }

    /// The plan of `session`'s pending ask `permission_id`, with the ask itself.
    pub(crate) fn pending_plan(
        &self,
        session: &Session,
        permission_id: &str,
    ) -> Result<(String, Value), RpcError> {
        let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        let pending = state.pending.get(permission_id).ok_or_else(|| {
            refused(
                "plan_build.not_pending",
                "that plan approval is no longer waiting for an answer",
            )
        })?;
        let plan = plan_of(&pending.request)
            .ok_or_else(|| refused("plan_build.not_plan", "that ask is not a plan approval"))?;
        Ok((plan, pending.request.clone()))
    }

    /// The record of build `build_id` on `parent`, and its builds that are still sub-sessions of
    /// `parent`, in the order they started.
    fn plan_builds(
        &self,
        parent: &Session,
        build_id: &str,
    ) -> Option<(PlanBuildRecord, Vec<(Arc<Session>, PlanBuildEntry)>)> {
        let record =
            parent.read_meta(|m| m.plan_builds.iter().find(|r| r.build_id == build_id).cloned())?;
        let builds = record
            .builds
            .iter()
            .filter_map(|entry| {
                let s =
                    self.resolve(&entry.session_id).ok().filter(|s| s.id == entry.session_id)?;
                let ours = s.read_meta(|m| {
                    m.subsession.as_ref().is_some_and(|l| l.started_by == parent.id)
                });
                ours.then(|| (s, entry.clone()))
            })
            .collect();
        Some((record, builds))
    }

    /// Starts the builds of `plan` from `parent` (`worktree`: one, `compare`: one per harness),
    /// recorded on `parent` as `build_id` ([`PlanBuildRecord`]). The starts that failed come back
    /// as `{harness, error}`.
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
        let mut entries = Vec::new();
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
                owner_authorized_race: false,
                race_id: None,
                fork: false,
                force_admit: false,
                local,
            };
            match self.start_subsession(parent, req).await {
                Ok(reply) => {
                    let id = reply
                        .get("sessionId")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    let text = |field: &str| {
                        reply.pointer(field).and_then(Value::as_str).map(str::to_owned)
                    };
                    entries.push(PlanBuildEntry {
                        session_id: id.clone(),
                        root: text("/worktree/root").map(PathBuf::from),
                        base: text("/worktree/base"),
                    });
                    started.push(json!({
                        "sessionId": id,
                        "name": reply.get("name"),
                        "shortName": reply.get("shortName"),
                        "harness": reply.get("harness"),
                        "branch": reply.pointer("/worktree/branch"),
                        "root": reply.pointer("/worktree/root"),
                        "base": reply.pointer("/worktree/base"),
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
        if !entries.is_empty() {
            let record =
                PlanBuildRecord { build_id: build_id.to_owned(), builds: entries, kept: None };
            {
                let mut meta = parent.meta.lock().unwrap_or_else(|e| e.into_inner());
                Arc::make_mut(&mut meta.plan_builds).push(record);
            }
            // Durable before the card's `started` record is appended, so a card that survives a
            // restart always finds its builds for compare and keep.
            if let Err(e) = self.save_meta_answered(parent) {
                tracing::warn!(session = %parent.id, "plan build record not saved: {}", e.message);
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
        let Some((record, builds)) = self.plan_builds(parent, build_id) else {
            return Err(RpcError::not_found(format!("no plan build {build_id:?} in this chat")));
        };
        let mut rows = Vec::with_capacity(builds.len());
        let kept = json!(record.kept);
        for (s, entry) in &builds {
            let m = s.meta();
            let archived = m.tags.contains_key(ARCHIVED_TAG);
            // The root and base its start recorded: git runs nowhere a chat's agent names.
            let branch = m.worktree.as_ref().and_then(|w| w.branch.clone());
            let root = entry.root.clone();
            let base = entry.base.clone();
            let mut row = json!({
                "sessionId": s.id,
                "name": m.name,
                "shortName": m.subsession.as_ref().map(|l| l.short_name.clone()),
                "harness": m.harness,
                "status": build_status(
                    m.status,
                    m.last_turn.as_ref().map(|t| t.get("status").and_then(Value::as_str).unwrap_or("")),
                    self.waits_for_slot(&m),
                ),
                "archived": archived,
                "branch": branch,
                "base": base,
                "root": root,
            });
            let read = match (root, base) {
                (Some(root), Some(base)) => {
                    tokio::task::spawn_blocking(move || read_change(&root, &base))
                        .await
                        .unwrap_or_else(|e| Err(e.to_string()))
                }
                _ => Err("this build has no worktree recorded".to_owned()),
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

    /// Records `keep` as the kept build of `build_id` and returns it with the other builds.
    /// `keep` must be one of them; keeping the kept build again answers the same, and keeping
    /// another after one was kept is refused (`plan_build.already_kept`).
    pub(crate) fn plan_keep_others(
        &self,
        parent: &Session,
        build_id: &str,
        keep: &str,
    ) -> Result<(Arc<Session>, Vec<Arc<Session>>), RpcError> {
        let (_, builds) = self.plan_builds(parent, build_id).ok_or_else(|| {
            RpcError::not_found(format!("no plan build {build_id:?} in this chat"))
        })?;
        let kept =
            builds.iter().find(|(s, _)| s.id == keep).map(|(s, _)| s.clone()).ok_or_else(|| {
                RpcError::invalid_params("keep must be one of this plan build's chats")
            })?;
        {
            let mut meta = parent.meta.lock().unwrap_or_else(|e| e.into_inner());
            let records = Arc::make_mut(&mut meta.plan_builds);
            let Some(record) = records.iter_mut().find(|r| r.build_id == build_id) else {
                return Err(RpcError::not_found(format!(
                    "no plan build {build_id:?} in this chat"
                )));
            };
            match record.kept.as_deref() {
                Some(earlier) if earlier != keep => {
                    return Err(refused(
                        "plan_build.already_kept",
                        "another build of this plan was already kept",
                    ));
                }
                _ => record.kept = Some(keep.to_owned()),
            }
        }
        self.save_meta_answered(parent)?;
        Ok((kept, builds.into_iter().map(|(s, _)| s).filter(|s| s.id != keep).collect()))
    }
}

#[cfg(test)]
#[path = "plan_build_tests.rs"]
mod tests;
