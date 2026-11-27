//! `HomeEngineTurn`: one Chief turn for the engine page, from a trace `turn.end` line or
//! the engine report's `recent` turn.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineTurn {
    pub harness: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub status: Option<String>,
    /// When it ended, seconds since 1970.
    pub ended_secs: Option<f64>,
    pub seconds: f64,
    pub tools: i64,
    pub tool_errors: i64,
    pub hit_rate: Option<f64>,
    pub cost: Option<f64>,
    pub tokens: Option<f64>,
    pub reply: Option<String>,
    pub error: Option<String>,
}

/// `HomeEngineTurn.usage`: (cache hit rate, total tokens).
pub fn usage(
    read: Option<f64>,
    written: Option<f64>,
    input: Option<f64>,
    output: Option<f64>,
    present: bool,
) -> (Option<f64>, Option<f64>) {
    if !present {
        return (None, None);
    }
    let read = read.unwrap_or(0.0);
    let prompt = read + written.unwrap_or(0.0) + input.unwrap_or(0.0);
    let total = prompt + output.unwrap_or(0.0);
    ((prompt > 0.0).then(|| read / prompt), (total > 0.0).then_some(total))
}

fn string(o: &Map<String, Value>, key: &str) -> Option<String> {
    o.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn number(o: &Map<String, Value>, key: &str) -> Option<f64> {
    o.get(key).and_then(Value::as_f64)
}

/// `as? Int`: an integer, or a float with no fraction.
fn int(o: &Map<String, Value>, key: &str) -> Option<i64> {
    let v = o.get(key)?;
    v.as_i64().or_else(|| {
        let f = v.as_f64()?;
        (f.fract() == 0.0 && f.abs() < 9.0e18).then_some(f as i64)
    })
}

fn prefix(o: &Map<String, Value>, key: &str) -> Option<String> {
    o.get(key)?.as_object().and_then(|p| string(p, "prefix"))
}

/// `HomeEngineTurn(line:)`.
pub fn from_line(line: &str) -> Option<EngineTurn> {
    let value: Value = serde_json::from_str(line).ok()?;
    let o = value.as_object()?;
    if o.get("ev").and_then(Value::as_str) != Some("turn.end") {
        return None;
    }
    let counts = o.get("usage").and_then(Value::as_object);
    let (hit_rate, tokens) = usage(
        counts.and_then(|c| number(c, "cache_read")),
        counts.and_then(|c| number(c, "cache_write")),
        counts.and_then(|c| number(c, "input")),
        counts.and_then(|c| number(c, "output")),
        counts.is_some(),
    );
    Some(EngineTurn {
        harness: string(o, "harness").unwrap_or_else(|| "?".into()),
        model: string(o, "model"),
        effort: string(o, "effort"),
        status: string(o, "status"),
        ended_secs: number(o, "ts").map(|ms| ms / 1000.0),
        seconds: number(o, "ms").unwrap_or(0.0) / 1000.0,
        tools: int(o, "tools").unwrap_or(0),
        tool_errors: int(o, "tool_errors").unwrap_or(0),
        hit_rate,
        cost: number(o, "cost_usd"),
        tokens,
        reply: prefix(o, "reply"),
        error: prefix(o, "error"),
    })
}

/// `ChiefEngineReport.Turn.Usage` (snake_case keys, as the engine report sends them).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ReportUsage {
    #[serde(alias = "cacheRead")]
    pub cache_read: Option<f64>,
    #[serde(alias = "cacheWrite")]
    pub cache_write: Option<f64>,
    pub input: Option<f64>,
    pub output: Option<f64>,
}

/// `ChiefEngineReport.Turn`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ReportTurn {
    pub harness: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub status: Option<String>,
    pub ts: Option<f64>,
    pub ms: Option<f64>,
    pub tools: Option<i64>,
    #[serde(alias = "toolErrors")]
    pub tool_errors: Option<i64>,
    #[serde(alias = "costUSD")]
    pub cost_usd: Option<f64>,
    pub usage: Option<ReportUsage>,
    pub reply: Option<String>,
    pub error: Option<String>,
}

/// `HomeEngineTurn(report:)`.
pub fn from_report(t: ReportTurn) -> EngineTurn {
    let u = t.usage.as_ref();
    let (hit_rate, tokens) = usage(
        u.and_then(|u| u.cache_read),
        u.and_then(|u| u.cache_write),
        u.and_then(|u| u.input),
        u.and_then(|u| u.output),
        u.is_some(),
    );
    EngineTurn {
        harness: t.harness.unwrap_or_else(|| "?".into()),
        model: t.model,
        effort: t.effort,
        status: t.status,
        ended_secs: t.ts.map(|ms| ms / 1000.0),
        seconds: t.ms.unwrap_or(0.0) / 1000.0,
        tools: t.tools.unwrap_or(0),
        tool_errors: t.tool_errors.unwrap_or(0),
        hit_rate,
        cost: t.cost_usd,
        tokens,
        reply: t.reply,
        error: t.error,
    }
}

/// `HomeChiefFiles.recentTurns(limit:)` over the trace files' texts (today's first):
/// the last `turn.end`s, newest first.
pub fn from_traces(texts: &[Option<String>], limit: usize) -> Vec<EngineTurn> {
    let mut found = Vec::new();
    for text in texts.iter().flatten() {
        let lines = text.split('\n').filter(|l| !l.is_empty()).rev();
        for line in lines.filter(|l| l.contains("\"turn.end\"")) {
            if let Some(turn) = from_line(line) {
                found.push(turn);
            }
            if found.len() >= limit {
                return found;
            }
        }
    }
    found
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineRequest {
    pub line: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReportRequest {
    #[serde(default)]
    pub turns: Vec<ReportTurn>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TracesRequest {
    #[serde(default)]
    pub texts: Vec<Option<String>>,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    5
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnReply {
    pub turn: Option<EngineTurn>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnsReply {
    pub turns: Vec<EngineTurn>,
}
