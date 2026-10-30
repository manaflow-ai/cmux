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
//! [`FIRST_READ_BYTES`]. Lines that cannot carry usage are skipped before they are
//! parsed. Spend is kept in minute buckets for the last day, so the 24-hour and
//! one-hour sums need no rescan. Cost is the model catalog's list price for the
//! tokens (USD per million), null when no model of the window has a price.

use crate::protocol::session::UsageStats;
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
            let info = &catalog.models[key];
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
    /// The argv its harness last started with.
    pub argv: Vec<String>,
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
}

impl Tracker {
    /// Reads what the chat's harness appended since the last refresh and returns the stats as of `now`.
    pub fn refresh(&mut self, source: &Source, now: u64, models: &Models) -> UsageStats {
        if self.main.is_none() && now >= self.look_again_at {
            match locate(source) {
                Some(path) => self.main = Some(Tail { path, ..Tail::default() }),
                None => self.look_again_at = now + LOOK_AGAIN_MS,
            }
        }
        let codex = source.family == "codex";
        if let Some(mut tail) = self.main.take() {
            read_new(&mut tail, |line, tail| {
                if codex {
                    self.codex_line(line, tail, now, models);
                } else {
                    self.claude_line(line, tail, now, true, models);
                }
            });
            if !codex {
                self.settle_context(&mut tail, now, models);
                self.claude_subagents(&tail.path, &source.agent_session_id, now, models);
            }
            self.main = Some(tail);
        }
        let cutoff = now.saturating_sub(DAY_MS);
        self.minutes = self.minutes.split_off(&(cutoff - cutoff % MINUTE_MS));
        let window =
            self.context_window.or_else(|| self.model.as_deref().and_then(|m| models.window(m)));
        self.stats(source, now, window)
    }

    fn stats(&self, source: &Source, now: u64, window: Option<u64>) -> UsageStats {
        let (mut day, mut hour_spawns, mut priced) = (Bucket::default(), 0, false);
        for (minute, b) in &self.minutes {
            day.tokens += b.tokens;
            day.cost_usd += b.cost_usd;
            day.compactions += b.compactions;
            day.spawns += b.spawns;
            priced |= b.priced;
            if minute + MINUTE_MS > now.saturating_sub(HOUR_MS) {
                hour_spawns += b.spawns;
            }
        }
        UsageStats {
            launcher: launcher(&source.argv),
            autocompact_cap: autocompact_cap(source, window),
            context_tokens: self.context_tokens,
            context_window: window,
            compactions24h: day.compactions,
            subagents_live: self.subagents.values().filter(|s| s.live).count() as u64,
            subagents1h: hour_spawns,
            subagents24h: day.spawns,
            tokens24h: day.tokens,
            // Rounded to the cent's hundredth: a sum of list prices, not a bill.
            cost_usd24h: priced.then(|| (day.cost_usd * 10_000.0).round() / 10_000.0),
            updated_at: now,
        }
    }

    fn bucket(&mut self, at: u64, now: u64) -> Option<&mut Bucket> {
        (at + DAY_MS > now).then(|| self.minutes.entry(at - at % MINUTE_MS).or_default())
    }

