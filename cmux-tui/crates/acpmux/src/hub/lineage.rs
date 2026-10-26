//! Session lineage: which session's agent started which (Leo 2026-10-21: agent-started sessions
//! nest under their parent at any depth; only person-started ones are top level).
//!
//! Recorded once, when the session is created, from a caller the daemon proved, never from a
//! request field alone:
//! - `session/new` on a connection whose `initialize` proved it runs in session P
//!   (`hub/person.rs` (a)): an agent's shell running `acpmux new` or `acpmux run`. The CLI may
//!   add the tool call that runs it (`ACPMUX_TOOL_CALL_ID`, when a harness exports it).
//! - `start_session` (`subsessions.rs`): the calling session, with its in-flight `start_session`
//!   tool call when the hub saw it ([`note_tool_call`]).
//! - A chat the person starts from a suggested task (`offers.rs`) joins the offering chat's tree,
//!   as its sub-session link does.
//!
//! The child gets `{parent, root, depth: parent's depth + 1, toolCallId?}`. A session no agent
//! started (the app, the palette, a person's terminal, a fork, a moved-in chat) is a root:
//! depth 0 and its own root. A parent that is not here leaves a root, never an error.
//!
//! One depth for every way in: a sub-session's depth is its lineage depth, and the sub-session
//! depth limit (`maxDepth`, `subsessions.rs`) refuses an `acpmux new` past it as it refuses
//! `start_session`. Sessions saved before lineage existed: a sub-session's link gives its
//! lineage ([`Hub::lineage_of`]); any other is a root.

use super::*;
use crate::store::Lineage;

/// `_meta.acpmux` field of `session/new`: the parent asked for. Absent: the proven caller.
/// Null: none (an ephemeral run, a probe: never a child). A session id: the caller itself or
/// one of its descendants, else refused.
pub const PARENT_FIELD: &str = "parent";
/// `_meta.acpmux` field of `session/new`: the caller's tool call that runs it.
pub const TOOL_CALL_FIELD: &str = "spawnToolCallId";
/// The env var a harness may set to the id of the tool call that runs a command;
/// `acpmux new` sends it as [`TOOL_CALL_FIELD`].
pub const TOOL_CALL_ENV: &str = "ACPMUX_TOOL_CALL_ID";
/// The longest tool call id kept.
const MAX_TOOL_CALL_ID: usize = 256;
/// The longest chain walked up to a root (a link loop in a hand-edited store ends here).
const MAX_WALK: usize = 1024;

/// What a `session/new` asks for its parent ([`PARENT_FIELD`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParentAsk {
    Caller,
    Root,
    Named(String),
}

/// The parent a `session/new`'s `_meta.acpmux` asks for.
pub fn parent_ask(meta: Option<&Value>) -> Result<ParentAsk, RpcError> {
    match meta.and_then(|m| m.get(PARENT_FIELD)) {
        None => Ok(ParentAsk::Caller),
        Some(Value::Null) => Ok(ParentAsk::Root),
        Some(Value::String(id)) if !id.is_empty() => Ok(ParentAsk::Named(id.clone())),
        Some(_) => Err(RpcError::invalid_params(format!(
            "_meta.acpmux.{PARENT_FIELD} must be a session id or null"
        ))),
    }
}

/// The tool call id a `session/new`'s `_meta.acpmux` names ([`TOOL_CALL_FIELD`]).
pub fn tool_call_id(meta: Option<&Value>) -> Result<Option<String>, RpcError> {
    match meta.and_then(|m| m.get(TOOL_CALL_FIELD)) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(id)) if id.is_empty() => Ok(None),
        Some(Value::String(id)) if id.len() <= MAX_TOOL_CALL_ID => Ok(Some(id.clone())),
        Some(_) => Err(RpcError::invalid_params(format!(
            "_meta.acpmux.{TOOL_CALL_FIELD} must be a string of at most {MAX_TOOL_CALL_ID} bytes"
        ))),
    }
}

/// The `start_session` tool calls of one session's agent that run, with their input.
type StartCalls = std::collections::HashMap<String, Value>;

/// Follows a `tool_call` or `tool_call_update` of `session`'s agent: a `start_session` call
/// is remembered with its input while it runs, so the start it makes can name it.
pub(super) fn note_tool_call(session: &Session, update: &Value) {
    track(&mut session.start_calls.lock().unwrap_or_else(|e| e.into_inner()), update);
}

/// The `start_session` call of `session` that asks for a child with `prompt`.
pub(super) fn start_tool_call(session: &Session, prompt: &str) -> Option<String> {
    asking(&session.start_calls.lock().unwrap_or_else(|e| e.into_inner()), prompt)
}

