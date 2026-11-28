//! `acpmux scorecard replay <session>` (`_acpmux/scorecard_replay`): walks a recorded chat's log
//! through deterministic code, with no model call, and checks the cache-prefix invariants of RFD
//! 0161 (cmuxterm-hq `docs/rfd/0161-hm-scorecard-and-replay.md`). Leo, 2026-11-25: "we can't be
//! letting important rfds like that take breaks ... esp when this is stuff that materially
//! improves the app".
//!
//! Each violation names the session, the record (`seq`, `at`) and the invariant. It checks all
//! five of the RFD's:
//!
//! - **1 `contextExtends`**: each main-loop call's prompt (input, cache read and cache write) is at
//!   least the context the call before it left (its prompt and output), less a slack
//!   ([`SHRINK_SLACK_SHARE`], at least [`SHRINK_SLACK_TOKENS`]: Claude Code drops a spent
//!   notice or a thought now and then; over 2,806 recorded calls no undeclared shrink was over
//!   3%). A compaction, a surgery, a config or model change in between declares it.
//! - **2 `stableInputs`**: the model, the tool definitions and the system prompt do not change
//!   inside a session. Read from Claude Code's `system/init` lines (`claude.system.init`, whose
//!   repeated sections the log leaves out, `claude_stdio/logged_init.rs`: a section that is
//!   present again is compared with the last one seen, so a restart that logs it whole again is
//!   no change) and the model each main-loop call's `message_start` names. The system prompt's
//!   text is not in the log; `output_style` (the part of it Claude Code reports) stands for it.
//! - **5 `cacheAgrees`**: a main-loop call (`usage_update` with `contextTokens`; a subagent's has
//!   none) that read under half of the context the call before it left is a cache collapse
//!   (`claude_stdio::prompt_cache`'s rule). It is declared, and so no violation, when a
//!   compaction, a context surgery (`harness_surgery`) or a config change came between the two,
//!   the model changed, or the cache had expired (the previous call's `cacheExpiresAt`). The
//!   cause is classified by `prompt_cache::miss_cause`, the daemon's own.
//!
//! - **3 `outputCapped`**: no tool result over the output cap enters context (RFD 0147). The size
//!   is the characters of the result's text as the log records it (a `tool_call_update` that
//!   completed or failed). The cap is Claude Code's own: [`SHELL_CAP_CHARS`] for a shell call (ACP
//!   kind `execute`; over it the output spills to a file and a preview comes back), and
//!   [`TOKEN_CAP`] tokens (at [`CHARS_PER_TOKEN`]) for every other tool (Read and MCP).
//! - **4 `rereadsBounded`**: after a compaction or a surgery, the results it removed that the
//!   agent fetches again (the same path read, command run, URL or search:
//!   `hub::surgery::refetch_key`, the daemon's own regret key) in the next
//!   [`REFETCH_TURNS`](crate::hub::surgery::REFETCH_TURNS) turns stay at or under
//!   [`REREAD_MAX_SHARE`] of them (and [`REREAD_MIN`]). Removed: a compaction's, every result of
//!   [`MIN_CHARS`](crate::hub::surgery::MIN_CHARS) characters or more since the boundary before; a
//!   surgery's, those of turns older than its `keepTurns` of at least its `minChars`.
//!
//! The CI job: `cmux_next_scorecard_replay_fixtures_break_only_what_they_recorded` replays the
//! recorded logs under `tests/fixtures/scorecard-replay` (scrubbed by
//! `scripts/scorecard-replay-fixture.py`) through the store the CLI's `--home` opens, in the
//! `cmux_next_ daemon tests` step. They break only invariant 2, where one recording's user
//! switched the model twice and an MCP server's tools went away; any other violation fails it.
//!
//! Off switch, as the RFD says: `agents.harnessMagic.scorecard.enabled: false` or
//! `ACPMUX_HM_SCORECARD=0` (`hub/harness_magic.rs`). Its counters,
//! `harnessMagic.scorecard.replaySessions` and `harnessMagic.scorecard.violations.<invariant>`,
//! are on every answer.