    fn claude_line(&mut self, line: &[u8], tail: &mut Tail, now: u64, main: bool, models: &Models) {
        if !(contains(line, b"\"assistant\"") || main && contains(line, b"compact_boundary")) {
            return;
        }
        // A line older than the window counts for nothing but, if it is the newest call, the
        // context: kept unparsed until the read ends (`settle_context`), as most of a long
        // chat's lines are, so its first read parses only the last day.
        if let Some(at) = quick_timestamp(line).filter(|at| at + DAY_MS <= now) {
            // What `parse_claude_line` takes as a call: a main-loop assistant line with usage and
            // a real model (an API error Claude Code makes up names `<synthetic>`).
            let call = contains(line, b"\"type\":\"assistant\"")
                && contains(line, b"\"input_tokens\"")
                && !contains(line, b"\"model\":\"<")
                && !contains(line, b"\"isSidechain\":true");
            if main && call && at >= self.context_at {
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
            self.parse_claude_line(&line, tail, now, true, models);
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
        let Ok(record) = serde_json::from_slice::<Value>(line) else { return };
        let at = timestamp(&record).unwrap_or(now);
        match record.get("type").and_then(Value::as_str) {
            Some("system") if main && record["subtype"] == "compact_boundary" => {
                if let Some(b) = self.bucket(at, now) {
                    b.compactions += 1;
                }
            }
            Some("assistant") => {
                let message = &record["message"];
                let model = message["model"].as_str().unwrap_or_default();
                let usage = &message["usage"];
                if model.is_empty() || model.starts_with('<') || !usage.is_object() {
                    return;
                }
                if let Some(id) = message["id"].as_str() {
                    if tail.recent.iter().any(|seen| seen == id) {
                        return;
                    }
                    if tail.recent.len() == RECENT_IDS {
                        tail.recent.pop_front();
                    }
                    tail.recent.push_back(id.to_owned());
                }
                let n = |k: &str| usage[k].as_u64().unwrap_or(0);
                let (input, output) = (n("input_tokens"), n("output_tokens"));
                let (read, write) =
                    (n("cache_read_input_tokens"), n("cache_creation_input_tokens"));
                // An hour's cache write is billed at twice the input price, five minutes' at the catalog's.
                let write_1h = usage.pointer("/cache_creation/ephemeral_1h_input_tokens");
                let write_1h = write_1h.and_then(Value::as_u64).unwrap_or(0).min(write);
                let cost = models.prices(model).map(|p| {
                    (input as f64 * p.input
                        + output as f64 * p.output
                        + read as f64 * p.cache_read
                        + (write - write_1h) as f64 * p.cache_write
                        + write_1h as f64 * p.input * 2.0)
                        / 1e6
                });
                if main && record["isSidechain"] != Value::Bool(true) && at >= self.context_at {
                    self.model = Some(model.to_owned());
                    self.context_tokens = Some(input + read + write);
                    self.context_at = at;
                }
                if let Some(b) = self.bucket(at, now) {
                    b.tokens += input + output + read + write;
                    if let Some(cost) = cost {
                        b.cost_usd += cost;
                        b.priced = true;
                    }
                }
            }
            _ => {}
        }
    }

    fn codex_line(&mut self, line: &[u8], tail: &mut Tail, now: u64, models: &Models) {
        let wanted = [&b"token_count"[..], b"\"compacted\"", b"spawn_agent", b"turn_context"];
        if !wanted.iter().any(|w| contains(line, w)) {
            return;
        }
        let Ok(record) = serde_json::from_slice::<Value>(line) else { return };
        let at = timestamp(&record).unwrap_or(now);
        let payload = &record["payload"];
        match (record["type"].as_str(), payload["type"].as_str()) {
            (Some("turn_context"), _) => {
                if let Some(model) = payload["model"].as_str() {
                    self.model = Some(model.to_owned());
                }
            }
            (Some("compacted"), _) => {
                if let Some(b) = self.bucket(at, now) {
                    b.compactions += 1;
                }
            }
            (Some("response_item"), Some("function_call" | "custom_tool_call"))
                if payload["name"] == "spawn_agent" =>
            {
                if let Some(b) = self.bucket(at, now) {
                    b.spawns += 1;
                }
            }
            (Some("event_msg"), Some("token_count")) => {
                let info = &payload["info"];
                let total = info.pointer("/total_token_usage/total_tokens").and_then(Value::as_u64);
                if total.is_none() || total == tail.last_total {
                    return;
                }
                tail.last_total = total;
                if let Some(window) = info["model_context_window"].as_u64() {
                    self.context_window = Some(window);
                }
                let last = &info["last_token_usage"];
                let n = |k: &str| last[k].as_u64().unwrap_or(0);
                // OpenAI counts cached input inside input_tokens.
                let (input, cached, output) =
                    (n("input_tokens"), n("cached_input_tokens"), n("output_tokens"));
                if at >= self.context_at {
                    self.context_tokens = Some(input);
                    self.context_at = at;
                }
                let model = self.model.clone().unwrap_or_default();
                let cost = models.prices(&model).map(|p| {
                    (input.saturating_sub(cached) as f64 * p.input
                        + cached as f64 * p.cache_read
                        + output as f64 * p.output)
                        / 1e6
                });
                let tokens = last["total_tokens"].as_u64().unwrap_or(input + output);
                if let Some(b) = self.bucket(at, now) {
                    b.tokens += tokens;
                    if let Some(cost) = cost {
                        b.cost_usd += cost;
                        b.priced = true;
                    }
                }
            }
            _ => {}
        }
    }

    /// Claude Code's subagents: one transcript per spawn beside the chat's
    /// (`<sid>/subagents/agent-*.jsonl`); its spend is the chat's too.
    fn claude_subagents(&mut self, main: &Path, sid: &str, now: u64, models: &Models) {
        let Some(dir) = main.parent().map(|d| d.join(sid).join("subagents")) else { return };
        let Ok(entries) = std::fs::read_dir(&dir) else { return };
        for entry in entries.flatten() {
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
                .is_some_and(|meta| meta["finished"] == Value::Bool(true));
            if agent.tail.path.as_os_str().is_empty() {
                agent.tail.path = path.clone();
                // Older than the window: nothing in it counts; never read.
                if modified + DAY_MS <= now {
                    agent.done = true;
                    self.subagents.insert(path, agent);
                    continue;
                }
            }
            let mut tail = std::mem::take(&mut agent.tail);
            let mut first = None;
            read_new(&mut tail, |line, tail| {
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
                    b.spawns += 1;
                }
            }
            let read_all = std::fs::metadata(&path).is_ok_and(|m| m.len() <= tail.offset);
            agent.tail = tail;
            agent.live = !finished && modified + LIVE_QUIET_MS > now;
            agent.done = finished && read_all;
            self.subagents.insert(path, agent);
        }
    }
}

/// Feeds each complete line appended to `tail.path` since `tail.offset` to `each`, at most
/// [`READ_STEP_BYTES`] a call; a first read starts at most [`FIRST_READ_BYTES`] before the end,
/// at a line start. A file that shrank (rewritten) is read again from its start.
fn read_new(tail: &mut Tail, mut each: impl FnMut(&[u8], &mut Tail)) {
    let Ok(mut file) = std::fs::File::open(&tail.path) else { return };
    let Ok(len) = file.metadata().map(|m| m.len()) else { return };
    if len < tail.offset {
        tail.offset = 0;
        tail.recent.clear();
        tail.last_total = None;
    }
    let mut skip_partial = false;
    if tail.offset == 0 && len > FIRST_READ_BYTES {
        tail.offset = len - FIRST_READ_BYTES;
        skip_partial = true;
    }
    if len == tail.offset || file.seek(SeekFrom::Start(tail.offset)).is_err() {
        return;
    }
    let mut buf = Vec::new();
    if file.take(READ_STEP_BYTES.min(len - tail.offset)).read_to_end(&mut buf).is_err() {
        return;
    }
    let Some(end) = memchr::memrchr(b'\n', &buf) else { return };
    let mut lines = buf[..end].split(|b| *b == b'\n');
    if skip_partial {
        lines.next();
    }
    for line in lines {
        each(line, tail);
    }
    tail.offset += end as u64 + 1;
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
            let near = [day.saturating_sub(1), day, day + 1].map(|d| {
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

/// The context size at which the harness compacts, when something caps it; None when
/// nothing does (the harness's own default). Claude Code: `--autocompact N`, else
/// `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, else `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` of the window,
/// else `autoCompactWindow` in its settings.json. Codex: `-c model_auto_compact_token_limit=N`,
/// else that key in its config.toml.
pub fn autocompact_cap(source: &Source, window: Option<u64>) -> Option<u64> {
    let argv = &source.argv;
    let env = |k: &str| source.env.get(k).cloned().or_else(|| std::env::var(k).ok());
    match source.family.as_str() {
        "claude" => {
            if let Some(value) = flag(argv, "--autocompact") {
                return tokens(&value);
            }
            if let Some(value) = env("CLAUDE_CODE_AUTO_COMPACT_WINDOW") {
                return tokens(&value);
            }
            if let Some(pct) = env("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE")
                .and_then(|p| p.trim().parse::<f64>().ok())
                .filter(|p| *p > 0.0 && *p < 100.0)
            {
                return window.map(|w| (w as f64 * pct / 100.0) as u64);
            }
            let settings = std::fs::read(source.home()?.join("settings.json")).ok()?;
            match &serde_json::from_slice::<Value>(&settings).ok()?["autoCompactWindow"] {
                Value::Number(n) => n.as_u64(),
                Value::String(s) => tokens(s),
                _ => None,
            }
        }
        "codex" => {
            const KEY: &str = "model_auto_compact_token_limit";
            let from_argv = argv.windows(2).rev().find_map(|w| {
                let value = (w[0] == "-c" || w[0] == "--config").then_some(&w[1])?;
                let (key, value) = value.split_once('=')?;
                (key.trim() == KEY).then(|| value.trim().to_owned())
            });
            if let Some(value) = from_argv {
                return tokens(&value);
            }
            let config = std::fs::read_to_string(source.home()?.join("config.toml")).ok()?;
            // Top-level keys only: the first `[table]` ends them.
            config.lines().take_while(|l| !l.trim_start().starts_with('[')).find_map(|l| {
                let (key, value) = l.split_once('=')?;
                (key.trim() == KEY).then(|| tokens(value.split('#').next()?)).flatten()
            })
        }
        _ => None,
    }
}

/// The value of `--name V` or `--name=V`, the last one given.
fn flag(argv: &[String], name: &str) -> Option<String> {
    let mut found = None;
    for (i, arg) in argv.iter().enumerate() {
        if arg == name {
            found = argv.get(i + 1).cloned();
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
    Some((n * scale) as u64)
}

/// A record's `"timestamp":"…"` found without parsing the line: Claude Code writes it on
/// every line, after the message, so the last one is the record's own.
fn quick_timestamp(line: &[u8]) -> Option<u64> {
    const KEY: &[u8] = b"\"timestamp\":\"";
    let start = memchr::memmem::rfind(line, KEY)? + KEY.len();
    let len = memchr::memchr(b'"', &line[start..])?;
    crate::server::machine_health::rfc3339_ms(std::str::from_utf8(&line[start..start + len]).ok()?)
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

/// The proleptic Gregorian date of a day count since 1970-01-01 (Howard Hinnant's algorithm).
fn civil_from_days(days: u64) -> (i64, u32, u32) {
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

#[cfg(test)]
#[path = "usage_stats_tests.rs"]
mod tests;