/// Follows one update in `calls`: a call named `start_session` (Claude Code's
/// `mcp__cmux-subsessions__start_session`, or a title) is kept until it completes or fails.
fn track(calls: &mut StartCalls, update: &Value) {
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
    let named = ["/_meta/claude/tool", "/title"]
        .iter()
        .filter_map(|p| update.pointer(p).and_then(Value::as_str))
        .any(|name| name.ends_with("start_session"));
    if named && !calls.contains_key(id) && calls.len() < 64 {
        calls.insert(id.to_owned(), Value::Null);
    }
    let Some(input) = calls.get_mut(id) else { return };
    if let Some(raw) = update.get("rawInput").filter(|v| !v.is_null()) {
        *input = raw.clone();
    }
    if matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed")) {
        calls.remove(id);
    }
}

/// The call in `calls` that asks for a child with `prompt`: the one whose input has that
/// prompt, else the only one running; None when that does not tell.
fn asking(calls: &StartCalls, prompt: &str) -> Option<String> {
    let only = |mut ids: Vec<&String>| (ids.len() == 1).then(|| ids.remove(0).clone());
    let matching: Vec<&String> = calls
        .iter()
        .filter(|(_, input)| input.get("prompt").and_then(Value::as_str) == Some(prompt))
        .map(|(id, _)| id)
        .collect();
    if matching.is_empty() { only(calls.keys().collect()) } else { only(matching) }
}

impl Hub {
    /// The lineage of the session with meta `m`: the recorded one, else (a sub-session saved
    /// before lineage existed) its link's; None for a root.
    pub fn lineage_of(&self, m: &SessionMeta) -> Option<Lineage> {
        if let Some(l) = &m.lineage {
            return Some(l.clone());
        }
        let link = m.subsession.as_ref()?;
        // The root: up the parents' links until one has none (or a recorded lineage).
        let mut root = link.started_by.clone();
        for _ in 0..MAX_WALK {
            let Some(up) = self.session_meta_by_id(&root) else { break };
            match (&up.lineage, &up.subsession) {
                (Some(l), _) => {
                    root = l.root.clone();
                    break;
                }
                (None, Some(upper)) => root = upper.started_by.clone(),
                (None, None) => break,
            }
        }
        Some(Lineage {
            parent: link.started_by.clone(),
            root,
            depth: link.depth,
            tool_call_id: None,
        })
    }

    /// The depth of the session with meta `m`: 0 for a root.
    pub fn lineage_depth(&self, m: &SessionMeta) -> u32 {
        self.lineage_of(m).map_or(0, |l| l.depth)
    }

    /// The lineage of a new child of the session with meta `pm`, started by `tool_call_id`.
    pub(super) fn lineage_under(&self, pm: &SessionMeta, tool_call_id: Option<String>) -> Lineage {
        let up = self.lineage_of(pm);
        Lineage {
            parent: pm.id.clone(),
            root: up.as_ref().map_or_else(|| pm.id.clone(), |l| l.root.clone()),
            // Saturating: a hand-edited store's depth never wraps past the depth limit.
            depth: up.map_or(0, |l| l.depth).saturating_add(1),
            tool_call_id,
        }
    }

    /// Whether `ancestor` is a strict lineage ancestor of session `id`.
    fn lineage_descends(&self, id: &str, ancestor: &str) -> bool {
        let mut next = self.session_meta_by_id(id).and_then(|m| self.lineage_of(&m));
        for _ in 0..MAX_WALK {
            let Some(l) = next else { return false };
            if l.parent == ancestor {
                return true;
            }
            next = self.session_meta_by_id(&l.parent).and_then(|m| self.lineage_of(&m));
        }
        false
    }

    /// Refuses a `session/new` that names parent `id` ([`PARENT_FIELD`]) unless the proven
    /// `caller` is that session or one of its lineage ancestors. Checked for every request
    /// that names one, also one that records no lineage (an adopted chat, an ephemeral run).
    pub fn check_lineage_parent(&self, caller: Option<&str>, id: &str) -> Result<(), RpcError> {
        if caller.is_some_and(|c| c == id || self.lineage_descends(id, c)) {
            return Ok(());
        }
        Err(RpcError::invalid_params(format!(
            "_meta.acpmux.{PARENT_FIELD} names a session this caller did not start"
        ))
        .with_data(json!({"reason": "lineage.parent_not_owned"})))
    }

