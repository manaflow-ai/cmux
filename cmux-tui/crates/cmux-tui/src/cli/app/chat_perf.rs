//! `cmux app chat perf --tab <tab> [--seconds <1-60>]`: what one chat page draws while its
//! records come in, measured in the running app (Release and Nightly too) without focusing,
//! selecting or showing the tab. The app's `agent.chat.perf` runs the page's own capture
//! (webviews chatPerfCapture.ts) and returns its report; `--json` prints it, the default prints a
//! short summary. A hidden or covered chat draws no frames: the report says it measured nothing
//! (`measured: false`, `unmeasured_reason`), and so does the summary.

use std::fmt::Write as _;
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};

use super::super::OutputMode;
use super::{AppCommand, GlobalArgs, Options, UsageError};
use crate::localization::AppControlMessages;

/// The app method (AgentChatPerfControl.swift registers it in every build).
pub(super) const METHOD: &str = "agent.chat.perf";
pub(super) const MAX_SECONDS: u64 = 60;
pub(super) const DEFAULT_SECONDS: u64 = 5;
/// The app answers within the capture plus 15 s; the CLI waits a little longer.
const MARGIN: Duration = Duration::from_secs(20);

/// `rest` starts with `chat`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control.chat_perf;
    if rest.get(1).map(String::as_str) != Some("perf") {
        return Err(UsageError::new(messages.usage));
    }
    let options = Options::parse(&rest[2..], &["tab", "seconds"], &[])?;
    let Some(tab) = options.value("tab").filter(|tab| !tab.is_empty()) else {
        return Err(UsageError::new(messages.usage));
    };
    let seconds = match options.value("seconds") {
        None => DEFAULT_SECONDS,
        Some(value) => value
            .parse::<u64>()
            .ok()
            .filter(|seconds| (1..=MAX_SECONDS).contains(seconds))
            .ok_or_else(|| UsageError::new(messages.seconds))?,
    };
    Ok(AppCommand::ChatPerf { params: json!({ "tab": tab, "seconds": seconds }), seconds })
}

/// Calls `agent.chat.perf` and prints its report (`--json`) or the summary.
pub(super) fn run(global: &GlobalArgs, stream: &mut UnixStream, params: Value, seconds: u64) -> i32 {
    let timeout = Duration::from_secs(seconds) + MARGIN;
    match super::wait::request(global, stream, METHOD, &params, Some(timeout)) {
        Ok(Ok(report)) => match global.output {
            OutputMode::Human => {
                print!("{}", human(&report, &crate::localization::catalog().app_control));
                0
            }
            _ => super::super::wire::print_local_success(&report, global.output),
        },
        Ok(Err(mut error)) => {
            if super::error_code(&error) == Some("method_not_found") {
                super::skew::annotate(stream, METHOD, &mut error);
            }
            super::super::wire::print_local_error(&error, global.output, 1)
        }
        Err(error) => super::super::wire::print_local_error(&error, global.output, 3),
    }
}

fn number(value: &Value, path: &[&str]) -> String {
    let mut at = value;
    for key in path {
        at = &at[*key];
    }
    match at {
        Value::Number(number) => number.to_string(),
        Value::String(text) => text.clone(),
        _ => "0".into(),
    }
}

fn fill(template: &str, pairs: &[(&str, String)]) -> String {
    pairs.iter().fold(template.to_owned(), |text, (name, value)| text.replace(&format!("{{{name}}}"), value))
}

/// The summary `cmux app chat perf` prints without `--json`.
pub(super) fn human(report: &Value, catalog: &AppControlMessages) -> String {
    let messages = &catalog.chat_perf;
    let mut out = String::new();
    let _ = writeln!(
        out,
        "{}",
        fill(
            messages.header,
            &[
                ("tab", number(report, &["tab"])),
                ("seconds", number(report, &["seconds"])),
                ("visibility", number(report, &["visibility", "end"])),
            ],
        )
    );
    match report["unmeasured_reason"].as_str() {
        Some("page_hidden") => {
            let _ = writeln!(out, "{}", messages.page_hidden);
            return out;
        }
        Some(_) => {
            let _ = writeln!(out, "{}", messages.no_frames);
            return out;
        }
        None => {}
    }
    let frames = &report["frames"];
    let _ = writeln!(
        out,
        "{}",
        fill(
            messages.frames,
            &[
                ("count", number(frames, &["count"])),
                ("p50", number(frames, &["interval_p50_ms"])),
                ("p95", number(frames, &["interval_p95_ms"])),
                ("p99", number(frames, &["interval_p99_ms"])),
                ("max", number(frames, &["interval_max_ms"])),
                ("over33", number(frames, &["over_33_ms"])),
                ("over50", number(frames, &["over_50_ms"])),
            ],
        )
    );
    let long = &report["long_tasks"];
    match long["source"].as_str() {
        Some(source) => {
            let _ = writeln!(
                out,
                "{}",
                fill(
                    messages.long_tasks,
                    &[
                        ("source", source.to_owned()),
                        ("count", number(long, &["count"])),
                        ("longest", number(long, &["longest_ms"])),
                        ("blocking", number(long, &["blocking_ms"])),
                    ],
                )
            );
            for script in long["top_scripts"].as_array().into_iter().flatten().take(3) {
                let _ = writeln!(
                    out,
                    "{}",
                    fill(
                        messages.script,
                        &[
                            ("total", number(script, &["total_ms"])),
                            ("count", number(script, &["count"])),
                            ("invoker", number(script, &["invoker"])),
                            ("source", number(script, &["source_url"])),
                        ],
                    )
                    .trim_end()
                );
            }
        }
        None => {
            let _ = writeln!(out, "{}", messages.long_tasks_unsupported);
        }
    }
    let _ = writeln!(
        out,
        "{}",
        fill(
            messages.layout_shift,
            &[
                ("sum", number(report, &["layout_shift", "sum"])),
                ("count", number(report, &["layout_shift", "count"])),
            ],
        )
    );
    let records = &report["records"];
    let _ = writeln!(out, "{}", messages.records);
    let mut any = false;
    for kind in ["tool_call", "tool_call_update", "agent_message_chunk", "other"] {
        let group = &records[kind];
        if group["count"].as_u64().unwrap_or(0) == 0 {
            continue;
        }
        any = true;
        let _ = writeln!(
            out,
            "{}",
            fill(
                messages.record,
                &[
                    ("kind", kind.to_owned()),
                    ("count", number(group, &["count"])),
                    ("p50", number(group, &["to_paint", "p50_ms"])),
                    ("p95", number(group, &["to_paint", "p95_ms"])),
                    ("max", number(group, &["to_paint", "max_ms"])),
                    ("apply", number(group, &["apply", "max_ms"])),
                ],
            )
        );
    }
    if !any {
        let _ = writeln!(out, "{}", messages.no_records);
    }
    if records["unpainted"].as_u64().unwrap_or(0) > 0 {
        let _ = writeln!(
            out,
            "{}",
            fill(messages.unpainted, &[("count", number(records, &["unpainted"]))])
        );
    }
    out
}

#[cfg(test)]
#[path = "chat_perf_tests.rs"]
mod tests;
