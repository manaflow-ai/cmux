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
//!   (`worktree_care.rs`), so no unpushed work is deleted here. With `removeOthers` (the
//!   composer's runs) the other builds' chats close and their worktrees go now
//!   (`plan_discard`), archived first by worktree care so each can be restored.
//! - `prompt` is the composer's Run on N agents: the same builds from a prompt the person typed,
//!   sent to each build as it is, one build per variant (a harness, and its model and effort).

use super::{Hub, Session};
use crate::rpc::RpcError;
use crate::store::SessionStatus;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// What a Keep finds: the run kept now, or the same run kept before (a retry, which finishes
/// what an earlier Keep left undone), and the build's other runs.
pub(crate) enum Kept {
    Now(Arc<Session>, Vec<Arc<Session>>),
    Already(Arc<Session>, Vec<Arc<Session>>),
}

/// One Keep at a time on this daemon, from its check to its last removal: a Keep reads which run
/// a build kept, so a second one waits for the first to have recorded it.
pub(crate) async fn keep_one() -> tokio::sync::MutexGuard<'static, ()> {
    static ONE: std::sync::LazyLock<tokio::sync::Mutex<()>> =
        std::sync::LazyLock::new(|| tokio::sync::Mutex::new(()));
    ONE.lock().await
}

/// The `mux` record kind on the plan's chat.
pub const RECORD_KIND: &str = "plan_build";
/// The tag on each build's session: its build id.
pub const BUILD_TAG: &str = "planBuild";
/// The tag on the kept build: when it was kept.
pub const KEPT_TAG: &str = "planBuildKept";
/// The tag on each build: the branch its worktree was made from.
pub const BASE_TAG: &str = "planBuildBase";
/// The tag on each build: its worktree's root, from the start (the session records its worktree
/// only later, and its folder is the started-from folder's place in the worktree).
pub const ROOT_TAG: &str = "planBuildRoot";
/// The tag the chat lists hide a session by (`server/requests.rs` `ARCHIVED_TAG`).
pub(crate) const ARCHIVED_TAG: &str = "archived";
/// Most harnesses one compare starts: the card offers two.
pub const MAX_COMPARE: usize = 3;
/// Most variants one composer prompt runs on: each is a worktree and an agent's turn.
pub const MAX_RUNS: usize = 4;
/// The longest a Keep waits on the other builds' worktrees going.
const DISCARD_LIMIT: Duration = Duration::from_secs(20);
/// Between two tries at a worktree a closing agent still works in.
const DISCARD_RETRY: Duration = Duration::from_secs(2);
/// Most files a build's change lists; its totals count them all.
const MAX_FILES: usize = 200;
/// The longest one build's git read takes before it is given up.
const GIT_LIMIT: Duration = Duration::from_secs(10);

/// Where an approved plan is built.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Here,
    Worktree,
    Compare,
    /// The composer's Run on N agents: a typed prompt, no plan approval.
    Prompt,
}

impl Target {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "here" => Some(Self::Here),
            "worktree" => Some(Self::Worktree),
            "compare" => Some(Self::Compare),
            "prompt" => Some(Self::Prompt),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Here => "here",
            Self::Worktree => "worktree",
            Self::Compare => "compare",
            Self::Prompt => "prompt",
        }
    }
}

/// One build's agent: a harness, and the model and effort it runs (None: the harness's default).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Variant {
    pub harness: String,
    pub model: Option<String>,
    pub effort: Option<String>,
}

impl Variant {
    pub fn harness(harness: impl Into<String>) -> Self {
        Self { harness: harness.into(), model: None, effort: None }
    }

