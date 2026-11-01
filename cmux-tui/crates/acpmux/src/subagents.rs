//! Subagent attribution for session updates.
//!
//! Harnesses report subagents three ways: native ACP subagent sessions
//! (draft agentclientprotocol/agent-client-protocol#1992: `subagent_spawned`,
//! `subagent_state_update`, and the child's updates under its own session
//! id), Codex's legacy `spawnAgent` collaboration calls, and Codex's legacy
//! subagent activity items. The hub forwards every update under its own
//! session id, so the child's id would be lost; this module writes one model
//! into each update's `_meta.acpmux` instead:
//!
//! - `subagent`: the subagent whose session the update belongs to.
//! - `subagents`: subagents this update starts or changes, each
//!   `{id, parent, name?, task?, prompt?, kind?, state, toolCallId?}`, with `parent`
//!   null for the session's own subagents and `state` one of `running`,
//!   `completed`, `failed`, `cancelled` or `disconnected`. A running one's
//!   progress adds `tokens`, `toolUses`, `elapsedMs`, `action` and, for a
//!   Claude workflow (`kind: "workflow"`), `agents: {done, started, failed?,
//!   queued?}`, its `runId` and `scriptPath` (what a resume names again)
//!   and `argsDigest` (a digest of its args, never the args) and, from Claude's progress snapshots, its
//!   `phases` (`{index, title}`, whole, when they change) and
//!   `workflowAgents`: each agent that changed, as its `index` and only the
//!   fields that changed (a removed one null), which a client merges by the
//!   subagent's id and `index`; at the run's end, every agent whole with
//!   `workflowAgentsFull: true`, which replaces them. An agent's fields are `label`, `state` (`queued`, `running`,
//!   `completed`, `failed`, `skipped` or `blocked`), `phase`, `phaseIndex`,
//!   `agentId`, `kind`, `model`, `effort`, `fallbackModel`, `tokens`, `toolUses`,
//!   `elapsedMs`, `queuedAt`, `startedAt`, `lastProgressAt`, `attempt`,
//!   `retryReason`, `cached`, `isolation`, `remoteSessionId`, `action`,
//!   `prompt`, `result` and `error` (`claude_stdio/workflows.rs`). A
//!   subagent's end may say why (`reason`: `paused` for a Claude workflow a
//!   resume can pick up by its `runId`). A failed one may say its `error`, and a Claude
//!   agent its `agentId` (what SendMessage resumes it by; a resume reports it `running`
//!   again).
//!   `background: true` marks one that outlives its parent's turn (every
//!   Codex child, which runs in its own thread).

use crate::hub::merge_mux_meta;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};

/// Whether a `session/update` params object is a subagent's (the hub tags it
/// `_meta.acpmux.subagent`, ``SubagentTree::annotate``). A subagent's text and
/// thinking reach its own view; a reader of the chat's own words (a reply, a
/// transcript, a handoff) skips them, or a subagent's report would join the
/// chat's answer.
pub fn is_subagents(params: &Value) -> bool {
    params.pointer("/_meta/acpmux/subagent").is_some()
}

/// The subagents seen in one session, each mapped to its parent subagent
/// (`None` for the session's own).
#[derive(Debug, Default)]
pub struct SubagentTree {
    parents: HashMap<String, Option<String>>,
    /// Children whose sender was not in the replay window yet. Once that sender
    /// appears, they can be restored as genuine grandchildren.
    pending: HashMap<String, HashSet<String>>,
    /// Bounded per-child text; projected only on existing lifecycle/progress events.
    previews: HashMap<String, ChildPreview>,
    /// The session's own agent session id (its harness thread), once known:
    /// never one of its subagents.
    own: Option<String>,
    /// The background subagents still running: they outlive the turn that
    /// started them, so the session works on past it (`hub/work_below.rs`).
    background: HashSet<String>,
    /// Every subagent that runs now (live updates only), foreground or background, at any
    /// depth, oldest first, each with the label a list names it by (its name, else its task):
    /// the summary's `subagentsRunning` and `subagentNames` (`hub/views.rs`).
    running: Vec<(String, Option<String>)>,
    /// Codex's native ids for this session. Legacy activity can echo a root id
    /// while a child is running; it is the root, never a subagent. The tree
    /// lives as long as the hub session, and a harness restart or a new Codex
    /// conversation names a new root, so every root learned is kept: replayed
    /// history still names the earlier ones.
    root_threads: HashSet<String>,
}

#[derive(Debug, Default)]
struct ChildPreview {
    text: String,
    message_id: Option<String>,
    streaming: bool,
    tokens: Option<u64>,
}

impl SubagentTree {
    /// Seed the native harness session id before the first update. The hub's
    /// ACP wrapper id is different from Codex's native thread id. A new id (a
    /// harness restart, a new conversation) joins the roots already known.
    pub fn set_root(&mut self, id: &str) {
        self.remember_root(id);
    }