use crate::claude_stdio::prompt_cache::{MIN_MISS_CONTEXT, miss_cause};
use crate::hub::surgery::{KEEP_TURNS, MIN_CHARS, REFETCH_TURNS, refetch_key};
use crate::store::{EventRecord, Store};
use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};

/// The record kinds replay reads.
const KINDS: &[&str] = &[
    "forked",
    "claude.system.init",
    "claude.stream_event",
    "usage_update",
    "compaction",
    "claude.system.compact_boundary",
    "harness_surgery",
    "config_option_update",
    "tool_call",
    "tool_call_update",
    "turn_started",
];

/// The invariants this build checks, by their number in the RFD and their name.
pub const CHECKED: &[(u8, &str)] = &[
    (1, CONTEXT_EXTENDS),
    (2, STABLE_INPUTS),
    (3, OUTPUT_CAPPED),
    (4, REREADS_BOUNDED),
    (5, CACHE_AGREES),
];
/// The invariants the RFD names that this build does not check yet: none.
pub const NOT_YET: &[(u8, &str)] = &[];
pub const CONTEXT_EXTENDS: &str = "contextExtends";
pub const STABLE_INPUTS: &str = "stableInputs";
pub const OUTPUT_CAPPED: &str = "outputCapped";
pub const REREADS_BOUNDED: &str = "rereadsBounded";
pub const CACHE_AGREES: &str = "cacheAgrees";

/// Invariant 1: the share of the last context a call's prompt may fall short of it by ...
pub const SHRINK_SLACK_SHARE: f64 = 0.05;
/// ... and the tokens it may always fall short by.
pub const SHRINK_SLACK_TOKENS: u64 = 2_048;
/// Invariant 3: Claude Code's shell output cap, in characters (vanilla's spill point; RFD 0147).
pub const SHELL_CAP_CHARS: usize = 30_000;
/// Invariant 3: Claude Code's cap of a Read or MCP result, in tokens (`MAX_MCP_OUTPUT_TOKENS`).
pub const TOKEN_CAP: usize = 25_000;
/// The characters a token, as `hub/surgery.rs` counts them.
pub const CHARS_PER_TOKEN: usize = 4;
/// Invariant 4: the share of removed results the agent may fetch again ...
pub const REREAD_MAX_SHARE: f64 = 0.5;
/// ... and the refetches always allowed, so a window of two or three removed results is not
/// judged on one.
pub const REREAD_MIN: usize = 3;

/// The `system/init` sections invariant 2 holds still: the tools, and the system prompt's
/// reported part.
const INIT_SECTIONS: &[&str] = &["tools", "output_style"];

/// One broken invariant.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Violation {
    pub session: String,
    pub invariant: u8,
    pub name: &'static str,
    pub seq: u64,
    pub at: u64,
    pub detail: String,
}

/// One session's replay.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionReplay {
    pub session: String,
    pub harness: String,
    /// Records read.
    pub records: u64,
    /// Main-loop model calls checked against invariant 5.
    pub calls: u64,
    /// `system/init` lines checked against invariant 2.
    pub inits: u64,
    /// Tool results checked against invariant 3.
    pub tool_results: u64,
    /// Compactions and surgeries whose re-reads invariant 4 watched.
    pub removals: u64,
    /// Removed results fetched again after them.
    pub refetched: u64,
    /// Calls that read under half of what the call before left, by their cause (declared ones
    /// included: `compaction`, `model`, `expired`, ...).
    pub collapses: BTreeMap<String, u64>,
    pub violations: Vec<Violation>,
}

/// The answer: every session asked for, and the counters.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Replay {
    pub checked: Vec<Value>,
    pub not_yet: Vec<Value>,
    pub sessions: Vec<SessionReplay>,
    /// Session ids asked for that this store does not have.
    pub missing: Vec<String>,
    pub violations: u64,
    pub counters: BTreeMap<String, u64>,
}

/// The previous main-loop call, as the next one is judged against it.
struct LastCall {
    /// What the next call should read: this one's prompt and output.
    context: u64,
    expires_at: u64,
    model: Option<String>,
}

