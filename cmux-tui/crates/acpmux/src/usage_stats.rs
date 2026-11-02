//! What each chat's harness spends and holds (`SessionSummary.usageStats`), read
//! from the harness's own records (Leo, 2026-10-30: "that visibility into
//! huge-blue guys was (and is?) pretty bad i feel like we can make more
//! improvements to acpmux/cmux-next"): four deputies ran plain Claude Code with
//! no autocompact cap for hours, at 290-330k tokens of context a call and 67-90
//! subagents each, and nothing in acpmux showed it.
//!
//! - Claude Code: the chat's transcript (`<CLAUDE_CONFIG_DIR or ~/.claude>/projects/<cwd>/<sid>.jsonl`),
//!   whose `assistant` lines carry each API call's `usage` (several lines share one
//!   `message.id` and its usage: counted once) and whose `compact_boundary` lines mark
//!   compactions; and its subagents' own transcripts (`<sid>/subagents/agent-*.jsonl`),
//!   one per spawn, with a `.meta.json` that says `finished` once it ends.
//! - Codex: the rollout (`<CODEX_HOME or ~/.codex>/sessions/YYYY/MM/DD/rollout-*-<sid>.jsonl`):
//!   `token_count` events (`last_token_usage`, `model_context_window`), `compacted`
//!   items, and `spawn_agent` calls. A Codex child runs in its own thread, so its spend is
//!   its own rollout's, not the parent's.
//!
//! Cheap and incremental: a [`Tracker`] keeps each file's read offset and reads only
//! what was appended since, in bounded steps; a first read takes at most the newest
//! [`FIRST_READ_BYTES`]. A count is unknown (null), never a lower number, until the reads
//! cover the whole day: a first read cut short after the day began, a backlog left for the
//! next refresh, or a file that could not be read. Lines that cannot carry usage are skipped
//! before they are parsed. Spend is kept in minute buckets for the last day, so the 24-hour and
//! one-hour sums need no rescan. Cost is the model catalog's list price for the
//! tokens (USD per million), null when no model of the window has a price.

use crate::protocol::session::{Autocompact, UsageStats};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

const MINUTE_MS: u64 = 60_000;
const HOUR_MS: u64 = 60 * MINUTE_MS;
pub const DAY_MS: u64 = 24 * HOUR_MS;
/// The most of a file a first read takes: its newest bytes.
pub const FIRST_READ_BYTES: u64 = 256 << 20;
/// The most one refresh reads of one file; the rest waits for the next refresh.
const READ_STEP_BYTES: u64 = 64 << 20;
/// A Claude subagent that never said `finished` and whose transcript has not
/// changed for this long has died with its process: it is not counted live.
const LIVE_QUIET_MS: u64 = 30 * MINUTE_MS;
/// How long a transcript that was not found is left before it is looked for again.
const LOOK_AGAIN_MS: u64 = 5 * MINUTE_MS;
/// Message ids remembered per file to count a streamed message's usage once.
const RECENT_IDS: usize = 64;

/// List prices of one model, USD per million tokens (the catalog's `cost`).
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Prices {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
}

/// What the model catalog says of each model a harness may name: its prices and context window.
#[derive(Debug, Clone, Default)]
pub struct Models(HashMap<String, (Option<Prices>, Option<u64>)>);

impl Models {
    /// The catalog's prices and windows by model id; Anthropic's and OpenAI's own
    /// entries first, so a reseller's copy of a model never sets its price.
    pub fn from_catalog(catalog: &crate::catalog::Catalog) -> Self {
        let mut models = Models::default();
        let resold = |key: &&String| !(key.starts_with("anthropic/") || key.starts_with("openai/"));
        let mut keys: Vec<&String> = catalog.models.keys().collect();
        keys.sort_by_key(resold);
        for key in keys {
            let Some(info) = catalog.models.get(key.as_str()) else { continue };
            let Some((_, id)) = key.split_once('/') else { continue };
            let prices = info.cost.as_ref().and_then(|c| {
                Some(Prices {
                    input: c.input?,
                    output: c.output?,
                    cache_read: c.cache_read.or(c.input)?,
                    cache_write: c.cache_write.or(c.input)?,
                })
            });
            models.add(id, prices, info.context_window);
        }
        models
    }

    /// Adds `id` (a catalog key's model part); the first entry of an id wins.
    pub fn add(&mut self, id: &str, prices: Option<Prices>, window: Option<u64>) {
        self.0.entry(id.to_ascii_lowercase()).or_insert((prices, window));
    }

    fn get(&self, model: &str) -> Option<&(Option<Prices>, Option<u64>)> {
        // `claude-opus-5-5[1m]` is the same model's long-context name.
        let id = model.split('[').next().unwrap_or(model).trim().to_ascii_lowercase();
        self.0.get(&id)
    }

    fn prices(&self, model: &str) -> Option<Prices> {
        self.get(model)?.0
    }

    fn window(&self, model: &str) -> Option<u64> {
        self.get(model)?.1
    }
}

