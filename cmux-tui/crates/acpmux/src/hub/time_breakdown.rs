//! Incremental per-chat time and token attribution.
//!
//! The reducer consumes journal records in order. A session seeds it once from its
//! journal and then feeds it records as they are appended. Recent spans are bounded;
//! category totals remain complete for the lifetime of the chat.

use crate::store::EventRecord;
use schemars::JsonSchema;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, VecDeque};

const MAX_SPANS: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Category {
    Read,
    Edit,
    Run,
    Think,
    Person,
    Model,
}

impl Category {
    const ALL: [Self; 6] =
        [Self::Read, Self::Edit, Self::Run, Self::Think, Self::Person, Self::Model];

    fn id(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Edit => "edit",
            Self::Run => "run",
            Self::Think => "think",
            Self::Person => "person",
            Self::Model => "model",
        }
    }
}

#[derive(Debug, Clone, Serialize, JsonSchema, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TimeCategory {
    pub id: String,
    pub wall_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<u64>,
}

#[derive(Debug, Clone, Serialize, JsonSchema, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TimeSpan {
    pub turn_seq: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    pub category: String,
    pub start_at: u64,
    pub end_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<u64>,
    /// Whole-turn usage, not usage attributed to this interval.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_tokens: Option<u64>,
}

#[derive(Debug, Clone, Serialize, JsonSchema, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TimeBreakdown {
    pub total_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_tokens: Option<u64>,
    pub tokens_complete: bool,
    pub categories: Vec<TimeCategory>,
    pub spans: Vec<TimeSpan>,
}

#[derive(Debug, Clone)]
struct Segment {
    category: Category,
    start_at: u64,
    end_at: u64,
}

#[derive(Debug, Clone)]
struct TurnState {
    seq: u64,
    id: Option<String>,
    start_at: u64,
    last_at: u64,
    phase: Category,
    waiting_requests: BTreeMap<String, Option<Value>>,
    status_waiting: bool,
    end_marker: bool,
    tools: BTreeMap<String, Category>,
    segments: VecDeque<Segment>,
    /// Durations evicted from the bounded recent span window.
    segment_totals: BTreeMap<Category, u64>,
}

impl TurnState {
    fn new(seq: u64, id: Option<String>, at: u64) -> Self {
        Self {
            seq,
            id,
            start_at: at,
            last_at: at,
            phase: Category::Model,
            waiting_requests: BTreeMap::new(),
            status_waiting: false,
            end_marker: false,
            tools: BTreeMap::new(),
            segments: VecDeque::new(),
            segment_totals: BTreeMap::new(),
        }
    }

    fn category(&self) -> Category {
        if self.status_waiting || !self.waiting_requests.is_empty() {
            return Category::Person;
        }
        // Concurrent tools share wall time. Attribute overlap to the lowest tool id
        // deterministically rather than counting the same interval more than once.
        self.tools.values().next().copied().unwrap_or(self.phase)
    }

    fn advance(&mut self, at: u64) {
        let at = at.max(self.last_at);
        if self.end_marker || at <= self.last_at {
            return;
        }
        let category = self.category();
        if let Some(last) = self.segments.back_mut()
            && last.category == category
            && last.end_at == self.last_at
        {
            last.end_at = at;
        } else {
            if self.segments.len() >= MAX_SPANS
                && let Some(evicted) = self.segments.pop_front()
            {
                *self.segment_totals.entry(evicted.category).or_default() +=
                    evicted.end_at.saturating_sub(evicted.start_at);
            }
            self.segments.push_back(Segment { category, start_at: self.last_at, end_at: at });
        }
        self.last_at = at;
    }
}

#[derive(Debug, Default)]
pub(crate) struct State {
    pub(crate) initialized: bool,
    reducer: Reducer,
}