#[derive(Default)]
struct Fold {
    out: SessionReplay,
    sections: BTreeMap<&'static str, Value>,
    init_model: Option<String>,
    /// The model the main loop's last `message_start` named.
    call_model: Option<String>,
    last: Option<LastCall>,
    /// A compaction, surgery or config change since the last call.
    boundary: Option<String>,
    /// Tool calls by id, in the order first seen.
    tools: HashMap<String, ToolCall>,
    /// The ids of the tool calls since the last compaction or surgery.
    since_removal: Vec<String>,
    /// `turn_started` records seen.
    turns: u64,
    /// The re-read watch after the last compaction or surgery.
    watch: Option<Watch>,
    /// Bumped at each compaction or surgery: a call first seen before it is not a re-read.
    generation: u64,
}

/// One tool call, as invariants 3 and 4 read it.
#[derive(Default)]
struct ToolCall {
    /// What fetching it again would repeat (`hub::surgery::refetch_key`).
    key: Option<String>,
    /// Its result's characters, once it completed or failed.
    chars: Option<usize>,
    /// The turn it ran in.
    turn: u64,
    /// [`Fold::generation`] when it was first seen.
    generation: u64,
    /// Its tool name (`_meta.claude.tool`), from whichever record named it: the completed
    /// update usually does not repeat it.
    tool: Option<String>,
    /// A shell call (`kind: execute` or Bash), from whichever record said so.
    shell: bool,
}

/// The removed results a compaction or surgery left, and the fetches of them since.
struct Watch {
    removed: HashSet<String>,
    hit: HashSet<String>,
    turns_left: u8,
    generation: u64,
    flagged: bool,
}

impl Fold {
    fn violation(&mut self, r: &EventRecord, invariant: u8, name: &'static str, detail: String) {
        self.out.violations.push(Violation {
            session: self.out.session.clone(),
            invariant,
            name,
            seq: r.seq,
            at: r.at,
            detail,
        });
    }

    fn record(&mut self, r: &EventRecord) {
        self.out.records += 1;
        match r.kind.as_str() {
            "forked" => {
                // What came before is the parent's, checked there.
                let out = SessionReplay {
                    session: std::mem::take(&mut self.out.session),
                    harness: std::mem::take(&mut self.out.harness),
                    records: self.out.records,
                    ..SessionReplay::default()
                };
                *self = Fold { out, ..Fold::default() };
            }
            "claude.system.init" => self.init(r),
            "claude.stream_event" => self.stream_event(r),
            "usage_update" => self.usage(r),
            "compaction" => {
                let state = update(&r.msg).get("state").and_then(Value::as_str);
                if state != Some("running") {
                    self.boundary = Some("compaction".into());
                    self.removal(None);
                }
            }
            "claude.system.compact_boundary" => {
                self.boundary = Some("compaction".into());
                self.removal(None);
            }
            "harness_surgery" => {
                self.boundary = Some("surgery".into());
                let n = |k: &str, d: usize| {
                    r.msg.get(k).and_then(Value::as_u64).map_or(d, |v| v as usize)
                };
                self.removal(Some((n("keepTurns", KEEP_TURNS), n("minChars", MIN_CHARS))));
            }
            "tool_call" | "tool_call_update" => self.tool(r),
            "turn_started" => self.turn(),
            "config_option_update" => self.boundary = Some("config".into()),
            _ => {}
        }
    }

    fn init(&mut self, r: &EventRecord) {
        self.out.inits += 1;
        if let Some(model) = r.msg.get("model").and_then(Value::as_str) {
            if let Some(before) = self.init_model.as_deref()
                && before != model
            {
                let detail = format!("model changed from {before} to {model} (system/init)");
                self.violation(r, 2, STABLE_INPUTS, detail);
            }
            self.init_model = Some(model.to_owned());
        }
        for section in INIT_SECTIONS {
            let Some(value) = r.msg.get(*section) else { continue };
            if let Some(before) = self.sections.get(section)
                && before != value
            {
                let detail = format!("{section} changed{}", tools_diff(section, before, value));
                self.violation(r, 2, STABLE_INPUTS, detail);
            }
            self.sections.insert(section, value.clone());
        }
    }