/// What the hub knows of one chat: enough to find its harness's records.
#[derive(Debug, Clone, Default)]
pub struct Source {
    /// `claude` or `codex`; any other family has no records read here.
    pub family: String,
    pub agent_session_id: String,
    pub cwd: PathBuf,
    /// Unix ms the chat was created: where a Codex rollout is looked for first.
    pub created_at: u64,
    /// The argv this daemon last started its harness with; None when it never did (an
    /// adopted, watched or revived chat), so its launcher and autocompact are unknown.
    pub argv: Option<Vec<String>>,
    /// The env its harness starts with (profile, preset, chat store, the chat's own).
    pub env: BTreeMap<String, String>,
}

impl Source {
    /// The harness's own home: `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, else `~/.claude` / `~/.codex`.
    fn home(&self) -> Option<PathBuf> {
        let (var, dir) = match self.family.as_str() {
            "claude" => ("CLAUDE_CONFIG_DIR", ".claude"),
            "codex" => ("CODEX_HOME", ".codex"),
            _ => return None,
        };
        let set = self.env.get(var).cloned().or_else(|| std::env::var(var).ok());
        match set.filter(|d| !d.is_empty()) {
            Some(dir) => Some(PathBuf::from(dir)),
            None => dirs::home_dir().map(|h| h.join(dir)),
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct Bucket {
    tokens: u64,
    cost_usd: f64,
    priced: bool,
    compactions: u64,
    spawns: u64,
}

/// One file read so far.
#[derive(Debug, Default)]
struct Tail {
    path: PathBuf,
    offset: u64,
    /// Message ids already counted (Claude streams one message over several lines).
    recent: VecDeque<String>,
    /// Codex's running total at the last `token_count`, which repeats on rate-limit updates.
    last_total: Option<u64>,
    /// Since when (unix ms) what was read covers the file: 0 from its start; None before a read,
    /// or when a first read began mid-file at a line with no time.
    covered_from: Option<u64>,
    /// The newest time (unix ms) of a record that should have counted but could not be read
    /// (not JSON, no time, no token counts, longer than a read step): the day's counts are
    /// unknown until it is older than the day.
    lost_at: Option<u64>,
    /// The read stopped inside a line longer than a read step: the next drops the rest of it.
    in_long_line: bool,
}

impl Tail {
    /// Whether what was read covers the day before `now`, with nothing in it lost.
    fn covers_day(&self, now: u64) -> bool {
        self.covered_from.is_some_and(|from| from == 0 || from.saturating_add(DAY_MS) <= now)
            && self.lost_at.is_none_or(|at| at.saturating_add(DAY_MS) <= now)
    }

    /// A record that should have counted could not be read: `at` is its time, else now.
    fn lose(&mut self, at: u64) {
        self.lost_at = Some(self.lost_at.map_or(at, |lost| lost.max(at)));
    }

    /// A record was seen: a later one with the same key is its duplicate ([`classify`]).
    fn remember(&mut self, key: &Key) {
        match key {
            Key::Message(id) if !self.recent.iter().any(|seen| seen == id) => {
                if self.recent.len() == RECENT_IDS {
                    self.recent.pop_front();
                }
                self.recent.push_back(id.clone());
            }
            Key::Total(total) => self.last_total = Some(*total),
            Key::Message(_) | Key::None => {}
        }
    }
}

#[derive(Debug, Default)]
struct Subagent {
    tail: Tail,
    /// Its first record was read and counted as a spawn.
    spawned: bool,
    /// It said `finished` and was read to its end: never read again.
    done: bool,
    live: bool,
}

/// The running state for one chat: offsets, the day's minute buckets, the last call's context.
#[derive(Debug, Default)]
pub struct Tracker {
    main: Option<Tail>,
    look_again_at: u64,
    subagents: HashMap<PathBuf, Subagent>,
    minutes: BTreeMap<u64, Bucket>,
    model: Option<String>,
    context_tokens: Option<u64>,
    /// When the call `context_tokens` comes from was made: an older one read later never replaces it.
    context_at: u64,
    context_window: Option<u64>,
    /// The newest call older than the window a read passed over, parsed at the read's end.
    old_context: Option<Vec<u8>>,
    /// The last refresh read every file to its end, covering the whole day: else the counts are
    /// lower than the truth, so they read as unknown.
    complete: bool,
    /// The most a first read takes and the most one refresh reads, per file (tests set them).
    limits: Option<(u64, u64)>,
}

impl Tracker {
    /// Reads what the chat's harness appended since the last refresh and returns the stats as
    /// of `now`; None while its transcript is not found.
    pub fn refresh(&mut self, source: &Source, now: u64, models: &Models) -> Option<UsageStats> {
        if self.main.is_none() && now >= self.look_again_at {
            match locate(source) {
                Some(path) => self.main = Some(Tail { path, ..Tail::default() }),
                None => self.look_again_at = now.saturating_add(LOOK_AGAIN_MS),
            }
        }
        let codex = source.family == "codex";
        let limits = self.limits.unwrap_or((FIRST_READ_BYTES, READ_STEP_BYTES));
        if let Some(mut tail) = self.main.take() {
            let read = read_new(&mut tail, limits, now, |line, tail| {
                if codex {
                    self.codex_line(line, tail, now, models);
                } else {
                    self.claude_line(line, tail, now, true, models);
                }
            });
            self.complete = read && tail.covers_day(now);
            if !codex {
                self.settle_context(&mut tail, now, models);
                let subagents =
                    self.claude_subagents(&tail.path, &source.agent_session_id, now, models);
                self.complete &= subagents;
            }
            self.main = Some(tail);
        }
        let cutoff = now.saturating_sub(DAY_MS);
        self.minutes = self.minutes.split_off(&cutoff.saturating_sub(cutoff % MINUTE_MS));
        let window =
            self.context_window.or_else(|| self.model.as_deref().and_then(|m| models.window(m)));
        self.main.as_ref()?;
        Some(self.stats(source, now, window))
    }

    fn stats(&self, source: &Source, now: u64, window: Option<u64>) -> UsageStats {
        let known = |n: u64| self.complete.then_some(n);
        let (mut day, mut hour_spawns, mut priced) = (Bucket::default(), 0_u64, false);
        for (minute, b) in &self.minutes {
            day.tokens = day.tokens.saturating_add(b.tokens);
            day.cost_usd += b.cost_usd;
            day.compactions = day.compactions.saturating_add(b.compactions);
            day.spawns = day.spawns.saturating_add(b.spawns);
            priced |= b.priced;
            if minute.saturating_add(MINUTE_MS) > now.saturating_sub(HOUR_MS) {
                hour_spawns = hour_spawns.saturating_add(b.spawns);
            }
        }
        let (autocompact, autocompact_cap) = autocompact(source, window);
        // Codex's children are not in its rollout: the hub fills them in (`hub/usage_view.rs`).
        let live = (source.family == "claude" && self.complete)
            .then(|| self.subagents.values().filter(|s| s.live).count() as u64);
        UsageStats {
            launcher: source.argv.as_deref().and_then(launcher),
            autocompact,
            autocompact_cap,
            context_tokens: self.context_tokens,
            context_window: window,
            compactions24h: known(day.compactions),
            subagents_live: live,
            subagents1h: known(hour_spawns),
            subagents24h: known(day.spawns),
            tokens24h: known(day.tokens),
            // Rounded to the cent's hundredth: a sum of list prices, not a bill.
            cost_usd24h: (self.complete && priced)
                .then(|| (day.cost_usd * 10_000.0).round() / 10_000.0),
            updated_at: now,
        }
    }

    fn bucket(&mut self, at: u64, now: u64) -> Option<&mut Bucket> {
        (at.saturating_add(DAY_MS) > now)
            .then(|| self.minutes.entry(at.saturating_sub(at % MINUTE_MS)).or_default())
    }

    fn claude_line(&mut self, line: &[u8], tail: &mut Tail, now: u64, main: bool, models: &Models) {
        if !(contains(line, b"\"assistant\"") || main && contains(line, b"compact_boundary")) {
            return escaped_kind(Harness::Claude { main }, line, tail, now);
        }
        // A line older than the window counts for nothing but, if it is the newest call, the
        // context: kept unparsed until the read ends (`settle_context`), as most of a long
        // chat's lines are, so its first read parses only the last day.
        if let Some(at) = quick_timestamp(line).filter(|at| at.saturating_add(DAY_MS) <= now) {
            // What `parse_claude_line` takes as a call: a main-loop assistant line with usage and
            // a real model (an API error Claude Code makes up names `<synthetic>`).
            let reply = contains(line, b"\"type\":\"assistant\"")
                && contains(line, b"\"input_tokens\"")
                && !contains(line, b"\"model\":\"<");
            // Seen, so a later untimed line of the same message is its duplicate, not lost.
            if reply && let Some(id) = quick_message_id(line) {
                tail.remember(&Key::Message(id));
            }
            if main && reply && !contains(line, b"\"isSidechain\":true") && at >= self.context_at {
                self.old_context = Some(line.to_vec());
            }
            return;
        }
        self.parse_claude_line(line, tail, now, main, models);
    }

    /// The newest old call a read passed over (`claude_line`) as the chat's context, unless a
    /// newer one was read.
    fn settle_context(&mut self, tail: &mut Tail, now: u64, models: &Models) {
        if let Some(line) = self.old_context.take() {
            // Its id is remembered already (`claude_line`): it is the call, not a repeat of it.
            let class = classify(Harness::Claude { main: true }, &line, &Tail::default());
            self.take(class, tail, now, models);
        }
    }

    fn parse_claude_line(
        &mut self,
        line: &[u8],
        tail: &mut Tail,
        now: u64,
        main: bool,
        models: &Models,
    ) {
        let class = classify(Harness::Claude { main }, line, tail);
        self.take(class, tail, now, models);
    }

    fn codex_line(&mut self, line: &[u8], tail: &mut Tail, now: u64, models: &Models) {
        let wanted = [&b"token_count"[..], b"\"compacted\"", b"spawn_agent", b"turn_context"];
        if !wanted.iter().any(|w| contains(line, w)) {
            return escaped_kind(Harness::Codex, line, tail, now);
        }
        let class = classify(Harness::Codex, line, tail);
        self.take(class, tail, now, models);
    }

    /// Applies one record's [`classify`]: what it counts goes in the day's buckets, what it
    /// should have counted and could not makes the day unknown (`Tail::lose`).
    fn take(&mut self, class: Class, tail: &mut Tail, now: u64, models: &Models) {
        let (at, counts) = match class {
            Class::Uncountable | Class::Duplicate => return,
            Class::Model { model } => return self.model = Some(model),
            Class::Lost { at, key } => {
                tail.remember(&key);
                return tail.lose(at.unwrap_or(now));
            }
            Class::Counted { at, counts } => (at, counts),
        };
        match counts {
            Counts::Compaction => {
                if let Some(b) = self.bucket(at, now) {
                    b.compactions = b.compactions.saturating_add(1);
                }
            }
            Counts::Spawn => {
                if let Some(b) = self.bucket(at, now) {
                    b.spawns = b.spawns.saturating_add(1);
                }
            }
            Counts::Tokens(t) => {
                tail.remember(&t.key);
                if let Some(window) = t.window {
                    self.context_window = Some(window);
                }
                if let Some(context) = t.context.filter(|_| at >= self.context_at) {
                    if t.model.is_some() {
                        self.model = t.model.clone();
                    }
                    self.context_tokens = Some(context);
                    self.context_at = at;
                }
                let model = t.model.clone().or_else(|| self.model.clone()).unwrap_or_default();
                let cost = models.prices(&model).map(|p| t.cost(&p));
                if let Some(b) = self.bucket(at, now) {
                    b.tokens = b.tokens.saturating_add(t.total);
                    if let Some(cost) = cost {
                        b.cost_usd += cost;
                        b.priced = true;
                    }
                }
            }
        }
    }

    /// Claude Code's subagents: one transcript per spawn beside the chat's
    /// (`<sid>/subagents/agent-*.jsonl`); its spend is the chat's too.
    /// Whether every subagent's transcript was read to its end, covering the day.
    fn claude_subagents(&mut self, main: &Path, sid: &str, now: u64, models: &Models) -> bool {
        let Some(dir) = main.parent().map(|d| d.join(sid).join("subagents")) else { return false };
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            // A chat that never started one.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return true,
            Err(_) => return false,
        };
        let limits = self.limits.unwrap_or((FIRST_READ_BYTES, READ_STEP_BYTES));
        let mut complete = true;
        for entry in entries {
            let Ok(entry) = entry else {
                complete = false;
                continue;
            };
            let path = entry.path();
            if path.extension().is_none_or(|e| e != "jsonl") {
                continue;
            }
            let mut agent = self.subagents.remove(&path).unwrap_or_default();
            if agent.done {
                self.subagents.insert(path, agent);
                continue;
            }
            let modified = modified_ms(&path).unwrap_or(0);
            let finished = std::fs::read(path.with_extension("meta.json"))
                .ok()
                .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
                .is_some_and(|meta| meta.get("finished").and_then(Value::as_bool) == Some(true));
            if agent.tail.path.as_os_str().is_empty() {
                agent.tail.path = path.clone();
                // Older than the window: nothing in it counts; never read.
                if modified.saturating_add(DAY_MS) <= now {
                    agent.done = true;
                    self.subagents.insert(path, agent);
                    continue;
                }
            }
            let mut tail = std::mem::take(&mut agent.tail);
            let mut first = None;
            let read = read_new(&mut tail, limits, now, |line, tail| {
                if first.is_none() && !agent.spawned {
                    first = serde_json::from_slice::<Value>(line).ok().and_then(|r| timestamp(&r));
                }
                self.claude_line(line, tail, now, false, models);
            });
            if !agent.spawned
                && let Some(at) = first.or(Some(modified)).filter(|&at| at > 0)
            {
                agent.spawned = true;
                if let Some(b) = self.bucket(at, now) {
                    b.spawns = b.spawns.saturating_add(1);
                }
            }
            complete &= read && tail.covers_day(now);
            agent.tail = tail;
            agent.live = !finished && modified.saturating_add(LIVE_QUIET_MS) > now;
            agent.done = finished && read;
            self.subagents.insert(path, agent);
        }
        complete
    }
}

/// Which records a transcript has, and the parse that reads them.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Harness {
    /// Claude Code; `main`: the chat's own transcript, not a subagent's.
    Claude {
        main: bool,
    },
    Codex,
}

/// What one transcript record is to the usage counts ([`classify`]).
#[derive(Debug, Clone, PartialEq)]
enum Class {
    /// Carries nothing to count: another kind of record, a reply Claude Code made up
    /// (`<synthetic>`), a rate-limit update, a subagent's compaction.
    Uncountable,
    /// Repeats one already counted: a streamed message's other lines, a repeated Codex total.
    Duplicate,
    /// Should count but cannot be read: not JSON, no time, no token counts. Its time, when known,
    /// and what tells a repeat of it (a later line of the same message is a duplicate of it).
    Lost { at: Option<u64>, key: Key },
    /// Counts at `at`.
    Counted { at: u64, counts: Counts },
    /// Names the model the Codex calls after it ran on (a timed turn context): no count.
    Model { model: String },
}

#[derive(Debug, Clone, PartialEq)]
enum Counts {
    Compaction,
    Spawn,
    Tokens(Tokens),
}

impl Counts {
    /// What tells a repeat of it: only a model call has one.
    fn key(&self) -> Key {
        match self {
            Counts::Tokens(t) => t.key.clone(),
            Counts::Compaction | Counts::Spawn => Key::None,
        }
    }
}

/// One model call's tokens.
#[derive(Debug, Clone, PartialEq)]
struct Tokens {
    /// The model it names (Claude); Codex's comes from its turn context.
    model: Option<String>,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    /// Of `cache_write`, the hour-long writes (billed at twice the input price).
    cache_write_1h: u64,
    /// What the day's count adds.
    total: u64,
    /// The chat's context after the call; None for a subagent's call.
    context: Option<u64>,
    /// The context window the harness reported.
    window: Option<u64>,
    /// What tells a repeat of it.
    key: Key,
}

#[derive(Debug, Clone, PartialEq)]
enum Key {
    Message(String),
    Total(u64),
    None,
}

impl Tokens {
    fn cost(&self, p: &Prices) -> f64 {
        let write_5m = self.cache_write.saturating_sub(self.cache_write_1h);
        (self.input as f64 * p.input
            + self.output as f64 * p.output
            + self.cache_read as f64 * p.cache_read
            + write_5m as f64 * p.cache_write
            + self.cache_write_1h as f64 * p.input * 2.0)
            / 1e6
    }
}

/// The one decision of what a record is to the counts, timed or not, for every parse
/// (`Tracker::take` applies it): first whether it is a kind that counts, then whether it
/// repeats one seen (`tail`'s ids and last total), then whether it can be read (a time, its
/// token counts). So nothing is lost that would have been skipped, and a record seen once,
/// counted or lost, is a duplicate after.
///
/// Outside it, by design, as they work on files, not records: `read_new` marks lost a line
/// longer than a read step (it cannot be parsed); `claude_subagents` counts one spawn per
/// subagent transcript, at its first record's time, else the file's; and the parses'
/// byte pre-filters pass on only lines that name a counted kind as Claude Code and Codex write
/// it, unescaped. A line whose kind is written escaped (`"\u0061ssistant"`) is caught by
/// `escaped_kind` and makes the day unknown, never a count of 0.
fn classify(harness: Harness, line: &[u8], tail: &Tail) -> Class {
    let Ok(record) = serde_json::from_slice::<Value>(line) else {
        // The callers pass only lines that name a kind that counts (`claude_line`, `codex_line`).
        return Class::Lost { at: quick_timestamp(line), key: Key::None };
    };
    let at = timestamp(&record);
    let counted = |counts: Counts| match at {
        Some(at) => Class::Counted { at, counts },
        None => Class::Lost { at: None, key: counts.key() },
    };
    let n = |v: &Value, k: &str| v.get(k).and_then(Value::as_u64);
    match harness {
        Harness::Claude { main } => match field(&record, "type").as_str() {
            Some("system") if field(&record, "subtype") == "compact_boundary" => {
                if main {
                    counted(Counts::Compaction)
                } else {
                    Class::Uncountable
                }
            }
            Some("assistant") => {
                let message = field(&record, "message");
                let model = field(message, "model").as_str().unwrap_or_default();
                let usage = field(message, "usage");
                if model.is_empty() || model.starts_with('<') || !usage.is_object() {
                    return Class::Uncountable;
                }
                let key = field(message, "id")
                    .as_str()
                    .map_or(Key::None, |id| Key::Message(id.to_owned()));
                if let Key::Message(id) = &key
                    && tail.recent.iter().any(|seen| seen == id)
                {
                    return Class::Duplicate;
                }
                // A reply without its token counts cannot be counted: never as 0.
                let (Some(input), Some(output)) =
                    (n(usage, "input_tokens"), n(usage, "output_tokens"))
                else {
                    return Class::Lost { at, key };
                };
                // The API leaves a cache count out when it is 0.
                let read = n(usage, "cache_read_input_tokens").unwrap_or(0);
                let write = n(usage, "cache_creation_input_tokens").unwrap_or(0);
                let write_1h = usage.pointer("/cache_creation/ephemeral_1h_input_tokens");
                let own = main && field(&record, "isSidechain").as_bool() != Some(true);
                counted(Counts::Tokens(Tokens {
                    model: Some(model.to_owned()),
                    input,
                    output,
                    cache_read: read,
                    cache_write: write,
                    cache_write_1h: write_1h.and_then(Value::as_u64).unwrap_or(0).min(write),
                    total: input.saturating_add(output).saturating_add(read).saturating_add(write),
                    context: own.then_some(input.saturating_add(read).saturating_add(write)),
                    window: None,
                    key,
                }))
            }
            _ => Class::Uncountable,
        },
        Harness::Codex => {
            let payload = field(&record, "payload");
            match (field(&record, "type").as_str(), field(payload, "type").as_str()) {
                // Untimed, it cannot say which calls ran after it: as before, it is passed over.
                (Some("turn_context"), _) => match (at, field(payload, "model").as_str()) {
                    (Some(_), Some(model)) => Class::Model { model: model.to_owned() },
                    _ => Class::Uncountable,
                },
                (Some("compacted"), _) => counted(Counts::Compaction),
                (Some("response_item"), Some("function_call" | "custom_tool_call"))
                    if field(payload, "name") == "spawn_agent" =>
                {
                    counted(Counts::Spawn)
                }
                (Some("event_msg"), Some("token_count")) => {
                    let info = field(payload, "info");
                    // A rate-limit update alone carries no info.
                    if info.is_null() {
                        return Class::Uncountable;
                    }
                    let total =
                        info.pointer("/total_token_usage/total_tokens").and_then(Value::as_u64);
                    // Codex repeats its last report with each rate-limit update.
                    if total.is_some() && total == tail.last_total {
                        return Class::Duplicate;
                    }
                    let last = field(info, "last_token_usage");
                    let (Some(total), Some(input), Some(output)) =
                        (total, n(last, "input_tokens"), n(last, "output_tokens"))
                    else {
                        return Class::Lost { at, key: total.map_or(Key::None, Key::Total) };
                    };
                    // OpenAI counts cached input inside input_tokens, and leaves out a 0 cache
                    // count; its total_tokens is input + output. Priced as it says, unclamped.
                    let cached = n(last, "cached_input_tokens").unwrap_or(0);
                    counted(Counts::Tokens(Tokens {
                        model: None,
                        input: input.saturating_sub(cached),
                        output,
                        cache_read: cached,
                        cache_write: 0,
                        cache_write_1h: 0,
                        total: n(last, "total_tokens").unwrap_or(input.saturating_add(output)),
                        context: Some(input),
                        window: n(info, "model_context_window"),
                        key: Key::Total(total),
                    }))
                }
                _ => Class::Uncountable,
            }
        }
    }
}

/// Feeds each complete line appended to `tail.path` since `tail.offset` to `each` (`now` is
/// when, for a line it has to skip), at most
/// `step` bytes a call; a first read starts at most `first` bytes before the end, at the
/// first line that starts there. A file that shrank (rewritten) is read again from its start.
/// Returns whether the read reached the end of the file as it was, at a line's end (false on
/// any error, a backlog left, or a line still being written).
fn read_new(
    tail: &mut Tail,
    (first, step): (u64, u64),
    now: u64,
    mut each: impl FnMut(&[u8], &mut Tail),
) -> bool {
    let Ok(mut file) = std::fs::File::open(&tail.path) else { return false };
    let Ok(len) = file.metadata().map(|m| m.len()) else { return false };
    if len < tail.offset {
        *tail = Tail { path: std::mem::take(&mut tail.path), ..Tail::default() };
    }
    // Bytes to drop through the first newline: the rest of a line the read starts inside.
    let mut skip_to_line = std::mem::take(&mut tail.in_long_line);
    if tail.offset == 0 {
        if len > first {
            // One byte early: a cut that falls on a line start drops only that newline.
            tail.offset = len.saturating_sub(first).saturating_sub(1);
            skip_to_line = true;
        } else {
            tail.covered_from = Some(0);
        }
    }
    if len == tail.offset {
        return true;
    }
    if file.seek(SeekFrom::Start(tail.offset)).is_err() {
        return false;
    }
    // This read reaches the end of the file as it is now; else a backlog stays for the next.
    let left = len.saturating_sub(tail.offset);
    let to_end = left <= step;
    let mut buf = Vec::new();
    if file.take(step.min(left)).read_to_end(&mut buf).is_err() {
        return false;
    }
    let Some(end) = memchr::memrchr(b'\n', &buf) else {
        if !to_end {
            // A line longer than a step: it cannot be read, so the day it falls in is unknown.
            tail.offset = tail.offset.saturating_add(buf.len() as u64);
            tail.in_long_line = true;
            tail.lose(now);
        } else if skip_to_line {
            tail.in_long_line = true;
        }
        // Else a line still being written: read again, whole, next time.
        return false;
    };
    let mut lines = buf.get(..end).unwrap_or_default().split(|b| *b == b'\n');
    if skip_to_line {
        lines.next();
    }
    for line in lines {
        if tail.covered_from.is_none() {
            let record = serde_json::from_slice::<Value>(line).ok();
            tail.covered_from = record.as_ref().and_then(timestamp);
        }
        each(line, tail);
    }
    tail.offset = tail.offset.saturating_add(end as u64).saturating_add(1);
    // Bytes past the last newline: a line still being written, read next time.
    to_end && buf.len().checked_sub(1) == Some(end)
}

/// The chat's transcript: Claude's under its project folder (else any project
/// folder, for a chat whose cwd moved), Codex's rollout under its creation day
/// (else any day).
fn locate(source: &Source) -> Option<PathBuf> {
    let sid = source.agent_session_id.as_str();
    if sid.is_empty() || sid.contains(['/', '\\']) {
        return None;
    }
    let home = source.home()?;
    match source.family.as_str() {
        "claude" => {
            let projects = home.join("projects");
            let name = format!("{sid}.jsonl");
            let direct = projects.join(claude_project_dir(&source.cwd)).join(&name);
            if direct.is_file() {
                return Some(direct);
            }
            let dirs = std::fs::read_dir(&projects).ok()?;
            dirs.flatten().map(|d| d.path().join(&name)).find(|p| p.is_file())
        }
        "codex" => {
            let sessions = home.join("sessions");
            let suffix = format!("-{sid}.jsonl");
            let day = source.created_at / DAY_MS;
            let near = [day.saturating_sub(1), day, day.saturating_add(1)].map(|d| {
                let (y, m, d) = civil_from_days(d);
                sessions.join(format!("{y:04}")).join(format!("{m:02}")).join(format!("{d:02}"))
            });
            let found = |dir: &Path| {
                std::fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).find(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with("rollout-") && n.ends_with(&suffix))
                })
            };
            near.iter().find_map(|d| found(d)).or_else(|| {
                let mut days = Vec::new();
                for y in std::fs::read_dir(&sessions).ok()?.flatten() {
                    for m in std::fs::read_dir(y.path()).into_iter().flatten().flatten() {
                        days.extend(std::fs::read_dir(m.path()).into_iter().flatten().flatten());
                    }
                }
                // Newest day first: a running chat's rollout is a recent one.
                days.sort_by_key(|d| std::cmp::Reverse(d.path()));
                days.iter().find_map(|d| found(&d.path()))
            })
        }
        _ => None,
    }
}

