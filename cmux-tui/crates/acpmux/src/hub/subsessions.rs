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
//! - Width: a session has at most `maxChildren` open children (not closed).
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
//! The index of open children per parent is a leaf lock: nothing else is
//! locked while it is held, so it may be taken under any other lock.

use super::*;
use crate::store::{SubsessionLimits, SubsessionLink};
use std::collections::BTreeSet;

/// The settings keys (schemas/settings/source/subsessions.json).
pub const SETTING_ENABLED: &str = "agents.subsessions.enabled";
pub const SETTING_MAX_CHILDREN: &str = "agents.subsessions.maxChildren";
pub const SETTING_MAX_DEPTH: &str = "agents.subsessions.maxDepth";
pub const SETTING_MAX_RUNNING: &str = "agents.subsessions.maxRunning";
/// `maxRunning`'s default and ceiling until the catalog has its row.
const MAX_RUNNING_FALLBACK: NumberSetting = NumberSetting { default: 16, max: 1000 };
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

/// The open children of each parent, and the slots reserved by starts in flight.
#[derive(Default)]
pub struct Index {
    state: StdMutex<IndexState>,
}

#[derive(Default)]
struct IndexState {
    open: HashMap<String, BTreeSet<String>>,
    reserved: HashMap<String, u32>,
    /// Every short name a child of each parent has or had, open or closed;
    /// a failed start keeps its name, so a name is never given twice.
    names: HashMap<String, BTreeSet<String>>,
}

impl Index {
    fn lock(&self) -> std::sync::MutexGuard<'_, IndexState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Notes `child` of `parent` as open or closed.
    pub(super) fn set_open(&self, parent: &str, child: &str, open: bool) {
        let mut s = self.lock();
        if open {
            s.open.entry(parent.to_owned()).or_default().insert(child.to_owned());
        } else if let Some(set) = s.open.get_mut(parent) {
            set.remove(child);
            if set.is_empty() {
                s.open.remove(parent);
            }
        }
    }

    /// Notes a loaded child's short name as taken.
    pub(super) fn note_name(&self, parent: &str, short: &str) {
        self.lock().names.entry(parent.to_owned()).or_default().insert(short.to_owned());
    }

    /// Takes the first free short name of `parent` from `base`, `base-2`, ...
    pub(super) fn claim_name(&self, parent: &str, base: &str) -> String {
        let mut s = self.lock();
        let taken = s.names.entry(parent.to_owned()).or_default();
        let short = (1..)
            .map(|n| if n == 1 { base.to_owned() } else { format!("{base}-{n}") })
            .find(|n| !taken.contains(n))
            .unwrap_or_else(|| base.to_owned());
        taken.insert(short.clone());
        short
    }

    /// How many children of `parent` are open.
    pub fn open_count(&self, parent: &str) -> u32 {
        self.lock().open.get(parent).map_or(0, |s| s.len() as u32)
    }

    /// Reserves one child slot of `parent` under `max`, or returns how many
    /// are open or reserved.
    fn reserve<'a>(&'a self, parent: &'a str, max: u32) -> Result<Reservation<'a>, u32> {
        let mut s = self.lock();
        let used = s.open.get(parent).map_or(0, |set| set.len() as u32)
            + s.reserved.get(parent).copied().unwrap_or(0);
        if used >= max {
            return Err(used);
        }
        *s.reserved.entry(parent.to_owned()).or_default() += 1;
        Ok(Reservation { index: self, parent })
    }

    fn release(&self, parent: &str) {
        let mut s = self.lock();
        if let Some(n) = s.reserved.get_mut(parent) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                s.reserved.remove(parent);
            }
        }
    }
}

/// One width slot held by a start in flight; dropped (an error, a panic, a
/// cancelled request) it frees the slot.
struct Reservation<'a> {
    index: &'a Index,
    parent: &'a str,
}

impl Reservation<'_> {
    /// The start made `child`: it holds the slot from now on, unless it was
    /// closed meanwhile. Under the child's meta lock, like every other
    /// change of its entry ([`Hub::set_status`]), so the index follows the
    /// order of the status writes.
    fn settle(self, child: &Session) {
        let m = child.meta.lock().unwrap_or_else(|e| e.into_inner());
        if m.status != SessionStatus::Closed {
            self.index.set_open(self.parent, &child.id, true);
        }
    }
}

impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        self.index.release(self.parent);
    }
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
}

