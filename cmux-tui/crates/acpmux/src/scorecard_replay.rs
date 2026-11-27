//! `acpmux scorecard replay <session>` (`_acpmux/scorecard_replay`): walks a recorded chat's log
//! through deterministic code, with no model call, and checks the cache-prefix invariants of RFD
//! 0161 (cmuxterm-hq `docs/rfd/0161-hm-scorecard-and-replay.md`). Leo, 2026-11-25: "we can't be
//! letting important rfds like that take breaks ... esp when this is stuff that materially
//! improves the app".
//!
//! Each violation names the session, the record (`seq`, `at`) and the invariant. All five:
//!
//! - **1 `contextExtends`**: each main-loop request's prompt (`used`: its input, cache reads and
//!   cache writes) is at least the one before's, unless a compaction, a context surgery or a
//!   `/clear` came between them, or the cache had expired (Claude Code clears old tool results
//!   once its cache lapses). A shrink under [`SHRINK_TOLERANCE`] of the prompt, or under
//!   [`MIN_MISS_CONTEXT`] tokens, is no violation: Claude Code trims the tail of the last turn
//!   (2.3-3.6% in three of 526 calls over twelve recorded sessions, 2026-11-26).
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
//! - **3 `outputCapped`**: no tool result over the output cap enters context (RFD 0147). The
//!   result is the `tool_call_update` that completes a call, whose text is the `tool_result`
//!   the model got. The cap is Claude Code's own: a Bash result over [`BASH_CAP_CHARS`] is
//!   spilled to a file with a short preview; Read and MCP results are capped at 25,000 tokens,
//!   taken as [`TOKEN_CAP_CHARS`] characters.
//! - **4 `rereadsBounded`**: after a compaction, a surgery or a `/clear`, the files read before
//!   it (a `read`-kind call's path) that are read again before the next one stay at most half of
//!   them, once [`REREAD_MIN_REMOVED`] files were removed (RFD 0149's regret rate). The
//!   violation names the boundary.
//!
//! The daemon's CI replays a fixed set of recorded sessions (`data/scorecard-replay/`, one
//! derived from a real lane session and one seeded break per invariant) and holds each to the
//! violations its `expected.json` names (`scorecard_replay_fixtures_tests.rs`).
//!
//! Off switch, as the RFD says: `agents.harnessMagic.scorecard.enabled: false` or
//! `ACPMUX_HM_SCORECARD=0` (`hub/harness_magic.rs`). Its counters,
//! `harnessMagic.scorecard.replaySessions` and `harnessMagic.scorecard.violations.<invariant>`,
//! are on every answer.

use crate::claude_stdio::prompt_cache::{MIN_MISS_CONTEXT, miss_cause};
use crate::store::{EventRecord, Store};
use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;

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
    "claude.system.conversation_reset",
    "tool_call",
    "tool_call_update",
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

/// Invariant 1: a prompt may come in this share under the one before (per mille) with no
/// boundary, the tail Claude Code trims.
pub const SHRINK_TOLERANCE: u64 = 50;
/// Invariant 3: Claude Code spills a Bash result over this many characters to a file.
pub const BASH_CAP_CHARS: usize = 30_000;
/// Invariant 3: Read and MCP results are capped at 25,000 tokens, at four characters a token.
pub const TOKEN_CAP_CHARS: usize = 25_000 * 4;
/// Invariant 4: a boundary that removed fewer files than this is not judged.
pub const REREAD_MIN_REMOVED: usize = 4;

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
    pub results: u64,
    /// Compactions, surgeries and `/clear`s that removed files, checked against invariant 4.
    pub boundaries: u64,
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
    /// This call's prompt, which the next one's extends.
    prompt: u64,
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
    /// Each tool call's tool and the path a `read` call names, by call id.
    calls: BTreeMap<String, Call>,
    /// Files read since the last boundary that removed context.
    read: std::collections::BTreeSet<String>,
    /// The re-reads of what the last such boundary removed.
    rereads: Option<Rereads>,
}

#[derive(Default)]
struct Call {
    tool: Option<String>,
    read_path: Option<String>,
    /// Its result was checked already.
    done: bool,
}