/// Claude Code's project folder name for a cwd: every character other than an
/// ASCII letter or digit becomes `-`.
fn claude_project_dir(cwd: &Path) -> String {
    cwd.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect()
}

/// The executable the harness runs, by file name (`claude`, `claude-sr2`, `codex-acp`).
pub fn launcher(argv: &[String]) -> Option<String> {
    let program = argv.first()?;
    let name = Path::new(program).file_name()?.to_string_lossy().into_owned();
    (!name.is_empty()).then_some(name)
}

/// Whether the harness's autocompact is capped, and at how many tokens when that is known.
/// Claude Code: `--autocompact N`, else `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, else
/// `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` of the window, else `autoCompactWindow` in its
/// settings.json. Codex: `-c model_auto_compact_token_limit=N`, else that key in its
/// config.toml. Unknown when its argv is not this daemon's, or a value or file that would
/// decide it cannot be read; `auto` and an absent setting are no cap.
pub fn autocompact(source: &Source, window: Option<u64>) -> (Autocompact, Option<u64>) {
    let capped =
        |n: Option<u64>| n.map_or((Autocompact::Unknown, None), |n| (Autocompact::Capped, Some(n)));
    let value = |text: &str| match text.trim().trim_matches('"') {
        t if t.eq_ignore_ascii_case("auto") => (Autocompact::Uncapped, None),
        t => capped(tokens(t)),
    };
    let Some(argv) = source.argv.as_deref() else { return (Autocompact::Unknown, None) };
    let env = |k: &str| source.env.get(k).cloned().or_else(|| std::env::var(k).ok());
    // A file the harness reads at start: absent is no setting; unreadable is unknown.
    let read = |name: &str| match source.home().map(|h| std::fs::read(h.join(name))) {
        Some(Ok(bytes)) => Ok(Some(bytes)),
        Some(Err(e)) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        _ => Err(()),
    };
    match source.family.as_str() {
        "claude" => {
            if let Some(v) = flag(argv, "--autocompact") {
                return value(&v);
            }
            if let Some(v) = env("CLAUDE_CODE_AUTO_COMPACT_WINDOW") {
                return value(&v);
            }
            if let Some(pct) = env("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE") {
                return match pct.trim().parse::<f64>().ok().filter(|p| *p > 0.0 && *p < 100.0) {
                    Some(pct) => {
                        (Autocompact::Capped, window.map(|w| whole_tokens(w as f64 * pct / 100.0)))
                    }
                    None => (Autocompact::Unknown, None),
                };
            }
            let Ok(settings) = read("settings.json") else { return (Autocompact::Unknown, None) };
            let Some(settings) = settings else { return (Autocompact::Uncapped, None) };
            let Ok(settings) = serde_json::from_slice::<Value>(&settings) else {
                return (Autocompact::Unknown, None);
            };
            match field(&settings, "autoCompactWindow") {
                Value::Null => (Autocompact::Uncapped, None),
                Value::Number(n) => capped(n.as_u64()),
                Value::String(s) => value(s),
                _ => (Autocompact::Unknown, None),
            }
        }
        "codex" => {
            const KEY: &str = "model_auto_compact_token_limit";
            let from_argv = argv.windows(2).rev().find_map(|w| {
                let [flag, value] = w else { return None };
                let value = (flag == "-c" || flag == "--config").then_some(value)?;
                let (key, value) = value.split_once('=')?;
                (key.trim() == KEY).then(|| value.trim().to_owned())
            });
            if let Some(v) = from_argv {
                return capped(tokens(&v));
            }
            let Ok(config) = read("config.toml") else { return (Autocompact::Unknown, None) };
            let Some(config) = config else { return (Autocompact::Uncapped, None) };
            let Ok(config) = String::from_utf8(config) else { return (Autocompact::Unknown, None) };
            // Top-level keys only: the first `[table]` ends them.
            let set =
                config.lines().take_while(|l| !l.trim_start().starts_with('[')).find_map(|l| {
                    let (key, value) = l.split_once('=')?;
                    (key.trim() == KEY).then(|| value.split('#').next().unwrap_or("").to_owned())
                });
            set.map_or((Autocompact::Uncapped, None), |v| capped(tokens(&v)))
        }
        _ => (Autocompact::Unknown, None),
    }
}