    /// Seeds every native root the chat had: its current id and its earlier ones
    /// (`SessionMeta::retired_agent_session_ids`), which replayed or persisted records still name.
    pub fn set_roots<'a>(&mut self, roots: impl IntoIterator<Item = &'a str>) {
        for root in roots {
            self.remember_root(root);
        }
    }

    /// Whether `session_id` is one of this session's subagents.
    pub fn owns(&self, session_id: &str) -> bool {
        self.own.as_deref() != Some(session_id) && self.parents.contains_key(session_id)
    }

    /// Names the session's own agent session id. A subagent may report its
    /// parent thread's state (Codex's app server sends a child's
    /// `subagent_state_update` for the root thread when the child talks to
    /// it); that is not a spawn, and recording it made the chat its own
    /// subagent: every later update of the chat read as that subagent's, and
    /// every later spawn nested under it.
    pub fn set_own(&mut self, own: Option<&str>) {
        if self.own.as_deref() != own {
            self.own = own.map(str::to_owned);
        }
    }

    /// Writes the subagent model into one `session/update`'s params. Returns
    /// the subagent the update belongs to, or `None` for the session's own.
    pub fn annotate(&mut self, params: &mut Value) -> Option<String> {
        self.annotate_live(params, true)
    }

    /// ``annotate``; a replayed update (`live` false: a `session/load` replays history) never
    /// changes which background subagents run, since the replay may hold a start without its end.
    pub fn annotate_live(&mut self, params: &mut Value, live: bool) -> Option<String> {
        let owner = params
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|sid| self.owns(sid))
            .map(str::to_owned);
        if let (Some(child), Some(update)) = (owner.as_deref(), params.get("update")) {
            let preview = self.previews.entry(child.to_owned()).or_default();
            match update.get("sessionUpdate").and_then(Value::as_str) {
                Some("agent_message_chunk") => {
                    let id = update.get("messageId").and_then(Value::as_str).map(str::to_owned);
                    if !preview.streaming || id != preview.message_id {
                        preview.text.clear();
                    }
                    preview.streaming = true;
                    preview.message_id = id;
                    if let Some(text) = update.pointer("/content/text").and_then(Value::as_str) {
                        // One child, bounded bytes, no sibling walk and no new event per token.
                        let left = LAST_MESSAGE_CHARS + 1 - preview.text.chars().count();
                        preview.text.extend(text.chars().take(left));
                    }
                }
                Some("usage_update") => {
                    // Claude's `used` is context-window occupancy, not token usage.
                    // Only a supplied `totalTokens` is a cumulative token total; an update
                    // without it must not erase a previously reported real total.
                    if let Some(total) = update.get("totalTokens").and_then(Value::as_u64) {
                        preview.tokens = Some(total);
                    }
                }
                Some("agent_thought_chunk" | "config_option_update" | "session_info_update") => {}
                _ => preview.streaming = false,
            }
        }
        let mut events =
            params.get("update").map(|u| self.events(u, owner.as_deref())).unwrap_or_default();
        for event in &mut events {
            let Some(id) = event.get("id").and_then(Value::as_str) else { continue };
            let preview = self.previews.entry(id.to_owned()).or_default();
            // A progress/state event is authoritative over an earlier usage_update;
            // retain its total for a later lifecycle event that omits tokens.
            if let Some(tokens) = event.get("tokens").and_then(Value::as_u64) {
                preview.tokens = Some(tokens);
            }
            if let Some(message) = event.get("lastMessage").and_then(Value::as_str) {
                // Explicit lifecycle text supersedes streamed text for later events.
                preview.text = message.to_owned();
                preview.streaming = false;
            }
            if event.get("tokens").is_none()
                && let Some(tokens) = preview.tokens
                && let Some(object) = event.as_object_mut()
            {
                object.insert("tokens".into(), json!(tokens));
            }
            if event.get("lastMessage").is_none()
                && !preview.text.is_empty()
                && let Some(object) = event.as_object_mut()
            {
                object.insert("lastMessage".into(), json!(truncate_last_message(&preview.text)));
            }
        }
        let mut fields = Map::new();
        if let Some(owner) = &owner {
            fields.insert("subagent".into(), json!(owner));
        }
        if live {
            self.note_background(&events);
            self.note_running(&events);
        }
        if !events.is_empty() {
            fields.insert("subagents".into(), Value::Array(events));
        }
        if !fields.is_empty() {
            merge_mux_meta(params, Value::Object(fields));
        }
        owner
    }

    /// How many background subagents still run.
    pub fn background_running(&self) -> usize {
        self.background.len()
    }

    /// The harness is gone, and its background subagents with it.
    pub fn end_background(&mut self) {
        self.background.clear();
        self.running.clear();
    }

    /// The subagents that run now and their labels, oldest first. A foreground subagent ends
    /// with its turn even when the harness never said so (a cancelled turn), so without a
    /// running turn (`turn_runs` false) only the background ones count.
    pub fn running_now(&self, turn_runs: bool) -> Vec<(&str, Option<&str>)> {
        self.running
            .iter()
            .filter(|(id, _)| turn_runs || self.background.contains(id))
            .map(|(id, label)| (id.as_str(), label.as_deref()))
            .collect()
    }

    /// A turn ended or a new one began: the foreground subagents of the one before are over
    /// even when the harness never said so (a cancelled turn), so only the background ones
    /// still run. Without it, the next turn's `running_now(true)` showed them again.
    pub fn end_foreground(&mut self) {
        let background = &self.background;
        self.running.retain(|(id, _)| background.contains(id));
    }

    /// How many subagents run now, whatever their turn (`running_now` with a running turn):
    /// the tap compares it around each update to tell watchers of a change.
    pub fn running_count(&self) -> usize {
        self.running.len()
    }

    /// Follows every running subagent through one live update's events: one that runs joins
    /// (keeping the first label any event gives it), any that ends leaves.
    fn note_running(&mut self, events: &[Value]) {
        for event in events {
            let Some(id) = event.get("id").and_then(Value::as_str) else { continue };
            let at = self.running.iter().position(|(known, _)| known == id);
            if event.get("state").and_then(Value::as_str) != Some("running") {
                if let Some(at) = at {
                    self.running.remove(at);
                }
                continue;
            }
            let label = ["name", "task"]
                .iter()
                .filter_map(|k| event.get(*k).and_then(Value::as_str))
                // A task can be the subagent's whole prompt: its secrets are masked before it is
                // cut, as a turn's preview is (`session::masked_preview`), so none leaves on the
                // summary's `subagentNames` or half a one survives the cut.
                .map(|t| {
                    crate::secret_scan::mask(t).split_whitespace().collect::<Vec<_>>().join(" ")
                })
                .find(|t| !t.is_empty())
                .map(|t| truncate_label(&t));
            match at {
                Some(at) => {
                    if let Some(slot) = self.running.get_mut(at)
                        && slot.1.is_none()
                    {
                        slot.1 = label;
                    }
                }
                None => self.running.push((id.to_owned(), label)),
            }
        }
    }

    /// Follows the background subagents through one update's events: one
    /// marked `background` that runs is added (a later event of it need not
    /// repeat the mark), and any that ends leaves.
    fn note_background(&mut self, events: &[Value]) {
        for event in events {
            let Some(id) = event.get("id").and_then(Value::as_str) else { continue };
            if event.get("state").and_then(Value::as_str) != Some("running") {
                self.background.remove(id);
            } else if event.get("background") == Some(&Value::Bool(true)) {
                self.background.insert(id.to_owned());
            }
        }
    }

    fn events(&mut self, update: &Value, owner: Option<&str>) -> Vec<Value> {
        let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("subagent_spawned") => {
                let Some(id) = s(update, "subagentSessionId") else { return vec![] };
                let Some(mut event) = self.spawn(&id, owner) else { return vec![] };
                for key in ["name", "task", "prompt"] {
                    if let Some(v) = s(update, key) {
                        event.insert(key.into(), json!(v));
                    }
                }
                for key in ["model", "effort", "reasoningEffort", "lastMessage", "last_message"] {
                    if let Some(v) = s(update, key) {
                        let key = if key == "reasoningEffort" {
                            "effort"
                        } else if key == "last_message" {
                            "lastMessage"
                        } else {
                            key
                        };
                        event.insert(
                            key.into(),
                            json!(if key == "lastMessage" { truncate_last_message(&v) } else { v }),
                        );
                    }
                }
                // The tool call that started it (Claude's Agent call), which a
                // client drawing the subagent can leave out.
                if let Some(call) = update.pointer("/_meta/claude/toolUseId") {
                    event.insert("toolCallId".into(), call.clone());
                }
                // The kind of agent it is (Claude's subagent_type: Explore,
                // general-purpose, a user agent), drawn beside its name.
                if let Some(kind) =
                    update.pointer("/_meta/claude/subagentType").and_then(Value::as_str)
                {
                    event.insert("kind".into(), json!(kind));
                }
                if update.get("background") == Some(&Value::Bool(true)) {
                    event.insert("background".into(), json!(true));
                }
                event.insert("state".into(), json!("running"));
                vec![Value::Object(event)]
            }
            Some("subagent_state_update") => {
                let Some(id) = s(update, "subagentSessionId") else { return vec![] };
                let state = s(update, "state").unwrap_or_else(|| "completed".into());
                let Some(mut event) = self.spawn(&id, owner) else { return vec![] };
                event.insert("state".into(), json!(state));
                // Why it ended, when the harness says (`paused`: a Claude workflow
                // whose run a resume can pick up again by its `runId`).
                if let Some(reason) = s(update, "reason") {
                    event.insert("reason".into(), json!(reason));
                }
                // A failed Claude agent's error, and the agent id SendMessage resumes it by.
                for key in ["agentId", "error", "model", "effort", "lastMessage"] {
                    if let Some(v) = s(update, key) {
                        event.insert(
                            key.into(),
                            json!(if key == "lastMessage" { truncate_last_message(&v) } else { v }),
                        );
                    }
                }
                if let Some(tokens) = update.get("tokens").and_then(Value::as_u64) {
                    event.insert("tokens".into(), json!(tokens));
                }
                vec![Value::Object(event)]
            }
            // A running subagent's or workflow's live numbers (claude_stdio/workflows.rs).
            Some("subagent_progress") => {
                let Some(id) = s(update, "subagentSessionId") else { return vec![] };
                let Some(mut event) = self.spawn(&id, owner) else { return vec![] };
                event.insert("state".into(), json!("running"));
                for key in [
                    "name",
                    "task",
                    "tokens",
                    "toolUses",
                    "elapsedMs",
                    "action",
                    "agents",
                    "runId",
                    "scriptPath",
                    "argsDigest",
                    "phases",
                    "workflowAgents",
                    "workflowAgentsFull",
                    "background",
                    "model",
                    "effort",
                    "reasoningEffort",
                    "lastMessage",
                    "last_message",
                ] {
                    if let Some(v) = update.get(key).filter(|v| !v.is_null()) {
                        let key = if key == "reasoningEffort" {
                            "effort"
                        } else if key == "last_message" {
                            "lastMessage"
                        } else {
                            key
                        };
                        let value = if key == "lastMessage" {
                            v.as_str()
                                .map(truncate_last_message)
                                .map(Value::String)
                                .unwrap_or_else(|| v.clone())
                        } else {
                            v.clone()
                        };
                        event.insert(key.into(), value);
                    }
                }
                vec![Value::Object(event)]
            }
            Some("tool_call" | "tool_call_update") => self.codex_legacy(update, owner),
            _ => vec![],
        }
    }

    /// Codex without native subagent sessions: `spawnAgent` collaboration
    /// calls list their children and states; activity items name one child.
    /// Each child runs in its own thread and outlives the turn that spawned it
    /// (the model may end its turn without a `wait`), so every one is
    /// `background`: a client never ends it at its turn's end.
    fn codex_legacy(&mut self, update: &Value, owner: Option<&str>) -> Vec<Value> {
        let codex = update.pointer("/_meta/codex");
        if let Some(collab) = codex.and_then(|c| c.get("collaboration"))
            && collab.get("tool").and_then(Value::as_str) == Some("spawnAgent")
        {
            let sender = collab.get("senderThreadId").and_then(Value::as_str);
            let input = update.get("rawInput");
            let states = input.and_then(|i| i.get("agentsStates"));
            let task = input.and_then(|i| i.get("prompt")).and_then(Value::as_str);
            let ids = collab
                .get("receiverThreadIds")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            return ids
                .iter()
                .filter_map(Value::as_str)
                .filter_map(|id| {
                    let status = states
                        .and_then(|s| s.get(id))
                        .and_then(|s| s.get("status"))
                        .and_then(Value::as_str);
                    // A sender this tree knows (the root or a child) decides the parent. An unseen
                    // one decides nothing yet: the child keeps any parent it has, and moves under the
                    // sender once that sender's own spawn arrives (`resolve_pending`).
                    let resolved = sender.is_some_and(|sender| {
                        self.is_root(sender) || self.parents.contains_key(sender)
                    });
                    let (parent, authoritative) = match sender {
                        Some(sender) if resolved => (self.authoritative_parent(sender), true),
                        Some(_) => (None, false),
                        None => (owner.map(str::to_owned), false),
                    };
                    if let Some(sender) = sender {
                        self.remember_pending(sender, id);
                    }
                    let mut event = if authoritative {
                        self.spawn_authoritative(id, parent.as_deref())?
                    } else {
                        self.spawn_with_parent(id, parent.as_deref())?
                    };
                    if let Some(task) = task {
                        event.insert("task".into(), json!(task));
                    }
                    for key in ["model", "effort", "reasoningEffort", "lastMessage", "last_message"]
                    {
                        if let Some(v) = update
                            .get(key)
                            .or_else(|| input.and_then(|i| i.get(key)))
                            .and_then(Value::as_str)
                        {
                            let key = if key == "reasoningEffort" {
                                "effort"
                            } else if key == "last_message" {
                                "lastMessage"
                            } else {
                                key
                            };
                            event.insert(
                                key.into(),
                                json!(if key == "lastMessage" {
                                    truncate_last_message(v)
                                } else {
                                    v.to_owned()
                                }),
                            );
                        }
                    }
                    if let Some(v) =
                        update.pointer("/_meta/codex/subagent/model").and_then(Value::as_str)
                    {
                        event.insert("model".into(), json!(v));
                    }
                    if let Some(v) =
                        update.pointer("/_meta/codex/subagent/effort").and_then(Value::as_str)
                    {
                        event.insert("effort".into(), json!(v));
                    }
                    if let Some(v) =
                        update.pointer("/_meta/codex/subagent/lastMessage").and_then(Value::as_str)
                    {
                        event.insert("lastMessage".into(), json!(truncate_last_message(v)));
                    }
                    if let Some(v) =
                        update.pointer("/_meta/codex/subagent/tokens").and_then(Value::as_u64)
                    {
                        event.insert("tokens".into(), json!(v));
                    }
                    event.insert("state".into(), json!(codex_state(status)));
                    event.insert("background".into(), json!(true));
                    if let Some(call) = update.get("toolCallId") {
                        event.insert("toolCallId".into(), call.clone());
                    }
                    Some(Value::Object(event))
                })
                .collect();
        }
        let Some(activity) = codex.and_then(|c| c.get("subagent")) else { return vec![] };
        let Some(id) = activity.get("threadId").and_then(Value::as_str) else { return vec![] };
        // The root's own id is occasionally echoed as a legacy activity item
        // while a direct child is active. Do not manufacture a root child.
        if self.is_root(id) {
            return vec![];
        }
        let name = activity
            .get("path")
            .and_then(Value::as_str)
            .and_then(|p| p.split('/').rfind(|part| !part.is_empty()))
            .map(str::to_owned);
        let state = match activity.get("activity").and_then(Value::as_str) {
            Some("completed") => "completed",
            Some("interrupted") => "cancelled",
            _ => "running",
        };
        let Some(mut event) = self.spawn(id, owner) else { return vec![] };
        if let Some(name) = name {
            event.insert("name".into(), json!(name));
        }
        for (from, to) in [
            ("model", "model"),
            ("effort", "effort"),
            ("reasoningEffort", "effort"),
            ("lastMessage", "lastMessage"),
            ("last_message", "lastMessage"),
        ] {
            if let Some(value) = activity.get(from).and_then(Value::as_str) {
                event.insert(
                    to.into(),
                    json!(if to == "lastMessage" {
                        truncate_last_message(value)
                    } else {
                        value.to_owned()
                    }),
                );
            }
        }
        if let Some(tokens) = activity.get("tokens").and_then(Value::as_u64) {
            event.insert("tokens".into(), json!(tokens));
        }
        event.insert("state".into(), json!(state));
        event.insert("background".into(), json!(true));
        vec![Value::Object(event)]
    }

    /// Records `id` under `owner` the first time it appears and starts its
    /// event with its id and parent. None when `id` is not a subagent of
    /// `owner`'s: the session itself, the known native root, or an ancestor.
    fn spawn(&mut self, id: &str, owner: Option<&str>) -> Option<Map<String, Value>> {
        self.spawn_with_parent(id, owner)
    }

    fn spawn_authoritative(
        &mut self,
        id: &str,
        parent: Option<&str>,
    ) -> Option<Map<String, Value>> {
        if self.own.as_deref() == Some(id) || self.is_root(id) || self.is_ancestor(id, parent) {
            return None;
        }
        self.forget_pending(id);
        let parent = parent.map(str::to_owned);
        let stored = self.parents.entry(id.to_owned()).or_insert_with(|| parent.clone());
        if *stored != parent {
            *stored = parent;
        }
        let current = stored.clone();
        self.resolve_pending(id);
        let mut event = Map::new();
        event.insert("id".into(), json!(id));
        event.insert("parent".into(), json!(current));
        Some(event)
    }

    fn spawn_with_parent(&mut self, id: &str, parent: Option<&str>) -> Option<Map<String, Value>> {
        if self.own.as_deref() == Some(id) || self.is_root(id) || self.is_ancestor(id, parent) {
            return None;
        }
        let parent =
            self.parents.entry(id.to_owned()).or_insert_with(|| parent.map(str::to_owned)).clone();
        self.resolve_pending(id);
        let mut event = Map::new();
        event.insert("id".into(), json!(id));
        event.insert("parent".into(), json!(parent));
        Some(event)
    }

    /// Whether `id` is `of` or above it in the tree.
    fn is_ancestor(&self, id: &str, of: Option<&str>) -> bool {
        let mut at = of;
        // The tree has no loops (``spawn``), but a bound costs nothing.
        for _ in 0..=self.parents.len() {
            match at {
                Some(node) if node == id => return true,
                Some(node) => at = self.parents.get(node).and_then(Option::as_deref),
                None => return false,
            }
        }
        false
    }

    /// Codex's sender id is authoritative when it names a known child or the
    /// native root. An unseen sender is deliberately left parentless: it may
    /// be a child whose spawn record has not arrived yet, so treating it as the
    /// root would create the hierarchy shown by the reported bug.
    fn authoritative_parent(&self, sender: &str) -> Option<String> {
        if self.is_root(sender) {
            None
        } else if self.parents.contains_key(sender) {
            Some(sender.to_owned())
        } else {
            None
        }
    }

    fn remember_pending(&mut self, sender: &str, child: &str) {
        if !self.is_root(sender) && !self.parents.contains_key(sender) {
            self.pending.entry(sender.to_owned()).or_default().insert(child.to_owned());
        }
    }

    fn forget_pending(&mut self, child: &str) {
        self.pending.retain(|_, children| {
            children.remove(child);
            !children.is_empty()
        });
    }

    fn resolve_pending(&mut self, sender: &str) {
        let Some(children) = self.pending.remove(sender) else { return };
        for child in children {
            if self.is_ancestor(&child, Some(sender)) {
                continue;
            }
            if let Some(parent) = self.parents.get_mut(&child) {
                *parent = Some(sender.to_owned());
            }
        }
    }

    fn is_root(&self, id: &str) -> bool {
        self.root_threads.contains(id)
    }

    /// Record a native root id (a restart's new root joins the earlier ones),
    /// and repair an out-of-order echo that arrived before session metadata
    /// identified it.
    fn remember_root(&mut self, id: &str) {
        // The hub seeds the roots on every update: a known one allocates nothing.
        if self.is_root(id) {
            return;
        }
        self.root_threads.insert(id.to_owned());
        self.previews.remove(id);
        self.parents.remove(id);
        let root_children = self.pending.remove(id).unwrap_or_default();
        for child in root_children {
            self.forget_pending(&child);
            if let Some(parent) = self.parents.get_mut(&child) {
                *parent = None;
            }
        }
        // An echo that arrived before the root was known counted it as background work.
        self.background.remove(id);
        self.running.retain(|(known, _)| known != id);
        let children = self
            .parents
            .iter()
            .filter_map(|(child, parent)| (parent.as_deref() == Some(id)).then_some(child.clone()))
            .collect::<Vec<_>>();
        for child in children {
            self.forget_pending(&child);
            if let Some(parent) = self.parents.get_mut(&child) {
                *parent = None;
            }
        }
    }
}

