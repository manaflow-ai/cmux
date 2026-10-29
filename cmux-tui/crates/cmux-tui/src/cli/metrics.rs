//! `cmux metrics [NAME ...] [--json]`: the cmux app's field histograms since
//! it started (plans/cmux-next/chrome-parity/p09-observability.md, task 065).
//!
//! One read-only app method, `metrics.snapshot {names?}` (CmuxNextControl
//! `ControlRouter.metricsMethod`), whose only parameter is `names`: the
//! substrings a histogram's name must contain, as Chrome's chrome://histograms
//! query keeps the histograms whose name contains it
//! (base/metrics/statistics_recorder.cc). The request carries no read barrier
//! (`after`): the counters are not session state, and the method refuses
//! every parameter but `names`. The human form is a table of name, unit,
//! count, mean, p50, p95, p99 and max; `--json` prints the app's reply.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};
use unicode_width::UnicodeWidthStr;

use super::{GlobalArgs, OutputMode, UsageError};
use crate::localization::MetricsMessages;

/// The app method (CmuxNextControl `MetricsSnapshot.method`).
pub(super) const METHOD: &str = "metrics.snapshot";
/// The app answers from memory off its main thread; this bounds a stuck app.
const TIMEOUT: Duration = Duration::from_secs(5);
/// The whole catalog with every bucket stays far below this.
const MAX_REPLY_BYTES: u64 = 4 * 1024 * 1024;
/// The percentile columns, by the JSON key each shows.
const PERCENTILES: [(&str, &str); 4] =
    [("P50", "p50"), ("P95", "p95"), ("P99", "p99"), ("MAX", "max")];

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    /// Ask for the histograms whose name contains one of these (all when empty).
    Snapshot(Vec<String>),
}

/// A failed request: the error printed and the exit code.
#[derive(Debug, PartialEq)]
pub(super) struct Failure {
    pub error: Value,
    pub exit_code: i32,
}

impl Failure {
    /// The app refused: 5 when it has no such method (an app from before task
    /// 065), else 1 (`unavailable` while its metricsView feature is off).
    fn refused(error: Value) -> Self {
        let exit_code = match error.get("code").and_then(Value::as_str) {
            Some("method_not_found") => 5,
            _ => 1,
        };
        Self { error, exit_code }
    }

    fn transport(error: Value) -> Self {
        Self { error, exit_code: 3 }
    }
}

