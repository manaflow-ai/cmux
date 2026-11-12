//! `fold(events) -> rows`: the row table and the one record at a time fold that keeps it.
//!
//! The fold reads records in log order (`seq` ascending). Each record begins at most one row,
//! at the end of the table, so a row's `index` and `seq` both rise with its place and nothing
//! is ever put before a row already there. A record that changes a row it did not begin writes
//! one patch for it: its text appended (`Append`), its text replaced (`Text`), or its head
//! changed (`Head`). Every patch carries the table's next version, 1.. with no gap, so a reader
//! that missed one knows it.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store::EventRecord;

/// What a row draws.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RowKind {
    /// A prompt or a steer the person (or another agent) sent: `user_message`.
    Prompt,
    /// One run of the agent's reply text (one reply segment).
    Reply,
    /// One run of the agent's thinking.
    Thought,
    /// One tool call, from its start to its end.
    Tool,
    /// The agent's checklist (a `plan` update), changed in place until the next prompt.
    Plan,
    /// A compaction, running or ended.
    Compaction,
    /// Where a turn ended (`turn_result`): its status, and where a fork can start.
    TurnEnd,
    /// A one-line notice acpmux recorded (`failover`, `forked`, `stopped`, ...).
    Notice,
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// Everything about a row but its text: what a `Head` patch carries.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowHead {
    /// The row's key: `prompt:<promptId>`, `reply:<segment>`, `tool:<toolCallId>`, or
    /// `<kind>@<seq>` for a row with no id of its own. Unique in the table.
    pub id: String,
    /// The row's place, 0.. with no gap.
    pub index: u64,
    /// The record that began the row.
    pub seq: u64,
    /// 1 when the row began, one more for each patch to it.
    pub rev: u64,
    /// Unix ms of the record that began the row.
    pub at: u64,
    pub kind: RowKind,
    /// The turn the row is in, when the log named one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
    /// A fork can be made at this row: its turn has ended. Set on the turn's `TurnEnd` row and
    /// its prompt row.
    #[serde(default, skip_serializing_if = "is_false")]
    pub forkable: bool,
    /// The row draws nothing now (a superseded reply, a cleared checklist); it keeps its place.
    #[serde(default, skip_serializing_if = "is_false")]
    pub hidden: bool,
    /// Text may still be added (a reply, thought or tool call not ended yet).
    #[serde(default, skip_serializing_if = "is_false")]
    pub streaming: bool,
    /// A prompt that steered a running turn.
    #[serde(default, skip_serializing_if = "is_false")]
    pub steer: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    /// A tool call's id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// A tool call's title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// A tool call's harness name (`_meta.claude.tool`), when it names one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// A tool call's ACP kind (`read`, `edit`, `execute`, ...).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_kind: Option<String>,
    /// A tool call's, compaction's or turn's status.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// A notice's record kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
    /// A checklist's entries as the agent sent them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<Value>,
}

/// One row: its head and its text (a prompt's, reply's or thought's words, a tool call's output).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Row {
    #[serde(flatten)]
    pub head: RowHead,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
}

/// One change to the table. `v` is the table's version after it: 1.. with no gap.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum Patch {
    /// A new row, at the end (`row.head.index` is the table's length before it).
    Insert { v: u64, row: Row },
    /// `text` added to the end of row `index`'s text.
    Append { v: u64, index: u64, rev: u64, text: String },
    /// Row `index`'s text is now `text`.
    Text { v: u64, index: u64, rev: u64, text: String },
    /// Row `head.index`'s head is now `head`.
    Head { v: u64, head: RowHead },
}

impl Patch {
    pub fn version(&self) -> u64 {
        match self {
            Patch::Insert { v, .. }
            | Patch::Append { v, .. }
            | Patch::Text { v, .. }
            | Patch::Head { v, .. } => *v,
        }
    }
}

#[cfg(test)]
/// Why a reader's copy could not take a patch: it missed one, or its copy is not the table's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PatchError {
    /// The patch is not the next version.
    Gap { have: u64, got: u64 },
    /// The patch names a row the copy does not have, or not at the next revision.
    Row { index: u64 },
}