/// The most characters of a running subagent's label (`SubagentTree::running_now`).
const LABEL_CHARS: usize = 60;

fn truncate_label(text: &str) -> String {
    if text.chars().count() <= LABEL_CHARS {
        return text.to_owned();
    }
    let cut: String = text.chars().take(LABEL_CHARS - 1).collect();
    format!("{}…", cut.trim_end())
}

/// A Codex agent status as a subagent state (codex-acp's `terminalStateOf`).
fn codex_state(status: Option<&str>) -> &'static str {
    match status {
        Some("completed") => "completed",
        Some("interrupted") => "cancelled",
        Some("errored" | "shutdown" | "notFound") => "failed",
        _ => "running",
    }
}

/// Keep the latest agent text bounded while respecting UTF-8 character
/// boundaries. This is intentionally done only when a subagent event is
/// already being emitted, never for every streamed token.
const LAST_MESSAGE_CHARS: usize = 240;

fn truncate_last_message(text: &str) -> String {
    let mut chars = text.chars();
    let value: String = chars.by_ref().take(LAST_MESSAGE_CHARS).collect();
    if chars.next().is_some() {
        format!("{}…", value.chars().take(LAST_MESSAGE_CHARS - 1).collect::<String>())
    } else {
        value
    }
}

#[cfg(test)]
mod codex_tests {
    use super::*;

