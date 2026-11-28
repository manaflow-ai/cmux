//! `cmux app chat memory [--empty-tab <tab>] [--empty-bytes <n>]`: the memory of each open agent
//! chat's web content process, the app's and the daemons' own, and each chat's ratio against an
//! empty chat's page. Read live from the running app, on request: nothing here keeps a timer, a
//! sampler or a cache between runs.
//!
//! The app's `agent.chat.memory` only hands over process ids (the app, its local daemons, and per
//! open chat the pid of its WebKit WebContent process, or null when the page has none). This module
//! reads each distinct pid's footprint once (macOS `phys_footprint` through `proc_pid_rusage`,
//! the number Activity Monitor calls Memory; other systems report resident size and say so in
//! `metric`) and does the arithmetic in [`report`]: chats that share one WebContent process are
//! grouped by pid and the process is counted once in every total.
//!
//! The empty chat's page, in order: `--empty-bytes <n>` (a footprint measured elsewhere),
//! `--empty-tab <tab>` (a chat the person named), else a New Tab page (a chat with nothing in it)
//! that has its WebContent process to itself. Without one the ratios are null and `empty` says why.
//! A shared process is no baseline: it holds other pages' memory too.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};

use super::super::OutputMode;
use super::{AppCommand, GlobalArgs, Options, UsageError};
use crate::localization::ChatMemoryMessages;

/// The app method (AgentChatMemoryControl.swift registers it in every build).
pub(super) const METHOD: &str = "agent.chat.memory";
const TIMEOUT: Duration = Duration::from_secs(10);

/// What the footprint is: the figure `cmux_tui_platform` reports as memory.
#[cfg(target_os = "macos")]
const METRIC: &str = "phys_footprint";
#[cfg(not(target_os = "macos"))]
const METRIC: &str = "rss";

/// `rest` starts with `chat` and `memory`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control.chat_memory;
    let options =
        Options::parse(rest.get(2..).unwrap_or_default(), &["empty-tab", "empty-bytes"], &[])?;
    let mut empty = serde_json::Map::new();
    if let Some(tab) = options.value("empty-tab") {
        if tab.is_empty() {
            return Err(UsageError::new(messages.usage));
        }
        empty.insert("tab".into(), json!(tab));
    }
    if let Some(bytes) = options.value("empty-bytes") {
        let bytes: u64 = bytes.parse().map_err(|_| UsageError::new(messages.usage))?;
        empty.insert("bytes".into(), json!(bytes));
    }
    Ok(AppCommand::ChatMemory { empty: Value::Object(empty) })
}

/// Asks the app for the pids, reads their footprints, prints the report (`--json`) or the summary.
pub(super) fn run(global: &GlobalArgs, stream: &mut UnixStream, empty: &Value) -> i32 {
    let handover = match super::wait::request(global, stream, METHOD, &json!({}), Some(TIMEOUT)) {
        Ok(Ok(handover)) => handover,
        Ok(Err(mut error)) => {
            if super::error_code(&error) == Some("method_not_found") {
                super::skew::annotate(stream, METHOD, &mut error);
            }
            return super::super::wire::print_local_error(&error, global.output, 1);
        }
        Err(error) => return super::super::wire::print_local_error(&error, global.output, 3),
    };
    let report = report(&handover, empty, &read_footprint);
    match global.output {
        OutputMode::Human => {
            print!("{}", human(&report, &crate::localization::catalog().app_control.chat_memory));
            0
        }
        _ => super::super::wire::print_local_success(&report, global.output),
    }
}

/// One process's footprint, read now; `None` when it is gone.
fn read_footprint(pid: u32) -> Option<u64> {
    cmux_tui_platform::process_resources::sample_process(pid).map(|sample| sample.memory_bytes)
}

fn pid_of(value: &Value) -> Option<u32> {
    value.as_u64().filter(|pid| *pid > 0).and_then(|pid| u32::try_from(pid).ok())
}

fn round4(value: f64) -> f64 {
    (value * 10_000.0).round() / 10_000.0
}

/// The median of a non-empty list of ratios.
fn median(sorted: &[f64]) -> f64 {
    let middle = sorted.len() / 2;
    if sorted.len() % 2 == 1 { sorted[middle] } else { (sorted[middle - 1] + sorted[middle]) / 2.0 }
}

