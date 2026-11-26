//! A finished recording as product feedback (Swift `PhoneFeedbackClip`): one
//! Markdown message plus the files to attach. The app passes its localized
//! strings (defaults below are the English ones) and the folder's URL.
use serde::{Deserialize, Serialize};

use crate::log_tail::LogLine;
use crate::recording::{PhonePoint, Recording, RecordingEvent};

/// The localized pieces of the summary. `inputs` is a format with two
/// integers (`%lld`, or positional `%1$lld` / `%2$lld`): inputs, then taps.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Strings {
    pub title: String,
    pub inputs: String,
    pub steps: String,
    pub log_errors: String,
    pub folder: String,
}

impl Default for Strings {
    fn default() -> Self {
        Strings {
            title: "Phone feedback".into(),
            inputs: "%lld inputs, %lld taps".into(),
            steps: "Steps:".into(),
            log_errors: "Log errors:".into(),
            folder: "Recording folder:".into(),
        }
    }
}

/// The most steps listed; more end in "- …".
pub const STEP_LIMIT: usize = 30;

/// The summary and the attachments, by file name inside the recording's folder.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Clip {
    pub markdown: String,
    /// The video first, then the poster frame when there is one.
    pub attachments: Vec<String>,
}

/// `0:07.4`: minutes, seconds and tenths.
pub fn clock(seconds: f64) -> String {
    let tenths = (seconds * 10.0).round() as i64;
    format!("{}:{:02}.{}", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

/// `String(format:)` with integer arguments: `%lld`/`%d` in turn, `%N$lld`
/// by position, `%%` as a percent sign.
fn format_integers(format: &str, values: &[i64]) -> String {
    let mut out = String::new();
    let mut next = 0;
    let mut rest = format;
    while let Some(start) = rest.find('%') {
        out.push_str(&rest[..start]);
        let spec = &rest[start + 1..];
        if let Some(after) = spec.strip_prefix('%') {
            out.push('%');
            rest = after;
            continue;
        }
        let digits = spec.bytes().take_while(u8::is_ascii_digit).count();
        let (position, body) = match spec[digits..].strip_prefix('$') {
            Some(body) if digits > 0 => (spec[..digits].parse::<usize>().ok(), body),
            _ => (None, spec),
        };
        let length = ["lld", "ld", "d"].into_iter().find(|conversion| body.starts_with(conversion));
        let Some(length) = length else {
            out.push('%');
            rest = spec;
            continue;
        };
        let index = position.map_or_else(
            || {
                next += 1;
                next - 1
            },
            |position| position.saturating_sub(1),
        );
        out.push_str(&values.get(index).copied().unwrap_or(0).to_string());
        rest = &body[length.len()..];
    }
    out.push_str(rest);
    out
}

fn point(point: Option<PhonePoint>) -> String {
    point.map(|p| format!("({}, {})", p.x as i64, p.y as i64)).unwrap_or_default()
}

fn describe(event: &RecordingEvent) -> String {
    match event.kind.as_str() {
        "tap" => format!("tap {}", point(event.point)),
        "swipe" => format!("swipe {} → {}", point(event.point), point(event.to)),
        _ => match &event.detail {
            Some(detail) => format!("{} `{detail}`", event.kind),
            None => event.kind.clone(),
        },
    }
}

/// The clip for `recording`. `log` is the log tail (see [`crate::log_tail`]);
/// `folder_url` the recording folder's URL, linked under the recording's id.
pub fn clip(recording: &Recording, log: &[LogLine], folder_url: &str, strings: &Strings) -> Clip {
    let device = &recording.device;
    let taps = recording.events.iter().filter(|event| event.kind == "tap").count();
    let mut lines: Vec<String> = Vec::new();
    lines.push(format!(
        "**{}**: {} ({}, {}) · {} · {}",
        strings.title,
        device.name,
        device.model,
        device.os_version,
        clock(recording.duration),
        format_integers(&strings.inputs, &[recording.events.len() as i64, taps as i64])
    ));
    let notes = recording.notes.trim();
    if !notes.is_empty() {
        lines.push(String::new());
        lines.push(notes.to_owned());
    }
    if !recording.events.is_empty() {
        lines.push(String::new());
        lines.push(strings.steps.clone());
        for event in recording.events.iter().take(STEP_LIMIT) {
            lines.push(format!("- {} {}", clock(event.at), describe(event)));
        }
        if recording.events.len() > STEP_LIMIT {
            lines.push("- …".into());
        }
    }
    if !log.is_empty() {
        lines.push(String::new());
        lines.push(strings.log_errors.clone());
        lines.push("```".into());
        for line in log {
            lines.push(format!("[{}] {}: {}", line.level, line.process, line.message));
        }
        lines.push("```".into());
    }
    lines.push(String::new());
    lines.push(format!("{} [{}]({folder_url})", strings.folder, recording.id));
    let mut attachments = vec![recording.video.clone()];
    attachments.extend(recording.poster.clone());
    Clip { markdown: lines.join("\n"), attachments }
}
