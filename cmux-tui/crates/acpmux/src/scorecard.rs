//! The harness-magic scorecard (`_acpmux/scorecard`, `acpmux scorecard`): the before/after
//! numbers every harness-magic feature is judged by, read from this machine's session logs.
//! Leo, 2026-11-24: each feature measured "before and after on real lanes (tokens per merged PR,
//! steering rate, time to the first useful result)". Local only, like `_acpmux/stats`: no prompt
//! or tool text is read into the answer.
//!
//! One pass over every session that changed in the range, reading only the record kinds below
//! (`KINDS`). Every number is per turn, so the turns can be split by the harness-magic features
//! they ran with (`harnessMagic.enabled` on their `turn_result`, `hub/harness_magic.rs`): before
//! and after compare like with like.
//!
//! Definitions:
//!
//! - **Turn**: a `turn_result` in the range. A fork's copies of its parent's records (before its
//!   `forked` record) count only in the parent.
//! - **Prompt source**: a `user_message` whose `_meta.provenance.kind` is `agent_message` is a
//!   coordinator's (another agent's message); any other provenance (an inbox notice, a background
//!   task's notice, a wake, a compaction) is automated; none is the person's.
//! - **Steer**: a prompt from the person or a coordinator that is a steer (`steer: true`), or
//!   arrives while a turn is running, or within `steerWindowS` (default 60 s) of the end of the
//!   session's last turn: a correction of what that turn did. It counts on that turn. A prompt id
//!   seen once (a steer that found no turn running is sent again as the next prompt) counts once.
//!   The **steering rate** is steers per turn. This is the cheap online proxy; the labelled
//!   reading of Leo's own messages (cmuxterm-hq `tools/transcript-analytics/steering.py`, steers
//!   per 100 of his messages) is joined in by the fleet tool (leo-workspace
//!   `tools/harness_scorecard.py`), and `steersPer100Prompts` here is on the same scale.
//! - **Time to first useful result** (`ttfu`): a turn's prompt to its first edit tool call that
//!   completed, or shell call that ran `git commit` and completed, or else its end when its
//!   `gitHead` moved from the session's previous turn's (a commit). Turns with none have no value.
//!   `sessionTtfu` is the same from a session's first prompt in the range.
//! - **firstModelMs**: the prompt written to the agent (`session/prompt`) to the model's first
//!   output (a Claude stream event, a tool call, or a message chunk), as `acpmux history` reads it.
//! - **Requests per turn**: `modelCalls` summed over the turns that reported it, per such turn.
//! - **Cache-hit ratio**: cache reads over all input (fresh input, cache reads and writes).
//! - **Leo-units**: dollars at list price: the harness's own cost of the turn, else its tokens at
//!   the bundled price table (`crate::pricing`); a turn neither prices counts in `unpricedTurns`.
//! - **Pull requests**: those a session opened in the range: its meta's
//!   (`SessionMeta::pull_requests`) and those its log shows a create opened (`gh pr create`, a
//!   lane VM broker's `pr_create` tool or `lane-gh call pr_create`, also behind `timeout`, a pipe
//!   or `bg_start`; `hub/pull_requests.rs`), counted on the group of the turn that opened them. Settled:
//!   one any session on this machine merged or closed (`closed_pull_requests`); this machine
//!   cannot tell a merge from a close nor see a merge done elsewhere, so the fleet tool asks GitHub
//!   which merged. `tokensPerSettledPr` is every token the group spent per such pull request.
//! - **harnessMagic counters**: every numeric `harnessMagic.<feature>.<counter>` on a turn's
//!   `turn_result` (nested or as a flat key), summed.

use crate::store::{EventRecord, SessionMeta, Store, TurnUsage};
use anyhow::Result;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

const DAY_MS: u64 = 24 * 3_600_000;
/// The range a request without `since` or `days` gets.
pub const DEFAULT_RANGE_DAYS: u64 = 7;
/// The widest range one request may ask for.
pub const MAX_RANGE_DAYS: u64 = 366;
/// How soon after a turn's end a prompt from the person or a coordinator counts as its steer.
pub const DEFAULT_STEER_WINDOW_S: u64 = 60;
/// The group of turns that ran with no harness-magic feature on (or before the seam existed).
pub const NONE_GROUP: &str = "none";

