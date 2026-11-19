//! `cmux cloud trace [TRACE_ID] [--limit N] [--platform URL] [--json]` (`cmux vm trace`): the
//! Cloud start timing waterfall (Leo, 2026-11-19: "the developer debug thing to be able to
//! visualize the sort of breakdown of the timings for the, like the cloud startups among all
//! areas").
//!
//! A Cloud start is one trace of fixed hops (`click`, `api`, `placement`, `provider_create`,
//! `restore`, `boot`, `network`, `agent_auth`, `first_token`), each one or more spans the client,
//! the platform and the machine posted (cmux-platform `StartTrace.ts`). This command reads them:
//!
//! - with an id, `GET /v1/cloud/start-traces/{trace}`: one row per hop with its start offset from
//!   the trace's first span, its duration and a bar scaled to the trace's total, beside the hop's
//!   p50/p95 over the last day (`GET /v1/cloud/start-traces?limit=1`'s `hops`);
//! - without one, `GET /v1/cloud/start-traces?limit=N`: the last day's p50/p95 per hop and the
//!   newest traces with their ids.
//!
//! `--json` prints the platform's body as it came. Sign-in: `CMUX_CLOUD_ACCESS_TOKEN`, else a
//! token the cmux app mints (`cmux auth token`); the platform is `--platform`, else
//! `CMUX_PLATFORM_URL`, else production (machine_join.rs `platform_origin`).
//!
//! A hop's duration follows the platform's rule (cmux-platform StartTrace.ts): the sum of the
//! winning source's spans, the platform's winning over a client's or the machine's; for
//! `network` the platform's and the client's sums are added (the server prepares and attaches,
//! the client connects). The bar marks every span of the hop, so a hop in two parts shows two.

use std::fmt::Write as _;
use std::time::Duration;

use serde_json::Value;

use super::cloud_help::{TRACE, TRACE_USAGE};
use super::{GlobalArgs, OutputMode};

/// The hops in the order a start runs them (the contract's fixed names).
pub(crate) const HOPS: [&str; 9] = [
    "click",
    "api",
    "placement",
    "provider_create",
    "restore",
    "boot",
    "network",
    "agent_auth",
    "first_token",
];
/// The bar's width in cells.
const BAR: usize = 32;
/// The newest traces the list shows by default, and the platform's most.
const DEFAULT_LIMIT: u32 = 20;
const MAX_LIMIT: u32 = 200;
/// One platform read.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

/// One parsed command.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help,
    One { trace: String, platform: Option<String> },
    List { limit: u32, platform: Option<String> },
}

/// `Some(exit code)` when `args` is `cloud trace …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, verb, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || verb != TRACE {
        return None;
    }
    let mut words = Vec::new();
    for word in rest {
        match word.as_str() {
            "--json" => global.output = OutputMode::Json,
            _ => words.push(word.clone()),
        }
    }
    Some(match parse(&words) {
        Ok(Parsed::Help) => {
            print!("{TRACE_USAGE}");
            0
        }
        Ok(parsed) => run(&global, &parsed),
        Err(message) => super::app::failure(
            "usage.invalid",
            &format!("cmux: {message}\n{TRACE_USAGE}"),
            global.output,
            2,
        ),
    })
}

/// Whether `id` is a trace id the platform takes (`^[A-Za-z0-9_-]{8,80}$`).
pub(crate) fn is_trace_id(id: &str) -> bool {
    (8..=80).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The words after `trace`.
pub(super) fn parse(words: &[String]) -> Result<Parsed, String> {
    let mut trace = None;
    let mut limit = None;
    let mut platform = None;
    let mut index = 0;
    let value = |index: &mut usize, flag: &str| {
        *index += 1;
        words.get(*index).cloned().ok_or_else(|| format!("{flag} needs a value"))
    };
    while let Some(word) = words.get(index).map(String::as_str) {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, inline)) if flag.starts_with("--") => (flag, Some(inline.to_owned())),
            _ => (word, None),
        };
        match flag {
            "-h" | "--help" | "help" => return Ok(Parsed::Help),
            "--limit" => {
                let raw = match inline {
                    Some(raw) => raw,
                    None => value(&mut index, "--limit")?,
                };
                let n: u32 = raw.parse().map_err(|_| format!("--limit {raw:?} is not a number"))?;
                if !(1..=MAX_LIMIT).contains(&n) {
                    return Err(format!("--limit is 1 to {MAX_LIMIT}"));
                }
                limit = Some(n);
            }
            "--platform" => {
                platform = Some(match inline {
                    Some(raw) => raw,
                    None => value(&mut index, "--platform")?,
                });
            }
            _ if word.starts_with('-') => return Err(format!("unexpected argument {word:?}")),
            _ if trace.is_none() => {
                if !is_trace_id(word) {
                    return Err(format!(
                        "{word:?} is not a trace id (8 to 80 letters, digits, _ or -)"
                    ));
                }
                trace = Some(word.to_owned());
            }
            _ => return Err(format!("unexpected argument {word:?}")),
        }
        index += 1;
    }
    match (trace, limit) {
        (Some(_), Some(_)) => Err("--limit is for the list (no trace id)".to_owned()),
        (Some(trace), None) => Ok(Parsed::One { trace, platform }),
        (None, limit) => Ok(Parsed::List { limit: limit.unwrap_or(DEFAULT_LIMIT), platform }),
    }
}

