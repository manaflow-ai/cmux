//! Efficiency insights on the person's own machine: why each cache-write token was paid, and
//! what would have avoided it (`cmux usage insights`, the MCP tool `usage_insights`).
//!
//! Leo, 2026-11-25: "there are likely actually good tools for analysis and tracking we can have
//! as opt-in for stuff to have people like... have apis to analyze their own stuff,
//! potentially...? hm.! as an upsell/value-add? to analyze stuff. eng leaders would love stuff
//! like this..." The design is cmuxterm-hq `docs/design/usage-efficiency-insights.md`: insights are
//! computed locally from the person's own records, so nothing is uploaded and no opt-in is needed;
//! a team rollup is a later, opt-in kind of the existing usage pipeline.
//!
//! This is the first insight, cache waste by cause, a port of the fleet meter that found 45% of
//! cache writes avoidable (leo-workspace `tools/cache_write_sources.py`). It reads Claude Code
//! transcripts (`<CLAUDE_CONFIG_DIR or ~/.claude>/projects/**/*.jsonl`, subagents included) and is
//! content-blind: of each line it reads only the type, time, model, usage numbers, the request's
//! cache lifetime, the prompt shape hash and compaction markers; a line with none of those words
//! is never parsed.
//!
//! The model. A request's context is input + cache read + cache write; its prefix up to the
//! previous request's context should be a cache read. Each request's write splits in two:
//! - append: what the request added since the previous one (the floor: every token of context is
//!   written once);
//! - rewrite: the part of the previous context not read back, paid again. Its cause is the first
//!   that holds: compaction, idle wake (a gap past the cache lifetime), model switch, shape change
//!   (system prompt or tool list), lost under ttl (over five minutes, nothing changed, the cache
//!   gone anyway), else prefix edit (something early in the prompt changed).
//!
//! A first request is its own cause: session start, or helper start for a subagent. The avoidable
//! cost of a rewrite is priced at write minus read, what a warm cache would have charged.

use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::BufRead;
use std::path::{Path, PathBuf};

/// Tokens of slack before a short cache read counts as a rewrite (cache block rounding).
pub const TOLERANCE: u64 = 1024;
/// A warm cache that misses after a gap this long, with the same prefix, is "lost under ttl".
pub const LOST_AFTER_MS: u64 = 5 * 60_000;
const FIVE_MIN_MS: u64 = 5 * 60_000;
const HOUR_MS: u64 = 60 * 60_000;
/// The longest window one report reads.
pub const MAX_HOURS: u64 = 24 * 30;
/// The sessions a report names, most avoidable first.
const TOP_SESSIONS: usize = 10;

/// Why a cache-write token was paid.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Cause {
    #[default]
    Append,
    SessionStart,
    HelperStart,
    IdleWake,
    Compaction,
    ModelSwitch,
    ShapeChange,
    LostUnderTtl,
    PrefixEdit,
}

impl Cause {
    pub const ALL: [Cause; 9] = [
        Cause::Append,
        Cause::SessionStart,
        Cause::HelperStart,
        Cause::IdleWake,
        Cause::Compaction,
        Cause::ModelSwitch,
        Cause::ShapeChange,
        Cause::LostUnderTtl,
        Cause::PrefixEdit,
    ];

    pub fn key(self) -> &'static str {
        match self {
            Cause::Append => "append",
            Cause::SessionStart => "session_start",
            Cause::HelperStart => "helper_start",
            Cause::IdleWake => "idle_wake",
            Cause::Compaction => "compaction",
            Cause::ModelSwitch => "model_switch",
            Cause::ShapeChange => "shape_change",
            Cause::LostUnderTtl => "lost_under_ttl",
            Cause::PrefixEdit => "prefix_edit",
        }
    }

    /// A rewrite a warm cache would have read instead. Append is the floor; a first request
    /// writes what it must (a forked helper reads its parent's cache, but that is not avoidable
    /// within one transcript).
    pub fn avoidable(self) -> bool {
        !matches!(self, Cause::Append | Cause::SessionStart | Cause::HelperStart)
    }

    /// What would have avoided it.
    pub fn fix(self) -> &'static str {
        match self {
            Cause::Append => "none: the floor, every token of context is written once",
            Cause::SessionStart => {
                "keep long-lived chats instead of starting new ones for related work"
            }
            Cause::HelperStart => "fork helpers from the parent so they read its cache",
            Cause::IdleWake => {
                "come back within the cache lifetime, ask for the 1 h cache, or start fresh after a long break instead of resuming a large context"
            }
            Cause::Compaction => {
                "compact earlier (a lower autocompact threshold), so each compaction rewrites less"
            }
            Cause::ModelSwitch => "stay on one model per chat; each model has its own cache",
            Cause::ShapeChange => {
                "load tools and MCP servers at the start; a changed tool list or system prompt rewrites everything"
            }
            Cause::LostUnderTtl => {
                "the cache was evicted inside its lifetime: keep one account per chat (a router or a pool of accounts moves it)"
            }
            Cause::PrefixEdit => {
                "stop writing into the prompt's start: hooks and reminders that change early context rewrite all after it"
            }
        }
    }
}

