//! `cmux app launch-times [--limit <n>] [--file <path>]`: the app's last launches, as each one
//! recorded itself (CMUX-571).
//!
//! The launch marks (`main_start`, `first_window_frame_committed`, `home.first_page`, ...) live in
//! the app's memory, and `debug.timings` answers only in a debug build, so a release or NIGHTLY
//! launch could not be read after the fact. Every build now appends one JSON line per launch to
//! `~/Library/Application Support/<bundle id>/launch-times.jsonl` (CmuxNextControl's
//! `LaunchTimesFile`, at most 50 lines), and this reads it: no app connection, so it works with the
//! app quit, in every build. The bundle id is the one around this CLI, or `CMUX_BUNDLE_ID`.

use std::io::Read as _;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::{AppCommand, GlobalArgs, Options, OutputMode, UsageError};
use crate::app_identity::AppIdentity;

/// The file's name in the app's folder of Application Support (`LaunchTimesFile.fileName`).
pub(super) const FILE_NAME: &str = "launch-times.jsonl";
/// More than the app's 50 records can be: a read never takes more (`LaunchTimesFile.maximumBytes`).
pub(super) const MAX_BYTES: u64 = 256 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct Command {
    /// Only the newest `limit` launches.
    pub limit: Option<usize>,
    /// Another file than the app's.
    pub file: Option<PathBuf>,
    /// Each row's launch phases on a line under it (the human view; JSON always has them).
    pub phases: bool,
}

/// `rest` starts with `launch-times`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let usage = || UsageError::new(crate::localization::catalog().app_control.launch_times.usage);
    let options =
        Options::parse(rest.get(1..).unwrap_or_default(), &["limit", "file"], &["phases"])
            .map_err(|_| usage())?;
    let limit = match options.value("limit") {
        Some(text) => {
            Some(text.parse::<usize>().ok().filter(|limit| *limit > 0).ok_or_else(usage)?)
        }
        None => None,
    };
    Ok(AppCommand::LaunchTimes(Command {
        limit,
        file: options.value("file").map(PathBuf::from),
        phases: options.flag("phases"),
    }))
}

/// The app's file: `<home>/Library/Application Support/<bundle id>/launch-times.jsonl`, for the app
/// `env` and `exe` name ([`AppIdentity::detect`]); `None` outside any cmux app.
pub(super) fn default_path(
    env: impl Fn(&str) -> Option<String>,
    exe: Option<&Path>,
    home: &Path,
) -> Option<PathBuf> {
    let bundle_id = AppIdentity::detect(env, exe)?.bundle_id?;
    Some(home.join("Library").join("Application Support").join(bundle_id).join(FILE_NAME))
}

/// The records in `path`, oldest first, the newest `limit` of them; a missing file has none. At most
/// [`MAX_BYTES`] are read; a line that is not a JSON object is skipped.
pub(super) fn read(path: &Path, limit: Option<usize>) -> std::io::Result<Vec<Value>> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut bytes = Vec::new();
    file.take(MAX_BYTES).read_to_end(&mut bytes)?;
    let mut records: Vec<Value> = String::from_utf8_lossy(&bytes)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .collect();
    if let Some(limit) = limit {
        let skip = records.len().saturating_sub(limit);
        records.drain(..skip);
    }
    Ok(records)
}

/// The row's launch phases (its `phases` object: mark name to ms since process start) in the order
/// they came, each with its step from the one before: `phases: dfl.menu=130.6 (+10.5)  ...`. `None`
/// for a row without phases (one written before the app recorded them).
pub(super) fn phase_line(record: &Value) -> Option<String> {
    let mut phases: Vec<(&str, f64)> = record
        .get("phases")?
        .as_object()?
        .iter()
        .filter_map(|(name, ms)| Some((name.as_str(), ms.as_f64()?)))
        .collect();
    if phases.is_empty() {
        return None;
    }
    phases.sort_by(|a, b| a.1.total_cmp(&b.1).then(a.0.cmp(b.0)));
    let shown = |ms: f64| {
        let ms = (ms * 10.0).round() / 10.0;
        if ms.fract() == 0.0 { format!("{ms:.0}") } else { format!("{ms:.1}") }
    };
    let mut before = 0.0;
    let cells: Vec<String> = phases
        .into_iter()
        .map(|(name, ms)| {
            let step = ms - before;
            before = ms;
            format!("{name}={} (+{})", shown(ms), shown(step))
        })
        .collect();
    Some(format!("  phases: {}", cells.join("  ")))
}