/// What one boundary removed, and what of it was read again.
struct Rereads {
    seq: u64,
    at: u64,
    cause: &'static str,
    removed: std::collections::BTreeSet<String>,
    again: std::collections::BTreeSet<String>,
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
                    self.removed(r, "compaction");
                }
            }
            "claude.system.compact_boundary" => self.removed(r, "compaction"),
            "harness_surgery" => self.removed(r, "surgery"),
            "claude.system.conversation_reset" => self.removed(r, "clear"),
            "config_option_update" => self.boundary = Some("config".into()),
            "tool_call" | "tool_call_update" => self.tool(r),
            _ => {}
        }
    }

    /// A boundary that took context out: what was read before it is gone.
    fn removed(&mut self, r: &EventRecord, cause: &'static str) {
        self.boundary = Some(cause.into());
        // A compaction logs its boundary and its end: the second removes nothing more.
        if self.read.is_empty() {
            return;
        }
        self.judge_rereads();
        self.rereads = Some(Rereads {
            seq: r.seq,
            at: r.at,
            cause,
            removed: std::mem::take(&mut self.read),
            again: Default::default(),
        });
    }

    /// Invariant 4 for the last boundary, once the next one (or the log's end) closes it.
    fn judge_rereads(&mut self) {
        let Some(w) = self.rereads.take() else { return };
        if w.removed.len() < REREAD_MIN_REMOVED {
            return;
        }
        self.out.boundaries += 1;
        if w.again.len() * 2 > w.removed.len() {
            let some: Vec<_> = w.again.iter().take(3).map(String::as_str).collect();
            self.out.violations.push(Violation {
                session: self.out.session.clone(),
                invariant: 4,
                name: REREADS_BOUNDED,
                seq: w.seq,
                at: w.at,
                detail: format!(
                    "{} of the {} files read before this {} were read again after it ({}, ...)",
                    w.again.len(),
                    w.removed.len(),
                    w.cause,
                    some.join(", ")
                ),
            });
        }
    }

    fn tool(&mut self, r: &EventRecord) {
        let u = update(&r.msg);
        let Some(id) = u.get("toolCallId").and_then(Value::as_str) else { return };
        let call = self.calls.entry(id.to_owned()).or_default();
        if let Some(tool) = u.pointer("/_meta/claude/tool").and_then(Value::as_str) {
            call.tool = Some(tool.to_owned());
        }
        if u.get("kind").and_then(Value::as_str) == Some("read") && call.read_path.is_none() {
            let path = u
                .pointer("/_meta/acpmux/canonicalPath")
                .or_else(|| u.pointer("/rawInput/file_path"))
                .or_else(|| u.pointer("/rawInput/path"))
                .and_then(Value::as_str);
            if let Some(path) = path {
                call.read_path = Some(path.to_owned());
                if let Some(w) = self.rereads.as_mut()
                    && w.removed.contains(path)
                {
                    w.again.insert(path.to_owned());
                }
                self.read.insert(path.to_owned());
            }
        }
        let status = u.get("status").and_then(Value::as_str);
        if call.done || !matches!(status, Some("completed" | "failed")) {
            return;
        }
        let Some(blocks) = u.get("content").and_then(Value::as_array) else { return };
        call.done = true;
        let chars: usize = blocks
            .iter()
            .filter_map(|b| b.pointer("/content/text").and_then(Value::as_str))
            .map(|t| t.chars().count())
            .sum();
        let tool = call.tool.clone().unwrap_or_default();
        self.out.results += 1;
        let cap = if tool == "Bash" { BASH_CAP_CHARS } else { TOKEN_CAP_CHARS };
        if chars > cap {
            let detail = format!(
                "a {} result of {chars} characters entered context, over the {cap} cap",
                if tool.is_empty() { "tool" } else { &tool }
            );
            self.violation(r, 3, OUTPUT_CAPPED, detail);
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
        let prompt = u
            .get("used")
            .and_then(Value::as_u64)
            .unwrap_or_else(|| n("inputTokens") + read + n("cachedWriteTokens"));
        let expires_at = u.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64);
        let boundary = self.boundary.take();
        if let Some(last) = &self.last
            && !matches!(boundary.as_deref(), Some("compaction" | "surgery" | "clear"))
            && !(last.expires_at > 0 && r.at >= last.expires_at)
            && last.prompt.saturating_sub(prompt)
                >= MIN_MISS_CONTEXT.max(last.prompt * SHRINK_TOLERANCE / 1000)
        {
            let detail = format!(
                "the prompt shrank from {} to {prompt} tokens with no compaction, surgery or /clear and the cache not expired",
                last.prompt
            );
            self.violation(r, 1, CONTEXT_EXTENDS, detail);
        }
        if let Some(last) = &self.last
            && last.context >= MIN_MISS_CONTEXT
            && read.saturating_mul(2) < last.context
        {
            let model_changed = last.model.is_some() && last.model != self.call_model;
            let cause = match boundary.as_deref() {
                Some("surgery") => "surgery",
                Some("clear") => "clear",
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
            prompt,
            // A call that names no expiry keeps the last one (`prompt_cache.rs`).
            expires_at: expires_at.or(self.last.as_ref().map(|l| l.expires_at)).unwrap_or(0),
            model: self.call_model.clone(),
        });
    }
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
    fold.judge_rereads();
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

#[cfg(test)]
#[path = "scorecard_replay_fixtures_tests.rs"]
mod fixtures_tests;