/// The record kinds the pass reads.
const KINDS: &[&str] = &[
    "user_message",
    "turn_result",
    "forked",
    "tool_call",
    "tool_call_update",
    "session/prompt",
    "claude.stream_event",
    "agent_message_chunk",
];

/// What one request asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScorecardOptions {
    pub since: u64,
    pub until: u64,
    pub steer_window_ms: u64,
    /// Answer one row per session too.
    pub sessions: bool,
}

impl ScorecardOptions {
    /// From request params `{since?, until?, days?, steerWindowS?, sessions?}` at `now`.
    pub fn from_params(params: &Value, now: u64) -> Self {
        let until = params.get("until").and_then(Value::as_u64).unwrap_or(now).min(now);
        let floor = until.saturating_sub(MAX_RANGE_DAYS * DAY_MS);
        let since = match params.get("since").and_then(Value::as_u64) {
            Some(since) => since.max(floor),
            None => {
                let days = params
                    .get("days")
                    .and_then(Value::as_u64)
                    .unwrap_or(DEFAULT_RANGE_DAYS)
                    .clamp(1, MAX_RANGE_DAYS);
                until.saturating_sub(days * DAY_MS)
            }
        };
        let window = params
            .get("steerWindowS")
            .and_then(Value::as_u64)
            .unwrap_or(DEFAULT_STEER_WINDOW_S)
            .min(3600);
        let sessions = params.get("sessions").and_then(Value::as_bool).unwrap_or(true);
        Self { since, until, steer_window_ms: window * 1000, sessions }
    }
}

/// Times in ms: how many, and their middle, 90th percentile and mean.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Spread {
    pub count: u64,
    pub median_ms: Option<u64>,
    pub p90_ms: Option<u64>,
    pub mean_ms: Option<u64>,
}

impl Spread {
    fn of(values: &[u64]) -> Self {
        if values.is_empty() {
            return Self::default();
        }
        let mut v = values.to_vec();
        v.sort_unstable();
        let at = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
        let sum: u128 = v.iter().map(|x| *x as u128).sum();
        Self {
            count: v.len() as u64,
            median_ms: Some(at(0.5)),
            p90_ms: Some(at(0.9)),
            mean_ms: Some((sum / v.len() as u128) as u64),
        }
    }
}

