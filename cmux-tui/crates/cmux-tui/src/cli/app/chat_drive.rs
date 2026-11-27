//! `cmux app chat drive --tab <tab> [--hover <test-id> | --hover-sent-image <n> |
//! --hover-tool-screenshot <n>] [--wheel <ticks> [--delta <px>] [--tick-ms <ms>]] [--hold-ms <ms>]
//! [--type <text> [--over-draft]] [--allow-busy] [--seconds <1-30>]`: rests a pointer on one
//! element of one chat page, wheels its transcript under that pointer and optionally types into
//! its composer, in the running app (Release and Nightly too), and reports what the page did on
//! each frame meanwhile: composer renders and DOM mutations, focus, `:focus-within` and
//! `data-page-inactive` flips, hover and hover card state, frame times.
//!
//! The app's `agent.chat.drive` (AgentChatDriveControl.swift) gives the page engine-level input
//! (WebKit gets events handed to its view, Chromium DevTools input), so the page gets a real
//! `:hover` and trusted wheel events while the system pointer stays where it is, and the window is
//! never focused, raised or shown. It is a fixed set of actions, never a script. It refuses a chat
//! whose turn is running unless `--allow-busy`, and typing into a non-empty draft unless
//! `--over-draft`. Typed text stays in the draft: nothing is restored. The page's counters exist
//! only for the run (webviews chatDrive.ts).

use std::fmt::Write as _;
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Map, Value, json};
use unicode_segmentation::UnicodeSegmentation as _;

use super::super::OutputMode;
use super::{AppCommand, GlobalArgs, Options, UsageError};
use crate::localization::AppControlMessages;

/// The app method (AgentChatDriveControl.swift registers it in every build).
pub(super) const METHOD: &str = "agent.chat.drive";
pub(super) const MAX_SECONDS: u64 = 30;
pub(super) const DEFAULT_SECONDS: u64 = 10;
pub(super) const MAX_TICKS: u64 = 200;
pub(super) const MAX_DELTA: i64 = 2000;
pub(super) const DEFAULT_DELTA: i64 = 100;
pub(super) const TICK_MS: (u64, u64) = (8, 200);
pub(super) const MAX_HOLD_MS: u64 = 10_000;
pub(super) const MAX_TEXT: usize = 500;
pub(super) const MAX_TEXT_UTF16: usize = 2000;
/// The highest --hover-sent-image or --hover-tool-screenshot position, as the app bounds it.
pub(super) const MAX_IMAGE_INDEX: u64 = 10_000;
/// The app answers within the run plus 15 s; the CLI waits a little longer.
const MARGIN: Duration = Duration::from_secs(20);

const VALUED: &[&str] = &[
    "tab",
    "hover",
    "hover-sent-image",
    "hover-tool-screenshot",
    "wheel",
    "delta",
    "tick-ms",
    "hold-ms",
    "type",
    "seconds",
];
const FLAGS: &[&str] = &["allow-busy", "over-draft"];

fn whole(
    value: Option<&str>,
    range: (u64, u64),
    error: &'static str,
) -> Result<Option<u64>, UsageError> {
    value
        .map(|value| {
            value
                .parse::<u64>()
                .ok()
                .filter(|number| (range.0..=range.1).contains(number))
                .ok_or_else(|| UsageError::new(error))
        })
        .transpose()
}

/// `--type` text the app takes by length: 1 to 500 characters as the app and the page count them
/// (graphemes: an emoji with a skin tone is one), and at most 2000 UTF-16 units.
pub(super) fn fits(text: &str) -> bool {
    (1..=MAX_TEXT).contains(&text.graphemes(true).count())
        && text.encode_utf16().count() <= MAX_TEXT_UTF16
}

/// `--type` text the app types as a person's keys (AgentChatDriveControl.Params.isTypable): no C0 or C1
/// control character (DEL too), no line or paragraph separator, and no `!` first after any spaces, which
/// in an empty draft would start a shell command. The CLI refuses what the app would; the cases are
/// cmux-tui/spec/fixtures/chat-drive-type-text.json, checked on both sides.
pub(super) fn typable(text: &str) -> bool {
    let control = text.chars().any(|c| {
        let c = u32::from(c);
        c < 0x20 || (0x7F..=0x9F).contains(&c) || c == 0x2028 || c == 0x2029
    });
    !control && !text.trim_start_matches(char::is_whitespace).starts_with('!')
}