/// One model request of a transcript, content-blind.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Request {
    pub at_ms: u64,
    pub input: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    /// The request wrote (some of) its cache at the hour-long lifetime.
    pub hour_cache: bool,
    pub model: String,
    /// A hash of the system prompt and tool list, where the harness records one.
    pub shape: Option<String>,
    /// A compaction happened since the previous request.
    pub compacted: bool,
}

impl Request {
    fn context(&self) -> u64 {
        self.input.saturating_add(self.cache_read).saturating_add(self.cache_write)
    }

    fn lifetime_ms(&self) -> u64 {
        if self.hour_cache { HOUR_MS } else { FIVE_MIN_MS }
    }
}

/// Words a line must hold to be parsed at all; the rest are skipped unread.
fn worth_parsing(line: &[u8]) -> bool {
    let has = |needle: &[u8]| line.windows(needle.len()).any(|window| window == needle);
    has(b"\"usage\"") || has(b"compact") || has(b"shapeHash")
}

/// The requests of one Claude Code transcript, in order, each once (a streamed message repeats
/// its usage over several lines).
pub fn parse_transcript(reader: impl BufRead) -> Vec<Request> {
    let mut requests: Vec<Request> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut shape: Option<String> = None;
    let mut compacted = false;
    for line in reader.split(b'\n') {
        let Ok(line) = line else { break };
        if !worth_parsing(&line) {
            continue;
        }
        let Ok(record) = serde_json::from_slice::<Value>(&line) else { continue };
        let kind = record.get("type").and_then(Value::as_str).unwrap_or_default();
        if matches!(kind, "api-request" | "api-request-shape") {
            if let Some(hash) = record.get("shapeHash").and_then(Value::as_str) {
                shape = Some(hash.to_owned());
            }
            continue;
        }
        if (kind == "system"
            && record.get("subtype").and_then(Value::as_str) == Some("compact_boundary"))
            || record.get("isCompactSummary").and_then(Value::as_bool) == Some(true)
        {
            compacted = true;
            continue;
        }
        if kind != "assistant" {
            continue;
        }
        let Some(message) = record.get("message") else { continue };
        let Some(usage) = message.get("usage") else { continue };
        let model = message.get("model").and_then(Value::as_str).unwrap_or_default();
        if !model.starts_with("claude") {
            continue;
        }
        let Some(at_ms) =
            record.get("timestamp").and_then(Value::as_str).and_then(crate::clock_text::rfc3339_ms)
        else {
            continue;
        };
        let key = record
            .get("requestId")
            .and_then(Value::as_str)
            .or_else(|| message.get("id").and_then(Value::as_str))
            .map(str::to_owned);
        if let Some(key) = &key
            && index.contains_key(key)
        {
            continue;
        }
        let count = |name: &str| usage.get(name).and_then(Value::as_u64).unwrap_or(0);
        let hour_written = usage
            .get("cache_creation")
            .and_then(|tiers| tiers.get("ephemeral_1h_input_tokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let hour_asked = record.get("promptCacheRequested").and_then(Value::as_str) == Some("1h");
        let request = Request {
            at_ms,
            input: count("input_tokens"),
            cache_read: count("cache_read_input_tokens"),
            cache_write: count("cache_creation_input_tokens"),
            hour_cache: hour_written > 0 || hour_asked,
            model: model.to_owned(),
            shape: shape.clone(),
            compacted,
        };
        compacted = false;
        if let Some(key) = key {
            index.insert(key, requests.len());
        }
        requests.push(request);
    }
    requests
}

/// Each request's cache write split by cause: `(request index, cause, tokens)`, zero-token
/// parts left out.
pub fn classify(requests: &[Request], helper: bool) -> Vec<(usize, Cause, u64)> {
    let mut out = Vec::new();
    let mut previous: Option<&Request> = None;
    for (at, request) in requests.iter().enumerate() {
        let Some(prev) = previous else {
            let first = if helper { Cause::HelperStart } else { Cause::SessionStart };
            if request.cache_write > 0 {
                out.push((at, first, request.cache_write));
            }
            previous = Some(request);
            continue;
        };
        let mut lost = prev.context().saturating_sub(request.cache_read).min(request.cache_write);
        if lost <= TOLERANCE {
            lost = 0;
        }
        if lost > 0 {
            let gap = request.at_ms.saturating_sub(prev.at_ms);
            let cause = if request.compacted {
                Cause::Compaction
            } else if gap > prev.lifetime_ms() {
                Cause::IdleWake
            } else if request.model != prev.model {
                Cause::ModelSwitch
            } else if request.shape.is_some() && prev.shape.is_some() && request.shape != prev.shape
            {
                Cause::ShapeChange
            } else if gap > LOST_AFTER_MS {
                Cause::LostUnderTtl
            } else {
                Cause::PrefixEdit
            };
            out.push((at, cause, lost));
        }
        let append = request.cache_write - lost;
        if append > 0 {
            out.push((at, Cause::Append, append));
        }
        previous = Some(request);
    }
    out
}

/// USD per million tokens of one request: (write at its lifetime, read).
fn rates(model: &str, hour_cache: bool) -> Option<(f64, f64)> {
    let (_, price) = crate::pricing::table().lookup(model)?;
    let write = if hour_cache { price.cache_write_1h_rate() } else { price.cache_write? };
    Some((write, price.cache_read.unwrap_or(price.input)))
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CauseRow {
    pub cause: Cause,
    pub tokens: u64,
    /// Requests that paid some of this cause.
    pub events: u64,
    /// The tokens' write cost at list price.
    pub cost_usd: f64,
    /// What a warm cache would have saved: write minus read, avoidable causes only.
    pub avoidable_usd: f64,
    pub avoidable: bool,
    pub fix: &'static str,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    /// The transcript's id (the Claude session id, or `agent-…` for a helper).
    pub session_id: String,
    pub helper: bool,
    pub cache_write_tokens: u64,
    pub avoidable_tokens: u64,
    pub avoidable_usd: f64,
    /// The avoidable cause with the most tokens: the first thing to fix there.
    pub top_cause: Option<Cause>,
}

/// The cache-waste insight over a window.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheWaste {
    pub insight: &'static str,
    pub since_ms: u64,
    pub until_ms: u64,
    pub transcripts: u64,
    pub requests: u64,
    pub cache_write_tokens: u64,
    /// The writes the work needed (append) and the first requests.
    pub floor_tokens: u64,
    pub avoidable_tokens: u64,
    /// Avoidable over all cache-write tokens, to four places; None with no writes.
    pub avoidable_share: Option<f64>,
    pub cache_write_usd: f64,
    pub avoidable_usd: f64,
    /// Models no price table entry covers: their tokens count, their cost does not.
    pub unpriced_models: Vec<String>,
    /// Every cause with tokens, most tokens first.
    pub causes: Vec<CauseRow>,
    pub top_sessions: Vec<SessionRow>,
    /// The fix of the largest avoidable cause.
    pub headline: Option<String>,
}

/// Folds transcripts into the report. Each item is `(transcript id, is a helper, requests)`; only
/// requests at or after `since_ms` and before `until_ms` count, though earlier ones still set
/// what the next one should have read.
pub fn report<'a>(
    transcripts: impl IntoIterator<Item = (String, bool, &'a [Request])>,
    since_ms: u64,
    until_ms: u64,
) -> CacheWaste {
    let mut out = CacheWaste { insight: "cache_waste", since_ms, until_ms, ..Default::default() };
    let mut causes: BTreeMap<Cause, CauseRow> = BTreeMap::new();
    let mut unpriced: HashSet<String> = HashSet::new();
    let mut sessions = Vec::new();
    for (id, helper, requests) in transcripts {
        let inside = |at: usize| {
            requests.get(at).is_some_and(|request| (since_ms..until_ms).contains(&request.at_ms))
        };
        let mut session = SessionRow { session_id: id, helper, ..Default::default() };
        let mut by_cause: BTreeMap<Cause, u64> = BTreeMap::new();
        let mut counted = HashSet::new();
        for (at, cause, tokens) in classify(requests, helper) {
            let Some(request) = requests.get(at).filter(|_| inside(at)) else {
                continue;
            };
            counted.insert(at);
            let row = causes.entry(cause).or_insert_with(|| CauseRow {
                cause,
                avoidable: cause.avoidable(),
                fix: cause.fix(),
                ..Default::default()
            });
            row.tokens += tokens;
            row.events += 1;
            session.cache_write_tokens += tokens;
            out.cache_write_tokens += tokens;
            let priced = rates(&request.model, request.hour_cache);
            if priced.is_none() {
                unpriced.insert(request.model.clone());
            }
            let (write, read) = priced.unwrap_or((0.0, 0.0));
            let cost = tokens as f64 * write / 1e6;
            row.cost_usd += cost;
            out.cache_write_usd += cost;
            if cause.avoidable() {
                let saved = tokens as f64 * (write - read).max(0.0) / 1e6;
                row.avoidable_usd += saved;
                out.avoidable_usd += saved;
                out.avoidable_tokens += tokens;
                session.avoidable_tokens += tokens;
                session.avoidable_usd += saved;
                *by_cause.entry(cause).or_default() += tokens;
            } else {
                out.floor_tokens += tokens;
            }
        }
        let requests_inside = (0..requests.len()).filter(|at| inside(*at)).count() as u64;
        out.requests += requests_inside;
        if requests_inside > 0 || !counted.is_empty() {
            out.transcripts += 1;
        }
        session.top_cause =
            by_cause.into_iter().max_by_key(|(cause, tokens)| (*tokens, *cause)).map(|(c, _)| c);
        if session.avoidable_tokens > 0 {
            sessions.push(session);
        }
    }
    out.avoidable_share = (out.cache_write_tokens > 0).then(|| {
        (out.avoidable_tokens as f64 / out.cache_write_tokens as f64 * 10_000.0).round() / 10_000.0
    });
    let mut rows: Vec<CauseRow> = causes.into_values().collect();
    rows.sort_by(|a, b| b.tokens.cmp(&a.tokens).then(a.cause.cmp(&b.cause)));
    for row in &mut rows {
        row.cost_usd = cents(row.cost_usd);
        row.avoidable_usd = cents(row.avoidable_usd);
    }
    out.headline = rows.iter().find(|row| row.avoidable).map(|row| {
        format!(
            "{} rewrote {} tokens ({:.0}% of cache writes): {}",
            row.cause.key(),
            row.tokens,
            row.tokens as f64 * 100.0 / out.cache_write_tokens.max(1) as f64,
            row.fix
        )
    });
    out.causes = rows;
    sessions.sort_by(|a, b| {
        b.avoidable_tokens.cmp(&a.avoidable_tokens).then(a.session_id.cmp(&b.session_id))
    });
    sessions.truncate(TOP_SESSIONS);
    for session in &mut sessions {
        session.avoidable_usd = cents(session.avoidable_usd);
    }
    out.top_sessions = sessions;
    out.cache_write_usd = cents(out.cache_write_usd);
    out.avoidable_usd = cents(out.avoidable_usd);
    let mut unpriced: Vec<String> = unpriced.into_iter().collect();
    unpriced.sort();
    out.unpriced_models = unpriced;
    out
}

fn cents(usd: f64) -> f64 {
    (usd * 100.0).round() / 100.0
}

/// Where Claude Code keeps transcripts on this machine: `CLAUDE_CONFIG_DIR` when set, else
/// `~/.claude`, and every `~/.claude-*` profile beside it.
pub fn claude_homes() -> Vec<PathBuf> {
    let mut homes = Vec::new();
    if let Some(dir) = std::env::var_os("CLAUDE_CONFIG_DIR").filter(|dir| !dir.is_empty()) {
        homes.push(PathBuf::from(dir));
    }
    if let Some(home) = dirs::home_dir() {
        homes.push(home.join(".claude"));
        if let Ok(entries) = std::fs::read_dir(&home) {
            let mut profiles: Vec<PathBuf> = entries
                .flatten()
                .filter(|entry| entry.file_name().to_string_lossy().starts_with(".claude-"))
                .map(|entry| entry.path())
                .filter(|path| path.join("projects").is_dir())
                .collect();
            profiles.sort();
            homes.extend(profiles);
        }
    }
    let mut seen = HashSet::new();
    homes.retain(|home| seen.insert(std::fs::canonicalize(home).unwrap_or_else(|_| home.clone())));
    homes
}

/// The transcripts under `homes` written at or after `since_ms`: `(path, is a helper)`.
/// A project's transcripts are `projects/<project>/<session>.jsonl`, its helpers'
/// `projects/<project>/<session>/subagents/agent-*.jsonl`.
pub fn transcripts(homes: &[PathBuf], since_ms: u64) -> Vec<(PathBuf, bool)> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let fresh = |path: &Path| {
        std::fs::metadata(path)
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
            .is_some_and(|at| at.as_millis() as u64 >= since_ms)
    };
    let jsonl = |path: &Path| path.extension().is_some_and(|ext| ext == "jsonl");
    let mut push = |path: PathBuf, helper: bool, out: &mut Vec<(PathBuf, bool)>| {
        let real = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
        if seen.insert(real) {
            out.push((path, helper));
        }
    };
    for home in homes {
        let Ok(projects) = std::fs::read_dir(home.join("projects")) else { continue };
        for project in projects.flatten() {
            let Ok(entries) = std::fs::read_dir(project.path()) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    let Ok(helpers) = std::fs::read_dir(path.join("subagents")) else { continue };
                    for helper in helpers.flatten() {
                        let path = helper.path();
                        if jsonl(&path) && fresh(&path) {
                            push(path, true, &mut out);
                        }
                    }
                } else if jsonl(&path) && fresh(&path) {
                    push(path, false, &mut out);
                }
            }
        }
    }
    out.sort();
    out
}