/// One group's numbers (every turn, one feature set, or one feature on or off).
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub sessions: u64,
    pub turns: u64,
    pub prompts_person: u64,
    pub prompts_coordinator: u64,
    pub prompts_automated: u64,
    pub steers: u64,
    /// Of `steers`, those sent as steers into a running turn (`steer: true`).
    pub steers_sent: u64,
    pub steering_rate: Option<f64>,
    pub steers_per_100_prompts: Option<f64>,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub total_tokens: u64,
    pub leo_units: f64,
    pub unpriced_turns: u64,
    pub model_calls: u64,
    pub requests_per_turn: Option<f64>,
    pub cache_hit_ratio: Option<f64>,
    pub useful_turns: u64,
    pub ttfu: Spread,
    pub session_ttfu: Spread,
    pub first_model: Spread,
    pub prs_opened: u64,
    pub prs_settled: u64,
    pub tokens_per_settled_pr: Option<f64>,
    pub leo_units_per_settled_pr: Option<f64>,
    pub harness_magic: BTreeMap<String, u64>,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FeatureSplit {
    pub on: Metrics,
    pub off: Metrics,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    pub id: String,
    pub name: String,
    pub harness: String,
    pub cwd: String,
    /// The feature sets its turns ran with.
    pub groups: Vec<String>,
    /// The pull requests it opened in the range, and of them those settled on this machine.
    pub pull_requests: Vec<String>,
    pub settled_pull_requests: Vec<String>,
    #[serde(flatten)]
    pub metrics: Metrics,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Scorecard {
    pub since: u64,
    pub until: u64,
    pub steer_window_s: u64,
    pub totals: Metrics,
    /// Tokens of the sessions that opened a settled pull request, per such pull request.
    pub attributed_tokens_per_settled_pr: Option<f64>,
    pub attributed_leo_units_per_settled_pr: Option<f64>,
    /// By the set of features the turns ran with (`none`, or their names joined by `,`).
    pub by_enabled_set: BTreeMap<String, Metrics>,
    /// Each feature seen: its turns on against every other turn.
    pub by_feature: BTreeMap<String, FeatureSplit>,
    pub sessions: Vec<SessionRow>,
}

/// One group's sums, made into [`Metrics`] at the end.
#[derive(Debug, Clone, Default)]
struct Acc {
    sessions: u64,
    turns: u64,
    prompts_person: u64,
    prompts_coordinator: u64,
    prompts_automated: u64,
    steers: u64,
    steers_sent: u64,
    usage: TurnUsage,
    leo_units: f64,
    unpriced_turns: u64,
    model_calls: u64,
    model_call_turns: u64,
    ttfu: Vec<u64>,
    session_ttfu: Vec<u64>,
    first_model: Vec<u64>,
    prs_opened: u64,
    prs_settled: u64,
    counters: BTreeMap<String, u64>,
}

fn ratio(a: f64, b: f64) -> Option<f64> {
    (b > 0.0).then(|| a / b)
}

impl Acc {
    fn add(&mut self, o: &Acc) {
        self.sessions += o.sessions;
        self.turns += o.turns;
        self.prompts_person += o.prompts_person;
        self.prompts_coordinator += o.prompts_coordinator;
        self.prompts_automated += o.prompts_automated;
        self.steers += o.steers;
        self.steers_sent += o.steers_sent;
        self.usage.add(&o.usage);
        self.leo_units += o.leo_units;
        self.unpriced_turns += o.unpriced_turns;
        self.model_calls += o.model_calls;
        self.model_call_turns += o.model_call_turns;
        self.ttfu.extend_from_slice(&o.ttfu);
        self.session_ttfu.extend_from_slice(&o.session_ttfu);
        self.first_model.extend_from_slice(&o.first_model);
        self.prs_opened += o.prs_opened;
        self.prs_settled += o.prs_settled;
        for (k, v) in &o.counters {
            *self.counters.entry(k.clone()).or_default() += v;
        }
    }

    fn total_tokens(&self) -> u64 {
        let u = &self.usage;
        u.input_tokens.unwrap_or(0)
            + u.output_tokens.unwrap_or(0)
            + u.cache_read_tokens.unwrap_or(0)
            + u.cache_write_tokens.unwrap_or(0)
    }

    fn metrics(&self) -> Metrics {
        let u = &self.usage;
        let (input, output) = (u.input_tokens.unwrap_or(0), u.output_tokens.unwrap_or(0));
        let (read, write) = (u.cache_read_tokens.unwrap_or(0), u.cache_write_tokens.unwrap_or(0));
        let total = self.total_tokens();
        let directed = self.prompts_person + self.prompts_coordinator;
        Metrics {
            sessions: self.sessions,
            turns: self.turns,
            prompts_person: self.prompts_person,
            prompts_coordinator: self.prompts_coordinator,
            prompts_automated: self.prompts_automated,
            steers: self.steers,
            steers_sent: self.steers_sent,
            steering_rate: ratio(self.steers as f64, self.turns as f64),
            steers_per_100_prompts: ratio(100.0 * self.steers as f64, directed as f64),
            input_tokens: input,
            output_tokens: output,
            cache_read_tokens: read,
            cache_write_tokens: write,
            total_tokens: total,
            leo_units: self.leo_units,
            unpriced_turns: self.unpriced_turns,
            model_calls: self.model_calls,
            requests_per_turn: ratio(self.model_calls as f64, self.model_call_turns as f64),
            cache_hit_ratio: ratio(read as f64, (input + read + write) as f64),
            useful_turns: self.ttfu.len() as u64,
            ttfu: Spread::of(&self.ttfu),
            session_ttfu: Spread::of(&self.session_ttfu),
            first_model: Spread::of(&self.first_model),
            prs_opened: self.prs_opened,
            prs_settled: self.prs_settled,
            tokens_per_settled_pr: ratio(total as f64, self.prs_settled as f64),
            leo_units_per_settled_pr: ratio(self.leo_units, self.prs_settled as f64),
            harness_magic: self.counters.clone(),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Source {
    Person,
    Coordinator,
    Automated,
}

/// Who a `user_message` came from (see the module doc).
fn source(msg: &Value) -> Source {
    match msg.pointer("/_meta/provenance") {
        None | Some(Value::Null) => Source::Person,
        Some(p) => match p.get("kind").and_then(Value::as_str) {
            Some("agent_message") => Source::Coordinator,
            _ => Source::Automated,
        },
    }
}

/// The features a `turn_result` ran with, as the group key, and its harness-magic counters.
fn harness_magic(msg: &Value) -> (Vec<String>, BTreeMap<String, u64>) {
    let mut enabled: Vec<String> = vec![];
    let mut counters = BTreeMap::new();
    fn walk(prefix: &str, v: &Value, out: &mut BTreeMap<String, u64>) {
        match v {
            Value::Object(o) => {
                for (k, v) in o {
                    if prefix.is_empty() && k == "enabled" {
                        continue;
                    }
                    let key = if prefix.is_empty() { k.clone() } else { format!("{prefix}.{k}") };
                    walk(&key, v, out);
                }
            }
            Value::Number(n) => {
                let n = n.as_u64().or_else(|| n.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64));
                if let Some(n) = n.filter(|_| !prefix.is_empty()) {
                    *out.entry(prefix.to_owned()).or_default() += n;
                }
            }
            _ => {}
        }
    }
    if let Some(hm) = msg.get("harnessMagic") {
        if let Some(list) = hm.get("enabled").and_then(Value::as_array) {
            enabled = list.iter().filter_map(Value::as_str).map(str::to_owned).collect();
        }
        walk("", hm, &mut counters);
    }
    if let Some(o) = msg.as_object() {
        for (k, v) in o {
            if let Some(rest) = k.strip_prefix("harnessMagic.")
                && rest != "enabled"
            {
                walk(rest, v, &mut counters);
            }
        }
    }
    enabled.sort();
    enabled.dedup();
    (enabled, counters)
}

fn group_key(enabled: &[String]) -> String {
    if enabled.is_empty() { NONE_GROUP.to_owned() } else { enabled.join(",") }
}

/// A turn still running.
#[derive(Default)]
struct Open {
    start: u64,
    source: Option<Source>,
    steers: u64,
    steers_sent: u64,
    written_at: Option<u64>,
    first_model_ms: Option<u64>,
    useful_at: Option<u64>,
}

/// A turn that ended in the log (in the range or not).
struct Closed {
    start: Option<u64>,
    end: u64,
    in_range: bool,
    group: Vec<String>,
    acc: Acc,
    useful_at: Option<u64>,
}

/// One session's pass.
struct SessionFold {
    options: ScorecardOptions,
    fresh_harness: bool,
    open: Option<Open>,
    closed: Vec<Closed>,
    seen_prompts: HashSet<String>,
    /// Tool call id -> (kind, runs `git commit`).
    calls: HashMap<String, (Option<String>, bool)>,
    last_head: Option<String>,
    /// Pull request creates still running (`hub/pull_requests.rs`), and what the log shows they
    /// opened, at when: the broker shapes the daemon's meta may predate (`pr_create` tools, `gh pr
    /// create` behind `timeout` or a pipe, one run by `bg_start`).
    creates: crate::hub::pull_requests::Creates,
    opened: Vec<(String, u64)>,
}

impl SessionFold {
    fn new(options: ScorecardOptions, fresh_harness: bool) -> Self {
        Self {
            options,
            fresh_harness,
            open: None,
            closed: vec![],
            seen_prompts: HashSet::new(),
            calls: HashMap::new(),
            last_head: None,
            creates: Default::default(),
            opened: vec![],
        }
    }

    fn in_range(&self, at: u64) -> bool {
        at >= self.options.since && at <= self.options.until
    }

    fn record(&mut self, r: &EventRecord) {
        let at = r.at;
        match (r.dir.as_str(), r.kind.as_str()) {
            ("mux", "user_message") => {
                let urls = crate::hub::pull_requests::follow_notice(&mut self.creates, &r.msg);
                self.note_opened(urls, at);
                self.user_message(at, &r.msg);
            }
            ("mux", "forked") => {
                // Everything before it is the parent's: counted there.
                self.closed.clear();
                self.open = None;
                self.seen_prompts.clear();
                self.calls.clear();
                self.creates.clear();
                self.opened.clear();
            }
            ("mux", "turn_result") => self.turn_result(at, &r.msg),
            ("out", "session/prompt") => {
                if let Some(o) = self.open.as_mut()
                    && o.written_at.is_none()
                {
                    o.written_at = Some(at);
                }
            }
            ("in", "claude.stream_event" | "agent_message_chunk" | "tool_call") => {
                if let Some(o) = self.open.as_mut()
                    && o.first_model_ms.is_none()
                    && let Some(w) = o.written_at
                {
                    o.first_model_ms = Some(at.saturating_sub(w));
                }
                if r.kind != "agent_message_chunk" && r.kind != "claude.stream_event" {
                    self.tool(at, &r.msg);
                }
            }
            ("in", "tool_call_update") => self.tool(at, &r.msg),
            _ => {}
        }
    }

    fn note_opened(&mut self, urls: Vec<String>, at: u64) {
        for url in urls {
            if !self.opened.iter().any(|(u, _)| *u == url) {
                self.opened.push((url, at));
            }
        }
    }

    fn tool(&mut self, at: u64, msg: &Value) {
        let u = msg.pointer("/params/update").unwrap_or(msg);
        let urls = crate::hub::pull_requests::follow(&mut self.creates, u);
        self.note_opened(urls, at);
        let Some(id) = u.get("toolCallId").and_then(Value::as_str) else { return };
        let entry = self.calls.entry(id.to_owned()).or_insert((None, false));
        if let Some(kind) = u.get("kind").and_then(Value::as_str) {
            entry.0 = Some(kind.to_owned());
        }
        let command = match u.pointer("/rawInput/command").or_else(|| u.pointer("/rawInput/cmd")) {
            Some(Value::String(s)) => Some(s.clone()),
            Some(Value::Array(a)) => {
                Some(a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
            }
            _ => None,
        };
        if command.is_some_and(|c| c.contains("git commit")) {
            entry.1 = true;
        }
        if u.get("status").and_then(Value::as_str) != Some("completed") {
            return;
        }
        let useful = match entry {
            (Some(k), _) if k == "edit" => true,
            (Some(k), true) if k == "execute" => true,
            _ => false,
        };
        self.calls.remove(id);
        if useful
            && let Some(o) = self.open.as_mut()
            && o.useful_at.is_none()
        {
            o.useful_at = Some(at);
        }
    }

    fn user_message(&mut self, at: u64, msg: &Value) {
        let steer_flag = msg.get("steer").and_then(Value::as_bool) == Some(true);
        let id = msg.get("promptId").and_then(Value::as_str).filter(|s| !s.is_empty());
        let fresh = id.is_none_or(|id| self.seen_prompts.insert(id.to_owned()));
        let src = source(msg);
        let in_range = self.in_range(at);
        if fresh && src != Source::Automated && in_range {
            let after_end = self
                .closed
                .last()
                .is_some_and(|c| at.saturating_sub(c.end) <= self.options.steer_window_ms);
            if let Some(o) = self.open.as_mut() {
                o.steers += 1;
                o.steers_sent += steer_flag as u64;
            } else if steer_flag || after_end {
                // A steer with no turn running corrects the turn that just ended.
                if let Some(c) = self.closed.last_mut() {
                    c.acc.steers += 1;
                    c.acc.steers_sent += steer_flag as u64;
                }
            }
        }
        if steer_flag {
            return;
        }
        // A prompt opens a turn; one that comes while a turn runs joins it (queued or steered in).
        if self.open.is_none() {
            self.open = Some(Open { start: at, source: fresh.then_some(src), ..Open::default() });
        }
    }

    fn turn_result(&mut self, at: u64, msg: &Value) {
        let open = self.open.take().unwrap_or(Open { start: at, ..Open::default() });
        let in_range = self.in_range(at);
        let (group, counters) = harness_magic(msg);
        let mut acc = Acc { turns: 1, counters, ..Acc::default() };
        match open.source {
            Some(Source::Person) => acc.prompts_person = 1,
            Some(Source::Coordinator) => acc.prompts_coordinator = 1,
            Some(Source::Automated) => acc.prompts_automated = 1,
            None => {}
        }
        acc.steers = open.steers;
        acc.steers_sent = open.steers_sent;
        let usage = crate::stats::turn_usage(msg, self.fresh_harness);
        let model = msg.get("model").and_then(Value::as_str).unwrap_or("");
        match usage.cost_usd {
            Some(cost) => acc.leo_units = cost,
            None => match crate::pricing::table().cost(model, &usage) {
                Some(cost) => acc.leo_units = cost,
                None if usage != TurnUsage::default() => acc.unpriced_turns = 1,
                None => {}
            },
        }
        acc.usage = usage;
        if let Some(calls) = msg.get("modelCalls").and_then(Value::as_u64) {
            acc.model_calls = calls;
            acc.model_call_turns = 1;
        }
        let mut useful_at = open.useful_at;
        let head = msg.get("gitHead").and_then(Value::as_str).map(str::to_owned);
        if useful_at.is_none()
            && let (Some(prev), Some(now)) = (self.last_head.as_ref(), head.as_ref())
            && prev != now
        {
            useful_at = Some(at);
        }
        if head.is_some() {
            self.last_head = head;
        }
        let started = open.source.is_some() || open.start != at;
        let start = started.then_some(open.start);
        if let (Some(s), Some(u)) = (start, useful_at) {
            acc.ttfu.push(u.saturating_sub(s));
        }
        if let Some(ms) = open.first_model_ms {
            acc.first_model.push(ms);
        }
        self.closed.push(Closed { start, end: at, in_range, group, acc, useful_at });
    }

    /// This session's turns in the range, by feature set, with its pull requests and first
    /// useful result counted on their turns' groups.
    fn finish(
        self,
        meta: &SessionMeta,
        settled: &HashSet<String>,
        row: &mut SessionRow,
    ) -> BTreeMap<String, Acc> {
        let options = self.options;
        let turns: Vec<Closed> = self.closed.into_iter().filter(|c| c.in_range).collect();
        let mut groups: BTreeMap<String, Acc> = BTreeMap::new();
        for t in &turns {
            groups.entry(group_key(&t.group)).or_default().add(&t.acc);
        }
        // From the first prompt in the range to the first useful result after it.
        if let Some(first) = turns.iter().find(|t| t.start.is_some())
            && let Some(useful) = turns.iter().filter_map(|t| t.useful_at).min()
            && let Some(start) = first.start
        {
            groups
                .entry(group_key(&first.group))
                .or_default()
                .session_ttfu
                .push(useful.saturating_sub(start));
        }
        // The meta's, then any the log shows that it lacks.
        let mut opened_prs: Vec<(String, u64)> = meta
            .pull_requests
            .iter()
            .map(|url| {
                (url.clone(), meta.pull_request_times.get(url).copied().unwrap_or(meta.created_at))
            })
            .collect();
        for (url, at) in self.opened {
            if !opened_prs.iter().any(|(u, _)| *u == url) {
                opened_prs.push((url, at));
            }
        }
        for (url, opened) in &opened_prs {
            let (url, opened) = (url, *opened);
            if opened < options.since || opened > options.until {
                continue;
            }
            let on = turns.iter().find(|t| t.end >= opened).or(turns.last());
            let key = on.map_or_else(|| NONE_GROUP.to_owned(), |t| group_key(&t.group));
            let acc = groups.entry(key).or_default();
            acc.prs_opened += 1;
            row.pull_requests.push(url.clone());
            if settled.contains(url) {
                acc.prs_settled += 1;
                row.settled_pull_requests.push(url.clone());
            }
        }
        for acc in groups.values_mut() {
            acc.sessions = 1;
        }
        groups
    }
}

/// One pass over every session that changed in the range; `fresh_input` tells whether a
/// session's harness counts its input apart from the cache (`stats::summarize_with`).
pub fn summarize_with(
    store: &dyn Store,
    options: &ScorecardOptions,
    fresh_input: &dyn Fn(&SessionMeta) -> bool,
) -> Result<Scorecard> {
    let metas = store.list()?;
    let settled: HashSet<String> =
        metas.iter().flat_map(|m| m.closed_pull_requests.iter().cloned()).collect();
    let mut by_set: BTreeMap<String, Acc> = BTreeMap::new();
    let mut total = Acc::default();
    let mut rows = vec![];
    let (mut attributed_tokens, mut attributed_units, mut attributed_prs) = (0u64, 0f64, 0u64);
    for meta in &metas {
        if meta.updated_at < options.since || meta.created_at > options.until || meta.cold.is_some()
        {
            continue;
        }
        let mut fold = SessionFold::new(*options, fresh_input(meta));
        let scanned = store.scan_kinds(&meta.id, KINDS, &mut |record| {
            fold.record(&record);
            true
        });
        if let Err(error) = scanned {
            tracing::warn!(session = %meta.id, "scorecard: skipping an unreadable log: {error:#}");
            continue;
        }
        let mut row = SessionRow {
            id: meta.id.clone(),
            name: meta.name.clone(),
            harness: meta.harness.clone(),
            cwd: meta.cwd.to_string_lossy().into_owned(),
            ..SessionRow::default()
        };
        let groups = fold.finish(meta, &settled, &mut row);
        if groups.is_empty() {
            continue;
        }
        let mut session = Acc::default();
        for (key, acc) in &groups {
            session.add(acc);
            by_set.entry(key.clone()).or_default().add(acc);
        }
        session.sessions = 1;
        if session.prs_settled > 0 {
            attributed_tokens += session.total_tokens();
            attributed_units += session.leo_units;
            attributed_prs += session.prs_settled;
        }
        total.add(&session);
        row.groups = groups.keys().cloned().collect();
        row.metrics = session.metrics();
        if options.sessions {
            rows.push(row);
        }
    }
    let features: BTreeSet<String> = by_set
        .keys()
        .filter(|k| *k != NONE_GROUP)
        .flat_map(|k| k.split(',').map(str::to_owned).collect::<Vec<_>>())
        .collect();
    let mut by_feature = BTreeMap::new();
    for f in features {
        let (mut on, mut off) = (Acc::default(), Acc::default());
        for (key, acc) in &by_set {
            if key != NONE_GROUP && key.split(',').any(|k| k == f) {
                on.add(acc);
            } else {
                off.add(acc);
            }
        }
        by_feature.insert(f, FeatureSplit { on: on.metrics(), off: off.metrics() });
    }
    rows.sort_by_key(|r| std::cmp::Reverse(r.metrics.total_tokens));
    Ok(Scorecard {
        since: options.since,
        until: options.until,
        steer_window_s: options.steer_window_ms / 1000,
        totals: total.metrics(),
        attributed_tokens_per_settled_pr: ratio(attributed_tokens as f64, attributed_prs as f64),
        attributed_leo_units_per_settled_pr: ratio(attributed_units, attributed_prs as f64),
        by_enabled_set: by_set.into_iter().map(|(k, v)| (k, v.metrics())).collect(),
        by_feature,
        sessions: rows,
    })
}

/// The scorecard as JSON (the RPC's answer).
/// The `harnessMagic` counters that are a prefix churn (RFD 0158 §1, `hub/cache_alarm.rs`): a
/// turn whose cache-read share collapsed with no boundary, and a call that missed with no cause.
pub const CHURN_COUNTERS: &[&str] = &["cacheAlarm.collapses", "cacheAlarm.callChurn"];

/// The prefix churns a scorecard's `totals` counted (`--assert-no-churn`).
pub fn churn(card: &Value) -> u64 {
    CHURN_COUNTERS
        .iter()
        .filter_map(|k| card.pointer("/totals/harnessMagic").and_then(|h| h.get(*k)))
        .filter_map(Value::as_u64)
        .sum()
}

pub fn to_value(card: &Scorecard) -> Value {
    serde_json::to_value(card).unwrap_or_else(|e| json!({"error": e.to_string()}))
}

#[cfg(test)]
#[path = "scorecard_tests.rs"]
mod tests;