/// The value of `--name V` or `--name=V`, the last one given.
fn flag(argv: &[String], name: &str) -> Option<String> {
    let mut found = None;
    for (i, arg) in argv.iter().enumerate() {
        if arg == name {
            found = argv.get(i.saturating_add(1)).cloned();
        } else if let Some(v) = arg.strip_prefix(name).and_then(|r| r.strip_prefix('=')) {
            found = Some(v.to_owned());
        }
    }
    found
}

/// A token count as the harnesses take one: `200000`, `200k`, `1M`, `1_000_000`; `auto` and
/// anything else is None.
fn tokens(text: &str) -> Option<u64> {
    let t = text.trim().trim_matches('"').replace('_', "").to_ascii_lowercase();
    let (digits, scale) = match t.strip_suffix('k') {
        Some(d) => (d, 1_000.0),
        None => t.strip_suffix('m').map_or((t.as_str(), 1.0), |d| (d, 1_000_000.0)),
    };
    let n = digits.trim().parse::<f64>().ok().filter(|n| n.is_finite() && *n > 0.0)?;
    Some(whole_tokens(n * scale))
}

/// A token count from a computed one: its whole part, saturating at the ends.
#[allow(
    clippy::cast_possible_truncation,
    reason = "f64 to u64 `as` drops the fraction and saturates; a token count wants just that"
)]
fn whole_tokens(n: f64) -> u64 {
    n as u64
}

