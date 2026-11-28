//! Finish a coord-sim seed before starting the measured daemon. This is fixture preparation,
//! not recovery code: it supports the lifecycle payloads of pinned coord-sim 6fab351.
//!
//! The daemon's reducers are private to `acpmux::hub`. The small reducer below follows
//! `queue_restore`, `lost_start`, `unstarted_prompt`, and `log_load::open_turn`; it refuses
//! richer queue/digest/transfer state instead of guessing. No Hub is opened, no kind index or
//! restore point is written, and existing log bytes are never rewritten. Only unresolved
//! prompts, the final interrupted turn, and unhandled inbox items get completion records.
//! [`append_settled_turns`] then repeats the history's latest whole turns after them, so the
//! newest pages a measurement reads are ordinary history and not those records.

use acpmux::hub::EventFilter;
use acpmux::store::{EventRecord, LocalStore, SessionStatus, Store};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Debug)]
pub struct Settled {
    /// Actual event-log bytes, including the completion suffix; excludes attachments/metadata.
    pub bytes: u64,
    pub records: u64,
    pub last_seq: u64,
    pub transcript_seq: u64,
    pub turns: u64,
    pub appended: u64,
    /// Number of queue_removed records (one can close multiple prompts sharing a turn).
    pub removed_prompts: u64,
    pub removed_inbox: u64,
    pub settled_turns: u64,
}

/// Index both identities: queue removal is by turn, lost-start completion is by prompt.
#[derive(Default)]
struct Pairs {
    turns: BTreeMap<String, BTreeSet<String>>,
    prompts: BTreeMap<String, BTreeSet<String>>,
}

impl Pairs {
    fn insert(&mut self, prompt: &str, turn: &str) {
        self.turns.entry(turn.into()).or_default().insert(prompt.into());
        self.prompts.entry(prompt.into()).or_default().insert(turn.into());
    }

    fn remove(&mut self, prompt: &str, turn: &str) {
        if let Some(ps) = self.turns.get_mut(turn) {
            ps.remove(prompt);
            if ps.is_empty() {
                self.turns.remove(turn);
            }
        }
        if let Some(ts) = self.prompts.get_mut(prompt) {
            ts.remove(turn);
            if ts.is_empty() {
                self.prompts.remove(prompt);
            }
        }
    }

    fn remove_turn(&mut self, turn: &str) {
        let prompts = self.turns.get(turn).cloned().unwrap_or_default();
        for prompt in prompts {
            self.remove(&prompt, turn);
        }
    }

    fn remove_prompt(&mut self, prompt: &str) -> BTreeSet<String> {
        let turns = self.prompts.get(prompt).cloned().unwrap_or_default();
        for turn in &turns {
            self.remove(prompt, turn);
        }
        turns
    }

    fn other_turns(&mut self, prompt: &str, turn: Option<&str>) {
        let turns = self.prompts.get(prompt).cloned().unwrap_or_default();
        for other in turns {
            if Some(other.as_str()) != turn {
                self.remove(prompt, &other);
            }
        }
    }

    fn pairs(&self) -> impl Iterator<Item = (&str, &str)> {
        self.turns.iter().flat_map(|(t, ps)| ps.iter().map(move |p| (p.as_str(), t.as_str())))
    }
}

#[derive(Default)]
struct Pending {
    waiting: Pairs,
    lost: Pairs,
    direct: Pairs,
    queued_turns: BTreeSet<String>,
    started_turns: BTreeSet<String>,
    open: Option<(String, String, u64)>,
    inbox: BTreeSet<String>,
    inbox_done: BTreeSet<String>,
}

fn field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

impl Pending {
    fn settle_lost(&mut self, prompt: &str) {
        for turn in self.lost.remove_prompt(prompt) {
            self.waiting.remove_turn(&turn);
        }
    }