#[derive(Debug, Clone, Default)]
struct Reducer {
    turn: Option<TurnState>,
    totals: BTreeMap<Category, u64>,
    spans: Vec<TimeSpan>,
    total_ms: u64,
    total_tokens: u64,
    ended_turns: u64,
    token_turns: u64,
    last_seq: u64,
}

impl State {
    pub(crate) fn record(&mut self, record: &EventRecord) {
        if record.seq <= self.reducer.last_seq {
            return;
        }
        self.reducer.last_seq = record.seq;
        self.reducer.record(record);
    }

    pub(crate) fn snapshot(&self, now: u64) -> TimeBreakdown {
        let mut reducer = self.reducer.clone();
        if let Some(turn) = reducer.turn.as_mut() {
            turn.advance(now);
        }
        reducer.output(true)
    }
}

impl Reducer {
    fn record(&mut self, record: &EventRecord) {
        let at = record.at;
        if record.msg.get("params").is_some_and(crate::subagents::is_subagents) {
            return;
        }
        match record.kind.as_str() {
            "user_message" if self.turn.as_ref().is_none_or(|turn| turn.end_marker) => {
                self.start_turn(
                    turn_seq(&record.msg).unwrap_or(record.seq),
                    turn_id(&record.msg),
                    at,
                );
            }
            "turn_started" => {
                let seq = turn_seq(&record.msg).unwrap_or(record.seq);
                let id = turn_id(&record.msg);
                if self.turn.as_ref().is_some_and(|turn| {
                    turn.end_marker || (turn.id.is_some() && id.is_some() && turn.id != id)
                }) {
                    self.start_turn(seq, id, at);
                } else if let Some(turn) = self.turn.as_mut() {
                    turn.seq = seq;
                    if id.is_some() {
                        turn.id = id;
                    }
                } else {
                    self.start_turn(seq, id, at);
                }
            }
            "tool_call" => {
                self.ensure_turn(record);
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    if let Some(id) = tool_id(&record.msg)
                        && !terminal_tool_update(&record.msg)
                    {
                        turn.tools.insert(id, tool_category(&record.msg));
                    }
                    turn.phase = Category::Model;
                }
            }
            "tool_call_update" => {
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    if terminal_tool_update(&record.msg)
                        && let Some(id) = tool_id(&record.msg)
                    {
                        turn.tools.remove(&id);
                    } else if value(&record.msg, "kind").is_some()
                        && let Some(id) = tool_id(&record.msg)
                        && let Some(category) = turn.tools.get_mut(&id)
                    {
                        *category = tool_category(&record.msg);
                    }
                }
            }
            "agent_thought_chunk" => {
                self.ensure_turn(record);
                if let Some(turn) = self.turn.as_mut()
                    && turn.phase != Category::Think
                {
                    turn.advance(at);
                    turn.phase = Category::Think;
                }
            }
            "agent_message_chunk" => {
                self.ensure_turn(record);
                if let Some(turn) = self.turn.as_mut()
                    && turn.phase != Category::Model
                {
                    turn.advance(at);
                    turn.phase = Category::Model;
                }
            }
            "permission_request" | "permission_reissued" => {
                self.ensure_turn(record);
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    turn.waiting_requests.insert(
                        permission_id(&record.msg),
                        record.msg.get("agentRequestId").cloned(),
                    );
                }
            }
            "permission_decision"
            | "permission_auto"
            | "permission_resolved"
            | "permission_withdrawn" => {
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    if record.kind == "permission_withdrawn"
                        && let Some(request) = record.msg.get("agentRequestId")
                    {
                        turn.waiting_requests.retain(|_, agent| agent.as_ref() != Some(request));
                    } else {
                        turn.waiting_requests.remove(&permission_id(&record.msg));
                    }
                    if turn.waiting_requests.is_empty() {
                        turn.status_waiting = false;
                    }
                    turn.phase = Category::Model;
                }
            }
            "status" => {
                if let Some(turn) = self.turn.as_mut()
                    && record.msg.get("status").and_then(Value::as_str) == Some("waiting")
                {
                    turn.advance(at);
                    turn.status_waiting = true;
                } else if let Some(turn) = self.turn.as_mut()
                    && matches!(
                        record.msg.get("status").and_then(Value::as_str),
                        Some("running" | "working")
                    )
                {
                    turn.advance(at);
                    turn.status_waiting = false;
                } else if let Some(turn) = self.turn.as_mut()
                    && matches!(
                        record.msg.get("status").and_then(Value::as_str),
                        Some("closed" | "idle")
                    )
                {
                    turn.advance(at);
                    turn.end_marker = true;
                }
            }
            "turn_result" => {
                if self.turn.as_ref().is_some_and(|turn| {
                    let id = turn_id(&record.msg);
                    turn.id.is_some() && id.is_some() && turn.id != id
                }) {
                    return;
                }
                if let Some(mut turn) = self.turn.take() {
                    turn.advance(at);
                    self.finish(turn, usage(&record.msg));
                }
            }
            "turn_end" | "turn_error" => {
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    turn.end_marker = true;
                    // Some harnesses emit an end marker before the result carrying usage. Keep
                    // the turn open so that result can close it and retain its token totals.
                }
            }
            _ => {}
        }
    }

    fn start_turn(&mut self, seq: u64, id: Option<String>, at: u64) {
        if let Some(mut turn) = self.turn.take() {
            turn.advance(at);
            self.finish(turn, None);
        }
        self.turn = Some(TurnState::new(seq, id, at));
    }

    fn ensure_turn(&mut self, record: &EventRecord) {
        if self.turn.is_none() {
            self.start_turn(
                turn_seq(&record.msg).unwrap_or(record.seq),
                turn_id(&record.msg),
                record.at,
            );
        }
    }

    fn finish(&mut self, turn: TurnState, usage: Option<u64>) {
        self.ended_turns = self.ended_turns.saturating_add(1);
        let mut by_category = turn.segment_totals;
        for segment in &turn.segments {
            let ms = segment.end_at.saturating_sub(segment.start_at);
            *by_category.entry(segment.category).or_default() += ms;
            self.spans.push(TimeSpan {
                turn_seq: turn.seq,
                turn_id: turn.id.clone(),
                category: segment.category.id().to_owned(),
                start_at: segment.start_at,
                end_at: segment.end_at,
                tokens: None,
                turn_tokens: usage,
            });
        }
        let duration = turn.last_at.saturating_sub(turn.start_at);
        self.total_ms = self.total_ms.saturating_add(duration);
        for (category, ms) in by_category {
            *self.totals.entry(category).or_default() += ms;
        }
        if let Some(tokens) = usage {
            self.token_turns = self.token_turns.saturating_add(1);
            self.total_tokens = self.total_tokens.saturating_add(tokens);
            // The journal reports whole-turn usage. Category attribution stays unknown:
            // elapsed test/permission time is not evidence of tokens spent in that category.
        }
        if self.spans.len() > MAX_SPANS {
            let excess = self.spans.len() - MAX_SPANS;
            self.spans.drain(..excess);
        }
    }

    fn output(&self, include_current: bool) -> TimeBreakdown {
        let mut totals = self.totals.clone();
        let mut total_ms = self.total_ms;
        let mut spans = self.spans.clone();
        if include_current && let Some(mut turn) = self.turn.clone() {
            let at = turn.last_at;
            turn.advance(at);
            for (category, ms) in &turn.segment_totals {
                total_ms = total_ms.saturating_add(*ms);
                *totals.entry(*category).or_default() += *ms;
            }
            for segment in turn.segments {
                let ms = segment.end_at.saturating_sub(segment.start_at);
                total_ms = total_ms.saturating_add(ms);
                *totals.entry(segment.category).or_default() += ms;
                spans.push(TimeSpan {
                    turn_seq: turn.seq,
                    turn_id: turn.id.clone(),
                    category: segment.category.id().to_owned(),
                    start_at: segment.start_at,
                    end_at: segment.end_at,
                    tokens: None,
                    turn_tokens: None,
                });
            }
        }
        if spans.len() > MAX_SPANS {
            let excess = spans.len() - MAX_SPANS;
            spans.drain(..excess);
        }
        let complete =
            self.ended_turns > 0 && self.token_turns == self.ended_turns && self.turn.is_none();
        TimeBreakdown {
            total_ms,
            total_tokens: (self.token_turns > 0).then_some(self.total_tokens),
            tokens_complete: complete,
            categories: Category::ALL
                .into_iter()
                .map(|id| TimeCategory {
                    id: id.id().to_owned(),
                    wall_ms: totals.get(&id).copied().unwrap_or(0),
                    tokens: None,
                })
                .collect(),
            spans,
        }
    }
}

