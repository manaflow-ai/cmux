//! Sub-sessions: an agent session starts, messages, watches and stops its own
//! child sessions (Lawrence 2026-10-18, after the Claude app's `ccd_session`).
//!
//! A sub-session is a normal session (it resumes, forks, moves and lists like any other) with one
//! more field, [`SubsessionLink`]: the parent session's id (`startedBy`), its short name among the
//! parent's children, and its depth (1 under a root). Agents get the tools from the
//! `cmux-subsessions` MCP server (`subsession_mcp.rs`, every local session by default,
//! `agent_tools.rs`); the server reaches these methods over the unix socket with the session's
//! caller token, so the daemon, not a request field, says which session acts (`hub/person.rs` (a)).
//!
//! Limits, decided here and nowhere else:
//! - Width: a session has at most `maxChildren` live children. A child counts while its harness
//!   is alive (`ready`, `running` or `waiting`); idle-finished, disconnected and closed children
//!   do not use a slot. One with a prompt on its way to a turn (queued, or starting its
//!   harness) counts as live (`waking_children`), so a start never takes the slot a wake needs.
//!   The limit is checked when a child starts: a prompt to a child it has still wakes it even
//!   past the limit, as a reopen always did, and the child frees its slot when it hibernates.
//!   Depth: a session is started at depth `parent.depth + 1` only when that
//!   is at most the parent's `maxDepth`.
//! - Running: at most `maxRunning` children run a turn at once; a start or a
//!   message past it waits its turn, queued (`subsession_runs.rs`). It also
//!   takes a workspace's value (`_acpmux/subsession/limits {workspaceId}`)
//!   between an ancestor's override and the settings.
//! - A session's limit is its own override (`SessionMeta::subsession_limits`),
//!   else its nearest ancestor's override, else the settings
//!   (`agents.subsessions.maxChildren`, `agents.subsessions.maxDepth`, read
//!   at each check), else the catalog defaults
//!   (schemas/settings/source/subsessions.json, embedded: [`catalog`]).
//! - Raised or lowered at runtime with `_acpmux/subsession/limits`: by the
//!   person to any value up to the catalog's range `max`,
//!   or by an ancestor session for a descendant, never above the ancestor's
//!   own limits. A session never raises its own.
//! - The width check and the start are one step: a slot is reserved under
//!   the index lock before the session is created, so concurrent starts
//!   never pass the limit.
//!
//! What a child may do is never wider than its parent
//! (`subsession_guard.rs`):
//! - Its folder is resolved once (a path that does not resolve is refused);
//!   that folder is what is checked and what the session (or its worktree)
//!   gets, and a child that reports another folder is closed. It must be
//!   inside the parent's folder or one the person trusted in cmux: the
//!   trust walk reads every folder up to `/`, and an untrusted one refuses
//!   unless the person's own nearer `trusted` decision ended the walk.
//!   Claude Code's or Codex's trust, or an agent-home folder, counts only
//!   for a parent in full access.
//! - It runs the parent's effective permission policy (one the parent does
//!   not name is the daemon default, which the child follows as its parent
//!   does; one acpmux cannot parse is `ask`).
//! - On the same harness family it starts in the parent's current mode (the
//!   start gate's inherit rule), on another family in the person's default
//!   start mode only when the parent runs with full access. A child that
//!   still asks less than the parent, on the reviewed lists, is moved to an
//!   asking mode or closed: OpenCode's `build`, a Codex mode that decides
//!   when to ask, a harness's own default that skips approvals.
//! - A folder profile, or a profile whose command skips the permission
//!   checks or the sandbox, starts only from a parent in full access (or as
//!   the parent's own harness).
//! - Every refusal after the session exists closes it.
//! - A message (`send`) never reaches a session that asks less than its
//!   sender, child or parent: checked when it is sent and again when it
//!   runs (a queued one, `turns.rs`).
//!
//! A family lives on one daemon: there is no start on another host (a start's
//! host `auto` only checks this machine has room, `server/place.rs`). What
//! the tools read back of a family member (its title, last reply, capped
//! at [`MAX_REPLY_CHARS`], error, running prompt and what it does now) is masked (`secret_scan`),
//! the reply and the prompt before their cut, and only the caller's descendants and its own parent
//! are read. A start or a message never attaches, so the receiver's unread mark stays.
//!
//! A chat the person starts from a suggested task (`offers.rs`) becomes the offering chat's
//! sub-session too ([`Hub::offer_link`]), so the agent that suggested it reads and waits on it with
//! the same tools; only the person prompts, stops or closes it (`subsession_write_target`).
//!
//! With `worktree: true` a child works in a new git worktree of its folder's repository
//! (`subsession_worktree.rs`, laid out as the app's `git.worktree.create`), made in the daemon
//! without running anything from that repository: its files are checked out without the
//! repository's config. A start that fails after it is made removes it again.
//!
//! The index of live children per parent (`subsession_index.rs`) is a leaf lock: nothing else is
//! locked while it is held, so it may be taken under any other lock.

use super::*;
use crate::store::{SubsessionLimits, SubsessionLink};
use cmux_json::JsonSet as _;

#[path = "subsession_index.rs"]
mod index;
pub use index::Index;

/// The settings keys (schemas/settings/source/subsessions.json).
pub const SETTING_ENABLED: &str = "agents.subsessions.enabled";
pub const SETTING_MAX_CHILDREN: &str = "agents.subsessions.maxChildren";
pub const SETTING_MAX_DEPTH: &str = "agents.subsessions.maxDepth";
pub const SETTING_MAX_RUNNING: &str = "agents.subsessions.maxRunning";
/// `maxRunning`'s default and ceiling until the catalog has its row.
const MAX_RUNNING_FALLBACK: NumberSetting = NumberSetting { default: 1000, max: 1000 };
pub const SETTING_ANSWER_QUESTIONS: &str = "agents.subsessions.answerQuestions";
/// The settings catalog source of those keys: their defaults and ranges have
/// one definition, shared with the app's Settings.
const CATALOG_SOURCE: &str =
    include_str!("../../../../../schemas/settings/source/subsessions.json");