/// Updates that neither end nor continue a reply segment, as `hub/stream.rs` counts them.
const SEGMENT_QUIET_UPDATES: &[&str] = &[
    "usage_update",
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
    "session_info_update",
    "prompt_suggestion",
    "compaction_summary",
];

/// acpmux records drawn as a one-line notice.
const NOTICE_KINDS: &[&str] = &[
    "failover",
    "forked",
    "fork_start_failed",
    "host_notice",
    "policy_unenforced",
    "recap",
    "stopping",
    "stopped",
    "exited",
];

/// The rows of one chat and what the fold needs to place the next record.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct RowTable {
    rows: Vec<Row>,
    by_id: HashMap<String, usize>,
    /// The table's version: how many patches it has made.
    version: u64,
    /// The newest record folded.
    last_seq: u64,
    /// The turn running now, as the log named it.
    turn: Option<String>,
    /// Reply segments counted in this turn, for a chunk acpmux did not stamp.
    segments: u32,
    /// The reply row text goes on in, and the `messageId` it streams.
    open_reply: Option<(usize, Option<String>)>,
    open_thought: Option<usize>,
    /// Each tool call's row by its call id.
    tools: HashMap<String, usize>,
    /// The checklist row the next plan update changes.
    plan: Option<usize>,
    /// The compaction row still running.
    compaction: Option<usize>,
    /// Each turn's prompt row, for its `forkable` at the turn's end.
    turn_prompts: HashMap<String, usize>,
    /// Each reply message's rows, for a `message_superseded` record.
    messages: HashMap<String, Vec<usize>>,
}

/// The agent update a record carries: its `params.update`, for a live `session/update` of the
/// chat itself (not a load replay, not a subagent's).
fn agent_update(rec: &EventRecord) -> Option<&Value> {
    if rec.dir != "in" || rec.kind.ends_with(".replay") {
        return None;
    }
    if rec.msg.get("method").and_then(Value::as_str) != Some(crate::rpc::method::SESSION_UPDATE) {
        return None;
    }
    let params = rec.msg.get("params")?;
    if params.pointer("/_meta/acpmux/subagent").is_some() {
        return None;
    }
    params.get("update")
}

/// The text of an ACP content value (a block, a list of them, or a tool call's wrapped block).
fn content_text(content: &Value, out: &mut String) {
    match content {
        Value::String(s) => out.push_str(s),
        Value::Array(items) => items.iter().for_each(|item| content_text(item, out)),
        Value::Object(o) => match o.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(Value::String(s)) = o.get("text") {
                    out.push_str(s);
                }
            }
            Some("content") => {
                if let Some(inner) = o.get("content") {
                    content_text(inner, out);
                }
            }
            _ => {}
        },
        _ => {}
    }
}

fn text_of(content: Option<&Value>) -> String {
    let mut out = String::new();
    if let Some(content) = content {
        content_text(content, &mut out);
    }
    out
}

fn str_at<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn owned(v: &Value, key: &str) -> Option<String> {
    str_at(v, key).map(str::to_owned)
}

impl RowTable {
    pub fn new() -> Self {
        Self::default()
    }