    fn subagents(tree: &mut SubagentTree, update: Value) -> Vec<Value> {
        subagents_for(tree, "s1", update)
    }

    fn subagents_for(tree: &mut SubagentTree, session_id: &str, update: Value) -> Vec<Value> {
        let mut params = json!({"sessionId": session_id, "update": update});
        tree.annotate(&mut params);
        params
            .pointer("/_meta/acpmux/subagents")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    }

    /// Leo's Codex chat (2026-10-22): its child `needs_you_review` reported
    /// the chat's own thread as running, under the child's session. That is
    /// not a spawn: the chat stays the root, its own updates stay its own, and
    /// its next child sits beside the first rather than under the chat.
    #[test]
    fn a_child_reporting_its_parent_thread_never_makes_the_chat_a_subagent() {
        let chat = "01a1658b-c32f-72b1-ab04-d5444235a91c";
        let review = "01a16655-c696-7982-9c38-9ededd986f9b";
        let prior_art = "01a16656-bb2d-7513-b459-4a893451d37a";
        let mut tree = SubagentTree::default();
        tree.set_own(Some(chat));
        let mut annotate = |sid: &str, update: Value| {
            let mut params = json!({"sessionId": sid, "update": update});
            let owner = tree.annotate(&mut params);
            (owner, params.pointer("/_meta/acpmux").cloned())
        };
        annotate(
            chat,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": review,
                   "name": "needs_you_review", "task": "needs_you_review"}),
        );
        // The child names its parent thread.
        let (owner, mux) = annotate(
            review,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": chat, "state": "running"}),
        );
        assert_eq!(owner.as_deref(), Some(review));
        assert_eq!(mux, Some(json!({"subagent": review})), "the chat is not one of its subagents");
        // The chat's own words stay the chat's.
        let (owner, mux) = annotate(
            chat,
            json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}}),
        );
        assert_eq!((owner, mux), (None, None));
        // Its next child is a top-level subagent, not a grandchild under the chat.
        let (_, mux) = annotate(
            chat,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": prior_art,
                   "name": "needs_you_prior_art"}),
        );
        assert_eq!(mux.unwrap()["subagents"][0]["parent"], Value::Null);
        // A grandchild reporting on the subagent above it makes no loop either.
        let grandchild = "01a16657-46e1-79a0-a61e-d1a99a36d095";
        annotate(
            prior_art,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": grandchild, "name": "g"}),
        );
        let (_, mux) = annotate(
            grandchild,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": prior_art, "state": "running"}),
        );
        assert_eq!(mux, Some(json!({"subagent": grandchild})));
        assert!(!tree.owns(chat));
    }

    /// A failed Claude agent's entry says why and which agent a resume names.
    #[test]
    fn a_failed_subagent_carries_its_error_and_agent_id() {
        let mut tree = SubagentTree::default();
        subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "s1/t1", "name": "Push relay"}),
        );
        let end = subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "s1/t1", "state": "failed",
                   "agentId": "a8e1", "error": "API Error: 503"}),
        );
        assert_eq!(
            end,
            [
                json!({"id": "s1/t1", "parent": null, "state": "failed", "agentId": "a8e1", "error": "API Error: 503"})
            ]
        );
    }

    /// Codex runs a `spawnAgent` child in its own thread: it outlives the turn
    /// that spawned it (the model may end its turn without a `wait`), so it is
    /// background work, and a client never ends it at the turn's end.
    #[test]
    fn codex_spawned_agents_are_background() {
        let mut tree = SubagentTree::default();
        let spawn = subagents(
            &mut tree,
            json!({"sessionUpdate": "tool_call", "toolCallId": "c1",
                   "rawInput": {"prompt": "Audit", "agentsStates": {"t1": {"status": "running"}}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent", "receiverThreadIds": ["t1"]}}}}),
        );
        assert_eq!(spawn.len(), 1);
        assert_eq!(spawn[0]["background"], json!(true));
        let activity = subagents(
            &mut tree,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c2",
                   "_meta": {"codex": {"subagent": {"threadId": "t1", "path": "/root/auditor", "activity": "working"}}}}),
        );
        assert_eq!(activity[0]["state"], json!("running"));
        assert_eq!(activity[0]["background"], json!(true));
    }

    #[test]
    fn claude_context_occupancy_is_not_reported_as_tokens() {
        let mut tree = SubagentTree::default();
        subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "claude-child"}),
        );
        let mut usage = json!({
            "sessionId": "claude-child",
            "update": {"sessionUpdate": "usage_update", "used": 100, "size": 200000}
        });
        tree.annotate(&mut usage);
        let completed = subagents(
            &mut tree,
            json!({
                "sessionUpdate": "subagent_state_update",
                "subagentSessionId": "claude-child",
                "state": "completed"
            }),
        );
        assert!(
            completed[0].get("tokens").is_none(),
            "context occupancy leaked as tokens: {completed:?}"
        );
    }

    #[test]
    fn claude_context_updates_do_not_erase_a_real_token_total() {
        let mut tree = SubagentTree::default();
        subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "claude-child"}),
        );
        let mut total = json!({
            "sessionId": "claude-child",
            "update": {"sessionUpdate": "usage_update", "totalTokens": 42}
        });
        tree.annotate(&mut total);
        let mut context = json!({
            "sessionId": "claude-child",
            "update": {"sessionUpdate": "usage_update", "used": 100, "size": 200000}
        });
        tree.annotate(&mut context);
        let completed = subagents(
            &mut tree,
            json!({
                "sessionUpdate": "subagent_state_update",
                "subagentSessionId": "claude-child",
                "state": "completed"
            }),
        );
        assert_eq!(completed[0]["tokens"], 42);
    }

    #[test]
    fn subagent_progress_tokens_take_precedence_over_cached_usage() {
        let mut tree = SubagentTree::default();
        subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "child"}),
        );
        let mut usage =
            json!({"sessionId": "child", "update": {"sessionUpdate": "usage_update", "used": 100}});
        tree.annotate(&mut usage);
        let events = subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "child", "tokens": 200}),
        );
        assert_eq!(events[0]["tokens"], 200);
        let completed = subagents(
            &mut tree,
            json!({
                "sessionUpdate": "subagent_state_update",
                "subagentSessionId": "child",
                "state": "completed"
            }),
        );
        assert_eq!(completed[0]["tokens"], 200);
        let explicit = subagents(
            &mut tree,
            json!({
                "sessionUpdate": "subagent_state_update",
                "subagentSessionId": "child",
                "state": "completed",
                "tokens": 300,
                "lastMessage": "final answer"
            }),
        );
        assert_eq!(explicit[0]["tokens"], 300);
        assert_eq!(explicit[0]["lastMessage"], "final answer");
    }

    #[test]
    fn native_and_codex_subagents_carry_orchestration_fields() {
        let mut tree = SubagentTree::default();
        let native = subagents(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "claude/task",
                "model": "claude-opus", "effort": "high", "lastMessage": "é".repeat(300)}),
        );
        assert_eq!(native[0]["model"], "claude-opus");
        assert_eq!(native[0]["effort"], "high");
        assert_eq!(native[0]["lastMessage"].as_str().unwrap().chars().count(), 240);

        let codex = subagents(
            &mut tree,
            json!({"sessionUpdate": "tool_call_update",
                "_meta": {"codex": {"subagent": {"threadId": "codex/task",
                    "activity": "working", "model": "gpt-6", "effort": "xhigh",
                    "lastMessage": "Reviewing", "tokens": 1234}}}}),
        );
        assert_eq!(
            codex[0],
            json!({"id": "codex/task", "parent": null,
                "model": "gpt-6", "effort": "xhigh", "lastMessage": "Reviewing", "tokens": 1234,
                "state": "running", "background": true})
        );
    }
    /// A Codex root's native thread id may be echoed by a direct child as a legacy
    /// activity item. It is the root that issued the call, never a child of that
    /// direct child; later root spawns must remain siblings in the model.
    #[test]
    fn codex_root_thread_is_never_inserted_as_a_nested_subagent() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        let review = "review-thread";
        let prior_art = "prior-art-thread";
        tree.set_root(root);

        let first = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [review]}}}}),
        );
        assert_eq!(first[0]["id"], review);
        assert_eq!(first[0]["parent"], Value::Null);

        // The child reports an activity item carrying the root's own native id.
        let echoed = subagents_for(
            &mut tree,
            review,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
        );
        assert!(echoed.is_empty(), "root echo became a child: {echoed:?}");

        let second = subagents_for(
            &mut tree,
            root,
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-prior-art",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [prior_art]}}}}),
        );
        assert_eq!(second[0]["id"], prior_art);
        assert_eq!(second[0]["parent"], Value::Null);
    }

    #[test]
    fn codex_child_sender_remains_the_parent_of_a_grandchild() {
        let mut tree = SubagentTree::default();
        let child = "review-thread";
        let grandchild = "review-helper-thread";
        let first = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "root-native-thread", "receiverThreadIds": [child]}}}}),
        );
        assert_eq!(first[0]["parent"], Value::Null);
        let nested = subagents_for(
            &mut tree,
            child,
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-helper",
                   "rawInput": {"prompt": "Helper", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": child, "receiverThreadIds": [grandchild]}}}}),
        );
        assert_eq!(nested[0]["id"], grandchild);
        assert_eq!(nested[0]["parent"], child);
    }

    #[test]
    fn a_known_child_sender_wins_over_the_wrapper_session_id() {
        let mut tree = SubagentTree::default();
        let child = "review-thread";
        let helper = "review-helper-thread";
        let first = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "root-native-thread", "receiverThreadIds": [child]}}}}),
        );
        assert_eq!(first[0]["parent"], Value::Null);
        let nested = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-helper",
                   "rawInput": {"prompt": "Helper", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": child, "receiverThreadIds": [helper]}}}}),
        );
        assert_eq!(nested[0]["id"], helper);
        assert_eq!(nested[0]["parent"], child);
    }

    #[test]
    fn a_known_root_sender_clears_a_wrong_parent_even_on_a_child_session_update() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        let child = "review-thread";
        let prior_art = "prior-art-thread";
        tree.set_root(root);
        let _ = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [child]}}}}),
        );
        // Simulate a malformed persisted first record; the next authoritative
        // root call must normalize it to a direct child.
        let malformed = subagents_for(
            &mut tree,
            child,
            json!({"sessionUpdate": "tool_call", "toolCallId": "old-spawn",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "receiverThreadIds": [prior_art]}}}}),
        );
        assert_eq!(malformed[0]["parent"], child);
        let repaired = subagents_for(
            &mut tree,
            child,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "root-replay",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [prior_art]}}}}),
        );
        assert_eq!(repaired[0]["parent"], Value::Null);
    }

    #[test]
    fn an_unseen_sender_does_not_fall_back_to_the_update_owner() {
        let mut tree = SubagentTree::default();
        let owner = "known-child";
        let _ = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": owner}),
        );
        let child = subagents_for(
            &mut tree,
            owner,
            json!({"sessionUpdate": "tool_call", "toolCallId": "unknown-sender",
                   "rawInput": {"prompt": "Unknown", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": "unseen-child", "receiverThreadIds": ["grandchild"]}}}}),
        );
        assert_eq!(child[0]["parent"], Value::Null);
    }

    #[test]
    fn an_unseen_sender_keeps_the_childs_parent() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        tree.set_root(root);
        let spawn = |tree: &mut SubagentTree, sender: &str, child: &str| {
            subagents_for(
                tree,
                "acp-root",
                json!({"sessionUpdate": "tool_call", "toolCallId": format!("spawn-{child}"),
                       "rawInput": {"prompt": "Work", "agentsStates": {}},
                       "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                         "senderThreadId": sender, "receiverThreadIds": [child]}}}}),
            )
        };
        spawn(&mut tree, root, "child");
        spawn(&mut tree, "child", "grandchild");
        assert_eq!(tree.parents.get("grandchild"), Some(&Some("child".to_owned())));
        // A later update names a sender whose spawn is outside the retained history.
        let again = spawn(&mut tree, "outside-history", "grandchild");
        assert_eq!(again[0]["parent"], "child");
        assert_eq!(tree.parents.get("grandchild"), Some(&Some("child".to_owned())));
    }

    #[test]
    fn a_grandchild_replayed_before_its_parent_is_reparented() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        let child = "child-thread";
        let grandchild = "grandchild-thread";
        tree.set_root(root);

        let early = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-grandchild",
                   "rawInput": {"prompt": "Grandchild", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": child, "receiverThreadIds": [grandchild]}}}}),
        );
        assert_eq!(early[0]["parent"], Value::Null);

        let _ = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-child",
                   "rawInput": {"prompt": "Child", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [child]}}}}),
        );
        assert_eq!(tree.parents.get(grandchild), Some(&Some(child.to_owned())));
    }

    #[test]
    fn an_authoritative_parent_clears_a_stale_pending_sender() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        let parent = "parent-thread";
        let child = "child-thread";
        let unseen = "unseen-sender";
        tree.set_root(root);
        let spawn = |tree: &mut SubagentTree, sender: &str, id: &str| {
            subagents_for(
                tree,
                "acp-root",
                json!({"sessionUpdate": "tool_call", "toolCallId": format!("spawn-{id}"),
                       "rawInput": {"prompt": "Work", "agentsStates": {}},
                       "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                         "senderThreadId": sender, "receiverThreadIds": [id]}}}}),
            )
        };
        let _ = spawn(&mut tree, root, parent);
        let _ = spawn(&mut tree, unseen, child);
        let _ = spawn(&mut tree, root, child);
        let _ = spawn(&mut tree, root, unseen);

        assert_eq!(tree.parents.get(parent), Some(&None));
        assert_eq!(tree.parents.get(child), Some(&None));
        assert_eq!(tree.parents.get(unseen), Some(&None));
    }

    #[test]
    fn learning_the_root_promotes_its_pending_children() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        let child = "child-thread";
        tree.parents.insert(child.to_owned(), Some("stale-parent".to_owned()));
        tree.pending.entry(root.to_owned()).or_default().insert(child.to_owned());

        tree.set_root(root);

        assert_eq!(tree.parents.get(child), Some(&None));
        assert!(!tree.pending.contains_key(root));
    }

    /// A root echo that arrives before the root is known reads as a running
    /// background child. Learning the root later must drop it from the
    /// background set too: no end event ever comes for it, so it would keep the
    /// session busy after the real child finishes.
    #[test]
    fn a_late_known_root_stops_counting_as_a_background_subagent() {
        let mut tree = SubagentTree::default();
        let root = "root-native-thread";
        let review = "review-thread";
        let echoed = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
        );
        assert_eq!(echoed[0]["background"], json!(true));
        let _ = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [review]}}}}),
        );
        assert_eq!(tree.background_running(), 2);
        tree.set_root(root);
        let _ = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "review-done",
                   "_meta": {"codex": {"subagent": {"threadId": review,
                     "activity": "completed"}}}}),
        );
        assert_eq!(tree.background_running(), 0, "the root is not background work");
    }

    /// The tree lives as long as the hub session, but a harness restart or a new
    /// Codex conversation gives the session a new native root id. The new root
    /// must be treated as a root too, not as an ordinary subagent; an echo of it
    /// recorded before the restart was known stops counting as background work.
    #[test]
    fn a_root_learned_after_a_restart_is_also_a_root() {
        let mut tree = SubagentTree::default();
        let first_root = "root-before-restart";
        let root = "root-after-restart";
        let review = "review-thread";
        let prior_art = "prior-art-thread";
        tree.set_root(first_root);

        // After the restart, the new root is echoed before the session metadata
        // names it, so it reads as running background work.
        let early = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-early",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
        );
        assert_eq!(early[0]["background"], json!(true));
        tree.set_root(root);
        assert_eq!(tree.background_running(), 0, "the new root is not background work");

        let first = subagents_for(
            &mut tree,
            "acp-root",
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-review",
                   "rawInput": {"prompt": "Review", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [review]}}}}),
        );
        assert_eq!(first[0]["id"], review);
        assert_eq!(first[0]["parent"], Value::Null);

        let echoed = subagents_for(
            &mut tree,
            review,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
                   "_meta": {"codex": {"subagent": {"threadId": root,
                     "path": "/root", "activity": "working"}}}}),
        );
        assert!(echoed.is_empty(), "the new root's echo became a child: {echoed:?}");

        let second = subagents_for(
            &mut tree,
            root,
            json!({"sessionUpdate": "tool_call", "toolCallId": "spawn-prior-art",
                   "rawInput": {"prompt": "Prior art", "agentsStates": {}},
                   "_meta": {"codex": {"collaboration": {"tool": "spawnAgent",
                     "senderThreadId": root, "receiverThreadIds": [prior_art]}}}}),
        );
        assert_eq!(second[0]["id"], prior_art);
        assert_eq!(second[0]["parent"], Value::Null);
        assert!(!tree.owns(root), "the new root is not a subagent");
    }
}