/// `rest` starts with `chat`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control.chat_drive;
    if rest.get(1).map(String::as_str) != Some("drive") {
        return Err(UsageError::new(messages.usage));
    }
    let options = Options::parse(rest.get(2..).unwrap_or_default(), VALUED, FLAGS)?;
    let Some(tab) = options.value("tab").filter(|tab| !tab.is_empty()) else {
        return Err(UsageError::new(messages.usage));
    };
    let mut params = Map::new();
    params.insert("tab".into(), json!(tab));

    let test_id = options.value("hover").filter(|id| !id.is_empty());
    let sent = whole(options.value("hover-sent-image"), (1, MAX_IMAGE_INDEX), messages.nth)?;
    let tool = whole(options.value("hover-tool-screenshot"), (1, MAX_IMAGE_INDEX), messages.nth)?;
    let target = match (test_id, sent, tool) {
        (None, None, None) => None,
        (Some(id), None, None) => Some(json!({ "test_id": id })),
        (None, Some(n), None) => Some(json!({ "sent_image": n })),
        (None, None, Some(n)) => Some(json!({ "tool_screenshot": n })),
        _ => return Err(UsageError::new(messages.one_target)),
    };

    let ticks = whole(options.value("wheel"), (1, MAX_TICKS), messages.wheel)?;
    let delta = options
        .value("delta")
        .map(|value| {
            value
                .parse::<i64>()
                .ok()
                // A range check, not `abs()`: `i64::MIN` has no absolute value.
                .filter(|delta| *delta != 0 && (-MAX_DELTA..=MAX_DELTA).contains(delta))
                .ok_or_else(|| UsageError::new(messages.delta))
        })
        .transpose()?;
    let tick_ms = whole(options.value("tick-ms"), TICK_MS, messages.tick_ms)?;
    match ticks {
        // The wheel goes to the transcript under the held pointer, so it needs the pointer's element.
        Some(_) if target.is_none() => return Err(UsageError::new(messages.wheel_needs_hover)),
        Some(ticks) => {
            let mut wheel = Map::new();
            wheel.insert("ticks".into(), json!(ticks));
            wheel.insert("delta".into(), json!(delta.unwrap_or(DEFAULT_DELTA)));
            if let Some(tick_ms) = tick_ms {
                wheel.insert("tick_ms".into(), json!(tick_ms));
            }
            params.insert("wheel".into(), Value::Object(wheel));
        }
        None if delta.is_some() || tick_ms.is_some() => {
            return Err(UsageError::new(messages.wheel));
        }
        None => {}
    }

    let text = options.value("type");
    match text {
        Some(text) if !fits(text) => return Err(UsageError::new(messages.text)),
        Some(text) if !typable(text) => return Err(UsageError::new(messages.text_keys)),
        Some(text) => {
            params.insert(
                "type".into(),
                json!({ "text": text, "allow_draft": options.flag("over-draft") }),
            );
        }
        None if options.flag("over-draft") => return Err(UsageError::new(messages.usage)),
        None => {}
    }
    if target.is_none() && text.is_none() {
        // Nothing to drive: `cmux app chat perf` measures a chat left alone.
        return Err(UsageError::new(messages.nothing));
    }
    if let Some(target) = target {
        params.insert("target".into(), target);
    }
    if let Some(hold) = whole(options.value("hold-ms"), (0, MAX_HOLD_MS), messages.hold_ms)? {
        params.insert("hold_ms".into(), json!(hold));
    }
    let seconds = whole(options.value("seconds"), (1, MAX_SECONDS), messages.seconds)?
        .unwrap_or(DEFAULT_SECONDS);
    params.insert("seconds".into(), json!(seconds));
    params.insert("allow_busy".into(), json!(options.flag("allow-busy")));
    Ok(AppCommand::ChatDrive { params: Value::Object(params), seconds })
}

/// Calls `agent.chat.drive` and prints its report (`--json`) or the summary.
pub(super) fn run(
    global: &GlobalArgs,
    stream: &mut UnixStream,
    params: Value,
    seconds: u64,
) -> i32 {
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

fn text(value: &Value) -> String {
    match value {
        Value::Number(number) => number.to_string(),
        Value::String(text) => text.clone(),
        Value::Bool(flag) => flag.to_string(),
        _ => "0".into(),
    }
}

fn fill(template: &str, pairs: &[(&str, String)]) -> String {
    pairs.iter().fold(template.to_owned(), |text, (name, value)| {
        text.replace(&format!("{{{name}}}"), value)
    })
}

/// The typing line, if the run typed: a count of what it typed; a page from before that sent the
/// text itself, and the summary counts it (in graphemes, as the page does) rather than printing it.
/// A run cut off before its text was all typed (time ran out, the person typed, focus left) says how
/// much of it went in; an older page sends no `type_asked`.
fn typing(
    page: &Value,
    catalog: &AppControlMessages,
) -> Option<(&'static str, Vec<(&'static str, String)>)> {
    let messages = &catalog.chat_drive;
    let typed = match &page["typed"] {
        Value::Number(count) => count.as_u64().unwrap_or(0),
        Value::String(typed) => typed.graphemes(true).count() as u64,
        _ => 0,
    };
    match (page["type_asked"].as_u64(), page["type_stopped"].as_str()) {
        (Some(asked), Some(why)) if asked > typed => Some((
            messages.typed_cut,
            vec![
                ("count", typed.to_string()),
                ("asked", asked.to_string()),
                ("why", why.to_owned()),
            ],
        )),
        _ if typed > 0 => Some((messages.typed, vec![("count", typed.to_string())])),
        _ => None,
    }
}