    /// `fold(events)`: the table of `records`, folded from empty.
    pub fn fold<'a>(records: impl IntoIterator<Item = &'a EventRecord>) -> Self {
        let mut table = Self::new();
        let mut sink = Vec::new();
        for rec in records {
            table.apply(rec, &mut sink);
            sink.clear();
        }
        table
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    pub fn version(&self) -> u64 {
        self.version
    }

    pub fn last_seq(&self) -> u64 {
        self.last_seq
    }

    pub fn row(&self, id: &str) -> Option<&Row> {
        self.by_id.get(id).and_then(|&at| self.rows.get(at))
    }

    /// Folds one record, pushing the patches it makes onto `out`. A record at or before the
    /// newest folded one changes nothing (a page read twice, a live record also paged).
    pub fn apply(&mut self, rec: &EventRecord, out: &mut Vec<Patch>) {
        if rec.seq <= self.last_seq && self.last_seq > 0 {
            return;
        }
        self.last_seq = rec.seq;
        if let Some(update) = agent_update(rec) {
            self.agent(rec, update, out);
        } else if rec.dir == "mux" {
            self.mux(rec, out);
        }
    }

    fn agent(&mut self, rec: &EventRecord, update: &Value, out: &mut Vec<Patch>) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or(rec.kind.as_str());
        if SEGMENT_QUIET_UPDATES.contains(&kind) {
            return;
        }
        if kind != "agent_message_chunk" {
            self.end_reply(out);
        }
        if kind != "agent_thought_chunk" {
            self.end_thought(out);
        }
        match kind {
            "agent_message_chunk" => self.reply(rec, update, out),
            "agent_thought_chunk" => self.thought(rec, update, out),
            "tool_call" | "tool_call_update" => self.tool(rec, update, kind == "tool_call", out),
            "plan" => self.plan(rec, update, out),
            "compaction" => self.compaction(rec, update, out),
            _ => {}
        }
    }

    fn mux(&mut self, rec: &EventRecord, out: &mut Vec<Patch>) {
        let msg = &rec.msg;
        match rec.kind.as_str() {
            "user_message" => {
                self.end_reply(out);
                self.end_thought(out);
                self.prompt(rec, out);
            }
            "turn_started" => {
                self.end_reply(out);
                self.end_thought(out);
                if let Some(turn) = owned(msg, "turnId")
                    && self.turn.as_deref() != Some(turn.as_str())
                {
                    self.open_turn(turn);
                }
            }
            "turn_result" => {
                self.end_reply(out);
                self.end_thought(out);
                self.turn_end(rec, out);
            }
            "message_superseded" => {
                if let Some(old) = str_at(msg, "oldMessageId") {
                    for at in self.messages.get(old).cloned().unwrap_or_default() {
                        self.change(at, out, |h| {
                            let was = h.hidden;
                            h.hidden = true;
                            !was
                        });
                    }
                }
            }
            kind if NOTICE_KINDS.contains(&kind) => {
                self.end_reply(out);
                self.end_thought(out);
                let text = ["text", "error", "reason", "detail"]
                    .iter()
                    .find_map(|key| owned(msg, key))
                    .unwrap_or_default();
                let head = self.head(rec, format!("{kind}@{}", rec.seq), RowKind::Notice);
                self.insert(RowHead { notice: Some(kind.to_owned()), ..head }, text, out);
            }
            _ => {}
        }
    }

    fn open_turn(&mut self, turn: String) {
        self.turn = Some(turn);
        self.segments = 0;
    }

    fn prompt(&mut self, rec: &EventRecord, out: &mut Vec<Patch>) {
        let msg = &rec.msg;
        let steer = msg.get("steer").and_then(Value::as_bool) == Some(true);
        if !steer {
            // A prompt starts a new checklist.
            self.plan = None;
            if let Some(turn) = owned(msg, "turnId") {
                self.open_turn(turn);
            }
        }
        let prompt_id = owned(msg, "promptId");
        let text = msg.get("text").and_then(Value::as_str).unwrap_or_default().to_owned();
        let id = prompt_id
            .as_ref()
            .map_or_else(|| format!("prompt@{}", rec.seq), |p| format!("prompt:{p}"));
        // The same prompt again (the steer that ran as its next prompt): its row, where it is.
        if let Some(&at) = self.by_id.get(&id) {
            let turn = (!steer).then(|| self.turn.clone()).flatten();
            self.change(at, out, |h| {
                let before = (h.steer, h.turn.clone());
                h.steer = h.steer && steer;
                if turn.is_some() {
                    h.turn = turn;
                }
                before != (h.steer, h.turn.clone())
            });
            if !steer && let Some(turn) = self.turn.clone() {
                self.turn_prompts.insert(turn, at);
            }
            if self.rows.get(at).is_some_and(|row| row.text != text) {
                self.set_text(at, text, out);
            }
            return;
        }
        let head = self.head(rec, id, RowKind::Prompt);
        let at = self.insert(RowHead { steer, prompt_id, ..head }, text, out);
        if !steer && let Some(turn) = self.turn.clone() {
            self.turn_prompts.insert(turn, at);
        }
    }

    fn turn_end(&mut self, rec: &EventRecord, out: &mut Vec<Patch>) {
        let msg = &rec.msg;
        let turn = owned(msg, "turnId").or_else(|| self.turn.clone());
        let id =
            turn.as_ref().map_or_else(|| format!("turn-end@{}", rec.seq), |t| format!("turn:{t}"));
        let id = if self.by_id.contains_key(&id) { format!("{id}@{}", rec.seq) } else { id };
        let head = self.head(rec, id, RowKind::TurnEnd);
        let status = owned(msg, "status");
        self.insert(
            RowHead { turn: turn.clone(), forkable: true, status, ..head },
            String::new(),
            out,
        );
        if let Some(at) = turn.as_ref().and_then(|t| self.turn_prompts.get(t)).copied() {
            self.change(at, out, |h| !std::mem::replace(&mut h.forkable, true));
        }
        if let Some(at) = self.compaction.take() {
            self.change(at, out, |h| std::mem::replace(&mut h.streaming, false));
        }
        self.turn = None;
        self.segments = 0;
    }

    fn reply(&mut self, rec: &EventRecord, update: &Value, out: &mut Vec<Patch>) {
        let text = text_of(update.get("content"));
        if text.is_empty() {
            return;
        }
        let message_id = owned(update, "messageId");
        let stamped = update
            .pointer("/_meta/acpmux/segment")
            .or_else(|| rec.msg.pointer("/params/_meta/acpmux/segment"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty());
        let goes_on = match (stamped, self.open_reply.as_ref()) {
            // acpmux named the segment: its row, if that is the reply streaming now.
            (Some(segment), Some((open, _))) => {
                self.by_id.get(&format!("reply:{segment}")).copied().filter(|at| at == open)
            }
            (Some(_), None) => None,
            // Counted as `hub/stream.rs` does: the same message, nothing between.
            (None, Some((at, open))) if *open == message_id => Some(*at),
            (None, _) => None,
        };
        if let Some(at) = goes_on {
            self.open_reply = Some((at, message_id));
            self.append(at, &text, out);
            return;
        }
        self.end_reply(out);
        self.segments = self.segments.saturating_add(1);
        let segment = stamped.map_or_else(
            || format!("{}.{}", self.turn.as_deref().unwrap_or("-"), self.segments),
            str::to_owned,
        );
        let mut id = format!("reply:{segment}");
        if self.by_id.contains_key(&id) {
            // A segment id seen before (acpmux's count starts again after a restart).
            id = format!("{id}@{}", rec.seq);
        }
        let head = self.head(rec, id, RowKind::Reply);
        let at = self.insert(
            RowHead { streaming: true, message_id: message_id.clone(), ..head },
            text,
            out,
        );
        if let Some(m) = &message_id {
            self.messages.entry(m.clone()).or_default().push(at);
        }
        self.open_reply = Some((at, message_id));
    }

    fn thought(&mut self, rec: &EventRecord, update: &Value, out: &mut Vec<Patch>) {
        let text = text_of(update.get("content"));
        if text.is_empty() {
            return;
        }
        if let Some(at) = self.open_thought {
            self.append(at, &text, out);
            return;
        }
        let head = self.head(rec, format!("thought@{}", rec.seq), RowKind::Thought);
        self.open_thought = Some(self.insert(RowHead { streaming: true, ..head }, text, out));
    }

    fn tool(&mut self, rec: &EventRecord, update: &Value, starts: bool, out: &mut Vec<Patch>) {
        let call = owned(update, "toolCallId").unwrap_or_else(|| format!("@{}", rec.seq));
        let status = owned(update, "status");
        let ended = |s: Option<&str>| matches!(s, Some("completed" | "failed"));
        let known = self.tools.get(&call).copied().filter(|&at| {
            // A call starting under an id whose call has ended is a new call.
            !(starts && ended(self.rows.get(at).and_then(|row| row.head.status.as_deref())))
        });
        let title = owned(update, "title");
        let tool = update.pointer("/_meta/claude/tool").and_then(Value::as_str).map(str::to_owned);
        let tool_kind = owned(update, "kind");
        let content = update.get("content").filter(|c| !c.is_null()).map(|c| text_of(Some(c)));
        let streamed = update.pointer("/_meta/terminal_output/data").and_then(Value::as_str);
        let Some(at) = known else {
            let mut id = format!("tool:{call}");
            if self.by_id.contains_key(&id) {
                id = format!("{id}@{}", rec.seq);
            }
            let head = self.head(rec, id, RowKind::Tool);
            let streaming = !ended(status.as_deref());
            let text = format!("{}{}", content.unwrap_or_default(), streamed.unwrap_or_default());
            let head = RowHead {
                streaming,
                call_id: Some(call.clone()),
                title,
                tool,
                tool_kind,
                status,
                ..head
            };
            let at = self.insert(head, text, out);
            self.tools.insert(call, at);
            return;
        };
        self.change(at, out, |h| {
            let before = (h.title.clone(), h.tool.clone(), h.tool_kind.clone(), h.status.clone());
            if title.is_some() {
                h.title = title;
            }
            if tool.is_some() {
                h.tool = tool;
            }
            if tool_kind.is_some() {
                h.tool_kind = tool_kind;
            }
            if status.is_some() {
                h.status = status;
            }
            h.streaming = h.streaming && !ended(h.status.as_deref());
            before != (h.title.clone(), h.tool.clone(), h.tool_kind.clone(), h.status.clone())
        });
        if let Some(text) = content
            && self.rows.get(at).is_some_and(|row| row.text != text)
        {
            self.set_text(at, text, out);
        }
        if let Some(data) = streamed.filter(|d| !d.is_empty()) {
            self.append(at, data, out);
        }
    }

    fn plan(&mut self, rec: &EventRecord, update: &Value, out: &mut Vec<Patch>) {
        let entries = update.get("entries").cloned().unwrap_or(Value::Null);
        let cleared = entries.as_array().is_some_and(Vec::is_empty);
        if let Some(at) = self.plan {
            self.change(at, out, |h| {
                let before = (h.plan.clone(), h.hidden);
                h.plan = Some(entries);
                h.hidden = cleared;
                before != (h.plan.clone(), h.hidden)
            });
            return;
        }
        if cleared {
            return;
        }
        let head = self.head(rec, format!("plan@{}", rec.seq), RowKind::Plan);
        self.plan = Some(self.insert(RowHead { plan: Some(entries), ..head }, String::new(), out));
    }

    fn compaction(&mut self, rec: &EventRecord, update: &Value, out: &mut Vec<Patch>) {
        let state = owned(update, "state").or_else(|| owned(update, "status"));
        let running = state.as_deref().is_none_or(|s| s == "running");
        if let Some(at) = self.compaction {
            self.change(at, out, |h| {
                let before = (h.status.clone(), h.streaming);
                h.status = state;
                h.streaming = running;
                before != (h.status.clone(), h.streaming)
            });
            if !running {
                self.compaction = None;
            }
            return;
        }
        let head = self.head(rec, format!("compaction@{}", rec.seq), RowKind::Compaction);
        let at =
            self.insert(RowHead { status: state, streaming: running, ..head }, String::new(), out);
        if running {
            self.compaction = Some(at);
        }
    }

    fn end_reply(&mut self, out: &mut Vec<Patch>) {
        if let Some((at, _)) = self.open_reply.take() {
            self.change(at, out, |h| std::mem::replace(&mut h.streaming, false));
        }
    }

    fn end_thought(&mut self, out: &mut Vec<Patch>) {
        if let Some(at) = self.open_thought.take() {
            self.change(at, out, |h| std::mem::replace(&mut h.streaming, false));
        }
    }

    /// A new row's head: begun by `rec`, at the end, in the running turn.
    fn head(&self, rec: &EventRecord, id: String, kind: RowKind) -> RowHead {
        RowHead {
            id,
            index: self.rows.len() as u64,
            seq: rec.seq,
            rev: 1,
            at: rec.at,
            kind,
            turn: self.turn.clone(),
            forkable: false,
            hidden: false,
            streaming: false,
            steer: false,
            prompt_id: None,
            message_id: None,
            call_id: None,
            title: None,
            tool: None,
            tool_kind: None,
            status: None,
            notice: None,
            plan: None,
        }
    }

    fn next_version(&mut self) -> u64 {
        self.version = self.version.saturating_add(1);
        self.version
    }

    fn insert(&mut self, head: RowHead, text: String, out: &mut Vec<Patch>) -> usize {
        let at = self.rows.len();
        self.by_id.insert(head.id.clone(), at);
        let row = Row { head, text };
        let v = self.next_version();
        out.push(Patch::Insert { v, row: row.clone() });
        self.rows.push(row);
        at
    }

    /// Changes row `at`'s head with `edit`, which says whether it changed anything; a change is
    /// one `Head` patch.
    fn change(&mut self, at: usize, out: &mut Vec<Patch>, edit: impl FnOnce(&mut RowHead) -> bool) {
        let Some(row) = self.rows.get_mut(at) else { return };
        let head = &mut row.head;
        if !edit(head) {
            return;
        }
        head.rev = head.rev.saturating_add(1);
        let head = head.clone();
        let v = self.next_version();
        out.push(Patch::Head { v, head });
    }

    /// `text` onto the end of row `at`'s text: costs `text`'s length, whatever the table holds.
    fn append(&mut self, at: usize, text: &str, out: &mut Vec<Patch>) {
        let Some(row) = self.rows.get_mut(at) else { return };
        row.text.push_str(text);
        row.head.rev = row.head.rev.saturating_add(1);
        let (index, rev) = (row.head.index, row.head.rev);
        let v = self.next_version();
        out.push(Patch::Append { v, index, rev, text: text.to_owned() });
    }

    fn set_text(&mut self, at: usize, text: String, out: &mut Vec<Patch>) {
        let Some(row) = self.rows.get_mut(at) else { return };
        row.text.clone_from(&text);
        row.head.rev = row.head.rev.saturating_add(1);
        let (index, rev) = (row.head.index, row.head.rev);
        let v = self.next_version();
        out.push(Patch::Text { v, index, rev, text });
    }
}