fn value<'a>(msg: &'a Value, key: &str) -> Option<&'a Value> {
    msg.get(key)
        .or_else(|| msg.pointer(&format!("/params/{key}")))
        .or_else(|| msg.pointer(&format!("/params/update/{key}")))
        .or_else(|| msg.pointer(&format!("/update/{key}")))
}

fn turn_seq(msg: &Value) -> Option<u64> {
    value(msg, "turnSeq").and_then(Value::as_u64)
}

fn turn_id(msg: &Value) -> Option<String> {
    value(msg, "turnId").and_then(Value::as_str).map(str::to_owned)
}

fn tool_id(msg: &Value) -> Option<String> {
    value(msg, "toolCallId").or_else(|| value(msg, "id")).and_then(Value::as_str).map(str::to_owned)
}

fn tool_category(msg: &Value) -> Category {
    match value(msg, "kind").and_then(Value::as_str).unwrap_or_default() {
        "read" | "search" => Category::Read,
        "edit" | "delete" | "move" | "fileChange" => Category::Edit,
        "fetch" | "web" => Category::Model,
        _ => Category::Run,
    }
}

fn terminal_tool_update(msg: &Value) -> bool {
    matches!(
        value(msg, "status").and_then(Value::as_str),
        Some("completed" | "failed" | "cancelled" | "canceled" | "done")
    )
}