/// The report: the app's `handover` (`app_pid`, `daemon_pids`, `chats[{tab, machine, pid,
/// new_tab, frozen}]`), `empty` (`tab`, `bytes` from the command line) and `footprint`, which
/// reads one pid. `footprint` is called once per distinct pid, however many chats share it.
pub(super) fn report(
    handover: &Value,
    empty: &Value,
    footprint: &dyn Fn(u32) -> Option<u64>,
) -> Value {
    let chats = handover["chats"].as_array().map(Vec::as_slice).unwrap_or_default();

    // Group chats by their WebContent pid. A pid is read once and counted once.
    let mut by_pid: BTreeMap<u32, Vec<&Value>> = BTreeMap::new();
    for chat in chats {
        if let Some(pid) = pid_of(&chat["pid"]) {
            by_pid.entry(pid).or_default().push(chat);
        }
    }
    let bytes_of: BTreeMap<u32, Option<u64>> =
        by_pid.keys().map(|pid| (*pid, footprint(*pid))).collect();
    let tabs_of = |pid: u32| -> Vec<&str> {
        let mut tabs: Vec<&str> =
            by_pid[&pid].iter().filter_map(|chat| chat["tab"].as_str()).collect();
        tabs.sort_unstable();
        tabs
    };
    let alone = |pid: u32| by_pid[&pid].len() == 1;

    // The empty chat's page.
    let empty_chat = |chat: &Value| -> Option<(u32, Option<u64>)> {
        let pid = pid_of(&chat["pid"])?;
        Some((pid, bytes_of[&pid]))
    };
    let named_tab = empty["tab"].as_str();
    let (baseline, empty_json) = if let Some(bytes) = empty["bytes"].as_u64() {
        (Some(bytes), json!({"source": "bytes", "footprint_bytes": bytes}))
    } else if let Some(tab) = named_tab {
        match chats.iter().find(|chat| chat["tab"] == tab).and_then(empty_chat) {
            None => (None, json!({"source": "tab", "tab": tab, "reason": "no_page"})),
            Some((pid, _)) if !alone(pid) => {
                (None, json!({"source": "tab", "tab": tab, "pid": pid, "reason": "shared_process"}))
            }
            Some((pid, None)) => {
                (None, json!({"source": "tab", "tab": tab, "pid": pid, "reason": "unreadable"}))
            }
            Some((pid, Some(bytes))) => (
                Some(bytes),
                json!({"source": "tab", "tab": tab, "pid": pid, "footprint_bytes": bytes}),
            ),
        }
    } else {
        let found = chats
            .iter()
            .filter(|chat| chat["new_tab"] == true)
            .filter_map(|chat| Some((chat, empty_chat(chat)?)))
            .find(|(_, (pid, bytes))| alone(*pid) && bytes.is_some());
        match found {
            Some((chat, (pid, Some(bytes)))) => (
                Some(bytes),
                json!({"source": "new_tab", "tab": chat["tab"], "pid": pid, "footprint_bytes": bytes}),
            ),
            _ => (None, json!({"source": null, "reason": "no_empty_chat"})),
        }
    };
    let empty_pid = empty_json["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok());
    let ratio_of = |bytes: Option<u64>| -> Value {
        match (bytes, baseline) {
            (Some(bytes), Some(base)) if base > 0 => json!(round4(bytes as f64 / base as f64)),
            _ => Value::Null,
        }
    };

    let chat_rows: Vec<Value> = chats
        .iter()
        .map(|chat| {
            let Some(pid) = pid_of(&chat["pid"]) else {
                return json!({
                    "tab": chat["tab"], "machine": chat["machine"], "pid": null,
                    "footprint_bytes": null, "shared": false, "shared_with": [],
                    "ratio": null, "frozen": chat["frozen"],
                });
            };
            let bytes = bytes_of[&pid];
            let shared_with: Vec<&str> =
                tabs_of(pid).into_iter().filter(|tab| Some(*tab) != chat["tab"].as_str()).collect();
            json!({
                "tab": chat["tab"], "machine": chat["machine"], "pid": pid,
                "footprint_bytes": bytes, "shared": !shared_with.is_empty(),
                "shared_with": shared_with, "ratio": ratio_of(bytes), "frozen": chat["frozen"],
            })
        })
        .collect();

    let processes: Vec<Value> = by_pid
        .keys()
        .map(|pid| json!({"pid": pid, "footprint_bytes": bytes_of[pid], "tabs": tabs_of(*pid)}))
        .collect();
    let web_total: u64 = bytes_of.values().flatten().sum();
    let shared_processes = by_pid.keys().filter(|pid| !alone(**pid)).count();

    // The headline ratio is over processes (each once) that hold at least one chat with
    // content, never the baseline's own process or a New Tab page's.
    let mut ratios: Vec<f64> = by_pid
        .iter()
        .filter(|(pid, tabs)| {
            Some(**pid) != empty_pid && tabs.iter().any(|chat| chat["new_tab"] != true)
        })
        .filter_map(|(pid, _)| match (bytes_of[pid], baseline) {
            (Some(bytes), Some(base)) if base > 0 => Some(bytes as f64 / base as f64),
            _ => None,
        })
        .collect();
    ratios.sort_by(f64::total_cmp);
    let (ratio_median, ratio_max) = match ratios.last() {
        Some(max) => (json!(round4(median(&ratios))), json!(round4(*max))),
        None => (Value::Null, Value::Null),
    };

    let own = |pid: &Value| {
        let pid = pid_of(pid);
        json!({"pid": pid, "footprint_bytes": pid.and_then(footprint)})
    };
    json!({
        "metric": METRIC,
        "app": own(&handover["app_pid"]),
        "daemons": handover["daemon_pids"].as_array().map(Vec::as_slice).unwrap_or_default()
            .iter().map(own).collect::<Vec<_>>(),
        "empty": empty_json,
        "chats": chat_rows,
        "processes": processes,
        "summary": {
            "chats": chats.len(),
            "chats_with_page": chats.iter().filter(|chat| pid_of(&chat["pid"]).is_some()).count(),
            "web_processes": by_pid.len(),
            "shared_processes": shared_processes,
            "web_total_bytes": web_total,
            "ratio_median": ratio_median,
            "ratio_max": ratio_max,
        },
    })
}

fn megabytes(value: &Value) -> String {
    value
        .as_u64()
        .map_or_else(|| "?".to_owned(), |bytes| format!("{:.1} MB", bytes as f64 / 1_048_576.0))
}

fn fill(template: &str, pairs: &[(&str, String)]) -> String {
    pairs.iter().fold(template.to_owned(), |text, (name, value)| {
        text.replace(&format!("{{{name}}}"), value)
    })
}

/// The summary `cmux app chat memory` prints without `--json`.
pub(super) fn human(report: &Value, messages: &ChatMemoryMessages) -> String {
    let text = |value: &Value| value.as_str().unwrap_or("?").to_owned();
    let number = |value: &Value| value.as_u64().map_or_else(|| "?".to_owned(), |n| n.to_string());
    let ratio =
        |value: &Value| value.as_f64().map_or_else(|| "-".to_owned(), |r| format!("{r:.2}x"));
    let mut out = String::new();
    let _ = writeln!(out, "{}", fill(messages.metric, &[("metric", text(&report["metric"]))]));
    let _ = writeln!(
        out,
        "{}",
        fill(
            messages.app,
            &[
                ("pid", number(&report["app"]["pid"])),
                ("size", megabytes(&report["app"]["footprint_bytes"]))
            ],
        )
    );
    for daemon in report["daemons"].as_array().into_iter().flatten() {
        let _ = writeln!(
            out,
            "{}",
            fill(
                messages.daemon,
                &[("pid", number(&daemon["pid"])), ("size", megabytes(&daemon["footprint_bytes"]))],
            )
        );
    }
    let empty = &report["empty"];
    if empty["footprint_bytes"].is_null() {
        let _ =
            writeln!(out, "{}", fill(messages.empty_none, &[("reason", text(&empty["reason"]))]));
    } else {
        let _ = writeln!(
            out,
            "{}",
            fill(messages.empty, &[("size", megabytes(&empty["footprint_bytes"]))])
        );
    }
    if report["chats"].as_array().is_none_or(Vec::is_empty) {
        let _ = writeln!(out, "{}", messages.no_chats);
    }
    for chat in report["chats"].as_array().into_iter().flatten() {
        if chat["pid"].is_null() {
            let _ =
                writeln!(out, "{}", fill(messages.chat_no_page, &[("tab", text(&chat["tab"]))]));
            continue;
        }
        let template = if chat["shared"] == true { messages.chat_shared } else { messages.chat };
        let _ = writeln!(
            out,
            "{}",
            fill(
                template,
                &[
                    ("tab", text(&chat["tab"])),
                    ("pid", number(&chat["pid"])),
                    ("size", megabytes(&chat["footprint_bytes"])),
                    ("ratio", ratio(&chat["ratio"])),
                    ("others", number(&json!(chat["shared_with"].as_array().map_or(0, Vec::len)))),
                ],
            )
        );
    }
    let summary = &report["summary"];
    let _ = writeln!(
        out,
        "{}",
        fill(
            messages.summary,
            &[
                ("processes", number(&summary["web_processes"])),
                ("shared", number(&summary["shared_processes"])),
                ("total", megabytes(&summary["web_total_bytes"])),
                ("median", ratio(&summary["ratio_median"])),
                ("max", ratio(&summary["ratio_max"])),
            ],
        )
    );
    out
}

#[cfg(test)]
#[path = "chat_memory_tests.rs"]
mod tests;
