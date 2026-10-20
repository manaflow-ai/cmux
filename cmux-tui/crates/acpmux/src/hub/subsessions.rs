//! Sub-sessions: an agent session starts, messages, watches and stops its own
//! child sessions (Lawrence 2026-10-18, after the Claude app's `ccd_session`).
//!
//! A sub-session is a normal session (it resumes, forks, moves and lists like
//! any other) with one more field, [`SubsessionLink`]: the parent session's
//! id (`startedBy`), its short name among the parent's children, and its
//! depth (1 under a root). Agents get the tools from the `cmux-subsessions`
//! MCP server (`subsession_mcp.rs`, every local session by default,
//! `agent_tools.rs`); the server reaches these methods over the unix socket
//! with the session's caller token, so the daemon, not a request field, says
//! which session acts (`hub/person.rs` (a)).
//!
//! Limits, decided here and nowhere else:
//! - Width: a session has at most `maxChildren` open children (not closed).
//!   Depth: a session is started at depth `parent.depth + 1` only when that
//!   is at most the parent's `maxDepth`.
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
//! What a child may do is never wider than its parent: it runs the parent's
//! permission policy; on the same harness family it starts in the parent's
//! current mode (the start gate's inherit rule), on another family in the
//! person's default start mode only when the parent runs with full access,
//! else in that harness's own (asking) mode. What the tools read back of a
//! child (its title, last reply and error) is masked (`secret_scan`).
//!
//! A chat the person starts from a suggested task (`offers.rs`) becomes the
//! offering chat's sub-session too ([`Hub::offer_link`]), so the agent that
//! suggested it reads and waits on it with the same tools; only the person
//! prompts, stops or closes it (`subsession_write_target`).
//!
//! With `worktree: true` a child works in a new git worktree of its folder's
//! repository (`subsession_worktree.rs`, laid out as the app's
//! `git.worktree.create`), made in the daemon without running anything from
//! that repository: its files are checked out without the repository's
//! config. A start that fails after it is made removes it again.
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
    pub max_children: NumberSetting,
    pub max_depth: NumberSetting,
}

/// The catalog, parsed once from the embedded source.
pub fn catalog() -> &'static Catalog {
    static CATALOG: std::sync::OnceLock<Catalog> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        // crash-allow: the source is a checked-in file embedded with include_str!, so a bad row fails every daemon start in tests/subsessions.rs before it can ship
        parse_catalog(CATALOG_SOURCE).expect("subsessions.json rows")
    })
}