fn permission_id(msg: &Value) -> String {
    value(msg, "permissionId").and_then(Value::as_str).unwrap_or("legacy").to_owned()
}

fn usage(msg: &Value) -> Option<u64> {
    // Durable results are flat; imported provider results can carry `usage`. Pick one
    // shape, never add aliases or a root and its nested copy twice.
    for source in [Some(msg), msg.get("usage"), msg.pointer("/result/usage")].into_iter().flatten()
    {
        let number =
            |keys: &[&str]| keys.iter().find_map(|key| source.get(*key).and_then(Value::as_u64));
        if let Some(total) = number(&["totalTokens", "total_tokens"]) {
            return Some(total);
        }
        let input = number(&["inputTokens", "input_tokens", "promptTokens"]);
        let output = number(&["outputTokens", "output_tokens"]);
        let read = number(&[
            "cacheReadTokens",
            "cachedReadTokens",
            "cache_read_input_tokens",
            "cache_read_tokens",
        ]);
        let write = number(&[
            "cacheWriteTokens",
            "cachedWriteTokens",
            "cache_creation_input_tokens",
            "cache_write_tokens",
        ]);
        // Only a durable record marked by turn_usage guarantees fresh input. Older
        // records without that marker may already include cache: leave unknown rather
        // than double count cached input.
        if (read.is_some() || write.is_some())
            && source.get("inputExcludesCache") != Some(&Value::Bool(true))
        {
            return None;
        }
        if let Some(total) =
            [input, output, read, write].into_iter().flatten().reduce(u64::saturating_add)
        {
            return Some(total);
        }
    }
    None
}

#[cfg(test)]
mod tests;