    fn stream_event(&mut self, r: &EventRecord) {
        if r.msg.get("parent_tool_use_id").is_some_and(|p| !p.is_null()) {
            return;
        }
        let Some(model) = r
            .msg
            .pointer("/event/message/model")
            .filter(|_| {
                r.msg.pointer("/event/type").and_then(Value::as_str) == Some("message_start")
            })
            .and_then(Value::as_str)
        else {
            return;
        };
        if let Some(before) = self.call_model.as_deref()
            && before != model
            && self.boundary.is_none()
        {
            let detail = format!("model changed from {before} to {model} between calls");
            self.violation(r, 2, STABLE_INPUTS, detail);
        }
        self.call_model = Some(model.to_owned());
    }

    fn usage(&mut self, r: &EventRecord) {
        let u = update(&r.msg);
        // A subagent's call names no context: its cache is its own.
        let Some(context_after) = u.get("contextTokens").and_then(Value::as_u64) else { return };
        if u.pointer("/_meta/acpmux/call").and_then(Value::as_bool) != Some(true) {
            return;
        }
        self.out.calls += 1;
        let n = |k: &str| u.get(k).and_then(Value::as_u64).unwrap_or(0);
        let read = n("cachedReadTokens");
        let expires_at = u.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64);
        let boundary = self.boundary.take();
        let prompt = n("inputTokens").saturating_add(read).saturating_add(n("cachedWriteTokens"));
        if let Some(last) = &self.last
            && boundary.is_none()
            && !(last.model.is_some() && last.model != self.call_model)
        {
            let slack =
                ((last.context as f64 * SHRINK_SLACK_SHARE) as u64).max(SHRINK_SLACK_TOKENS);
            if prompt.saturating_add(slack) < last.context {
                let detail = format!(
                    "the call's prompt of {prompt} tokens is {} short of the {} the call before left, with no compaction, surgery, config or model change",
                    last.context - prompt,
                    last.context
                );
                self.violation(r, 1, CONTEXT_EXTENDS, detail);
            }
        }
        if let Some(last) = &self.last
            && last.context >= MIN_MISS_CONTEXT
            && read.saturating_mul(2) < last.context
        {
            let model_changed = last.model.is_some() && last.model != self.call_model;
            let cause = match boundary.as_deref() {
                Some("surgery") => "surgery",
                Some("config") => "config",
                b => {
                    miss_cause(b == Some("compaction"), model_changed, false, last.expires_at, r.at)
                }
            };
            *self.out.collapses.entry(cause.to_owned()).or_default() += 1;
            if cause == "unknown" {
                let detail = format!(
                    "cache read collapsed to {read} of {} tokens the call before left, with no compaction, surgery, config or model change and the cache not expired",
                    last.context
                );
                self.violation(r, 5, CACHE_AGREES, detail);
            }
        }
        self.last = Some(LastCall {
            context: context_after,
            // A call that names no expiry keeps the last one (`prompt_cache.rs`).
            expires_at: expires_at.or(self.last.as_ref().map(|l| l.expires_at)).unwrap_or(0),
            model: self.call_model.clone(),
        });
    }
}