/// The summary `cmux app chat drive` prints without `--json`.
pub(super) fn human(report: &Value, catalog: &AppControlMessages) -> String {
    let messages = &catalog.chat_drive;
    let page = &report["page"];
    let totals = &page["totals"];
    let mut out = String::new();
    let mut line = |template: &str, pairs: &[(&str, String)]| {
        let _ = writeln!(out, "{}", fill(template, pairs));
    };
    line(messages.header, &[("tab", text(&report["tab"])), ("engine", text(&report["engine"]))]);
    let hover = &report["hover"];
    if hover.is_object() {
        if hover["held"].as_bool() == Some(true) {
            line(messages.hover_held, &[("x", text(&hover["x"])), ("y", text(&hover["y"]))]);
        } else {
            line(messages.hover_missed, &[("reason", text(&hover["reason"]))]);
        }
    }
    let wheel = &report["wheel"];
    if wheel.is_object() {
        line(
            messages.wheel_sent,
            &[
                // An app from before `sent` counted sends as `delivered`.
                (
                    "sent",
                    text(if wheel["sent"].is_null() {
                        &wheel["delivered"]
                    } else {
                        &wheel["sent"]
                    }),
                ),
                ("ticks", text(&wheel["ticks"])),
                ("delta", text(&wheel["delta"])),
                ("seen", text(&totals["wheel_events"])),
                ("trusted", text(&totals["wheel_trusted"])),
            ],
        );
        // What the ticks really moved, against what they asked for: a dropped tick shows here.
        if wheel["scrolled"].is_number() {
            line(
                messages.wheel_scrolled,
                &[("scrolled", text(&wheel["scrolled"])), ("expected", text(&wheel["expected"]))],
            );
        }
    }
    if page["measured"].as_bool() == Some(false) {
        line(messages.unmeasured, &[("reason", text(&page["unmeasured_reason"]))]);
        // Typing goes on with no frames (a hidden or throttled chat): what went in still shows.
        if let Some((template, pairs)) = typing(page, catalog) {
            line(template, &pairs);
        }
        return out;
    }
    line(
        messages.frames,
        &[
            ("count", text(&totals["frames"])),
            ("p50", text(&totals["frame_p50_ms"])),
            ("p95", text(&totals["frame_p95_ms"])),
            ("max", text(&totals["frame_max_ms"])),
            ("over33", text(&totals["over_33_ms"])),
        ],
    );
    line(
        messages.composer,
        &[
            ("renders", text(&totals["composer_renders"])),
            ("mutations", text(&totals["composer_mutations"])),
            ("nodes", text(&totals["mutation_nodes"])),
        ],
    );
    line(
        messages.flips,
        &[
            ("focus", text(&totals["focus_flips"])),
            ("within", text(&totals["focus_within_flips"])),
            ("inactive", text(&totals["page_inactive_flips"])),
        ],
    );
    let frames = page["frames"].as_array().map(Vec::as_slice).unwrap_or_default();
    let count =
        |key: &str| frames.iter().filter(|frame| frame[key].as_bool() == Some(true)).count();
    line(
        messages.hover_frames,
        &[
            ("hovered", count("hovered").to_string()),
            ("card", count("card_open").to_string()),
            ("frames", frames.len().to_string()),
        ],
    );
    if let Some((template, pairs)) = typing(page, catalog) {
        line(template, &pairs);
    }
    match report["engine_counters"].as_object() {
        Some(counters) => {
            let pairs: Vec<String> =
                counters.iter().map(|(key, value)| format!("{key} {}", text(value))).collect();
            line(messages.engine_counters, &[("counters", pairs.join(", "))]);
        }
        None => line(
            messages.engine_counters_unavailable,
            &[("reason", text(&report["engine_counters_unavailable"]))],
        ),
    }
    out
}

#[cfg(test)]
#[path = "chat_drive_tests.rs"]
mod tests;