    fn read(&mut self, e: &EventRecord) -> Result<()> {
        if e.kind == "subagent_state_update" {
            for entry in e
                .msg
                .pointer("/params/_meta/acpmux/subagents")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                ensure!(
                    ["retry", "retryInFlight"]
                        .iter()
                        .all(|k| entry.get(k).is_none_or(Value::is_null)),
                    "unsupported seed subagent retry at {}",
                    e.seq
                );
            }
        }
        if e.dir != "mux" {
            return Ok(());
        }
        let (p, t) = (field(&e.msg, "promptId"), field(&e.msg, "turnId"));
        // These are absent from the pinned generator's lifecycle templates. In particular,
        // dequeued inbox digests and joined turns require the real digest/starting-turn fold.
        for key in ["digestPromptId", "joinedTurnId", "hiddenContext", "transferId"] {
            ensure!(
                e.msg.get(key).is_none_or(Value::is_null),
                "unsupported seed state {}.{key} at seq {}",
                e.kind,
                e.seq
            );
        }
        ensure!(!e.kind.starts_with("agent_pair_"), "unsupported seed agent pair at {}", e.seq);
        ensure!(
            e.msg.pointer("/_meta/provenance").is_none(),
            "unsupported seed provenance at {}",
            e.seq
        );
        if matches!(e.kind.as_str(), "queue_order" | "queue_paused") {
            for key in ["order", "held", "retrying"] {
                ensure!(
                    e.msg.get(key).is_none_or(|v| v.as_array().is_some_and(Vec::is_empty)),
                    "unsupported seed queue ordering/hold at {}",
                    e.seq
                );
            }
        }
        // lost_start::Unstarted is read before the queue and direct-prompt folds.
        match e.kind.as_str() {
            "dequeued" if self.open.is_none() => {
                if let (Some(p), Some(t)) = (p, t)
                    && self.waiting.turns.contains_key(t)
                    && !self.lost.turns.contains_key(t)
                {
                    self.lost.insert(p, t);
                }
            }
            "turn_started" => {
                let (Some(p), Some(t)) = (p, t) else {
                    bail!("seed turn_started lacks identities at {}", e.seq);
                };
                self.settle_lost(p);
                let lost = self.lost.turns.get(t).cloned().unwrap_or_default();
                for p in lost {
                    self.settle_lost(&p);
                }
                self.open = Some((p.into(), t.into(), e.seq));
            }
            "turn_result" => {
                self.open = None;
                if let Some(p) = p {
                    self.settle_lost(p);
                }
            }
            "user_message" => {
                if let Some(p) = p {
                    let turns = self.lost.prompts.get(p).cloned().unwrap_or_default();
                    for turn in turns {
                        if e.msg.get("steer") == Some(&Value::Bool(true))
                            || Some(turn.as_str()) != t
                        {
                            self.lost.remove(p, &turn);
                            self.waiting.remove_turn(&turn);
                        }
                    }
                }
            }
            "prompt_refused" | "queue_removed" | "queued" => {
                if let Some(p) = p {
                    self.settle_lost(p);
                }
            }
            _ => {}
        }
        // unstarted_prompt::Unstarted: accepted direct prompts can survive without a queue.
        match e.kind.as_str() {
            "queued" => {
                if let Some(t) = t {
                    self.queued_turns.insert(t.into());
                }
                if let Some(p) = p {
                    self.direct.remove_prompt(p);
                }
            }
            "user_message" if e.msg.get("steer") != Some(&Value::Bool(true)) => {
                if let (Some(p), Some(t)) = (p, t) {
                    self.direct.other_turns(p, Some(t));
                    if !self.queued_turns.contains(t) && !self.started_turns.contains(t) {
                        // The daemon keeps the first accepted direct prompt per turn.
                        if !self.direct.turns.contains_key(t) {
                            self.direct.insert(p, t);
                        }
                    }
                }
            }
            "turn_started" | "turn_result" | "queue_removed" | "prompt_refused" | "dequeued" => {
                if let Some(t) = t {
                    self.direct.remove_turn(t);
                    if e.kind == "turn_started" {
                        self.started_turns.insert(t.into());
                    }
                }
                if e.kind != "dequeued"
                    && let Some(p) = p
                {
                    self.direct.remove_prompt(p);
                }
            }
            _ => {}
        }
        // queue_restore: matching turn ids retire queued entries, unless a dequeue was lost.
        if matches!(e.kind.as_str(), "queued" | "user_message" | "turn_started")
            && let Some(p) = p
        {
            self.waiting.other_turns(p, t);
        }
        match e.kind.as_str() {
            "queued" => {
                if let (Some(p), Some(t)) = (p, t) {
                    if e.msg.get("requeued") == Some(&Value::Bool(true)) {
                        self.waiting.remove_turn(t);
                    }
                    self.waiting.insert(p, t);
                }
            }
            "dequeued" | "user_message" if t.is_some_and(|t| self.lost.turns.contains_key(t)) => {}
            "dequeued" | "queue_removed" | "queue_declined" | "user_message" | "turn_started" => {
                if let Some(t) = t {
                    self.waiting.remove_turn(t);
                }
            }
            "inbox" => {
                if let Some(p) = p {
                    self.inbox.insert(p.into());
                    if e.msg.get("deliveredRead") == Some(&Value::Bool(true)) {
                        self.inbox_done.insert(p.into());
                    }
                }
            }
            "inbox_removed" => {
                if let Some(p) = p {
                    self.inbox_done.insert(p.into());
                }
            }
            // Reading alone does not suppress an inbox wake: inbox::next checks `noticed`.
            "inbox_noticed" => {
                for p in e
                    .msg
                    .get("promptIds")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                {
                    self.inbox_done.insert(p.into());
                }
            }
            "inbox_returned" => {
                bail!("unsupported seed inbox_returned at {}", e.seq);
            }
            _ => {}
        }
        Ok(())
    }

    fn suffix(&self) -> Vec<(&'static str, Value)> {
        let mut out = Vec::new();
        // One removal per turn clears all its waiting records and its direct prompt. If it
        // has a lost dequeue, use that dequeue's prompt id to clear lost_start too. That id
        // can differ from a queued peer prompt in the pinned generator.
        let mut prompts = BTreeMap::new();
        for (p, t) in self.waiting.pairs().chain(self.direct.pairs()).chain(self.lost.pairs()) {
            prompts.insert(t, p);
        }
        for (t, p) in prompts {
            out.push((
                "queue_removed",
                json!({"promptId":p,"turnId":t,"reason":"fixture_complete"}),
            ));
        }
        for p in self.inbox.difference(&self.inbox_done) {
            out.push(("inbox_removed", json!({"promptId":p,"reason":"fixture_complete"})));
        }
        if let Some((p, t, seq)) = &self.open {
            out.push((
                "turn_result",
                json!({"promptId":p,"turnId":t,"turnSeq":seq,
                "status":"completed","stopReason":"end_turn","fixtureComplete":true}),
            ));
        }
        out
    }
}