/// One row per launch under the record's own key names. The prior chat's columns (CMUX-119) are `-`
/// for a launch whose restored front tab was not an agent chat. With `phases`, each row that has
/// them is followed by its [`phase_line`].
pub(super) fn table(records: &[Value], phases: bool) -> String {
    const HEADER: [&str; 16] = [
        "started_at",
        "build",
        "commit",
        "pre_main_ms",
        "main_ms",
        "first_window_frame_ms",
        "home_first_page_ms",
        "home_revealed_by",
        "window_usable_ms",
        "first_shell_live_ms",
        "no_snapshot",
        "prior_chat_painted_ms",
        "prior_chat_live_ms",
        "prewarmed",
        "prewarm_reason",
        "first_launch_of_build",
    ];
    let cell = |record: &Value, key: &str| -> String {
        match record.get(key) {
            None | Some(Value::Null) => "-".to_owned(),
            Some(Value::String(text)) if key == "commit" => text.chars().take(8).collect(),
            Some(Value::String(text)) if key == "build" => {
                let version = record.get("version").and_then(Value::as_str).unwrap_or_default();
                if version.is_empty() { text.clone() } else { format!("{version} ({text})") }
            }
            Some(Value::String(text)) => text.clone(),
            Some(Value::Bool(flag)) => if *flag { "yes" } else { "no" }.to_owned(),
            Some(other) => other.to_string(),
        }
    };
    let rows: Vec<Vec<String>> =
        std::iter::once(HEADER.iter().map(|key| (*key).to_owned()).collect())
            .chain(
                records.iter().map(|record| HEADER.iter().map(|key| cell(record, key)).collect()),
            )
            .collect();
    let widths: Vec<usize> = (0..HEADER.len())
        .map(|column| {
            rows.iter()
                .filter_map(|row| row.get(column))
                .map(|text| text.chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for (index, row) in rows.iter().enumerate() {
        let line: Vec<String> =
            row.iter().zip(&widths).map(|(text, width)| format!("{text:<width$}")).collect();
        out.push_str(line.join("  ").trim_end());
        out.push('\n');
        let record = index.checked_sub(1).and_then(|index| records.get(index));
        if let Some(extra) = record.filter(|_| phases).and_then(phase_line) {
            out.push_str(&extra);
            out.push('\n');
        }
    }
    out
}

pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let messages = &crate::localization::catalog().app_control.launch_times;
    let path = command.file.clone().or_else(|| {
        let home = std::env::var_os("HOME").filter(|home| !home.is_empty())?;
        let exe = std::env::current_exe().ok().and_then(|path| path.canonicalize().ok());
        default_path(|key| std::env::var(key).ok(), exe.as_deref(), Path::new(&home))
    });
    let Some(path) = path else {
        let error = json!({ "code": "app.not_found", "message": messages.no_app });
        return super::super::wire::print_local_error(&error, global.output, 2);
    };
    let shown = path.display().to_string();
    let records = match read(&path, command.limit) {
        Ok(records) => records,
        Err(error) => {
            let message = messages
                .unreadable
                .replace("{path}", &shown)
                .replace("{error}", &error.to_string());
            let error = json!({ "code": "launch_times.unreadable", "message": message });
            return super::super::wire::print_local_error(&error, global.output, 3);
        }
    };
    match global.output {
        OutputMode::Human if records.is_empty() => {
            println!("{}", messages.empty.replace("{path}", &shown));
            0
        }
        OutputMode::Human => {
            print!("{}", table(&records, command.phases));
            0
        }
        _ => super::super::wire::print_local_success(
            &json!({ "path": shown, "launches": records }),
            global.output,
        ),
    }
}

#[cfg(test)]
#[path = "launch_times_tests.rs"]
mod tests;