/// A sub-session's new worktree (and the folder it was made from) until its
/// start succeeds: dropped before [`KeptWorktree::keep`] (a later refusal,
/// failure, or the parent closing meanwhile), it is removed, off the async
/// runtime.
struct KeptWorktree {
    folder: PathBuf,
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
            let (folder, made) = (self.folder.clone(), self.made.clone());
            std::thread::spawn(move || crate::subsession_worktree::remove_worktree(&folder, &made));
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
        let depth = parent.meta().subsession.as_ref().map_or(0, |l| l.depth) + 1;
        let base = short_name_of(title, "task");
        SubsessionLink { started_by: parent.id.clone(), short_name: base, depth, offered: true }
    }

    /// The limits in force for the session with meta `m`.
    pub fn subsession_effective(&self, m: &SessionMeta) -> Effective {
        let mut children: Option<(u32, Source)> = None;
        let mut depth: Option<(u32, Source)> = None;
        let mut running: Option<(u32, Source)> = None;
        let mut limits = m.subsession_limits.clone();
        let mut parent = m.subsession.as_ref().map(|l| l.started_by.clone());
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
            let Some(up) = self
                .sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(&id)
                .cloned()
            else {
                break;
            };
            let up = up.meta.lock().unwrap_or_else(|e| e.into_inner());
            limits = up.subsession_limits.clone();
            parent = up.subsession.as_ref().map(|l| l.started_by.clone());
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

    /// Notes a sub-session's status change in its parent's index, and tells
    /// the parent's watchers when it opened or closed.
    pub(super) fn subsession_status(
        &self,
        id: &str,
        link: &SubsessionLink,
        was: SessionStatus,
        now: SessionStatus,
    ) {
        let event = match (was == SessionStatus::Closed, now == SessionStatus::Closed) {
            (false, true) => "closed",
            // Reopened (a prompt to a closed child, by the user or a client):
            // it holds a slot again, past the limit if the parent is full.
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
        let depth = pm.subsession.as_ref().map_or(0, |l| l.depth) + 1;
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
        let slot = match self.subsessions.reserve(&parent.id, limits.max_children) {
            Ok(slot) => slot,
            Err(used) => {
                return Err(refused(
                    "subsessions.width_limit",
                    format!(
                        "start_session refused: width limit reached. This session has {used} open sub-sessions and may have at most {} open at once (source: {}). Close finished ones with stop_session (close: true) to free a slot, or ask for more: the user can raise it (Settings > Agents > Sub-sessions > Open Sub-sessions per Session), and your parent session can raise it within its own limit with set_session_limits; ask it with send_message.",
                        limits.max_children,
                        limits.max_children_source.as_str()
                    ),
                    json!({"open": used, "maxChildren": limits.max_children, "source": limits.max_children_source.as_str()}),
                ));
            }
        };
        let (child, reply, worktree) = self.start_reserved(parent, &pm, depth, req).await?;
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
        depth: u32,
        req: StartRequest,
    ) -> Result<(Arc<Session>, Value, Option<KeptWorktree>), RpcError> {
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
        // Its worktree is made only while the folder checked is still at its path (git still runs
        // by path in it), and its harness spawns only in the folder then resolved and pinned.
        let (cwd, worktree) = if req.worktree {
            folder.still_here()?;
            let mut kept = self.subsession_worktree(pm, &folder, &short).await?;
            kept.source_decided = decided;
            let start = super::subsession_guard::CheckedFolder::resolve(&kept.made.cwd)?;
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
            ..Default::default()
        };
        let probe = self.new_session(request).await?;
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
            reply["worktree"] = json!({"root": w.root, "branch": w.branch, "base": w.base});
        }
        Ok((probe, reply, worktree))
    }

    /// A new worktree of `folder`'s repository for a sub-session named
    /// `name` (`subsession_worktree.rs`), made off the async runtime. Only
    /// on this machine: a remote parent's folder is not here.
    async fn subsession_worktree(
        &self,
        pm: &SessionMeta,
        folder: &Path,
        name: &str,
    ) -> Result<KeptWorktree, RpcError> {
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
        let (folder2, name2) = (folder.to_path_buf(), name.to_owned());
        // The guard is made with the worktree, so a start dropped while this
        // runs (its caller gone) still removes it.
        tokio::task::spawn_blocking(move || {
            crate::subsession_worktree::make_worktree(&folder2, &name2).map(|made| KeptWorktree {
                folder: folder2,
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
            provenance["fromShortName"] = json!(link.short_name);
        }
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        // An agent a remote device drove (its turn, or its last one, is a Web
        // turn) prompts under the remote floor, and so does a prompt to a
        // session whose last turn was one: a family prompt never runs, or
        // lets the receiver run, below the floor (`remote_floor.rs`).
        let web = Self::web_turn(from) || Self::web_turn(to);
        let stop = self.interrupt_once_queued(to, interrupt);
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
        // Masked before their cut (`TurnInfo::masked_preview`, `doing`), for `turn` and `doing`.
        if let Some(t) = s.turn().filter(|t| summary["turn"]["turnId"] == t.turn_id.as_str()) {
            summary["turn"]["prompt"] = json!(t.masked_preview);
            t.doing.mask_into(&mut summary["turn"]);
        }
        if summary["waitingPrompt"].is_string() {
            summary["waitingPrompt"] = json!(super::subsession_send::masked_waiting_prompt(s));
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
            row["lastReply"] = json!(self.last_reply(s));
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
                "depth": m.subsession.as_ref().map_or(0, |l| l.depth),
                "startedBy": m.subsession.as_ref().map(|l| &l.started_by),
                "openChildren": self.subsessions.open_count(&caller.id),
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
        let after = last.saturating_sub(4000);
        let events = self.events(&s.id, after, 4000).ok()?;
        let mut reply = String::new();
        let mut open = false;
        for e in events {
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