fn run(global: &GlobalArgs, parsed: &Parsed) -> i32 {
    let fail = |code: &str, message: String| {
        super::app::failure(code, &format!("cmux: {message}"), global.output, 1)
    };
    let platform_flag = match parsed {
        Parsed::One { platform, .. } | Parsed::List { platform, .. } => platform.as_deref(),
        Parsed::Help => return 0,
    };
    let env = |key: &str| std::env::var(key).ok();
    let origin = match super::platform_origin(platform_flag, &env) {
        Ok(origin) => origin,
        Err(message) => return fail("usage.invalid", message),
    };
    let credential = match super::joined_machine_credential(None, false) {
        Ok(Some(credential)) => credential,
        Ok(None) => match super::chat_start::joined::app_token(global) {
            Ok(token) => token,
            Err(reason) => return fail("cloud.not_signed_in", reason),
        },
        Err(message) => return fail("cloud.not_signed_in", message),
    };
    let platform = match super::Platform::new(origin, credential, REQUEST_TIMEOUT) {
        Ok(platform) => platform,
        Err(failure) => return fail("internal", failure.message),
    };
    let json = global.output != OutputMode::Human;
    let answer = match parsed {
        Parsed::One { trace, .. } => {
            let one = match platform
                .get_with_timeout(&format!("/v1/cloud/start-traces/{trace}"), REQUEST_TIMEOUT)
            {
                Ok(body) => body,
                Err(error) => return fail(error_code(&error), refusal(&error, Some(trace))),
            };
            if json {
                Ok(one)
            } else {
                // The day's p50/p95 beside the hops; a list that fails leaves them out.
                let day = platform
                    .get_with_timeout("/v1/cloud/start-traces?limit=1", REQUEST_TIMEOUT)
                    .ok();
                Err(waterfall(&one, day.as_ref()))
            }
        }
        Parsed::List { limit, .. } => {
            match platform
                .get_with_timeout(&format!("/v1/cloud/start-traces?limit={limit}"), REQUEST_TIMEOUT)
            {
                Ok(body) if json => Ok(body),
                Ok(body) => Err(summary(&body)),
                Err(error) => return fail(error_code(&error), refusal(&error, None)),
            }
        }
        Parsed::Help => return 0,
    };
    match answer {
        Ok(body) => println!("{body}"),
        Err(text) => print!("{text}"),
    }
    0
}

/// The error code of a failed read, for `--json` failures.
fn error_code(error: &super::PlatformCallError) -> &'static str {
    match error {
        super::PlatformCallError::Status { status: 404, .. } => "cloud.start_trace.not_found",
        super::PlatformCallError::Status { status: 401 | 403, .. } => "cloud.not_signed_in",
        _ => "cloud.unavailable",
    }
}

/// Why a read failed, in words.
fn refusal(error: &super::PlatformCallError, trace: Option<&str>) -> String {
    match (error, trace) {
        (super::PlatformCallError::Status { status: 404, .. }, Some(trace)) => format!(
            "no start trace {trace} in your team (traces are kept 48 hours; `cmux vm trace` lists them)"
        ),
        (super::PlatformCallError::Status { status: 404, .. }, None) => {
            "this cmux platform has no start traces yet (it answered 404)".to_owned()
        }
        (super::PlatformCallError::Status { status: 401, .. }, _) => {
            "the cmux platform did not accept your sign-in (401)".to_owned()
        }
        (super::PlatformCallError::Status { status, code, .. }, _) => {
            format!("the cmux platform refused the read: {}", format!("{status} {code}").trim_end())
        }
        (super::PlatformCallError::Unreachable(reason), _) => {
            format!("the cmux platform did not answer: {reason}")
        }
        (super::PlatformCallError::Unreadable(status), _) => {
            format!("the cmux platform answered {status} with no readable body")
        }
    }
}