/// The cache-waste insight over this machine's Claude Code transcripts of the last `hours`.
pub fn cache_waste(homes: &[PathBuf], hours: u64, now_ms: u64) -> CacheWaste {
    let hours = hours.clamp(1, MAX_HOURS);
    let since_ms = now_ms.saturating_sub(hours * HOUR_MS);
    let parsed: Vec<(String, bool, Vec<Request>)> = transcripts(homes, since_ms)
        .into_iter()
        .filter_map(|(path, helper)| {
            let file = std::fs::File::open(&path).ok()?;
            let requests = parse_transcript(std::io::BufReader::new(file));
            let id = path.file_stem()?.to_string_lossy().into_owned();
            Some((id, helper, requests))
        })
        .collect();
    report(
        parsed.iter().map(|(id, helper, requests)| (id.clone(), *helper, requests.as_slice())),
        since_ms,
        now_ms.saturating_add(1),
    )
}

/// The human form of the report: one line per cause, then the sessions to look at.
pub fn render(report: &CacheWaste) -> String {
    let mut out = String::new();
    let hours = (report.until_ms.saturating_sub(report.since_ms) + HOUR_MS / 2) / HOUR_MS;
    let share = report.avoidable_share.map_or("n/a".to_owned(), |s| format!("{:.0}%", s * 100.0));
    out.push_str(&format!(
        "Cache writes, last {hours} h: {} tokens over {} requests in {} transcripts (${:.2}).\n",
        report.cache_write_tokens, report.requests, report.transcripts, report.cache_write_usd
    ));
    out.push_str(&format!(
        "Avoidable: {} tokens ({share}), ${:.2} a warm cache would have saved.\n",
        report.avoidable_tokens, report.avoidable_usd
    ));
    if report.causes.is_empty() {
        out.push_str("No cache writes in this window.\n");
        return out;
    }
    out.push('\n');
    for row in &report.causes {
        let pct = row.tokens as f64 * 100.0 / report.cache_write_tokens.max(1) as f64;
        let mark = if row.avoidable { "avoidable" } else { "floor" };
        out.push_str(&format!(
            "  {:<15} {:>13} tok {:>4.0}%  {:<9}  {}\n",
            row.cause.key(),
            row.tokens,
            pct,
            mark,
            row.fix
        ));
    }
    if !report.top_sessions.is_empty() {
        out.push_str("\nMost avoidable sessions:\n");
        for session in &report.top_sessions {
            out.push_str(&format!(
                "  {}{}  {} tok  ${:.2}  {}\n",
                session.session_id,
                if session.helper { " (helper)" } else { "" },
                session.avoidable_tokens,
                session.avoidable_usd,
                session.top_cause.map_or("", Cause::key)
            ));
        }
    }
    if !report.unpriced_models.is_empty() {
        out.push_str(&format!("\nUnpriced models: {}\n", report.unpriced_models.join(", ")));
    }
    out
}

#[cfg(test)]
#[path = "usage_insights_tests.rs"]
mod tests;
