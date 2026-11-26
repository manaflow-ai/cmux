//! Usage efficiency insights, catalog 1: why each cache-write token was paid, and what would
//! have avoided it (design `docs/design/usage-efficiency-insights.md` in cmuxterm-hq, I2).
//!
//! Local and on demand: it reads this machine's Claude Code transcripts when asked, uploads
//! nothing, and is content-blind (record types, timestamps, usage numbers, model, `shapeHash`,
//! compact markers; never message text). A port of leo-workspace `tools/cache_write_sources.py`'s
//! classifier, so the two agree on the same transcripts.
//!
//! The model: a request's context is input + cache read + cache write. Its write splits into the
//! append (context added since the previous request: the floor, every token is written once) and
//! the rewrite (the previous context that was not read back). A rewrite's cause is the first of
//! compaction, idle wake, model switch, shape change, lost under ttl and prefix edit that holds; a
//! file's first request is a session start (or a helper start for a subagent's transcript).

use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Tokens of slack before a short cache read counts as a rewrite (block rounding).
pub const TOLERANCE: u64 = 1024;
/// A warm cache that misses after a gap this long, nothing else changed: "lost under ttl".
pub const LOST_AFTER_SECS: f64 = 300.0;

/// Every cause, the floor first.
pub const CAUSES: &[&str] = &[
    "append",
    "session start",
    "helper start",
    "idle wake",
    "compaction",
    "model switch",
    "shape change",
    "lost under ttl",
    "prefix edit",
];

/// What would have avoided a cause's rewrite (catalog 1 of the design).
pub fn fix_for(cause: &str) -> &'static str {
    match cause {
        "append" => "none: new context has to be written once",
        "session start" => "reuse a warm session instead of starting a new one for a short task",
        "helper start" => "fork helpers off the parent's cache instead of starting them cold",
        "idle wake" => "compact (or end the turn) before idling past the cache lifetime",
        "compaction" => "compact less often: each compaction rewrites the whole context",
        "model switch" => "keep one model per session; each model has its own cache",
        "shape change" => "keep the tool list and system prompt fixed within a session",
        "lost under ttl" => "pin a session to one account: a prompt cache is per account",
        "prefix edit" => "move hook and reminder text out of the prompt prefix",
        _ => "",
    }
}

/// $ per million tokens for one model.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rates {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
}

/// The fallback rates by model family, as `cache_write_sources.py`'s `FALLBACK_RATES`.
pub fn fallback_rates(model: &str) -> Rates {
    let m = model.to_ascii_lowercase();
    let (input, output, cache_read) = if m.starts_with("claude-fable") {
        (8.0, 40.0, 0.2)
    } else if m.starts_with("claude-sonnet") {
        (3.0, 15.0, 0.1)
    } else if m.starts_with("claude-haiku") {
        (1.0, 5.0, 0.1)
    } else {
        (5.0, 25.0, 0.2)
    };
    Rates { input, output, cache_read }
}

/// One request, deduplicated by request id.
#[derive(Debug, Clone, Default)]
struct Req {
    t: f64,
    input: u64,
    cr: u64,
    cw: u64,
    out: u64,
    model: String,
    w1: u64,
    ttl1h: bool,
    shape: Option<String>,
    compact: bool,
}

impl Req {
    fn ctx(&self) -> u64 {
        self.input + self.cr + self.cw
    }
}

/// One cause's share.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct CauseRow {
    pub cause: String,
    pub tokens: u64,
    pub events: u64,
    /// $ these writes cost.
    pub write_usd: f64,
    /// $ over what reading them back would have cost (0 for the append).
    pub gap_usd: f64,
    pub fix: String,
}

/// The insight for a set of transcripts.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct Insights {
    pub files: u64,
    pub requests: u64,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    /// The whole bill of the requests counted.
    pub bill_usd: f64,
    /// The append writes: what the work needed.
    pub floor_write_tokens: u64,
    /// Everything else written.
    pub gap_write_tokens: u64,
    pub gap_write_pct: f64,
    pub gap_usd: f64,
    pub gap_pct_of_bill: f64,
    /// By cause, the costliest gap first; the append last.
    pub causes: Vec<CauseRow>,
}

#[derive(Debug, Default)]
struct Acc {
    files: u64,
    requests: u64,
    input: u64,
    cr: u64,
    cw: u64,
    out: u64,
    bill: f64,
    gap_tokens: u64,
    gap_usd: f64,
    cause: HashMap<&'static str, (u64, u64, f64, f64)>,
}

fn parse_ts(v: &Value) -> Option<f64> {
    let s = v.as_str()?;
    let t = chrono::DateTime::parse_from_rfc3339(s).ok()?;
    Some(t.timestamp_millis() as f64 / 1000.0)
}

fn num(v: Option<&Value>) -> u64 {
    v.and_then(Value::as_u64).unwrap_or(0)
}

