//! Incremental per-chat time and token attribution.
//!
//! The reducer consumes journal records in order. A session seeds it once from its
//! journal and then feeds it records as they are appended. Recent spans are bounded;
//! category totals remain complete for the lifetime of the chat.

use crate::store::EventRecord;
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;

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
    const ALL: [Self; 6] = [Self::Read, Self::Edit, Self::Run, Self::Think, Self::Person, Self::Model];

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

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TimeCategory {
    pub id: String,
    pub wall_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<u64>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
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
}

#[derive(Debug, Clone, Serialize, PartialEq)]
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
    waiting: bool,
    tools: BTreeMap<String, Category>,
    segments: Vec<Segment>,
}

impl TurnState {
    fn new(seq: u64, id: Option<String>, at: u64) -> Self {
        Self {
            seq,
            id,
            start_at: at,
            last_at: at,
            phase: Category::Model,
            waiting: false,
            tools: BTreeMap::new(),
            segments: Vec::new(),
        }
    }

    fn category(&self) -> Category {
        if self.waiting {
            return Category::Person;
        }
        self.tools.values().next().copied().unwrap_or(self.phase)
    }

    fn advance(&mut self, at: u64) {
        let at = at.max(self.last_at);
        if at <= self.last_at {
            return;
        }
        let category = self.category();
        if let Some(last) = self.segments.last_mut()
            && last.category == category
            && last.end_at == self.last_at
        {
            last.end_at = at;
        } else {
            self.segments.push(Segment { category, start_at: self.last_at, end_at: at });
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
    token_totals: BTreeMap<Category, u64>,
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
        match record.kind.as_str() {
            "user_message" | "turn_started" => {
                if self.turn.is_none() {
                    self.start_turn(turn_seq(&record.msg).unwrap_or(record.seq), turn_id(&record.msg), at);
                }
            }
            "tool_call" => {
                self.ensure_turn(record);
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    if let Some(id) = tool_id(&record.msg) {
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
                    }
                }
            }
            "agent_thought_chunk" => {
                self.ensure_turn(record);
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    turn.phase = Category::Think;
                }
            }
            "agent_message_chunk" => {
                self.ensure_turn(record);
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    turn.phase = Category::Model;
                }
            }
            "permission_request" => {
                self.ensure_turn(record);
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    turn.waiting = true;
                }
            }
            "permission_decision" | "permission_auto" => {
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                    turn.waiting = false;
                    turn.phase = Category::Model;
                }
            }
            "status" => {
                if let Some(turn) = self.turn.as_mut()
                    && record.msg.get("status").and_then(Value::as_str) == Some("waiting")
                {
                    turn.advance(at);
                    turn.waiting = true;
                }
            }
            "turn_result" | "turn_end" | "turn_error" => {
                if let Some(mut turn) = self.turn.take() {
                    turn.advance(at);
                    self.finish(turn, usage(&record.msg));
                }
            }
            _ => {
                if let Some(turn) = self.turn.as_mut() {
                    turn.advance(at);
                }
            }
        }
    }

    fn start_turn(&mut self, seq: u64, id: Option<String>, at: u64) {
        if let Some(turn) = self.turn.take() {
            self.finish(turn, None);
        }
        self.turn = Some(TurnState::new(seq, id, at));
    }

    fn ensure_turn(&mut self, record: &EventRecord) {
        if self.turn.is_none() {
            self.start_turn(turn_seq(&record.msg).unwrap_or(record.seq), turn_id(&record.msg), record.at);
        }
    }

    fn finish(&mut self, turn: TurnState, usage: Option<u64>) {
        self.ended_turns = self.ended_turns.saturating_add(1);
        let duration = turn.last_at.saturating_sub(turn.start_at);
        self.total_ms = self.total_ms.saturating_add(duration);
        let mut by_category = BTreeMap::<Category, u64>::new();
        for segment in &turn.segments {
            let ms = segment.end_at.saturating_sub(segment.start_at);
            *by_category.entry(segment.category).or_default() += ms;
            *self.totals.entry(segment.category).or_default() += ms;
            self.spans.push(TimeSpan {
                turn_seq: turn.seq,
                turn_id: turn.id.clone(),
                category: segment.category.id().to_owned(),
                start_at: segment.start_at,
                end_at: segment.end_at,
                tokens: None,
            });
        }
        if let Some(tokens) = usage {
            self.token_turns = self.token_turns.saturating_add(1);
            self.total_tokens = self.total_tokens.saturating_add(tokens);
            let mut remaining = tokens;
            let mut category_order: Vec<_> = by_category.into_iter().collect();
            if category_order.is_empty() {
                category_order.push((Category::Model, 1));
            }
            category_order.sort_by_key(|(_, ms)| std::cmp::Reverse(*ms));
            for (index, (category, ms)) in category_order.iter().enumerate() {
                let share = if index + 1 == category_order.len() {
                    remaining
                } else {
                    tokens.saturating_mul(*ms) / duration.max(1)
                };
                remaining = remaining.saturating_sub(share);
                *self.token_totals.entry(*category).or_default() += share;
                for span in self.spans.iter_mut().rev().filter(|span| {
                    span.turn_seq == turn.seq && span.category == category.id() && span.tokens.is_none()
                }) {
                    span.tokens = Some(
                        span.end_at
                            .saturating_sub(span.start_at)
                            .saturating_mul(share)
                            / (*ms).max(1),
                    );
                }
            }
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
                });
            }
        }
        let complete = self.ended_turns > 0 && self.token_turns == self.ended_turns;
        TimeBreakdown {
            total_ms,
            total_tokens: complete.then_some(self.total_tokens),
            tokens_complete: complete,
            categories: Category::ALL
                .into_iter()
                .map(|id| TimeCategory {
                    id: id.id().to_owned(),
                    wall_ms: totals.get(&id).copied().unwrap_or(0),
                    tokens: complete.then(|| self.token_totals.get(&id).copied().unwrap_or(0)),
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
    value(msg, "toolCallId")
        .or_else(|| value(msg, "id"))
        .and_then(Value::as_str)
        .map(str::to_owned)
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

fn usage(msg: &Value) -> Option<u64> {
    let usage = msg.get("usage").or_else(|| msg.pointer("/result/usage"))?;
    let mut total = 0u64;
    let mut found = false;
    for key in [
        "inputTokens",
        "outputTokens",
        "cacheReadTokens",
        "cacheWriteTokens",
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
    ] {
        if let Some(value) = usage.get(key).and_then(Value::as_u64) {
            total = total.saturating_add(value);
            found = true;
        }
    }
    found.then_some(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(seq: u64, at: u64, kind: &str, msg: Value) -> EventRecord {
        EventRecord { seq, at, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
    }

    #[test]
    fn folds_fixture_journal_into_categories_and_tokens() {
        let mut state = State::default();
        for record in [
            record(1, 1_000, "turn_started", serde_json::json!({"turnSeq": 1, "turnId": "t1"})),
            record(2, 2_000, "agent_thought_chunk", serde_json::json!({})),
            record(3, 5_000, "tool_call", serde_json::json!({"toolCallId": "r", "kind": "read"})),
            record(4, 9_000, "tool_call_update", serde_json::json!({"toolCallId": "r", "status": "completed"})),
            record(5, 10_000, "permission_request", serde_json::json!({})),
            record(6, 13_000, "permission_decision", serde_json::json!({})),
            record(7, 15_000, "turn_result", serde_json::json!({"usage": {"inputTokens": 5, "outputTokens": 7}})),
        ] {
            state.record(&record);
        }
        let result = state.snapshot(15_000);
        assert_eq!(result.total_ms, 14_000);
        assert_eq!(result.total_tokens, Some(12));
        assert_eq!(result.categories.iter().find(|c| c.id == "think").unwrap().wall_ms, 3_000);
        assert_eq!(result.categories.iter().find(|c| c.id == "read").unwrap().wall_ms, 4_000);
        assert_eq!(result.categories.iter().find(|c| c.id == "person").unwrap().wall_ms, 3_000);
        assert!(result.spans.iter().any(|span| span.category == "read" && span.turn_seq == 1));
    }

    #[test]
    fn repeated_records_and_snapshots_do_not_replay() {
        let mut state = State::default();
        let started = record(1, 10, "turn_started", serde_json::json!({"turnSeq": 1}));
        let ended = record(2, 20, "turn_result", serde_json::json!({}));
        state.record(&started);
        state.record(&ended);
        state.record(&ended);
        let first = state.snapshot(20);
        let second = state.snapshot(20);
        assert_eq!(first, second);
        assert_eq!(first.total_ms, 10);
    }

    #[test]
    fn live_turn_is_included_without_becoming_durable_total() {
        let mut state = State::default();
        state.record(&record(1, 100, "turn_started", serde_json::json!({"turnSeq": 1})));
        state.record(&record(2, 150, "agent_thought_chunk", serde_json::json!({})));
        let result = state.snapshot(200);
        assert_eq!(result.total_ms, 100);
        assert_eq!(result.categories.iter().find(|c| c.id == "think").unwrap().wall_ms, 50);
        assert_eq!(result.spans.len(), 2);
    }
}