/// The three agents.subsessions rows of a settings source file, or None when one is missing.
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
        max_children: number(SETTING_MAX_CHILDREN)?,
        max_depth: number(SETTING_MAX_DEPTH)?,
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
    fn claim_name(&self, parent: &str, base: &str) -> String {
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
    Settings,
    Default,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Session => "session",
            Self::Inherited => "inherited",
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

fn refused(reason: &str, message: String, data: Value) -> RpcError {
    let mut data = data;
    data["reason"] = json!(reason);
    RpcError::invalid_params(message).with_data(data)
}

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
    pub(super) fn offer_link(&self, parent: &Session, title: Option<&str>) -> SubsessionLink {
        let depth = parent.meta().subsession.as_ref().map_or(0, |l| l.depth) + 1;
        let base = short_name_of(title, "task");
        let short = self.subsessions.claim_name(&parent.id, &base);
        SubsessionLink { started_by: parent.id.clone(), short_name: short, depth, offered: true }
    }

    /// The limits in force for the session with meta `m`.
    pub fn subsession_effective(&self, m: &SessionMeta) -> Effective {
        let mut children: Option<(u32, Source)> = None;
        let mut depth: Option<(u32, Source)> = None;
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
            if children.is_some() && depth.is_some() {
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
        Effective { max_children, max_children_source, max_depth, max_depth_source }
    }

    /// The summary's `subsessionLimits` for `m`.
    pub(super) fn subsession_limits_value(&self, m: &SessionMeta) -> Value {
        let e = self.subsession_effective(m);
        json!({
            "maxChildren": e.max_children,
            "maxChildrenSource": e.max_children_source.as_str(),
            "maxDepth": e.max_depth,
            "maxDepthSource": e.max_depth_source.as_str(),
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
                    "start_session refused: depth limit reached. This session is at depth {} and may start sessions only down to depth {} (source: {}). Do the work in this session instead, or ask for a deeper limit: the user can raise it (Settings > Agents > Sub-sessions > Deepest Nesting, or this session's limits in its sidebar), and your parent session can raise it within its own limit with set_session_limits; ask it with send_message.",
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
                        "start_session refused: width limit reached. This session has {used} open sub-sessions and may have at most {} open at once (source: {}). Close finished ones with stop_session (close: true) to free a slot, or ask for more: the user can raise it (Settings > Agents > Sub-sessions > Open Sub-sessions per Session, or this session's limits in its sidebar), and your parent session can raise it within its own limit with set_session_limits; ask it with send_message.",
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
            kept.keep();
        }
        let link = child.meta().subsession.clone();
        self.append(
            parent,
            "mux",
            RECORD_KIND,
            json!({"event": "started", "childSessionId": child.id, "shortName": link.as_ref().map(|l| &l.short_name)}),
        );
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
        if let Some(cwd) = &req.cwd
            && !(cwd.is_absolute() && cwd.is_dir())
        {
            return Err(RpcError::invalid_params(format!(
                "cwd {} must be an absolute path to an existing folder",
                cwd.display()
            )));
        }
        let mut cwd = req.cwd.clone().unwrap_or_else(|| pm.cwd.clone());
        let worktree = if req.worktree {
            let kept = self.subsession_worktree(pm, &cwd, &short).await?;
            cwd = kept.made.cwd.clone();
            Some(kept)
        } else {
            None
        };
        let parent_mode = crate::web_modes::mode_of(pm);
        let parent_full = parent_mode
            .as_deref()
            .is_some_and(|m| super::start_mode::FULL_ACCESS_MODES.contains(&m));
        let policy = pm.permission_policy.as_deref().and_then(|p| p.parse().ok());
        let request = NewRequest {
            harness: Some(harness),
            name: Some(name),
            cwd: Some(cwd),
            policy,
            model: req.model.clone(),
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
        // The parent's rules above its policy (which can deny) and the MCP
        // servers the user turned off apply to the child too.
        {
            let mut m = probe.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.permission_rules = pm.permission_rules.clone();
            for row in &pm.tools.off {
                if !m.tools.off.contains(row) {
                    m.tools.off.push(row.clone());
                }
            }
        }
        self.save_meta(&probe);
        let cm = probe.meta();
        let same_family = crate::web_modes::family_of(&cm) == crate::web_modes::family_of(pm);
        let mode = if same_family {
            parent_mode.clone()
        } else if parent_full {
            self.start_mode(&probe).await
        } else {
            None
        };
        if let Some(mode) = mode {
            let params = json!({"_meta": {"acpmux": {(super::person::START_MODE_FIELD): mode}}});
            // The inherit rule (or the person's default under a full-access
            // parent) grants it; a refusal ends the new session.
            if same_family {
                self.start_in_mode(false, Some(&parent.id), &params, &probe, false).await?;
            } else if let Err(e) = self.set_mode(&probe, &mode).await {
                tracing::warn!(session = %probe.id, "sub-session start mode skipped: {}", e.message);
            }
        }
        let accepted = self.send_family_prompt(parent, &probe, &req.prompt, None).await;
        let accepted = match accepted {
            Ok(v) => v,
            Err(e) => {
                let _ = self.kill(&probe, true).await;
                return Err(e);
            }
        };
        let summary = self.session_summary(&probe);
        let mut reply = json!({
            "sessionId": probe.id,
            "name": cm.name,
            "shortName": short,
            "depth": depth,
            "harness": cm.harness,
            "mode": crate::web_modes::mode_of(&probe.meta()),
            "turnId": accepted.get("turnId"),
            "session": summary,
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
            })
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(refuse)
    }

    /// Sends `text` from `from` to `to` as a prompt with the family
    /// provenance; answers once it is accepted (started or queued).
    async fn send_family_prompt(
        self: &Arc<Self>,
        from: &Arc<Session>,
        to: &Arc<Session>,
        text: &str,
        prompt_id: Option<String>,
    ) -> Result<Value, RpcError> {
        let fm = from.meta();
        let provenance = json!({
            "kind": PROVENANCE_KIND,
            "from": from.id,
            "fromName": fm.name,
            "to": to.id,
        });
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        let opts = PromptOptions {
            prompt_id: Some(prompt_id.unwrap_or_else(|| format!("sub-{}", uuid::Uuid::now_v7()))),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        let (hub, to2) = (self.clone(), to.clone());
        // The turn runs on: only its acceptance is awaited here.
        let turn = tokio::spawn(async move {
            hub.prompt_with(&to2, blocks, "acpmux-subsession", false, opts).await
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
        let summary = self.session_summary(s);
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
            // Non-null from the moment a prompt is accepted to its turn's end.
            "turn": pick("turn"),
        });
        if with_reply {
            row["lastReply"] = json!(self.last_reply(s));
        }
        // The tools hand this to another session's agent: a secret in the
        // child's text (one it read from a file, say) is masked.
        for key in ["title", "lastReply"] {
            if let Some(text) = row[key].as_str() {
                row[key] = json!(crate::secret_scan::mask(text));
            }
        }
        if let Some(text) = row["lastTurn"]["errorText"].as_str() {
            row["lastTurn"]["errorText"] = json!(crate::secret_scan::mask(text));
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

    /// `_acpmux/subsession/send`: a prompt from `caller` to a descendant or
    /// to its parent, queued behind a running turn, or after stopping it.
    pub async fn subsession_send(
        self: &Arc<Self>,
        caller: &Arc<Session>,
        target: &Arc<Session>,
        text: &str,
        interrupt: bool,
        prompt_id: Option<String>,
    ) -> Result<Value, RpcError> {
        if text.trim().is_empty() {
            return Err(RpcError::invalid_params("text must not be empty"));
        }
        if target.meta().status == SessionStatus::Closed {
            return Err(refused(
                "subsessions.closed",
                "that session is closed; start a new one with start_session".to_owned(),
                json!({"sessionId": target.id}),
            ));
        }
        // A child reports to its parent; it never stops the parent's turn.
        let to_parent =
            caller.meta().subsession.as_ref().is_some_and(|l| l.started_by == target.id);
        if interrupt && to_parent {
            return Err(RpcError::invalid_params(
                "a sub-session never interrupts its parent: send without interrupt, and the message waits for the parent's turn to end",
            ));
        }
        if interrupt && target.turn().is_some() {
            self.cancel(target).await?;
        }
        let accepted = self.send_family_prompt(caller, target, text, prompt_id).await?;
        Ok(json!({
            "sessionId": target.id,
            "queued": accepted.get("queued").cloned().unwrap_or(json!(false)),
            "turnId": accepted.get("turnId"),
        }))
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
    ) -> Result<Value, RpcError> {
        let tm = target.meta();
        let ceiling = match actor {
            LimitsActor::Person => (catalog().max_children.max, catalog().max_depth.max),
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
                (e.max_children, e.max_depth)
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
        {
            let mut m = target.meta.lock().unwrap_or_else(|e| e.into_inner());
            let SubsessionLimits { max_children: c, max_depth: d } = &mut m.subsession_limits;
            if let Some(v) = max_children {
                *c = v;
            }
            if let Some(v) = max_depth {
                *d = v;
            }
        }
        self.save_meta(target);
        let limits = self.subsession_limits_value(&target.meta());
        self.append(target, "mux", RECORD_KIND, json!({"event": "limits", "limits": limits}));
        Ok(json!({"sessionId": target.id, "subsessionLimits": limits}))
    }

    /// The text of the session's last agent message (its own, not a
    /// harness subagent's), from the newest records; null before any.
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
        let mut cut: String = reply.chars().take(MAX_REPLY_CHARS).collect();
        if reply.chars().count() > MAX_REPLY_CHARS {
            cut.push('…');
        }
        Some(cut)
    }
}