/// The requests of one transcript, in order.
fn requests(text: &str) -> Vec<Req> {
    let mut reqs: Vec<Req> = Vec::new();
    let mut by_id: HashMap<String, usize> = HashMap::new();
    let mut shape: Option<String> = None;
    let mut compact = false;
    for line in text.lines() {
        let Ok(d) = serde_json::from_str::<Value>(line) else { continue };
        let typ = d.get("type").and_then(Value::as_str).unwrap_or("");
        if matches!(typ, "api-request" | "api-request-shape") {
            if let Some(h) = d.get("shapeHash").and_then(Value::as_str).filter(|h| !h.is_empty()) {
                shape = Some(h.to_string());
                continue;
            }
        }
        let boundary =
            typ == "system" && d.get("subtype").and_then(Value::as_str) == Some("compact_boundary");
        if boundary || d.get("isCompactSummary").and_then(Value::as_bool).unwrap_or(false) {
            compact = true;
            continue;
        }
        if typ != "assistant" {
            continue;
        }
        let Some(m) = d.get("message") else { continue };
        let model = m.get("model").and_then(Value::as_str).unwrap_or("");
        let Some(u) = m.get("usage").filter(|u| u.is_object()) else { continue };
        if !model.starts_with("claude") {
            continue;
        }
        let Some(t) = d.get("timestamp").and_then(parse_ts) else { continue };
        let key = d
            .get("requestId")
            .and_then(Value::as_str)
            .or_else(|| m.get("id").and_then(Value::as_str))
            .map(str::to_string);
        if let Some(i) = key.as_ref().and_then(|k| by_id.get(k)) {
            if let Some(r) = reqs.get_mut(*i) {
                r.out = r.out.max(num(u.get("output_tokens")));
            }
            continue;
        }
        let cc = u.get("cache_creation");
        reqs.push(Req {
            t,
            input: num(u.get("input_tokens")),
            cr: num(u.get("cache_read_input_tokens")),
            cw: num(u.get("cache_creation_input_tokens")),
            out: num(u.get("output_tokens")),
            model: model.to_string(),
            w1: num(cc.and_then(|c| c.get("ephemeral_1h_input_tokens"))),
            ttl1h: d.get("promptCacheRequested").and_then(Value::as_str) == Some("1h"),
            shape: shape.clone(),
            compact,
        });
        compact = false;
        if let Some(k) = key {
            by_id.insert(k, reqs.len() - 1);
        }
    }
    reqs
}

/// The rewrite cause of `r` after `prev`.
fn cause_of(prev: &Req, r: &Req) -> &'static str {
    let ttl = if prev.w1 > 0 || prev.ttl1h { 3600.0 } else { 300.0 };
    let gap = r.t - prev.t;
    if r.compact {
        "compaction"
    } else if gap > ttl {
        "idle wake"
    } else if r.model != prev.model {
        "model switch"
    } else if matches!((&r.shape, &prev.shape), (Some(a), Some(b)) if a != b) {
        "shape change"
    } else if gap > LOST_AFTER_SECS {
        "lost under ttl"
    } else {
        "prefix edit"
    }
}