/// Settle a freshly generated, offline acpmux home. Call before `Daemon::start`, and use the
/// returned sizes/seq instead of the generator manifest's pre-completion values. A repeat is
/// idempotent. This does not support live, archived, transferred, or restored real sessions.
pub fn settle(home: &Path, id: &str) -> Result<Settled> {
    // LocalStore writes directly to segments; Store::open would create a journal. Neither
    // scan_strict nor append populates kind indexes, unlike scan_kinds/Hub log loading.
    let store = LocalStore::new(home.join("sessions"), 8 << 20)?;
    let mut meta = store.load(id)?.context("seed session metadata is missing")?;
    ensure!(meta.id == id && meta.status == SessionStatus::Idle, "expected an idle offline seed");
    let filter = EventFilter::parse(Some(&json!(["transcript"])))?;
    let mut pending = Pending::default();
    let (mut records, mut last_seq, mut at, mut transcript_seq, mut turns) =
        (0_u64, 0_u64, 0_u64, 0_u64, 0_u64);
    let mut failure = None;
    store.scan_strict(id, 0, &mut |e| {
        if e.seq != last_seq + 1 {
            failure = Some(anyhow::anyhow!("noncontiguous seed seq {} after {last_seq}", e.seq));
            return false;
        }
        records += 1;
        last_seq = e.seq;
        at = at.max(e.at);
        if filter.matches(&e) {
            transcript_seq = e.seq;
        }
        if e.dir == "mux" && e.kind == "user_message" {
            turns += 1;
        }
        if let Err(error) = pending.read(&e) {
            failure = Some(error);
            return false;
        }
        true
    })?;
    if let Some(error) = failure {
        return Err(error);
    }
    let suffix = pending.suffix();
    let appended = suffix.len() as u64;
    let count = |kind| suffix.iter().filter(|(k, _)| *k == kind).count() as u64;
    let (removed_prompts, removed_inbox, settled_turns) =
        (count("queue_removed"), count("inbox_removed"), count("turn_result"));
    for (kind, msg) in suffix {
        last_seq += 1;
        at += 1;
        let e = EventRecord {
            seq: last_seq,
            at,
            dir: "mux".into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        if filter.matches(&e) {
            transcript_seq = e.seq;
        }
        store.append(id, &e)?;
        records += 1;
    }
    if appended > 0
        || meta.last_seq != last_seq
        || meta.event_count != records
        || meta.transcript_seq != transcript_seq
        || meta.turn_count != turns
        || meta.updated_at < at
    {
        meta.last_seq = last_seq;
        meta.event_count = records;
        meta.transcript_seq = transcript_seq;
        meta.turn_count = turns;
        meta.updated_at = meta.updated_at.max(at);
        store.save(&meta)?;
        store.flush()?;
    }
    let mut bytes = 0;
    for entry in std::fs::read_dir(home.join("sessions").join(id).join("events"))? {
        let entry = entry?;
        if entry.path().extension().is_some_and(|e| e == "ndjson") {
            bytes += entry.metadata()?.len();
        }
    }
    Ok(Settled {
        bytes,
        records,
        last_seq,
        transcript_seq,
        turns,
        appended,
        removed_prompts,
        removed_inbox,
        settled_turns,
    })
}

/// What [`append_settled_turns`] wrote after the completion records.
#[derive(Debug)]
pub struct Tail {
    /// Original history the run copies: the seqs after `from` through `through`.
    pub from: u64,
    pub through: u64,
    pub records: u64,
    pub bytes: u64,
    pub turns: u64,
    /// The completion records the copy needed (queued or inbox prompts it leaves open), each
    /// right after the copy's last record of that prompt or turn, not at the end.
    pub completion_seqs: Vec<u64>,
    /// The log after the run, as [`Settled`] reports it.
    pub log_bytes: u64,
    pub log_records: u64,
    pub last_seq: u64,
    pub log_turns: u64,
}

/// The ids a copied record carries, so they differ from the history it repeats.
fn rename(msg: &mut Value) {
    let Some(map) = msg.as_object_mut() else { return };
    for key in ["promptId", "turnId", "messageId", "noticePromptId"] {
        if let Some(Value::String(s)) = map.get_mut(key) {
            s.push_str("~tail");
        }
    }
    if let Some(Value::Array(ids)) = map.get_mut("promptIds") {
        for id in ids.iter_mut() {
            if let Value::String(s) = id {
                s.push_str("~tail");
            }
        }
    }
}

fn mentions(e: &EventRecord, prompt: &str, turn: Option<&str>) -> bool {
    e.dir == "mux"
        && (field(&e.msg, "promptId") == Some(prompt)
            || turn.is_some_and(|t| field(&e.msg, "turnId") == Some(t))
            || e.msg
                .get("promptIds")
                .and_then(Value::as_array)
                .is_some_and(|ids| ids.iter().any(|id| id.as_str() == Some(prompt))))
}

/// A run of the history's own settled turns after [`settle`]'s completion records, so the
/// newest pages read ordinary history and not the records that settled it. The run copies the
/// latest whole turns of the history through `history_end` (from just after one `turn_result`
/// through a later one) of at least `target` bytes, or a quarter of the history when that is
/// less, with fresh prompt, turn and message ids, and times and host seqs after the log's. The
/// copy leaves no queued prompt or inbox item open: what it would leave gets its completion
/// right after that prompt's last record. Not idempotent: call once, after `settle`.
pub fn append_settled_turns(home: &Path, id: &str, history_end: u64, target: u64) -> Result<Tail> {
    let store = LocalStore::new(home.join("sessions"), 8 << 20)?;
    let mut meta = store.load(id)?.context("seed session metadata is missing")?;
    let filter = EventFilter::parse(Some(&json!(["transcript"])))?;
    // Each turn_result through history_end, with the history's bytes through it.
    let (mut ends, mut bytes) = (vec![(0_u64, 0_u64)], 0_u64);
    let (mut last_seq, mut at, mut host_seq, mut records, mut turns, mut transcript_seq) =
        (0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64);
    store.scan_strict(id, 0, &mut |e| {
        if e.seq <= history_end {
            bytes += serde_json::to_vec(&e).map_or(0, |v| v.len() as u64 + 1);
            if e.dir == "mux" && e.kind == "turn_result" {
                ends.push((e.seq, bytes));
            }
        }
        records += 1;
        last_seq = e.seq;
        at = at.max(e.at);
        host_seq = host_seq.max(e.host_seq.unwrap_or(0));
        if filter.matches(&e) {
            transcript_seq = e.seq;
        }
        if e.dir == "mux" && e.kind == "user_message" {
            turns += 1;
        }
        true
    })?;
    let &(through, through_bytes) = ends.last().expect("ends starts with the log's start");
    ensure!(through > 0, "the seed history has no settled turn to repeat");
    let target = target.min(bytes / 4).max(1);
    // The latest turn boundary with at least `target` bytes after it.
    let from = ends
        .iter()
        .rev()
        .skip(1)
        .find(|(_, b)| through_bytes - b >= target)
        .map_or(0, |(seq, _)| *seq);

    let mut window = Vec::new();
    store.scan_strict(id, from, &mut |mut e| {
        if e.seq > through {
            return false;
        }
        if e.dir == "mux" {
            rename(&mut e.msg);
        }
        window.push(e);
        true
    })?;
    ensure!(
        window.first().is_some_and(|e| e.seq == from + 1)
            && window.last().is_some_and(|e| e.seq == through),
        "the seed history between {from} and {through} is not contiguous"
    );

    // What the copy would leave open, completed after its last record of that prompt or turn.
    let mut pending = Pending::default();
    for e in &window {
        pending.read(e)?;
    }
    let mut after: BTreeMap<usize, Vec<(&'static str, Value)>> = BTreeMap::new();
    for (kind, msg) in pending.suffix() {
        let prompt = field(&msg, "promptId").unwrap_or_default().to_owned();
        let turn = field(&msg, "turnId").map(str::to_owned);
        let i = window
            .iter()
            .rposition(|e| mentions(e, &prompt, turn.as_deref()))
            .unwrap_or(window.len() - 1);
        after.entry(i).or_default().push((kind, msg));
    }

    let first_at = window[0].at;
    let first_host = window.iter().filter_map(|e| e.host_seq).min().unwrap_or(0);
    let base_at = at + 1;
    let mut check = Pending::default();
    let mut tail = Tail {
        from,
        through,
        records: 0,
        bytes: 0,
        turns: 0,
        completion_seqs: vec![],
        log_bytes: 0,
        log_records: 0,
        last_seq: 0,
        log_turns: 0,
    };
    for (i, mut e) in window.into_iter().enumerate() {
        last_seq += 1;
        e.seq = last_seq;
        e.at = (base_at + e.at.saturating_sub(first_at)).max(at);
        at = e.at;
        e.host_seq = e.host_seq.map(|h| host_seq + 1 + h.saturating_sub(first_host));
        let mut out = vec![(e, false)];
        for (kind, msg) in after.remove(&i).unwrap_or_default() {
            last_seq += 1;
            let rec = EventRecord {
                seq: last_seq,
                at,
                dir: "mux".into(),
                kind: kind.into(),
                msg,
                host_seq: None,
            };
            out.push((rec, true));
        }
        for (e, completion) in out {
            check.read(&e)?;
            if filter.matches(&e) {
                transcript_seq = e.seq;
            }
            if e.dir == "mux" && e.kind == "user_message" {
                turns += 1;
                tail.turns += 1;
            }
            if completion {
                tail.completion_seqs.push(e.seq);
            } else {
                tail.records += 1;
                tail.bytes += serde_json::to_vec(&e).map_or(0, |v| v.len() as u64 + 1);
            }
            store.append(id, &e)?;
            records += 1;
        }
    }
    let left = check.suffix();
    ensure!(left.is_empty(), "the repeated turns leave {} records open: {left:?}", left.len());
    meta.last_seq = last_seq;
    meta.event_count = records;
    meta.transcript_seq = transcript_seq;
    meta.turn_count = turns;
    meta.updated_at = meta.updated_at.max(at);
    store.save(&meta)?;
    store.flush()?;
    let mut log_bytes = 0;
    for entry in std::fs::read_dir(home.join("sessions").join(id).join("events"))? {
        let entry = entry?;
        if entry.path().extension().is_some_and(|e| e == "ndjson") {
            log_bytes += entry.metadata()?.len();
        }
    }
    tail.log_bytes = log_bytes;
    tail.log_records = records;
    tail.last_seq = last_seq;
    tail.log_turns = turns;
    Ok(tail)
}

#[cfg(test)]
#[path = "chat_size_seed_tests.rs"]
mod tests;