/// `cmux metrics …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "metrics" {
        return None;
    }
    Some(match parse(rest) {
        Ok(invocation) => run(&global, invocation),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

pub(super) fn parse(rest: &[String]) -> Result<Invocation, UsageError> {
    let messages = &crate::localization::catalog().metrics;
    if rest.iter().any(|arg| arg == "--help" || arg == "-h") || rest == ["help"] {
        return Ok(Invocation::Help);
    }
    if let Some(option) = rest.iter().find(|arg| arg.starts_with('-')) {
        return Err(UsageError::new(messages.unknown_option.replace("{option}", option)));
    }
    Ok(Invocation::Snapshot(rest.iter().filter(|name| !name.is_empty()).cloned().collect()))
}

/// The request's params: `names` only when some are given.
pub(super) fn params(names: &[String]) -> Value {
    if names.is_empty() { json!({}) } else { json!({ "names": names }) }
}

fn run(global: &GlobalArgs, invocation: Invocation) -> i32 {
    let messages = &crate::localization::catalog().metrics;
    let Invocation::Snapshot(names) = invocation else {
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(messages.usage.as_bytes());
        let _ = stdout.flush();
        return 0;
    };
    match snapshot(global, &names) {
        Ok(reply) => {
            let shown = match global.output {
                OutputMode::Human => json!(table(&reply, messages)),
                _ => reply,
            };
            super::wire::print_local_success(&shown, global.output)
        }
        Err(failure) => {
            super::wire::print_local_error(&failure.error, global.output, failure.exit_code)
        }
    }
}

/// The app's `metrics.snapshot` reply for `names`, or why there is none.
pub(super) fn snapshot(global: &GlobalArgs, names: &[String]) -> Result<Value, Failure> {
    let mut stream = super::app::connect_command(global).map_err(Failure::transport)?;
    match exchange(&mut stream, params(names)) {
        Ok(Ok(reply)) => Ok(reply),
        Ok(Err(error)) => Err(Failure::refused(error)),
        Err(message) => Err(Failure::transport(json!({
            "code": "app.transport", "message": message, "details": {}, "retryable": false,
        }))),
    }
}

/// One request line out and one reply line back.
fn exchange(stream: &mut UnixStream, params: Value) -> Result<Result<Value, Value>, String> {
    let line = json!({ "id": 1, "method": METHOD, "params": params });
    super::app::send_line(stream, &line)?;
    // wakeup-allow: cli-only `cmux metrics`'s one bound on the reply; the reply ends the read first
    stream.set_read_timeout(Some(TIMEOUT)).map_err(|error| error.to_string())?;
    let reader = stream.try_clone().map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(reader.take(MAX_REPLY_BYTES));
    let mut reply = String::new();
    reader.read_line(&mut reply).map_err(|error| error.to_string())?;
    super::app::parse_response(&reply)
}

/// The human form of a reply: one aligned row per histogram, then the
/// summary line. Columns align in terminal cells (a CJK title fills two per char).
pub(super) fn table(reply: &Value, messages: &MetricsMessages) -> String {
    if reply.get("recording").and_then(Value::as_bool) == Some(false) {
        return messages.not_recording.to_owned();
    }
    let histograms =
        reply.get("histograms").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    if histograms.is_empty() {
        return messages.no_histograms.to_owned();
    }
    let mut rows = vec![
        [messages.column_name, messages.column_unit, messages.column_count, messages.column_mean]
            .into_iter()
            .map(str::to_owned)
            .chain(PERCENTILES.iter().map(|(title, _)| (*title).to_owned()))
            .collect::<Vec<_>>(),
    ];
    rows.extend(histograms.iter().map(row));
    let columns = rows.first().map_or(0, Vec::len);
    let mut widths = vec![0; columns];
    for row in &rows {
        for (width, cell) in widths.iter_mut().zip(row) {
            *width = (*width).max(cell.width());
        }
    }
    let mut text = String::new();
    for row in &rows {
        let mut line = String::new();
        for (column, (cell, width)) in row.iter().zip(&widths).enumerate() {
            let pad = width.saturating_sub(cell.width());
            if column == 0 || column == 1 {
                line.push_str(cell);
                line.push_str(&" ".repeat(pad));
            } else {
                line.push_str(&" ".repeat(pad));
                line.push_str(cell);
            }
            if column + 1 < columns {
                line.push_str("  ");
            }
        }
        text.push_str(line.trim_end());
        text.push('\n');
    }
    let pid =
        reply.get("pid").and_then(Value::as_u64).map(|pid| pid.to_string()).unwrap_or_default();
    text.push_str(
        &messages.summary.replace("{count}", &histograms.len().to_string()).replace("{pid}", &pid),
    );
    text
}

/// One histogram's cells: name, unit, count, mean, then each percentile
/// (`-` for none, as an enumeration has; `>MAX` past its largest bucket).
fn row(histogram: &Value) -> Vec<String> {
    let text = |key: &str| histogram.get(key).and_then(Value::as_str).unwrap_or("-").to_owned();
    let count =
        histogram.get("count").and_then(Value::as_f64).map_or_else(|| "-".to_owned(), whole);
    let mean = histogram.get("mean").and_then(Value::as_f64).map_or_else(|| "-".to_owned(), whole);
    let overflowed = histogram.get("overflow_count").and_then(Value::as_f64).unwrap_or(0.0) > 0.0;
    let maximum =
        histogram.get("layout").and_then(|layout| layout.get("maximum")).and_then(Value::as_f64);
    let mut cells = vec![text("name"), text("unit"), count, mean];
    for (_, key) in PERCENTILES {
        let cell = match histogram.get(key).and_then(Value::as_f64) {
            None => "-".to_owned(),
            Some(value) if overflowed && maximum.is_some_and(|maximum| value > maximum) => {
                format!(">{}", whole(maximum.unwrap_or(value)))
            }
            Some(value) => whole(value),
        };
        cells.push(cell);
    }
    cells
}

/// `value` rounded to a whole number.
fn whole(value: f64) -> String {
    format!("{}", value.round() as i64)
}

#[cfg(test)]
#[path = "metrics_tests.rs"]
mod tests;