/// One number setting of the catalog: its default and the largest value.
#[derive(Clone, Copy)]
pub struct NumberSetting {
    pub default: u32,
    pub max: u32,
}

/// The catalog rows the daemon reads.
pub struct Catalog {
    pub enabled: bool,
    pub answer_questions: bool,
    pub max_children: NumberSetting,
    pub max_depth: NumberSetting,
    pub max_running: NumberSetting,
}

/// The catalog, parsed once from the embedded source.
pub fn catalog() -> &'static Catalog {
    static CATALOG: std::sync::OnceLock<Catalog> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        // crash-allow: the source is a checked-in file embedded with include_str!, so a bad row fails every daemon start in tests/subsessions.rs before it can ship
        parse_catalog(CATALOG_SOURCE).expect("subsessions.json rows")
    })
}

/// The agents.subsessions rows of a settings source file, or None when one is missing.
fn parse_catalog(source: &str) -> Option<Catalog> {
    let doc: Value = serde_json::from_str(source).ok()?;
    let row = |key: &str| -> Option<Value> {
        doc["lists"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|l| l["rows"].as_array().into_iter().flatten())
            .find(|r| r["key"] == key)
            .cloned()
    };
    let get = |v: &Value| v.as_u64().and_then(|n| u32::try_from(n).ok());
    let number = |key: &str| -> Option<NumberSetting> {
        let r = row(key)?;
        Some(NumberSetting { default: get(&r["default"])?, max: get(&r["range"]["max"])? })
    };
    Some(Catalog {
        enabled: row(SETTING_ENABLED)?["default"].as_bool()?,
        answer_questions: row(SETTING_ANSWER_QUESTIONS)?["default"].as_bool()?,
        max_children: number(SETTING_MAX_CHILDREN)?,
        max_depth: number(SETTING_MAX_DEPTH)?,
        max_running: number(SETTING_MAX_RUNNING).unwrap_or(MAX_RUNNING_FALLBACK),
    })
}

/// Longest short name, in characters.
const MAX_SHORT_NAME: usize = 40;
/// Longest reply text a tool returns, in characters.
const MAX_REPLY_CHARS: usize = 4000;
/// The provenance kind of a prompt one family member sends another.
pub const PROVENANCE_KIND: &str = "subsession_message";
/// The mux record on a parent when a child starts or closes.
pub const RECORD_KIND: &str = "subsession";

/// Whether sub-session tools are on (settings `agents.subsessions.enabled`,
/// else the catalog default).
pub fn enabled() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING_ENABLED)
                .and_then(|v| v.as_bool())
                .unwrap_or(catalog().enabled)
        }
        _ => catalog().enabled,
    }
}

/// One limit as the settings give it, clamped to 1..=`max` the way the app's
/// Settings reads it (a fraction rounds down).
fn setting(key: &str, max: u32) -> Option<u32> {
    let crate::user_settings::Settings::Parsed(doc) = crate::user_settings::read() else {
        return None;
    };
    let n = crate::user_settings::value(&doc, key)?.as_f64().filter(|n| n.is_finite())?;
    Some(n.floor().clamp(1.0, f64::from(max)) as u32)
}

/// Where a limit value came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// The session's own override.
    Session,
    /// An ancestor's override.
    Inherited,
    /// The session's workspace's (`subsession_runs.rs`).
    Workspace,
    Settings,
    Default,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Session => "session",
            Self::Inherited => "inherited",
            Self::Workspace => "workspace",
            Self::Settings => "settings",
            Self::Default => "default",
        }
    }
}

/// A session's limits in force.
#[derive(Debug, Clone, Copy)]
pub struct Effective {
    pub max_children: u32,
    pub max_children_source: Source,
    pub max_depth: u32,
    pub max_depth_source: Source,
    pub max_running: u32,
    pub max_running_source: Source,
}

/// Who changes a session's limits.
pub enum LimitsActor<'a> {
    Person,
    /// An agent session, by id (proven by its caller token).
    Session(&'a str),
}

/// What `start_session` asks for.
#[derive(Debug, Default)]
pub struct StartRequest {
    pub prompt: String,
    pub name: Option<String>,
    pub harness: Option<String>,
    pub model: Option<String>,
    /// Thinking effort (`acpmux new --parent -e`); None is the harness's default.
    pub effort: Option<String>,
    pub cwd: Option<PathBuf>,
    /// Work in a new git worktree of the folder's repository
    /// (`subsession_worktree.rs`) instead of the folder itself.
    pub worktree: bool,
    /// `_meta.acpmux.forceAdmit` (`acpmux new --parent --force-admit`):
    /// admitted past this host's refusal, logged (`admission.rs`).
    pub force_admit: bool,
    /// A refusal may name this host and its paths: false for a Web client, here or
    /// through a peer (`server/requests.rs`).
    pub local: bool,
}

/// A sub-session's new worktree (and the folder it was made from) until its
/// start succeeds: dropped before [`KeptWorktree::keep`] (a later refusal,
/// failure, or the parent closing meanwhile), it is removed, off the async
/// runtime.
struct KeptWorktree {
    folder: PathBuf,
    /// `folder` as its start checked it, held open (unix): removed from that very folder.
    held: Option<Arc<std::fs::File>>,
    made: crate::subsession_worktree::Worktree,
    kept: bool,
    /// A decision trusts `folder` (a person's, an agent's own, or cmux's for a folder it made),
    /// not an auto-trust rule alone (`ensure_folder_trusted`): the worktree is recorded as
    /// trusted too.
    source_decided: bool,
}

impl KeptWorktree {
    /// The start succeeded: the worktree stays.
    fn keep(mut self) {
        self.kept = true;
    }
}