impl Fold {
    /// A `tool_call` or `tool_call_update`: its key for invariant 4, its result for invariant 3.
    fn tool(&mut self, r: &EventRecord) {
        let u = update(&r.msg);
        let Some(id) = u.get("toolCallId").and_then(Value::as_str) else { return };
        let (turn, generation) = (self.turns, self.generation);
        let call = self.tools.entry(id.to_owned()).or_insert_with(|| ToolCall {
            turn,
            generation,
            ..ToolCall::default()
        });
        let mut fetched = None;
        if call.key.is_none()
            && let Some(key) = u.get("rawInput").filter(|v| v.is_object()).and_then(refetch_key)
        {
            call.key = Some(key.clone());
            if call.generation == generation {
                fetched = Some(key);
            }
        }
        if let Some(tool) = u.pointer("/_meta/claude/tool").and_then(Value::as_str) {
            call.shell |= tool == "Bash";
            call.tool = Some(tool.to_owned());
        }
        call.shell |= u.get("kind").and_then(Value::as_str) == Some("execute");
        let done = matches!(u.get("status").and_then(Value::as_str), Some("completed" | "failed"));
        let mut over = None;
        if done && call.chars.is_none() {
            let chars = result_chars(u);
            call.chars = Some(chars);
            let cap = if call.shell { SHELL_CAP_CHARS } else { TOKEN_CAP * CHARS_PER_TOKEN };
            if chars > cap {
                let tool = call.tool.as_deref().unwrap_or("tool");
                over = Some(format!(
                    "a {tool} result of {chars} characters entered context, over the {cap} cap (RFD 0147)"
                ));
            }
        }
        let new = !self.since_removal.iter().any(|i| i == id);
        if new {
            self.since_removal.push(id.to_owned());
        }
        if done {
            self.out.tool_results += 1;
        }
        if let Some(detail) = over {
            self.violation(r, 3, OUTPUT_CAPPED, detail);
        }
        if let Some(key) = fetched {
            self.refetch(r, key);
        }
    }

    /// A fetch of `key` by a call made after the last compaction or surgery.
    fn refetch(&mut self, r: &EventRecord, key: String) {
        let Some(w) = self.watch.as_mut() else { return };
        if w.generation != self.generation || !w.removed.contains(&key) || !w.hit.insert(key) {
            return;
        }
        self.out.refetched += 1;
        let allowed = ((w.removed.len() as f64 * REREAD_MAX_SHARE).ceil() as usize).max(REREAD_MIN);
        if w.hit.len() > allowed && !w.flagged {
            w.flagged = true;
            let detail = format!(
                "{} of the {} results the last compaction or surgery removed were fetched again within {} turns (allowed {allowed}, RFD 0149)",
                w.hit.len(),
                w.removed.len(),
                REFETCH_TURNS
            );
            self.violation(r, 4, REREADS_BOUNDED, detail);
        }
    }

    fn turn(&mut self) {
        self.turns += 1;
        if let Some(w) = self.watch.as_mut() {
            if w.turns_left == 0 {
                self.watch = None;
            } else {
                w.turns_left -= 1;
            }
        }
    }

    /// A compaction (`surgery` None) or a surgery (its `keepTurns` and `minChars`): what it
    /// removed starts the re-read watch. A second record of the same compaction (its `done`
    /// update and its `compact_boundary`) finds nothing new and keeps the watch.
    fn removal(&mut self, surgery: Option<(usize, usize)>) {
        let (keep_turns, min_chars) = surgery.unwrap_or((0, MIN_CHARS));
        let cutoff = self.turns.saturating_sub(keep_turns.saturating_sub(1) as u64);
        let mut removed = HashSet::new();
        let mut kept = vec![];
        for id in std::mem::take(&mut self.since_removal) {
            let Some(call) = self.tools.get(&id) else { continue };
            let masked = surgery.is_none() || call.turn < cutoff;
            if masked {
                if let (Some(key), Some(chars)) = (&call.key, call.chars)
                    && chars >= min_chars
                {
                    removed.insert(key.clone());
                }
            } else {
                kept.push(id);
            }
        }
        self.since_removal = kept;
        if removed.is_empty() {
            return;
        }
        self.generation += 1;
        self.out.removals += 1;
        self.watch = Some(Watch {
            removed,
            hit: HashSet::new(),
            turns_left: REFETCH_TURNS,
            generation: self.generation,
            flagged: false,
        });
    }
}

/// The characters of a tool result's text, as the log records it.
fn result_chars(u: &Value) -> usize {
    u.get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|c| c.pointer("/content/text").and_then(Value::as_str))
        .map(|t| t.chars().count())
        .sum()
}

/// The `session/update`'s update, or the record itself.
fn update(msg: &Value) -> &Value {
    msg.pointer("/params/update").unwrap_or(msg)
}