/// One span of a trace body.
#[derive(Debug, Clone, PartialEq)]
struct Span {
    hop: String,
    start_ms: i64,
    end_ms: i64,
    source: String,
}

fn spans(trace: &Value) -> Vec<Span> {
    trace
        .get("spans")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|span| {
            let start_ms = span.get("start_ms").and_then(Value::as_i64)?;
            let end_ms = span.get("end_ms").and_then(Value::as_i64)?.max(start_ms);
            Some(Span {
                hop: span.get("hop").and_then(Value::as_str)?.to_owned(),
                start_ms,
                end_ms,
                source: span.get("source").and_then(Value::as_str).unwrap_or("").to_owned(),
            })
        })
        .collect()
}

/// A hop's duration in one trace by the platform's rule (module docs).
fn hop_duration(hop: &str, spans: &[&Span]) -> i64 {
    let sum = |source: &dyn Fn(&str) -> bool| -> Option<i64> {
        let mine: Vec<_> = spans.iter().filter(|span| source(&span.source)).collect();
        (!mine.is_empty()).then(|| mine.iter().map(|span| span.end_ms - span.start_ms).sum())
    };
    let platform = sum(&|source| source == "platform");
    let client = sum(&|source| source == "app" || source == "cli");
    if hop == "network" && (platform.is_some() || client.is_some()) {
        return platform.unwrap_or(0) + client.unwrap_or(0);
    }
    platform
        .or_else(|| sum(&|source| source == "machine"))
        .or(client)
        .or_else(|| sum(&|_| true))
        .unwrap_or(0)
}

/// `ms` for a person: `840 ms`, `8.4 s`, `2m 05s`.
pub(crate) fn duration_text(ms: i64) -> String {
    let ms = ms.max(0);
    if ms < 1000 {
        format!("{ms} ms")
    } else if ms < 60_000 {
        format!("{:.1} s", ms as f64 / 1000.0)
    } else {
        format!("{}m {:02}s", ms / 60_000, (ms % 60_000) / 1000)
    }
}

/// An epoch-ms time as `2026-11-19 13:00:01Z` (UTC).
pub(crate) fn utc_text(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// `started_at` as epoch ms or the platform's text, for a person.
fn started_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::Number(n)) => n.as_i64().map(utc_text).unwrap_or_default(),
        Some(Value::String(text)) => text.clone(),
        _ => "-".to_owned(),
    }
}

/// The `p50 p95 (n)` cell of `hop` from a list body's `hops`.
fn stats_cell(day: Option<&Value>, hop: &str) -> String {
    let Some(stats) = day.and_then(|day| day.pointer(&format!("/hops/{hop}"))) else {
        return "-".to_owned();
    };
    let ms =
        |key: &str| stats.get(key).and_then(Value::as_i64).map_or("-".to_owned(), duration_text);
    let n = stats.get("n").and_then(Value::as_u64).unwrap_or(0);
    format!("{:>8} {:>8}  ({n})", ms("p50_ms"), ms("p95_ms"))
}

/// The bar of the cells `spans` cover in `[origin, origin + total)`.
fn bar(spans: &[&Span], origin: i64, total: i64) -> String {
    let mut cells = [' '; BAR];
    let total = total.max(1);
    let cell_of = |ms: i64| -> usize {
        let at = (ms - origin).clamp(0, total) as f64 / total as f64 * BAR as f64;
        (at as usize).min(BAR)
    };
    for span in spans {
        let from = cell_of(span.start_ms).min(BAR - 1);
        let to = cell_of(span.end_ms).max(from + 1).min(BAR);
        for cell in &mut cells[from..to] {
            *cell = '#';
        }
    }
    cells.iter().collect()
}