impl Drop for KeptWorktree {
    fn drop(&mut self) {
        if !self.kept {
            let (folder, held, made) = (self.folder.clone(), self.held.clone(), self.made.clone());
            std::thread::spawn(move || {
                let at = crate::subsession_worktree::Dir::held(&folder, held.as_deref());
                crate::subsession_worktree::remove_worktree(at, &made)
            });
        }
    }
}

pub(super) use super::subsession_guard::refusal as refused;

/// A short name from the request or the prompt: lowercase words joined by
/// dashes, at most [`MAX_SHORT_NAME`] characters.
fn short_name_of(requested: Option<&str>, prompt: &str) -> String {
    let source = requested.filter(|n| !n.trim().is_empty()).unwrap_or(prompt);
    let mut out = String::new();
    for word in source.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()) {
        let word = word.to_lowercase();
        let next = if out.is_empty() { word } else { format!("{out}-{word}") };
        if next.chars().count() > MAX_SHORT_NAME {
            if out.is_empty() {
                out = next.chars().take(MAX_SHORT_NAME).collect();
            }
            break;
        }
        out = next;
        if requested.is_none() && out.split('-').count() >= 4 {
            break;
        }
    }
    if out.is_empty() { "task".to_owned() } else { out }
}

impl Hub {
    /// The link that makes a chat the person started for `parent`'s
    /// suggested task (`offers.rs`) one of its sub-sessions: one level
    /// under it, its short name from the task's title. The person chose it,
    /// so no width or depth limit refuses it; it counts as an open child.
    /// Its `short_name` is the base name, not yet claimed: the caller claims
    /// it (`claim_name`) only when the link is set, so a refused answer
    /// takes no name.
    pub(super) fn offer_link(&self, parent: &Session, title: Option<&str>) -> SubsessionLink {
        let depth = self.lineage_depth(&parent.meta()).saturating_add(1);
        let base = short_name_of(title, "task");
        SubsessionLink { started_by: parent.id.clone(), short_name: base, depth, offered: true }
    }

    /// The limits in force for the session with meta `m`.
    pub fn subsession_effective(&self, m: &SessionMeta) -> Effective {
        let mut children: Option<(u32, Source)> = None;
        let mut depth: Option<(u32, Source)> = None;
        let mut running: Option<(u32, Source)> = None;
        let mut limits = m.subsession_limits.clone();
        // Up the lineage (`lineage.rs`): a session `acpmux new` started inherits as a sub-session does.
        let mut parent = self.lineage_of(m).map(|l| l.parent);
        let mut source = Source::Session;
        // Bounded: a link loop (a moved chat whose parent id came back) ends here.
        for _ in 0..=catalog().max_depth.max {
            if children.is_none() {
                // An override never passes the catalog's ceiling (a moved-in or
                // hand-edited session.json).
                children =
                    limits.max_children.map(|n| (n.clamp(1, catalog().max_children.max), source));
            }
            if depth.is_none() {
                depth = limits.max_depth.map(|n| (n.clamp(1, catalog().max_depth.max), source));
            }
            if running.is_none() {
                running =
                    limits.max_running.map(|n| (n.clamp(1, catalog().max_running.max), source));
            }
            if children.is_some() && depth.is_some() && running.is_some() {
                break;
            }
            let Some(id) = parent.take() else { break };
            let Some(up) = self.session_meta_by_id(&id) else { break };
            limits = up.subsession_limits.clone();
            parent = self.lineage_of(&up).map(|l| l.parent);
            source = Source::Inherited;
        }
        let pick = |own: Option<(u32, Source)>, key: &str, max: u32, default: u32| {
            own.or_else(|| setting(key, max).map(|n| (n, Source::Settings)))
                .unwrap_or((default, Source::Default))
        };
        let (max_children, max_children_source) = pick(
            children,
            SETTING_MAX_CHILDREN,
            catalog().max_children.max,
            catalog().max_children.default,
        );
        let (max_depth, max_depth_source) =
            pick(depth, SETTING_MAX_DEPTH, catalog().max_depth.max, catalog().max_depth.default);
        // The workspace's value sits between the family's overrides and the settings.
        let running = running.or_else(|| {
            let ws = m.workspace_id.as_deref()?;
            let n = self.subsession_runs.workspace_limit(ws)?;
            Some((n.clamp(1, catalog().max_running.max), Source::Workspace))
        });
        let (max_running, max_running_source) = pick(
            running,
            SETTING_MAX_RUNNING,
            catalog().max_running.max,
            catalog().max_running.default,
        );
        Effective {
            max_children,
            max_children_source,
            max_depth,
            max_depth_source,
            max_running,
            max_running_source,
        }
    }

    /// The summary's `subsessionLimits` for `m`.
    pub(super) fn subsession_limits_value(&self, m: &SessionMeta) -> Value {
        let e = self.subsession_effective(m);
        json!({
            "maxChildren": e.max_children,
            "maxChildrenSource": e.max_children_source.as_str(),
            "maxDepth": e.max_depth,
            "maxDepthSource": e.max_depth_source.as_str(),
            "maxRunning": e.max_running,
            "maxRunningSource": e.max_running_source.as_str(),
            // Its sub-sessions running a turn now, and the ones waiting for a slot.
            "running": self.subsession_runs.running(&m.id),
            "queued": self.subsession_runs.waiting(&m.id),
        })
    }