#[cfg(test)]
mod background_tests {
    use super::*;

    fn annotate(tree: &mut SubagentTree, update: Value, live: bool) {
        let mut params = json!({"sessionId": "s1", "update": update});
        tree.annotate_live(&mut params, live);
    }

    /// manaflow-ai/cmux#25230: the background subagents a chat runs past its turn, from their
    /// start to their end; a foreground one ends with its turn, and a replay changes nothing.
    #[test]
    fn background_subagents_run_from_their_start_to_their_end() {
        let mut tree = SubagentTree::default();
        tree.set_own(Some("s1"));
        let spawn = |id: &str, background: bool| json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "background": background});
        let end = |id: &str| json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": id, "state": "completed"});
        annotate(&mut tree, spawn("fg", false), true);
        assert_eq!(tree.background_running(), 0);
        annotate(&mut tree, spawn("replayed", true), false);
        assert_eq!(tree.background_running(), 0, "a replay starts nothing");
        annotate(&mut tree, spawn("bg", true), true);
        // Moved to the background later (Claude's task_started is_backgrounded).
        annotate(
            &mut tree,
            json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "fg", "background": true}),
            true,
        );
        assert_eq!(tree.background_running(), 2);
        // Progress without the mark keeps it.
        annotate(
            &mut tree,
            json!({"sessionUpdate": "subagent_progress", "subagentSessionId": "bg"}),
            true,
        );
        assert_eq!(tree.background_running(), 2);
        annotate(&mut tree, end("bg"), true);
        annotate(&mut tree, end("fg"), true);
        assert_eq!(tree.background_running(), 0);
        annotate(&mut tree, spawn("bg2", true), true);
        tree.end_background();
        assert_eq!(tree.background_running(), 0, "its harness exited");
    }

    /// The hover card's live count (cmux NEXT sidebar, Leo 2026-11-01: "this hover preview being
    /// able to see the # of associated subagents"): every running subagent, foreground or
    /// background, nested ones too, with its name; a replay counts none, and without a running
    /// turn only the background ones still run.
    #[test]
    fn running_subagents_are_counted_with_their_names_from_start_to_end() {
        let mut tree = SubagentTree::default();
        tree.set_own(Some("s1"));
        let spawn = |id: &str, name: &str, background: bool| json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "name": name, "background": background});
        let end = |id: &str| json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": id, "state": "completed"});
        annotate(&mut tree, spawn("replayed", "Old", false), false);
        assert_eq!(tree.running_count(), 0, "a replay starts nothing");
        annotate(&mut tree, spawn("a", "Review the sidebar", false), true);
        annotate(&mut tree, spawn("b", "Fix   the\nbuild", true), true);
        annotate(&mut tree, spawn("c", &"x".repeat(80), false), true);
        assert_eq!(tree.running_count(), 3);
        let names: Vec<_> =
            tree.running_now(true).into_iter().map(|(_, l)| l.unwrap().to_owned()).collect();
        assert_eq!(names[0], "Review the sidebar");
        assert_eq!(names[1], "Fix the build", "one line, single spaces");
        assert_eq!(names[2].chars().count(), LABEL_CHARS, "a long name is cut");
        assert_eq!(tree.running_now(false).len(), 1, "between turns only the background one runs");
        annotate(&mut tree, end("a"), true);
        assert_eq!(tree.running_count(), 2);
        assert_eq!(tree.running_now(true)[0].0, "b", "oldest first");
        tree.end_background();
        assert_eq!(tree.running_count(), 0, "its harness exited");
    }

    /// A subagent named by its task (its prompt) never carries a credential out to the summary.
    #[test]
    fn a_running_subagents_task_label_has_its_secrets_masked() {
        let mut tree = SubagentTree::default();
        tree.set_own(Some("s1"));
        let token: String = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k");
        let task = format!("Push with GITHUB_TOKEN={token} and open the PR");
        annotate(
            &mut tree,
            json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "a", "task": task}),
            true,
        );
        let label = tree.running_now(true)[0].1.unwrap().to_owned();
        assert!(!label.contains(&token), "the token survives in {label:?}");
        assert!(label.starts_with("Push with"), "{label:?}");
    }

    /// Two turns in a row: the first turn's foreground subagents, whose ends the harness never
    /// sent, are gone once it ends, and only its background one runs on into the next.
    #[test]
    fn a_turns_foreground_subagents_do_not_show_again_in_the_next_turn() {
        let mut tree = SubagentTree::default();
        tree.set_own(Some("s1"));
        let spawn = |id: &str, background: bool| json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": id, "name": id, "background": background});
        annotate(&mut tree, spawn("fg1", false), true);
        annotate(&mut tree, spawn("bg1", true), true);
        assert_eq!(tree.running_now(true).len(), 2, "turn 1");
        tree.end_foreground();
        annotate(&mut tree, spawn("fg2", false), true);
        let ids: Vec<_> = tree.running_now(true).into_iter().map(|(id, _)| id).collect();
        assert_eq!(ids, vec!["bg1", "fg2"], "turn 2 shows its own and the background one");
    }

    /// A legacy activity echo of the native root that arrives before the root is known counts as
    /// running background work; recognizing the root afterwards must stop counting it.
    #[test]
    fn a_late_root_seed_stops_counting_its_echo_as_background_work() {
        let mut tree = SubagentTree::default();
        tree.set_own(Some("s1"));
        annotate(
            &mut tree,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "echo-root",
                   "_meta": {"codex": {"subagent": {"threadId": "root-native",
                     "path": "/root", "activity": "working"}}}}),
            true,
        );
        assert_eq!(tree.background_running(), 1, "the echo was counted before the root was known");
        tree.set_root("root-native");
        assert_eq!(tree.background_running(), 0, "the native root is not background work");
    }
}