/// A record's `"timestamp":"…"` found without parsing the line: Claude Code writes it on
/// every line, after the message, so the last one is the record's own.
fn quick_timestamp(line: &[u8]) -> Option<u64> {
    const KEY: &[u8] = b"\"timestamp\":\"";
    let rest = line.get(memchr::memmem::rfind(line, KEY)?..)?.strip_prefix(KEY)?;
    let len = memchr::memchr(b'"', rest)?;
    crate::server::machine_health::rfc3339_ms(std::str::from_utf8(rest.get(..len)?).ok()?)
}

/// A Claude reply's message id found without parsing the line (`"id":"msg_…"`, as the API
/// names them); None when the line names none.
fn quick_message_id(line: &[u8]) -> Option<String> {
    const KEY: &[u8] = b"\"id\":\"msg_";
    // From `msg_`, the id's own start.
    let rest = line.get(memchr::memmem::find(line, KEY)?..)?.strip_prefix(b"\"id\":\"")?;
    let len = memchr::memchr(b'"', rest)?;
    String::from_utf8(rest.get(..len)?.to_vec()).ok()
}

/// A record's field, `Null` when it has none: `record[key]` without the index (the panic ratchet).
fn field<'a>(record: &'a Value, key: &str) -> &'a Value {
    const NULL: &Value = &Value::Null;
    record.get(key).unwrap_or(NULL)
}