    /// The lineage of a `session/new` from a connection that proved it runs in session
    /// `caller` (None: the person, the app or any client outside a session), as `ask`s.
    /// A parent that is not here leaves a root. Refused: naming a parent the caller does not
    /// own, and a depth past the parent's sub-session depth limit.
    pub fn new_session_lineage(
        &self,
        caller: Option<&str>,
        ask: ParentAsk,
        tool_call_id: Option<String>,
    ) -> Result<Option<Lineage>, RpcError> {
        let parent = match ask {
            ParentAsk::Root => return Ok(None),
            ParentAsk::Caller => match caller {
                Some(c) => c.to_owned(),
                None => return Ok(None),
            },
            ParentAsk::Named(id) => {
                self.check_lineage_parent(caller, &id)?;
                id
            }
        };
        let Some(pm) = self.session_meta_by_id(&parent) else { return Ok(None) };
        let lineage = self.lineage_under(&pm, tool_call_id);
        let limits = self.subsession_effective(&pm);
        if lineage.depth > limits.max_depth {
            return Err(super::subsessions::refused(
                "subsessions.depth_limit",
                format!(
                    "session/new refused: depth limit reached. The session this runs in is at depth {} and may start sessions only down to depth {} (source: {}). Do the work in this session instead, or ask for a deeper limit: the user can raise it (Settings > Agents > Sub-sessions > Deepest Nesting).",
                    lineage.depth - 1,
                    limits.max_depth,
                    limits.max_depth_source.as_str()
                ),
                json!({"depth": lineage.depth - 1, "maxDepth": limits.max_depth, "source": limits.max_depth_source.as_str()}),
            ));
        }
        Ok(Some(lineage))
    }

    /// The meta of the session with id `id` (an exact id, never a name or prefix).
    pub(super) fn session_meta_by_id(&self, id: &str) -> Option<SessionMeta> {
        let session = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(id)
            .cloned();
        session.map(|s| s.meta())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parent_ask_reads_absent_null_and_an_id() {
        assert_eq!(parent_ask(None).unwrap(), ParentAsk::Caller);
        assert_eq!(parent_ask(Some(&json!({}))).unwrap(), ParentAsk::Caller);
        assert_eq!(parent_ask(Some(&json!({"parent": null}))).unwrap(), ParentAsk::Root);
        assert_eq!(
            parent_ask(Some(&json!({"parent": "s1"}))).unwrap(),
            ParentAsk::Named("s1".into())
        );
        assert!(parent_ask(Some(&json!({"parent": 3}))).is_err());
        assert!(parent_ask(Some(&json!({"parent": ""}))).is_err());
    }

    #[test]
    fn tool_call_id_is_bounded() {
        assert_eq!(
            tool_call_id(Some(&json!({"spawnToolCallId": "toolu_1"}))).unwrap().as_deref(),
            Some("toolu_1")
        );
        assert_eq!(tool_call_id(Some(&json!({"spawnToolCallId": ""}))).unwrap(), None);
        assert_eq!(tool_call_id(None).unwrap(), None);
        assert!(tool_call_id(Some(&json!({"spawnToolCallId": "x".repeat(257)}))).is_err());
        assert!(tool_call_id(Some(&json!({"spawnToolCallId": 7}))).is_err());
    }

    #[test]
    fn a_running_start_session_call_names_the_child_it_asks_for() {
        let mut calls = StartCalls::new();
        let call = |id: &str, prompt: &str| {
            json!({"toolCallId": id, "status": "pending", "title": "start_session",
                   "_meta": {"claude": {"tool": "mcp__cmux-subsessions__start_session"}},
                   "rawInput": {"prompt": prompt}})
        };
        // Another tool is never kept.
        track(&mut calls, &json!({"toolCallId": "bash", "title": "ls", "status": "pending"}));
        assert_eq!(asking(&calls, "x"), None);
        track(&mut calls, &call("t1", "review"));
        // The only call running names a start even when its input is not known yet.
        assert_eq!(asking(&calls, "other").as_deref(), Some("t1"));
        track(&mut calls, &call("t2", "tests"));
        assert_eq!(asking(&calls, "tests").as_deref(), Some("t2"));
        assert_eq!(asking(&calls, "review").as_deref(), Some("t1"));
        // Two running calls and no prompt match: unknown, never a guess.
        assert_eq!(asking(&calls, "other"), None);
        track(&mut calls, &json!({"toolCallId": "t1", "status": "completed"}));
        track(&mut calls, &json!({"toolCallId": "t2", "status": "failed"}));
        assert!(calls.is_empty());
    }

    #[test]
    fn a_lineage_round_trips_and_an_old_meta_has_none() {
        let old = json!({
            "schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "fake",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        });
        let mut m: SessionMeta = serde_json::from_value(old).unwrap();
        assert_eq!(m.lineage, None);
        assert!(serde_json::to_value(&m).unwrap().get("lineage").is_none());
        m.lineage = Some(Lineage {
            parent: "p".into(),
            root: "r".into(),
            depth: 2,
            tool_call_id: Some("toolu_9".into()),
        });
        let saved = serde_json::to_value(&m).unwrap();
        assert_eq!(
            saved["lineage"],
            json!({"parent": "p", "root": "r", "depth": 2, "toolCallId": "toolu_9"})
        );
        let back: SessionMeta = serde_json::from_value(saved).unwrap();
        assert_eq!(back.lineage, m.lineage);
    }
}