/// One trace as a text waterfall, with the day's p50/p95 per hop from `day` (a list body).
pub(crate) fn waterfall(trace: &Value, day: Option<&Value>) -> String {
    let spans = spans(trace);
    let origin = spans.iter().map(|span| span.start_ms).min().unwrap_or(0);
    let last = spans.iter().map(|span| span.end_ms).max().unwrap_or(origin);
    let total =
        trace.get("total_ms").and_then(Value::as_i64).unwrap_or(last - origin).max(last - origin);
    let text = |key: &str| trace.get(key).and_then(Value::as_str).unwrap_or("-").to_owned();
    let mut out = String::new();
    let _ = writeln!(out, "trace {}", text("trace"));
    let _ = writeln!(
        out,
        "  machine {}  path {}  started {}  total {}",
        text("machine"),
        text("path"),
        started_text(trace.get("started_at")),
        duration_text(total)
    );
    if !spans.iter().any(|span| span.hop == "click") {
        // The macOS app does not time its click yet (its create is the app's own); the trace
        // starts where the platform received the create.
        let _ = writeln!(
            out,
            "  the click is not timed: the trace starts at the platform's receipt of the create"
        );
    }
    out.push('\n');
    let _ = writeln!(
        out,
        "{:<16}{:>9}{:>9}  |{:<BAR$}|{:>9}{:>9}  (n, last day)",
        "hop", "start", "took", "", "p50", "p95"
    );
    // The fixed hops first, then any hop the platform added later, in its order.
    let mut names: Vec<&str> = HOPS.to_vec();
    for span in &spans {
        if !names.contains(&span.hop.as_str()) {
            names.push(&span.hop);
        }
    }
    for hop in names {
        let mine: Vec<&Span> = spans.iter().filter(|span| span.hop == hop).collect();
        let stats = stats_cell(day, hop);
        if mine.is_empty() {
            let _ = writeln!(out, "{hop:<16}{:>9}{:>9}  |{:<BAR$}|{stats}", "-", "-", "");
            continue;
        }
        let start = mine.iter().map(|span| span.start_ms).min().unwrap_or(origin) - origin;
        let _ = writeln!(
            out,
            "{hop:<16}{:>9}{:>9}  |{}|{stats}",
            format!("+{}", duration_text(start)),
            duration_text(hop_duration(hop, &mine)),
            bar(&mine, origin, total),
        );
    }
    out
}

/// The list body as the day's p50/p95 table and the newest traces.
pub(crate) fn summary(list: &Value) -> String {
    let window = list.get("window_ms").and_then(Value::as_i64).unwrap_or(86_400_000);
    let traces = list.get("traces").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut out = String::new();
    let _ = writeln!(
        out,
        "Cloud start hops, last {}",
        duration_text(window).replace("1440m 00s", "24 h")
    );
    let _ = writeln!(out, "{:<16}{:>6}{:>10}{:>10}", "hop", "n", "p50", "p95");
    let mut names: Vec<String> = HOPS.iter().map(|hop| (*hop).to_owned()).collect();
    if let Some(hops) = list.get("hops").and_then(Value::as_object) {
        names.extend(hops.keys().filter(|hop| !HOPS.contains(&hop.as_str())).cloned());
    }
    for hop in &names {
        let stats = list.pointer(&format!("/hops/{hop}"));
        let ms = |key: &str| {
            stats
                .and_then(|s| s.get(key))
                .and_then(Value::as_i64)
                .map_or("-".to_owned(), duration_text)
        };
        let n = stats.and_then(|s| s.get("n")).and_then(Value::as_u64).unwrap_or(0);
        let _ = writeln!(out, "{hop:<16}{n:>6}{:>10}{:>10}", ms("p50_ms"), ms("p95_ms"));
    }
    out.push('\n');
    if traces.is_empty() {
        out.push_str("No Cloud starts in this window.\n");
        return out;
    }
    let _ = writeln!(out, "Newest traces (`cmux vm trace ID` draws one)");
    let _ = writeln!(
        out,
        "{:<40}  {:<21}{:>9}  {:<8}{:>5}  machine",
        "trace", "started", "total", "path", "hops"
    );
    for row in &traces {
        let text = |key: &str| row.get(key).and_then(Value::as_str).unwrap_or("-").to_owned();
        let total =
            row.get("total_ms").and_then(Value::as_i64).map_or("-".to_owned(), duration_text);
        let seen = row.get("hops_seen").and_then(Value::as_array).map_or(0, Vec::len);
        let _ = writeln!(
            out,
            "{:<40}  {:<21}{:>9}  {:<8}{:>5}  {}",
            text("trace"),
            started_text(row.get("started_at")),
            total,
            text("path"),
            format!("{seen}/{}", HOPS.len()),
            text("machine"),
        );
    }
    out
}

#[cfg(test)]
#[path = "cloud_trace/tests.rs"]
mod tests;