    /// `parent`'s open children with a prompt on its way to a turn: queued (for the turn lock or
    /// a run slot), or holding the turn lock while their harness starts. The index counts the
    /// ones among them that are not live (`Index::reserve`), so a wake never lets a start take
    /// its slot. Read over every open child, live ones too: one that hibernates between this
    /// read and the reservation still counts. A prompt that comes after this read wakes its child
    /// as one after the reservation would: past the limit, as a reopen does. Prompts a failed
    /// turn holds (`pause_queue`) wake nothing until released, so they do not count.
    pub(super) fn waking_children(&self, parent: &str) -> Vec<String> {
        let open = self.subsessions.open_children(parent);
        let children: Vec<Arc<Session>> = {
            let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            open.iter().filter_map(|id| sessions.get(id).cloned()).collect()
        };
        let waking = |c: &Session| {
            let held = c.queue().iter().filter(|q| q.held).count() as u64;
            c.queued() > held || c.turn_lock.try_lock().is_err()
        };
        children.iter().filter(|c| waking(c)).map(|c| c.id.clone()).collect()
    }

    /// How many of `parent`'s children use a width slot now: live or waking.
    pub(super) fn width_used(&self, parent: &str) -> u32 {
        self.subsessions.used(parent, &self.waking_children(parent))
    }

    /// Tells the parent's watchers when a sub-session closed or reopened. Its width slot follows
    /// every status write (`note_status`); hibernating or waking is not a close or a reopen.
    pub(super) fn subsession_status(
        &self,
        id: &str,
        link: &SubsessionLink,
        was: SessionStatus,
        now: SessionStatus,
    ) {
        let event = match (was == SessionStatus::Closed, now == SessionStatus::Closed) {
            (false, true) => "closed",
            // Reopened (a prompt to a closed child, by the user or a client): once its harness
            // is up it holds a slot again, past the limit if the parent is full.
            (true, false) => "reopened",
            _ => return,
        };
        if let Ok(parent) = self.resolve(&link.started_by) {
            self.append(
                &parent,
                "mux",
                RECORD_KIND,
                json!({"event": event, "childSessionId": id, "shortName": link.short_name}),
            );
        }
    }

    /// Whether `ancestor` is a strict ancestor of the session with meta `m`.
    pub fn subsession_is_ancestor(&self, ancestor: &str, m: &SessionMeta) -> bool {
        let mut next = m.subsession.as_ref().map(|l| l.started_by.clone());
        for _ in 0..=catalog().max_depth.max {
            let Some(id) = next else { return false };
            if id == ancestor {
                return true;
            }
            next = self
                .sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(&id)
                .and_then(|s| s.meta.lock().ok().and_then(|m| m.subsession.clone()))
                .map(|l| l.started_by);
        }
        false
    }

    /// The direct children of `parent`, open or closed, newest first.
    fn subsession_children(&self, parent: &str) -> Vec<Arc<Session>> {
        self.sessions()
            .into_iter()
            .filter(|s| {
                let m = s.meta.lock().unwrap_or_else(|e| e.into_inner());
                m.subsession.as_ref().is_some_and(|l| l.started_by == parent)
            })
            .collect()
    }

    /// `_acpmux/subsession/start`: `parent`'s agent starts a child with a
    /// first prompt. Answers once the prompt is accepted.
    pub async fn start_subsession(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        req: StartRequest,
    ) -> Result<Value, RpcError> {
        if !enabled() {
            return Err(refused(
                "subsessions.disabled",
                format!("sub-sessions are turned off in Settings ({SETTING_ENABLED} is false)"),
                json!({}),
            ));
        }
        if req.prompt.trim().is_empty() {
            return Err(RpcError::invalid_params("prompt must not be empty"));
        }
        let pm = parent.meta();
        if pm.status == SessionStatus::Closed {
            return Err(RpcError::invalid_params("a closed session starts no sub-session"));
        }
        let limits = self.subsession_effective(&pm);
        // One depth for every way a session starts another (`lineage.rs`).
        let lineage = self.lineage_under(&pm, super::lineage::start_tool_call(parent, &req.prompt));
        let depth = lineage.depth;
        if depth > limits.max_depth {
            return Err(refused(
                "subsessions.depth_limit",
                format!(
                    "start_session refused: depth limit reached. This session is at depth {} and may start sessions only down to depth {} (source: {}). Do the work in this session instead, or ask for a deeper limit: the user can raise it (Settings > Agents > Sub-sessions > Deepest Nesting), and your parent session can raise it within its own limit with set_session_limits; ask it with send_message.",
                    depth - 1,
                    limits.max_depth,
                    limits.max_depth_source.as_str()
                ),
                json!({"depth": depth - 1, "maxDepth": limits.max_depth, "source": limits.max_depth_source.as_str()}),
            ));
        }
        let waking = self.waking_children(&parent.id);
        let slot = match self.subsessions.reserve(&parent.id, limits.max_children, &waking) {
            Ok(slot) => slot,
            Err(live) => {
                return Err(refused(
                    "subsessions.width_limit",
                    format!(
                        "start_session refused: width limit reached. This session has {live} live sub-sessions (running, waiting for input, with a harness process alive, or with a message on its way to a turn); finished, dead, idle-finished and closed sub-sessions do not count. It may have at most {} live at once (source: {}). Ask for more: the user can raise it (Settings > Agents > Sub-sessions > Open Sub-sessions per Session), and your parent session can raise it within its own limit with set_session_limits; ask it with send_message.",
                        limits.max_children,
                        limits.max_children_source.as_str()
                    ),
                    json!({"open": live, "live": live, "maxChildren": limits.max_children, "source": limits.max_children_source.as_str(), "counted": "running, waiting, harness-alive, or a message on its way"}),
                ));
            }
        };
        let (child, reply, worktree) = self.start_reserved(parent, &pm, lineage, req).await?;
        slot.settle(&child);
        // A stop_session close:true of an ancestor that ran while this start
        // was in flight did not see the child: close it now, not orphaned
        // (and its worktree, dropped unkept, is removed).
        if parent.meta().status == SessionStatus::Closed {
            let _ = self.kill(&child, false).await;
            return Err(RpcError::invalid_params(
                "the session closed while its sub-session started",
            ));
        }
        if let Some(kept) = worktree {
            // The folder it was made from is trusted by a decision, so its worktree is too. A
            // folder only an auto-trust rule trusts gets no record: a Web client reads a record
            // as a person's answer, and the rule still answers the pane for the worktree's own
            // folder when it covers it.
            if kept.source_decided {
                self.trust_made_worktree(&kept.made.cwd).await;
            }
            kept.keep();
        }
        Ok(reply)
    }