    /// The build's chat name: `build-<harness>` for a compare, `run-<harness>[-<model>]` for a
    /// prompt's run, `build-plan` for one build.
    fn chat_name(&self, target: Target) -> String {
        match target {
            Target::Compare => format!("build-{}", self.harness),
            Target::Prompt => match &self.model {
                Some(model) => format!("run-{}-{model}", self.harness),
                None => format!("run-{}", self.harness),
            },
            _ => "build-plan".to_owned(),
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

/// The start of a composer run's build id (`_acpmux/plan/fanout`), the only build whose Keep
/// removes the other runs' worktrees (`removeOthers`). A plan approval's builds are `build-<id>`.
pub(crate) const RUN_PREFIX: &str = "run-";

/// Whether the worktree recorded for a run is still at its path: a Keep's retry tries again only
/// those, not the runs an earlier Keep removed.
pub(crate) fn worktree_left(run: &Session) -> bool {
    let m = run.meta();
    m.subsession
        .as_ref()
        .and_then(|l| l.worktree.as_ref())
        .is_some_and(|w| w.root.symlink_metadata().is_ok())
}

/// The harnesses a compare runs when the caller names none: the chat's, then the other of
/// Claude and Codex.
pub(crate) fn compare_harnesses(chat: &str) -> Vec<String> {
    let other = if chat == "claude" || chat.starts_with("claude-") { "codex" } else { "claude" };
    vec![chat.to_owned(), other.to_owned()]
}

/// The first prompt of a build: the plan, and where the build runs. A prompt's run gets the
/// prompt as the person typed it.
pub(crate) fn build_prompt(plan: &str, chat_name: &str, target: Target) -> String {
    if target == Target::Prompt {
        return plan.to_owned();
    }
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
    // A base git no longer has (a branch renamed or deleted since, in a run recorded before its
    // commit was) says so: never HEAD, which would hide every committed change.
    let from = git_by(root, &["merge-base", "HEAD", base], by)
        .map_err(|_| format!("its base {base} is no longer in the repository"))?;
    if from.is_empty() || from.starts_with('-') {
        return Err("no commit to compare against".into());
    }
    let mut change = Change::default();
    let numstat = crate::subsession_worktree::numstat_without_config(root, &from, by)?;
    parse_numstat(&numstat, &mut change);
    Ok(change)
}

/// The status a build shows: working while its harness runs a turn or waits on an answer, and
/// before its first turn ended (its first prompt may wait for a run slot of the parent).
pub(crate) fn build_status(
    status: SessionStatus,
    turn_ended: bool,
    waits_for_slot: bool,
) -> &'static str {
    match status {
        SessionStatus::Running | SessionStatus::Waiting => "working",
        SessionStatus::Disconnected => "failed",
        SessionStatus::Closed => "closed",
        SessionStatus::Idle | SessionStatus::Ready if waits_for_slot || !turn_ended => "working",
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
            refused(
                "plan_build.not_pending",
                "that plan approval is no longer waiting for an answer",
            )
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
                // Only the daemon's record of the build it started the chat as, never the tag (an
                // agent may write tags): no other chat joins a build, so a Keep closes, archives
                // and removes only the build's own runs.
                let ours = m.subsession.as_ref().is_some_and(|l| {
                    l.started_by == parent && l.plan_build.as_deref() == Some(build_id)
                });
                let created = m.created_at;
                drop(m);
                ours.then_some((created, s))
            })
            .collect();
        builds.sort_by_key(|(created, _)| *created);
        builds.into_iter().map(|(_, s)| s).collect()
    }