/// A line the parse's byte pre-filter passed over that is a counted kind written escaped
/// (`"\u0061ssistant"`; Claude Code and Codex never write one): the day it falls in is lost
/// (unknown), never a count of 0. Only a line with an escape, within the day, is parsed.
fn escaped_kind(harness: Harness, line: &[u8], tail: &mut Tail, now: u64) {
    let at = quick_timestamp(line);
    if !contains(line, b"\\u") || at.is_some_and(|at| at.saturating_add(DAY_MS) <= now) {
        return;
    }
    let Ok(record) = serde_json::from_slice::<Value>(line) else { return };
    let (kind, payload) =
        (field(&record, "type").as_str().unwrap_or_default(), field(&record, "payload"));
    let counted = match harness {
        Harness::Claude { main } => {
            kind == "assistant"
                || main && kind == "system" && field(&record, "subtype") == "compact_boundary"
        }
        Harness::Codex => {
            kind == "compacted"
                || kind == "event_msg" && field(payload, "type") == "token_count"
                || kind == "response_item" && field(payload, "name") == "spawn_agent"
        }
    };
    if counted {
        tail.lose(timestamp(&record).unwrap_or(now));
    }
}

fn timestamp(record: &Value) -> Option<u64> {
    record
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(crate::server::machine_health::rfc3339_ms)
}

fn modified_ms(path: &Path) -> Option<u64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    let since = modified.duration_since(std::time::UNIX_EPOCH).ok()?;
    u64::try_from(since.as_millis()).ok()
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    memchr::memmem::find(hay, needle).is_some()
}

/// The proleptic Gregorian date of a day count since 1970-01-01.
fn civil_from_days(days: u64) -> (i64, u32, u32) {
    // A day of a unix-ms time (at most ~2.1e11) always fits an i64.
    crate::server::civil_from_days(i64::try_from(days).unwrap_or(i64::MAX))
}

#[cfg(test)]
#[path = "usage_stats_tests.rs"]
mod tests;