    /// The start itself, inside a reserved slot; with its new worktree,
    /// removed unless the caller keeps it.
    async fn start_reserved(
        self: &Arc<Self>,
        parent: &Arc<Session>,
        pm: &SessionMeta,
        lineage: crate::store::Lineage,
        req: StartRequest,
    ) -> Result<(Arc<Session>, Value, Option<KeptWorktree>), RpcError> {
        let depth = lineage.depth;
        let base = short_name_of(req.name.as_deref(), &req.prompt);
        let short = self.subsessions.claim_name(&parent.id, &base);
        let name = self.unique_name(&format!("{}/{short}", pm.name));
        let harness = req.harness.clone().unwrap_or_else(|| pm.harness.clone());
        let asked = req.cwd.clone().unwrap_or_else(|| pm.cwd.clone());
        let folder = super::subsession_guard::CheckedFolder::resolve(&asked)?;
        // The harness, then the folder: one nobody answered the trust question for waits on a
        // card in the parent's chat instead of failing (`subsession_guard.rs`, `trust_wait.rs`).
        let model = req.model.as_deref();
        let decided =
            self.subsession_place_check(parent, pm, &folder, &harness, model, &short).await?;
        // A sub-session is a new session: it needs room on this host (`admission.rs`).
        // Before the worktree, so a refusal makes none.
        let who = format!("session {}", parent.id);
        let admitted = self
            .admit_new(super::admission::Ask {
                force: req.force_admit,
                // Set by the server only where the caller may force (`server/requests.rs`).
                can_force: req.force_admit,
                person: false,
                who: &who,
                local: req.local,
                peers: req.local,
                // A child's name is made unique before this (`unique_name`).
                name: None,
            })
            .await?;
        // Its worktree is made, and its harness spawns, only in the very folder checked.
        let (cwd, worktree) = if req.worktree {
            folder.still_here()?;
            let mut kept = self.subsession_worktree(pm, &folder, &short).await?;
            kept.source_decided = decided;
            let start = super::subsession_guard::CheckedFolder::resolve(&kept.made.cwd)?;
            // The folder resolved is in the worktree just made, not one that took its place.
            super::subsession_guard::verify_worktree(&folder, &kept.made, &start).await?;
            (start, Some(kept))
        } else {
            (folder, None)
        };
        // The caller's own policy. A caller that names none runs the daemon
        // default, and so does its child: the default as the child's own
        // would narrow it (`policy_mode.rs`) and start the child of a caller
        // in full access in an asking mode. A child harness default laxer
        // than the caller's is held to the caller's (`hold_subsession`).
        let policy = if pm.permission_policy.is_some() {
            Some(self.effective_policy(pm).await)
        } else {
            None
        };
        let request = NewRequest {
            harness: Some(harness),
            name: Some(name),
            cwd: Some(cwd.to_path_buf()),
            checked_cwd: Some(cwd.clone()),
            policy,
            model: req.model.clone(),
            effort: req.effort.clone(),
            remote: pm.remote_origin,
            vm_boundary: pm.vm_boundary,
            workspace_id: pm.workspace_id.clone(),
            // Same family: the parent's mode, set below. Another family: the
            // person's default start mode only under a full-access parent.
            keep_harness_mode: true,
            subsession: Some(SubsessionLink {
                started_by: parent.id.clone(),
                short_name: short.clone(),
                depth,
                offered: false,
            }),
            lineage: Some(lineage),
            ..Default::default()
        };
        let probe = admitted.run(self.new_session(request)).await?;
        // From here every refusal closes the child: it never runs unchecked.
        if let Err(e) = self.settle_subsession(parent, pm, &probe, &cwd, req.name.as_deref()).await
        {
            return Err(self.close_refused(&probe, e).await);
        }
        let cm = probe.meta();
        // At its prompt's acceptance: the parent's log has `started` only for a child that runs,
        // and before that turn's `turn_ended`.
        let (hub, to, child) = (self.clone(), parent.clone(), probe.clone());
        let (prompt, asked) = (req.prompt.clone(), (req.model.clone(), req.effort.clone()));
        let started: Box<dyn FnOnce() + Send> =
            Box::new(move || hub.subsession_started(&to, &child, &prompt, asked));
        let accepted = self
            .send_family_prompt(
                parent,
                &probe,
                text_block(&req.prompt),
                None,
                false,
                false,
                Some(started),
                None,
            )
            .await;
        let accepted = match accepted {
            Ok(v) => v,
            Err(e) => {
                let _ = self.kill(&probe, true).await;
                return Err(e);
            }
        };
        // The row get_session reads, not the session summary: a summary's
        // `shown` says whether a client has the chat open right now, which a
        // parent read as "the user cannot see it" (it is under the parent's
        // chat in the sidebar from the start).
        let row = self.subsession_row(&probe, false);
        let mut reply = json!({
            "sessionId": probe.id,
            "name": cm.name,
            "shortName": short,
            "depth": depth,
            "harness": cm.harness,
            "mode": crate::web_modes::mode_of(&probe.meta()),
            "turnId": accepted.get("turnId"),
            // Its parent runs as many sub-sessions as `maxRunning` allows: its first prompt
            // waits for a run slot (`subsession_runs.rs`).
            "waitsForSlot": accepted["waitsForSlot"].as_bool().unwrap_or(false),
            "session": row,
        });
        if let Some(kept) = &worktree {
            let w = &kept.made;
            reply.set("worktree", json!({"root": w.root, "branch": w.branch, "base": w.base}));
        }
        Ok((probe, reply, worktree))
    }