    /// Starts the builds of `plan` from `parent` (`worktree`: one, `compare` and `prompt`: one
    /// per variant), each tagged with `build_id`. The starts that failed come back as
    /// `{harness, model, error}`.
    pub(crate) async fn start_plan_builds(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        plan: &str,
        target: Target,
        variants: &[Variant],
        build_id: &str,
        local: bool,
    ) -> (Vec<Value>, Vec<Value>) {
        let chat = parent.meta();
        let prompt = build_prompt(plan, &chat.name, target);
        let mut started = Vec::new();
        let mut failed = Vec::new();
        for variant in variants {
            let harness = &variant.harness;
            let req = super::subsessions::StartRequest {
                prompt: prompt.clone(),
                name: Some(variant.chat_name(target)),
                harness: Some(harness.clone()),
                model: variant.model.clone(),
                effort: variant.effort.clone(),
                cwd: None,
                worktree: true,
                // A plan build is no model race (`hub/races.rs`): the person's own build.
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
                    if let Ok(child) = self.resolve(&id) {
                        // Where an agent cannot write it: only the daemon makes a chat a build
                        // (the tag below is what the lists read, and `_acpmux/tag` may set it).
                        let mut m = child.meta.lock().unwrap_or_else(|e| e.into_inner());
                        if let Some(link) = m.subsession.as_mut() {
                            link.plan_build = Some(build_id.to_owned());
                        }
                        drop(m);
                        let mut set = serde_json::Map::new();
                        set.insert(BUILD_TAG.into(), Value::String(build_id.to_owned()));
                        for (tag, field) in
                            [(BASE_TAG, "/worktree/base"), (ROOT_TAG, "/worktree/root")]
                        {
                            if let Some(v) = reply.pointer(field).and_then(Value::as_str) {
                                set.insert(tag.into(), Value::String(v.to_owned()));
                            }
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
                        "model": variant.model,
                        "effort": variant.effort,
                        "branch": reply.pointer("/worktree/branch"),
                        "root": reply.pointer("/worktree/root"),
                        "base": reply.pointer("/worktree/base"),
                        "worktree": reply.get("worktree"),
                    }));
                }
                Err(e) => failed.push(json!({
                    "harness": harness,
                    "model": variant.model,
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
            if m.subsession.as_ref().is_some_and(|l| l.plan_build_kept) {
                kept = json!(s.id);
            }
            // The daemon's record of the worktree it made, in the run's lineage: never the
            // `planBuildRoot` or `planBuildBase` tags, which `_acpmux/tag` lets an agent rewrite
            // to point the comparison at another folder or commit.
            let made = m.subsession.as_ref().and_then(|l| l.worktree.as_ref());
            let root = made
                .map(|w| w.root.clone())
                .or_else(|| m.worktree.as_ref().map(|w| w.root.clone()))
                .unwrap_or_else(|| m.cwd.clone());
            let branch = made
                .map(|w| w.branch.clone())
                .filter(|b| !b.is_empty())
                .or_else(|| m.worktree.as_ref().and_then(|w| w.branch.clone()));
            let base = made.and_then(|w| w.base.clone());
            let mut row = json!({
                "sessionId": s.id,
                "name": m.name,
                "shortName": m.subsession.as_ref().map(|l| l.short_name.clone()),
                "harness": m.harness,
                "model": m.model_request,
                "status": build_status(m.status, m.last_turn.is_some(), self.waits_for_slot(&m)),
                "archived": archived,
                "branch": branch,
                "base": base,
                "root": root,
            });
            let read = match base {
                Some(base) => {
                    let root: PathBuf = root.clone();
                    // Only from the worktree the run was made in: a folder put at its path since
                    // (another checkout, the branch re-added) is not this run's change.
                    let made = made.cloned();
                    tokio::task::spawn_blocking(move || {
                        // Checked before and after the read: a folder swapped in while git read
                        // by path is never shown as the run's change.
                        let same = || match &made {
                            Some(made) => still_made(made).map_err(|why| {
                                format!(
                                    "the folder at its path is not this run's worktree now: {why}"
                                )
                            }),
                            None => Ok(()),
                        };
                        same()?;
                        let change = read_change(&root, &base)?;
                        same()?;
                        Ok(change)
                    })
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

    /// The builds of `build_id` other than `keep`, after checking `keep` is one of them, and marks
    /// `keep` kept in its lineage (the caller saves it). A build keeps one run: keeping it again
    /// answers [`Kept::Already`] (a retry finishes what the first Keep left), and keeping another
    /// is refused, so two panes
    /// that chose different runs never discard each other's. Run under [`keep_one`].
    pub(crate) fn plan_keep_others(
        &self,
        parent: &Session,
        build_id: &str,
        keep: &str,
    ) -> Result<Kept, RpcError> {
        let builds = self.plan_builds(&parent.id, build_id);
        let kept = builds.iter().find(|s| s.id == keep).cloned().ok_or_else(|| {
            RpcError::invalid_params("keep must be one of this plan build's chats")
        })?;
        let was =
            |s: &Arc<Session>| s.meta().subsession.as_ref().is_some_and(|l| l.plan_build_kept);
        if let Some(winner) = builds.iter().find(|s| was(s)) {
            if winner.id == keep {
                return Ok(Kept::Already(
                    kept,
                    builds.into_iter().filter(|s| s.id != keep).collect(),
                ));
            }
            return Err(refused(
                "plan_build.already_kept",
                "another run of this build was already kept",
            ));
        }
        if let Some(link) = kept.meta.lock().unwrap_or_else(|e| e.into_inner()).subsession.as_mut()
        {
            link.plan_build_kept = true;
        }
        Ok(Kept::Now(kept, builds.into_iter().filter(|s| s.id != keep).collect()))
    }

    /// The builds a Keep let go, gone now: each chat closes, then worktree care archives its
    /// worktree and only then removes it (`cmux_worktree_care::archive::reclaim`: the manifest,
    /// and a bundle of work found only there, are saved before `git worktree remove`), with no
    /// quiet time to wait out: the person chose to drop it. The branch stays, so a removed run
    /// is restorable (`_acpmux/worktree/restore` by its archive id). A worktree counts as
    /// removed only when care's pass archived it; one care left (in use, unarchivable, or an
    /// agent still letting go of its folder) is tried again for at most [`DISCARD_LIMIT`], then
    /// stays. Answers each build's `{sessionId, removed, archive?, error?}`.
    pub(crate) async fn plan_discard(
        self: &Arc<Self>,
        build_id: &str,
        others: &[Arc<Session>],
    ) -> Vec<Value> {
        let mut left: Vec<(String, PathBuf)> = Vec::new();
        let mut made_at: std::collections::HashMap<PathBuf, crate::store::MadeWorktree> =
            Default::default();
        let mut rows = Vec::new();
        for s in others {
            if let Err(e) = self.kill(s, false).await {
                tracing::warn!(session = %s.id, error = %e.message, "plan build close");
            }
            // Only the worktree the daemon made at its start, for a chat the daemon started as
            // this build, both recorded in its lineage then: never a folder it was opened in,
            // and never one the tags name (an agent may write those).
            let m = s.meta();
            let link = m.subsession.as_ref();
            // And only while the folder at its path is still that worktree: one made again there
            // after it went (its inode reused, or another branch) stays.
            let made = link
                .filter(|l| l.plan_build.as_deref() == Some(build_id))
                .and_then(|l| l.worktree.clone());
            let Some(made) = made else {
                rows.push(
                    json!({"sessionId": s.id, "removed": false, "error": "no worktree of its own"}),
                );
                continue;
            };
            let checked = made.clone();
            match tokio::task::spawn_blocking(move || still_made(&checked)).await {
                Ok(Ok(())) => {
                    left.push((s.id.clone(), made.root.clone()));
                    made_at.insert(made.root.clone(), made);
                }
                Ok(Err(why)) => {
                    tracing::warn!(session = %s.id, root = %made.root.display(), why, "plan build worktree kept");
                    rows.push(json!({"sessionId": s.id, "removed": false, "error": why}));
                }
                Err(e) => {
                    rows.push(json!({"sessionId": s.id, "removed": false, "error": e.to_string()}))
                }
            }
        }
        // Checked again inside worktree care, before it acts and right before each folder goes:
        // a worktree made at a path since the check above is never removed in its place.
        let made_at = Arc::new(made_at);
        let still: Arc<cmux_worktree_care::procs::Still> = {
            let made_at = Arc::clone(&made_at);
            Arc::new(move |path: &Path, at: &Path| match made_at.get(path) {
                Some(made) => still_made_at(made, at).map_err(str::to_owned),
                None => Err("not a worktree this build made".to_owned()),
            })
        };
        let by = Instant::now() + DISCARD_LIMIT;
        let mut last_error: std::collections::HashMap<String, String> = Default::default();
        while !left.is_empty() {
            let only: Vec<PathBuf> = left.iter().map(|(_, root)| root.clone()).collect();
            // Each worktree care's pass acted on, by its folder, with the archive id it reported:
            // a folder gone after care said it went is removed, whatever the archive says.
            let mut archives: std::collections::HashMap<String, Option<String>> =
                Default::default();
            match self.care_discard(only, Arc::clone(&still)).await {
                Ok(report) => {
                    for item in report.get("items").and_then(Value::as_array).into_iter().flatten()
                    {
                        let Some(path) = item.get("path").and_then(Value::as_str) else {
                            continue;
                        };
                        if item.pointer("/outcome/ok") == Some(&json!(true)) {
                            let archive = item.pointer("/outcome/archive").and_then(Value::as_str);
                            archives.insert(path.to_owned(), archive.map(str::to_owned));
                        } else if let Some(reason) = item
                            .pointer("/outcome/error")
                            .or_else(|| item.pointer("/verdict/reason"))
                            .and_then(Value::as_str)
                        {
                            last_error.insert(path.to_owned(), reason.to_owned());
                        }
                    }
                }
                Err(e) => {
                    for (_, root) in &left {
                        last_error.insert(root.to_string_lossy().into_owned(), e.message.clone());
                    }
                }
            }
            left.retain(|(id, root)| {
                if root.exists() {
                    // Another folder at its path now: it stays, with no more tries.
                    if let Err(why) = still(root, root) {
                        rows.push(json!({"sessionId": id, "removed": false, "error": why}));
                        return false;
                    }
                    return true;
                }
                rows.push(match archives.remove(&*root.to_string_lossy()) {
                    Some(Some(archive)) => {
                        json!({"sessionId": id, "removed": true, "archive": archive})
                    }
                    Some(None) => json!({"sessionId": id, "removed": true}),
                    // Gone from its path but not through this archive: care's own reason when it
                    // gave one (a worktree git could not remove stays aside, and that says where),
                    // else nothing here says its work was kept.
                    None => json!({"sessionId": id, "removed": false,
                    "error": last_error.get(&*root.to_string_lossy()).cloned().unwrap_or_else(
                        || "its folder went without an archive from here".to_owned(),
                    )}),
                });
                false
            });
            if left.is_empty() || Instant::now() + DISCARD_RETRY > by {
                break;
            }
            tokio::time::sleep(DISCARD_RETRY).await;
        }
        for (id, root) in left {
            let error = last_error
                .remove(&*root.to_string_lossy())
                .unwrap_or_else(|| "it stays".to_owned());
            tracing::warn!(session = %id, root = %root.display(), %error, "plan build worktree kept");
            rows.push(json!({"sessionId": id, "removed": false, "error": error}));
        }
        rows
    }
}

/// Whether the folder at `made.root` is still the worktree a run's start made: the same device,
/// inode and creation time, and on the branch it was made on (read from its git files, running nothing). A
/// folder that fails either is not removed for the run.
pub(crate) fn still_made(made: &crate::store::MadeWorktree) -> Result<(), &'static str> {
    still_made_at(made, &made.root)
}

/// [`still_made`] of the folder now at `at`: the worktree moved aside to go
/// (`cmux_worktree_care::archive`), or at its own path.
pub(crate) fn still_made_at(
    made: &crate::store::MadeWorktree,
    at: &Path,
) -> Result<(), &'static str> {
    let born =
        || std::fs::File::open(at).ok().and_then(|f| crate::store::MadeWorktree::born_of(&f));
    // Off unix a folder's identity is not recorded (`CwdPin`): nothing proves the folder is the
    // one made, so Keep leaves it, and says why.
    if !cfg!(unix) {
        return Err("this system keeps no record of which folder was made; it stays");
    }
    if made.pin.is_none()
        || crate::cwd_pin::CwdPin::of(at) != made.pin
        || made.born.is_some_and(|t| born() != Some(t))
    {
        return Err("the folder at its path is no longer the worktree it was made in");
    }
    let dot_git = std::fs::read_to_string(at.join(".git")).unwrap_or_default();
    let admin = dot_git.trim().strip_prefix("gitdir: ").map(|dir| at.join(dir));
    let head = admin.and_then(|admin| std::fs::read_to_string(admin.join("HEAD")).ok());
    if head.as_deref().map(str::trim) != Some(&format!("ref: refs/heads/{}", made.branch)) {
        return Err("its worktree is no longer on the branch it was made on");
    }
    Ok(())
}

#[cfg(test)]
#[path = "plan_build_tests.rs"]
mod tests;