/// For `tools`, which names were added and removed.
fn tools_diff(section: &str, before: &Value, after: &Value) -> String {
    if section != "tools" {
        return String::new();
    }
    let names = |v: &Value| -> std::collections::BTreeSet<String> {
        v.as_array()
            .into_iter()
            .flatten()
            .filter_map(|t| t.as_str().or_else(|| t.get("name").and_then(Value::as_str)))
            .map(str::to_owned)
            .collect()
    };
    let (b, a) = (names(before), names(after));
    let added: Vec<_> = a.difference(&b).take(5).cloned().collect();
    let removed: Vec<_> = b.difference(&a).take(5).cloned().collect();
    format!(": +[{}] -[{}]", added.join(", "), removed.join(", "))
}

/// Replays one session's log.
pub fn replay_session(store: &dyn Store, id: &str, harness: &str) -> Result<SessionReplay> {
    let mut fold = Fold {
        out: SessionReplay {
            session: id.to_owned(),
            harness: harness.to_owned(),
            ..Default::default()
        },
        ..Fold::default()
    };
    store.scan_kinds(id, KINDS, &mut |r| {
        fold.record(&r);
        true
    })?;
    Ok(fold.out)
}

/// The sessions `wanted` names: an id, a unique id prefix or a unique name.
fn resolve(metas: &[crate::store::SessionMeta], wanted: &str) -> Option<usize> {
    if let Some(i) = metas.iter().position(|m| m.id == wanted) {
        return Some(i);
    }
    let one = |hits: Vec<usize>| match hits.as_slice() {
        [hit] => Some(*hit),
        _ => None,
    };
    one(metas
        .iter()
        .enumerate()
        .filter(|(_, m)| m.id.starts_with(wanted))
        .map(|(i, _)| i)
        .collect())
    .or_else(|| {
        one(metas.iter().enumerate().filter(|(_, m)| m.name == wanted).map(|(i, _)| i).collect())
    })
}

/// Replays the sessions `wanted` names (all of them when empty).
pub fn replay(store: &dyn Store, wanted: &[String]) -> Result<Replay> {
    let metas = store.list()?;
    let mut answer = Replay {
        checked: CHECKED.iter().map(|(n, name)| json!({"invariant": n, "name": name})).collect(),
        not_yet: NOT_YET.iter().map(|(n, name)| json!({"invariant": n, "name": name})).collect(),
        ..Replay::default()
    };
    let picked: Vec<usize> = if wanted.is_empty() {
        (0..metas.len()).collect()
    } else {
        let mut picked = vec![];
        for w in wanted {
            match resolve(&metas, w) {
                Some(i) if !picked.contains(&i) => picked.push(i),
                Some(_) => {}
                None => answer.missing.push(w.clone()),
            }
        }
        picked
    };
    for (_, name) in CHECKED {
        answer.counters.insert(format!("harnessMagic.scorecard.violations.{name}"), 0);
    }
    for i in picked {
        let meta = metas.get(i).context("scorecard replay: selected session is missing")?;
        let session = match replay_session(store, &meta.id, &meta.harness) {
            Ok(s) => s,
            Err(error) => {
                tracing::warn!(session = %meta.id, "scorecard replay: an unreadable log: {error:#}");
                answer.missing.push(meta.id.clone());
                continue;
            }
        };
        for v in &session.violations {
            *answer
                .counters
                .entry(format!("harnessMagic.scorecard.violations.{}", v.name))
                .or_default() += 1;
        }
        answer.violations += session.violations.len() as u64;
        answer.sessions.push(session);
    }
    answer
        .counters
        .insert("harnessMagic.scorecard.replaySessions".into(), answer.sessions.len() as u64);
    Ok(answer)
}

/// The replay as JSON (the RPC's answer).
pub fn to_value(r: &Replay) -> Value {
    serde_json::to_value(r).unwrap_or_else(|e| json!({"error": e.to_string()}))
}

#[cfg(test)]
#[path = "scorecard_replay_tests.rs"]
mod tests;