#[cfg(test)]
/// A reader's copy of the table: rows and the version it is at. What the page keeps, in Rust, so
/// the tests can check the patch stream rebuilds the table exactly.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct RowMirror {
    pub rows: Vec<Row>,
    pub version: u64,
}

#[cfg(test)]
#[allow(
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "a test reader's copy: an index past its rows is a failed test"
)]
impl RowMirror {
    /// Takes the next patch; refuses one that is not the next version or names a row out of turn.
    pub fn apply(&mut self, patch: &Patch) -> Result<(), PatchError> {
        let v = patch.version();
        if v != self.version + 1 {
            return Err(PatchError::Gap { have: self.version, got: v });
        }
        let next_rev = |rows: &[Row], index: u64, rev: u64| -> Result<usize, PatchError> {
            let at = usize::try_from(index).map_err(|_| PatchError::Row { index })?;
            match rows.get(at) {
                Some(row) if row.head.rev + 1 == rev => Ok(at),
                _ => Err(PatchError::Row { index }),
            }
        };
        match patch {
            Patch::Insert { row, .. } => {
                if row.head.index != self.rows.len() as u64 || row.head.rev != 1 {
                    return Err(PatchError::Row { index: row.head.index });
                }
                self.rows.push(row.clone());
            }
            Patch::Append { index, rev, text, .. } => {
                let at = next_rev(&self.rows, *index, *rev)?;
                self.rows[at].text.push_str(text);
                self.rows[at].head.rev = *rev;
            }
            Patch::Text { index, rev, text, .. } => {
                let at = next_rev(&self.rows, *index, *rev)?;
                self.rows[at].text.clone_from(text);
                self.rows[at].head.rev = *rev;
            }
            Patch::Head { head, .. } => {
                let at = next_rev(&self.rows, head.index, head.rev)?;
                if self.rows[at].head.id != head.id {
                    return Err(PatchError::Row { index: head.index });
                }
                self.rows[at].head = head.clone();
            }
        }
        self.version = v;
        Ok(())
    }
}