    /// A new worktree of `folder`'s repository for a sub-session named
    /// `name` (`subsession_worktree.rs`), made off the async runtime. Only
    /// on this machine: a remote parent's folder is not here.
    async fn subsession_worktree(
        &self,
        pm: &SessionMeta,
        checked: &super::subsession_guard::CheckedFolder,
        name: &str,
    ) -> Result<KeptWorktree, RpcError> {
        let folder: &Path = checked;
        let refuse = |why: String| {
            refused(
                "subsessions.worktree_refused",
                format!("start_session refused: no worktree: {why}"),
                json!({"cwd": folder}),
            )
        };
        if pm.remote_origin {
            return Err(refuse("this session runs on another machine".into()));
        }
        let (folder2, held, name2) = (folder.to_path_buf(), checked.held(), name.to_owned());
        // The guard is made with the worktree, so a start dropped while this
        // runs (its caller gone) still removes it. Git runs in the very folder
        // checked, through its open handle, wherever its path leads by now.
        tokio::task::spawn_blocking(move || {
            let at = crate::subsession_worktree::Dir::held(&folder2, held.as_deref());
            let made = crate::subsession_worktree::make_worktree(at, &name2)?;
            Ok::<_, String>(KeptWorktree {
                folder: folder2,
                held,
                made,
                kept: false,
                source_decided: false,
            })
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(refuse)
    }

    /// Sends `blocks` from `from` to `to` as a prompt with the family provenance; answers once it
    /// is accepted (started or queued). `steer`: into the running turn (`Delivery::NextStep`);
    /// `interrupt`: `Hub::interrupt_once_queued`. `accepted` runs at the acceptance, before the
    /// turn can end. `saved`: the message's attachments, settled when its turn ends (`attach.rs`).
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn send_family_prompt(
        self: &Arc<Self>,
        from: &Arc<Session>,
        to: &Arc<Session>,
        blocks: Vec<Value>,
        prompt_id: Option<String>,
        steer: bool,
        interrupt: bool,
        accepted: Option<Box<dyn FnOnce() + Send>>,
        saved: Option<crate::attach::Saved>,
    ) -> Result<Value, RpcError> {
        let fm = from.meta();
        let mut provenance = json!({
            "kind": PROVENANCE_KIND,
            "from": from.id,
            "fromName": fm.name,
            "to": to.id,
            // Who the sender is to the receiver, for its chat's label.
            "fromRole": super::subsession_send::family_role(&fm, &to.meta()),
        });
        if let Some(link) = &fm.subsession {
            provenance.set("fromShortName", json!(link.short_name));
        }
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        // An agent a remote device drove (its turn, or its last one, is a Web
        // turn) prompts under the remote floor, and so does a prompt to a
        // session whose last turn was one: a family prompt never runs, or
        // lets the receiver run, below the floor (`remote_floor.rs`).
        let web = Self::web_turn(from) || Self::web_turn(to);
        // A family message waits behind a review box's review, never stops it (`inbox.rs`).
        let stop = self.interrupt_once_queued(to, interrupt && !super::inbox::review_box(to));
        let on_accepted: Option<Box<dyn FnOnce(Value) + Send>> = Some(Box::new(move |v| {
            stop(&v);
            if let Some(accepted) = accepted {
                accepted();
            }
            let _ = tx.send(v);
        }));
        let opts = PromptOptions {
            control: if web { Control::Web } else { Control::Local },
            prompt_id: Some(prompt_id.unwrap_or_else(|| format!("sub-{}", uuid::Uuid::now_v7()))),
            on_accepted: match &saved {
                Some(saved) => saved.watch(on_accepted),
                None => on_accepted,
            },
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let (hub, to2) = (self.clone(), to.clone());
        // The turn runs on: only its acceptance is awaited here.
        let turn = tokio::spawn(async move {
            let answer = hub.prompt_with(&to2, blocks, "acpmux-subsession", steer, opts).await;
            if let Some(saved) = saved {
                saved.settle(&hub, &answer).await;
            }
            answer
        });
        match rx.await {
            Ok(v) => Ok(v),
            // Dropped before acceptance: the prompt was refused.
            Err(_) => match turn.await {
                Ok(Err(e)) => Err(e),
                Ok(Ok(v)) => Ok(v),
                Err(e) => Err(RpcError::internal(e.to_string())),
            },
        }
    }

    /// One family row for the tools: the session's place, state and last reply.
    pub fn subsession_row(&self, s: &Session, with_reply: bool) -> Value {
        let mut summary = self.session_summary(s);
        // Masked before its cut (`TurnInfo::masked_preview`), for `turn` and `doing`; the turn's
        // activity and plan step are masked in every summary (`activity.rs`).
        if let Some(t) = s.turn().filter(|t| summary["turn"]["turnId"] == t.turn_id.as_str()) {
            summary.set_path(&["turn", "prompt"], json!(t.masked_preview));
        }
        if summary["waitingPrompt"].is_string() {
            summary.set("waitingPrompt", json!(super::subsession_send::masked_waiting_prompt(s)));
        }
        let pick = |k: &str| summary.get(k).cloned().unwrap_or(Value::Null);
        let mut row = json!({
            "sessionId": s.id,
            "name": pick("name"),
            "shortName": pick("shortName"),
            "startedBy": pick("startedBy"),
            "depth": pick("depth"),
            "status": pick("status"),
            "indicator": pick("indicator"),
            "title": pick("title"),
            "harness": pick("harness"),
            "children": pick("children"),
            "updatedAt": pick("updatedAt"),
            "lastTurn": pick("lastTurn"),
            "pendingPermissions": pick("pendingPermissions"),
            "queued": pick("queued"),
            // Its prompt waits for a run slot of its parent (`subsession_runs.rs`): not done yet.
            "waitsForSlot": summary["waitsForSlot"].as_bool().unwrap_or(false),
            // Non-null from the moment a prompt is accepted to its turn's end.
            "turn": pick("turn"),
            // working, input, failed, lost or idle, and since when (`views::lane`).
            "state": summary["lane"]["state"].clone(),
            "stateSince": summary["lane"]["since"].clone(),
            // Working, but quiet with no tool call in flight since then (`hub/activity.rs`).
            "stalledSince": summary["lane"]["stalledSince"].clone(),
            "doing": super::subsession_send::doing(&summary),
            // question or permission: only the person allows a permission, in the app.
            "waitingOn": pick("waitingOn"),
            "questions": self.subsession_questions(s), // ancestors may answer them
        });
        if with_reply {
            row.set("lastReply", json!(self.last_reply(s)));
        }
        // The tools hand this to another session's agent: a secret in the
        // child's text (one it read from a file, say) is masked.
        for key in ["title", "lastReply", "doing"] {
            if let Some(text) = row[key].as_str() {
                row[key] = json!(crate::secret_scan::mask(text));
            }
        }
        // The last turn's text, and the running turn's again (a turn that changed between the
        // two reads above): a parent may have pasted a key into it, and what it does now is a
        // tool call's title, often a command with its arguments.
        let turn_text = ["/turn/prompt", "/turn/activity", "/turn/planStep"];
        for pointer in ["/lastTurn/errorText", "/lastTurn/prompt"].into_iter().chain(turn_text) {
            if let Some(slot) = row.pointer_mut(pointer)
                && let Some(text) = slot.as_str()
            {
                *slot = json!(crate::secret_scan::mask(text));
            }
        }
        row
    }

    /// `_acpmux/subsession/list`: the caller's children, or all its descendants.
    pub fn subsession_list(&self, caller: &Session, descendants: bool) -> Value {
        let mut rows = Vec::new();
        let mut frontier = vec![caller.id.clone()];
        while let Some(id) = frontier.pop() {
            for child in self.subsession_children(&id) {
                if descendants {
                    frontier.push(child.id.clone());
                }
                rows.push(self.subsession_row(&child, false));
            }
            if rows.len() > 10 * catalog().max_children.max as usize {
                break;
            }
        }
        let m = caller.meta();
        let e = self.subsession_effective(&m);
        json!({
            "sessions": rows,
            "self": {
                "sessionId": caller.id,
                "depth": self.lineage_depth(&m),
                "startedBy": m.subsession.as_ref().map(|l| &l.started_by),
                "openChildren": self.subsessions.open_count(&caller.id),
                "liveChildren": self.width_used(&caller.id),
                "maxChildren": e.max_children,
                "maxDepth": e.max_depth,
                "maxRunning": e.max_running,
                "running": self.subsession_runs.running(&caller.id),
                "queued": self.subsession_runs.waiting(&caller.id),
            },
        })
    }

    /// The session `key` names, when `caller` may act on it: a descendant,
    /// or (`parent_ok`) the caller's own parent.
    pub fn subsession_target(
        &self,
        caller: &Session,
        key: &str,
        parent_ok: bool,
    ) -> Result<Arc<Session>, RpcError> {
        let target = self.resolve(key)?;
        let tm = target.meta();
        let own_parent = parent_ok
            && caller.meta().subsession.as_ref().is_some_and(|l| l.started_by == target.id);
        if own_parent || self.subsession_is_ancestor(&caller.id, &tm) {
            return Ok(target);
        }
        Err(refused(
            "subsessions.not_family",
            format!(
                "session {} is not one this session started (or started by one of its sub-sessions){}",
                tm.name,
                if parent_ok { ", nor its parent" } else { "" }
            ),
            json!({"sessionId": target.id}),
        ))
    }

    /// [`Hub::subsession_target`] for `send` and `stop`: refused when a
    /// session on the way from the target up to the caller is one the person
    /// started from a suggested task (`offers.rs`). The person chose its
    /// mode, which may allow more than the caller's own, so the caller only
    /// reads and waits on it.
    pub fn subsession_write_target(
        &self,
        caller: &Session,
        key: &str,
        parent_ok: bool,
    ) -> Result<Arc<Session>, RpcError> {
        let target = self.subsession_target(caller, key, parent_ok)?;
        // A child writing to its own parent: the parent's own link is not this caller's business.
        if caller.meta().subsession.as_ref().is_some_and(|l| l.started_by == target.id) {
            return Ok(target);
        }
        let mut link = target.meta().subsession.clone();
        for _ in 0..=catalog().max_depth.max {
            let Some(l) = link else { break };
            if l.offered {
                let name = target.meta().name.clone();
                return Err(refused(
                    "subsessions.person_started",
                    format!(
                        "the user started {name} from your suggested task, in a mode they chose: read it and wait on it, but only the user prompts, stops or closes it"
                    ),
                    json!({"sessionId": target.id}),
                ));
            }
            if l.started_by == caller.id {
                break;
            }
            link = self
                .sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(&l.started_by)
                .and_then(|s| s.meta.lock().ok().and_then(|m| m.subsession.clone()));
        }
        Ok(target)
    }

    /// `_acpmux/subsession/stop`: stops a descendant's turn, or with `close`
    /// closes it and every session under it (deepest first), which frees
    /// their slots.
    pub async fn subsession_stop(
        self: &Arc<Self>,
        target: &Arc<Session>,
        close: bool,
    ) -> Result<Value, RpcError> {
        if !close {
            // A start or message still waiting for a run slot is stopped too: it never runs.
            if self.waits_for_slot(&target.meta()) {
                self.withdraw_family_prompts(target, "stopped");
            }
            if target.turn().is_some() {
                self.cancel(target).await?;
            }
            return Ok(json!({"sessionId": target.id, "stopped": true, "closed": []}));
        }
        // Visited ids end a link loop (a moved chat whose parent id came back).
        let mut seen = std::collections::HashSet::from([target.id.clone()]);
        let mut order = vec![target.clone()];
        let mut i = 0;
        while i < order.len() {
            let id = order[i].id.clone();
            order.extend(
                self.subsession_children(&id).into_iter().filter(|c| seen.insert(c.id.clone())),
            );
            i += 1;
        }
        let mut closed = Vec::new();
        for s in order.iter().rev() {
            // A family prompt still queued would take a run slot later and open it again.
            self.withdraw_family_prompts(s, "closed");
            if s.meta().status != SessionStatus::Closed {
                self.kill(s, false).await?;
                closed.push(Value::String(s.id.clone()));
            }
        }
        Ok(json!({"sessionId": target.id, "stopped": true, "closed": closed}))
    }

    /// `_acpmux/subsession/limits`: sets (a number) or clears (null) the
    /// target's own limits. Fields left out stay as they are.
    pub fn set_subsession_limits(
        &self,
        actor: LimitsActor<'_>,
        target: &Session,
        max_children: Option<Option<u32>>,
        max_depth: Option<Option<u32>>,
        max_running: Option<Option<u32>>,
    ) -> Result<Value, RpcError> {
        let tm = target.meta();
        let ceiling = match actor {
            LimitsActor::Person => {
                (catalog().max_children.max, catalog().max_depth.max, catalog().max_running.max)
            }
            LimitsActor::Session(caller) => {
                if !self.subsession_is_ancestor(caller, &tm) {
                    return Err(refused(
                        "subsessions.limits_person_required",
                        "only the user, or a session above this one in its family, changes its limits; a session never raises its own. Ask the user, or your parent session with send_message.".to_owned(),
                        json!({"sessionId": target.id}),
                    ));
                }
                let cm = self.resolve(caller)?.meta();
                let e = self.subsession_effective(&cm);
                (e.max_children, e.max_depth, e.max_running)
            }
        };
        let check = |v: Option<Option<u32>>, max: u32, what: &str| -> Result<(), RpcError> {
            match v {
                Some(Some(n)) if n == 0 || n > max => Err(refused(
                    "subsessions.limit_out_of_range",
                    format!("{what} must be from 1 to {max} (the most this caller may give)"),
                    json!({"max": max}),
                )),
                _ => Ok(()),
            }
        };
        check(max_children, ceiling.0, "maxChildren")?;
        check(max_depth, ceiling.1, "maxDepth")?;
        check(max_running, ceiling.2, "maxRunning")?;
        let changed = max_children.is_some() || max_depth.is_some() || max_running.is_some();
        // Nothing to set: only reads the limits (the CLI's `acpmux session limits NAME`).
        if !changed {
            let limits = self.subsession_limits_value(&tm);
            return Ok(json!({"sessionId": target.id, "subsessionLimits": limits}));
        }
        {
            let mut m = target.meta.lock().unwrap_or_else(|e| e.into_inner());
            let SubsessionLimits { max_children: c, max_depth: d, max_running: r } =
                &mut m.subsession_limits;
            if let Some(v) = max_children {
                *c = v;
            }
            if let Some(v) = max_depth {
                *d = v;
            }
            if let Some(v) = max_running {
                *r = v;
            }
        }
        self.save_meta(target);
        // A raised limit starts waiting sub-sessions now; a lowered one stops none.
        self.subsession_runs.wake();
        let limits = self.subsession_limits_value(&target.meta());
        self.append(target, "mux", RECORD_KIND, json!({"event": "limits", "limits": limits}));
        Ok(json!({"sessionId": target.id, "subsessionLimits": limits}))
    }

    /// The text of the session's last agent message (its own, not a
    /// harness subagent's), from the newest records; null before any.
    /// Secrets are masked (`secret_scan`) before the text is cut at
    /// `MAX_REPLY_CHARS`, so a cut never leaves a secret's head unmasked.
    pub fn last_reply(&self, s: &Session) -> Option<String> {
        let last = s.meta().last_seq;
        self.reply_between(s, last.saturating_sub(4000), last)
    }

    /// [`Hub::last_reply`] among the records after `after` up to `upto` only (the last 4000 of
    /// them): one turn's reply, read after later turns began (the Cloud hand-off reports,
    /// `daemon/cloud_handoff.rs`).
    pub fn reply_between(&self, s: &Session, after: u64, upto: u64) -> Option<String> {
        let after = after.max(upto.saturating_sub(4000));
        let count = usize::try_from(upto.saturating_sub(after)).unwrap_or(4000);
        let events = self.events(&s.id, after, count).ok()?;
        let mut reply = String::new();
        let mut open = false;
        for e in events.into_iter().take_while(|e| e.seq <= upto) {
            if e.dir == "mux" && matches!(e.kind.as_str(), "turn_started" | "user_message") {
                open = false;
                continue;
            }
            let update = e.dir == "in"
                && !e.kind.ends_with(".replay")
                && e.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
                && e.msg.pointer("/params/_meta/acpmux/subagent").is_none();
            if !update {
                continue;
            }
            match e.kind.as_str() {
                "agent_message_chunk" => {
                    if !open {
                        reply.clear();
                        open = true;
                    }
                    let chunk = e.msg.pointer("/params/update/content/text");
                    reply.push_str(chunk.and_then(Value::as_str).unwrap_or_default());
                }
                "tool_call" | "tool_call_update" | "agent_thought_chunk" | "plan" => open = false,
                _ => {}
            }
        }
        let reply = reply.trim();
        if reply.is_empty() {
            return None;
        }
        // Mask before the cut: a cut through a secret leaves a head the
        // scanner no longer recognizes, and that head would go out unmasked.
        let masked = crate::secret_scan::mask(reply);
        let mut cut: String = masked.chars().take(MAX_REPLY_CHARS).collect();
        if masked.chars().count() > MAX_REPLY_CHARS {
            cut.push('…');
        }
        Some(cut)
    }
}

/// A prompt of `text` alone.
fn text_block(text: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": text})]
}