impl Acc {
    fn scan(&mut self, text: &str, helper: bool, since: f64, rates: &dyn Fn(&str) -> Rates) {
        self.files += 1;
        let reqs = requests(text);
        let mut prev: Option<&Req> = None;
        for r in &reqs {
            if r.t >= since {
                let p = rates(&r.model);
                let wprice = p.input * if r.w1 > 0 || r.ttl1h { 2.0 } else { 1.25 };
                let mut causes: Vec<(&'static str, u64)> = Vec::new();
                match prev {
                    None => {
                        causes.push((if helper { "helper start" } else { "session start" }, r.cw))
                    }
                    Some(prev) => {
                        let mut lost = r.cw.min(prev.ctx().saturating_sub(r.cr));
                        if lost <= TOLERANCE {
                            lost = 0;
                        }
                        if lost > 0 {
                            causes.push((cause_of(prev, r), lost));
                        }
                        causes.push(("append", r.cw - lost));
                    }
                }
                self.requests += 1;
                self.input += r.input;
                self.cr += r.cr;
                self.cw += r.cw;
                self.out += r.out;
                self.bill += (r.input as f64 * p.input
                    + r.cr as f64 * p.cache_read
                    + r.cw as f64 * wprice
                    + r.out as f64 * p.output)
                    / 1e6;
                for (cause, tok) in causes {
                    if tok == 0 {
                        continue;
                    }
                    let waste = cause != "append";
                    let gap = if waste { tok as f64 * (wprice - p.cache_read) / 1e6 } else { 0.0 };
                    let c = self.cause.entry(cause).or_default();
                    c.0 += tok;
                    c.1 += 1;
                    c.2 += tok as f64 * wprice / 1e6;
                    c.3 += gap;
                    if waste {
                        self.gap_tokens += tok;
                        self.gap_usd += gap;
                    }
                }
            }
            prev = Some(r);
        }
    }

    fn finish(self) -> Insights {
        let mut causes: Vec<CauseRow> = CAUSES
            .iter()
            .filter_map(|c| {
                let (tokens, events, write, gap) = *self.cause.get(c)?;
                Some(CauseRow {
                    cause: c.to_string(),
                    tokens,
                    events,
                    write_usd: write,
                    gap_usd: gap,
                    fix: fix_for(c).to_string(),
                })
            })
            .collect();
        causes.sort_by(|a, b| {
            (a.cause == "append").cmp(&(b.cause == "append")).then(b.gap_usd.total_cmp(&a.gap_usd))
        });
        let pct = |a: f64, b: f64| if b > 0.0 { (a / b * 1000.0).round() / 10.0 } else { 0.0 };
        Insights {
            files: self.files,
            requests: self.requests,
            input_tokens: self.input,
            cache_read_tokens: self.cr,
            cache_write_tokens: self.cw,
            output_tokens: self.out,
            bill_usd: self.bill,
            floor_write_tokens: self.cw - self.gap_tokens,
            gap_write_tokens: self.gap_tokens,
            gap_write_pct: pct(self.gap_tokens as f64, self.cw as f64),
            gap_usd: self.gap_usd,
            gap_pct_of_bill: pct(self.gap_usd, self.bill),
            causes,
        }
    }
}

/// One transcript's text, and whether it is a subagent's.
pub struct Transcript<'a> {
    pub text: &'a str,
    pub helper: bool,
}

/// The insight over `transcripts`, counting requests at or after `since` (unix seconds).
pub fn analyze(
    transcripts: &[Transcript<'_>],
    since: f64,
    rates: &dyn Fn(&str) -> Rates,
) -> Insights {
    let mut acc = Acc::default();
    for t in transcripts {
        acc.scan(t.text, t.helper, since, rates);
    }
    acc.finish()
}

/// Whether `path` is a subagent's transcript.
pub fn is_helper(path: &Path) -> bool {
    path.components().any(|c| c.as_os_str() == "subagents")
}

/// The Claude Code transcripts under `roots` (each a `projects` folder) modified at or after
/// `since` (unix seconds).
pub fn transcripts_since(roots: &[PathBuf], since: f64) -> Vec<PathBuf> {
    fn walk(dir: &Path, since: f64, out: &mut Vec<PathBuf>, depth: usize) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for e in entries.flatten() {
            let path = e.path();
            let Ok(meta) = e.metadata() else { continue };
            if meta.is_dir() {
                if depth < 4 {
                    walk(&path, since, out, depth + 1);
                }
            } else if path.extension().is_some_and(|x| x == "jsonl") {
                let mtime = meta
                    .modified()
                    .ok()
                    .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
                    .map_or(0.0, |d| d.as_secs_f64());
                if mtime >= since {
                    out.push(path);
                }
            }
        }
    }
    let mut out = Vec::new();
    for root in roots {
        walk(root, since, &mut out, 0);
    }
    out.sort();
    out
}

/// `~/.claude/projects` and every `~/.claude-*/projects` (other accounts' config folders).
pub fn default_roots(home: &Path) -> Vec<PathBuf> {
    let mut roots = vec![home.join(".claude/projects")];
    if let Ok(entries) = std::fs::read_dir(home) {
        let mut more: Vec<PathBuf> = entries
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with(".claude-"))
            .map(|e| e.path().join("projects"))
            .filter(|p| p.is_dir())
            .collect();
        more.sort();
        roots.extend(more);
    }
    roots
}

/// Plain-text rendering.
pub fn render(i: &Insights, hours: f64) -> String {
    use std::fmt::Write as _;
    let mut s = String::new();
    let _ = writeln!(
        s,
        "Cache writes, last {hours}h: {} requests in {} transcripts, bill ${:.2}",
        i.requests, i.files, i.bill_usd
    );
    let _ = writeln!(
        s,
        "  written {} tokens: floor {} ({:.1}%), gap {} ({:.1}%), gap ${:.2} ({:.1}% of the bill)",
        i.cache_write_tokens,
        i.floor_write_tokens,
        100.0 - i.gap_write_pct,
        i.gap_write_tokens,
        i.gap_write_pct,
        i.gap_usd,
        i.gap_pct_of_bill
    );
    for c in &i.causes {
        let _ = writeln!(
            s,
            "  {:<15} {:>12} tok {:>6} events  gap ${:>8.2}  fix: {}",
            c.cause, c.tokens, c.events, c.gap_usd, c.fix
        );
    }
    s
}

#[cfg(test)]
#[path = "usage_insights_tests.rs"]
mod tests;
