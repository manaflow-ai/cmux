//! The trigger of best-of-N (RFD 0158 §3, harness magic `bestOfN`, off by default): best-of-N is
//! an escalation only, "after two red checks on one task", so this piece watches a chat's own
//! check runs (tests, builds, type checks, linters) and marks the turn whose check went red for
//! the second time in a row with no green run of it between. The mark is `bestOfN` on the
//! turn's `turn_result`: the check, how many times in a row it went red, and `due: true` on the
//! turn that crossed the line. Forking the turn N ways and keeping the attempt whose check
//! passes reads this mark; it is the next piece (`fork.rs`, Cloud forks).
//!
//! Zero model tokens and no spawn: it reads the daemon's own `tool_call` records as they pass. A
//! streak lives as long as the chat (a task's checks span turns); a green run of the same check
//! ends it. The settings file is read once a turn, at its start.
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I put
//! in fleet wide pauses, esp when this is stuff that materially improves the app".

use regex::Regex;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};

/// The feature's name in `agents.harnessMagic.<name>.enabled` and in the `turn_result` stamp.
pub(crate) const FEATURE: &str = "bestOfN";
/// Its settings switch (off unless `true`).
const SETTING_ENABLED: &str = "agents.harnessMagic.bestOfN.enabled";
/// Red runs of one check in a row that make best-of-N due (RFD 0158 §3: "after two red checks").
pub(crate) const REDS: u32 = 2;
/// Chats watched at once; past it the one watched longest ago is dropped.
const MAX_SESSIONS: usize = 256;
/// Calls remembered within one chat (a call's command arrives before its outcome).
const MAX_CALLS: usize = 1024;
/// Checks with a streak kept within one chat.
const MAX_CHECKS: usize = 64;
/// The output read from one call, from its end (a summary is printed last).
const MAX_OUTPUT_BYTES: usize = 64 << 10;
/// A check's command is kept and shown cut at this many characters.
const MAX_COMMAND_CHARS: usize = 200;

/// Whether the trigger is on, given the settings file and the kill switch's value: off unless
/// the setting is `true`; the kill switch (`ACPMUX_HM_BESTOFN=0`) turns it off.
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED))
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

/// Whether the trigger is on now.
pub(crate) fn enabled() -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    let env = std::env::var(super::harness_magic::env_key(FEATURE)).ok();
    enabled_with(doc.as_ref(), env.as_deref())
}

/// What one chat's checks did so far.
#[derive(Default, Debug)]
struct Watch {
    /// The order the chat was last touched in, to drop the oldest past [`MAX_SESSIONS`].
    touched: u64,
    /// Whether the trigger was on when the current turn started.
    on: bool,
    /// Each check call's command, by call id, until its outcome arrives.
    calls: HashMap<String, String>,
    /// Red runs in a row, by check command.
    streak: HashMap<String, u32>,
    /// This turn's check runs, red runs, and the check that crossed [`REDS`] in it.
    runs: u64,
    reds: u64,
    due: Option<(String, u32)>,
}

static WATCHES: LazyLock<Mutex<HashMap<String, Watch>>> = LazyLock::new(Default::default);
static CLOCK: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn all() -> MutexGuard<'static, HashMap<String, Watch>> {
    WATCHES.lock().unwrap_or_else(PoisonError::into_inner)
}

fn tick() -> u64 {
    CLOCK.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

static CHECK_COMMAND: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?x)\b(
            cargo\s+(\+\S+\s+)?(test|nextest|check|clippy|build)
          | cmux-ci\s+(test|compile-check)
          | pytest | python3?\s+-m\s+(pytest|unittest|mypy)
          | (npm|pnpm|yarn|bun)\s+(run\s+)?(test|typecheck|lint|build)
          | vitest | jest | playwright\s+test
          | go\s+(test|vet|build) | swift\s+(test|build) | xcodebuild\b.*\b(test|build)
          | tsc | make\s+(test|check) | bazel\s+(test|build) | ctest
          | ruff | mypy | eslint
        )\b",
    )
    .ok()
});
/// Output that says a check failed even when its call did not (a wrapper that exits 0).
static FAILED_TEXT: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"test result: FAILED|error: could not compile|cmux-ci test: FAILURE|lane-gh ci: FAILURE|Found \d+ errors?",
    )
    .ok()
});
static EXIT_LINE: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?m)^Exit code (\d+)\s*$").ok());

/// Whether `command` runs one of the project's own checks.
pub(crate) fn is_check(command: &str) -> bool {
    CHECK_COMMAND.as_ref().is_some_and(|re| re.is_match(command))
}

/// `command` on one line, cut at [`MAX_COMMAND_CHARS`]: the key one check's streak is kept by.
fn key(command: &str) -> String {
    let one_line = command.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= MAX_COMMAND_CHARS {
        return one_line;
    }
    let mut cut: String = one_line.chars().take(MAX_COMMAND_CHARS - 1).collect();
    cut.push('…');
    cut
}

/// The command a call runs: its `rawInput.command` (a string, or Codex's argv list).
fn command_of(update: &Map<String, Value>) -> Option<String> {
    match update.get("rawInput")?.get("command")? {
        Value::String(s) => Some(s.clone()),
        Value::Array(argv) => {
            let words: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            (!words.is_empty()).then(|| words.join(" "))
        }
        _ => None,
    }
}

/// The text a call returned, at most [`MAX_OUTPUT_BYTES`] from its end.
fn output_text(update: &Map<String, Value>) -> String {
    let mut out = String::new();
    let mut push = |s: &str| {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(s);
    };
    match update.get("rawOutput") {
        Some(Value::String(s)) => push(s),
        Some(Value::Object(o)) => {
            for k in ["output", "stdout", "stderr", "formatted_output", "aggregated_output"] {
                if let Some(s) = o.get(k).and_then(Value::as_str) {
                    push(s);
                }
            }
        }
        _ => {}
    }
    for item in update.get("content").and_then(Value::as_array).into_iter().flatten() {
        if let Some(s) = item.pointer("/content/text").and_then(Value::as_str) {
            push(s);
        }
    }
    if out.len() > MAX_OUTPUT_BYTES {
        let mut cut = out.len() - MAX_OUTPUT_BYTES;
        while !out.is_char_boundary(cut) {
            cut += 1;
        }
        out.drain(..cut);
    }
    out
}

/// Whether a finished check call went red: it failed, exited non-zero, or printed a failure.
fn red(update: &Map<String, Value>) -> bool {
    if update.get("status").and_then(Value::as_str) == Some("failed") {
        return true;
    }
    let output = output_text(update);
    let raw = update.get("rawOutput").and_then(Value::as_object);
    let exit = raw
        .and_then(|o| o.get("exit_code").or_else(|| o.get("exitCode")))
        .and_then(Value::as_i64)
        .or_else(|| EXIT_LINE.as_ref()?.captures(&output).and_then(|c| c[1].parse().ok()));
    exit.is_some_and(|c| c != 0) || FAILED_TEXT.as_ref().is_some_and(|re| re.is_match(&output))
}

/// Watches one record of `session`: `turn_started` starts the turn's counts (and reads the
/// switch, once a turn); a `tool_call` or `tool_call_update` of a check adds its outcome once it
/// finished. Off: nothing is kept, and a chat's streaks are dropped.
pub(super) fn record(session: &str, kind: &str, msg: &Value) {
    match kind {
        "turn_started" => begin(session, enabled()),
        "tool_call" | "tool_call_update" => watch(session, msg),
        _ => {}
    }
}

/// Starts `session`'s turn, watching only when `on`; its streaks carry over from earlier turns.
fn begin(session: &str, on: bool) {
    let mut all = all();
    if !on {
        all.remove(session);
        return;
    }
    if !all.contains_key(session) && all.len() >= MAX_SESSIONS {
        let oldest = all.iter().min_by_key(|(_, w)| w.touched).map(|(k, _)| k.clone());
        if let Some(oldest) = oldest {
            all.remove(&oldest);
        }
    }
    let w = all.entry(session.to_owned()).or_default();
    w.touched = tick();
    w.on = true;
    w.runs = 0;
    w.reds = 0;
    w.due = None;
}

/// Adds one tool record to `session`'s watch, when its turn's watch is on.
fn watch(session: &str, msg: &Value) {
    let Some(update) = msg.pointer("/params/update").and_then(Value::as_object) else { return };
    let mut all = all();
    let Some(w) = all.get_mut(session).filter(|w| w.on) else { return };
    let Some(id) = update.get("toolCallId").and_then(Value::as_str).filter(|s| !s.is_empty())
    else {
        return;
    };
    if let Some(command) = command_of(update).filter(|c| is_check(c))
        && w.calls.len() < MAX_CALLS
    {
        w.calls.insert(id.to_owned(), key(&command));
    }
    if !matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed")) {
        return;
    }
    let Some(check) = w.calls.remove(id) else { return };
    w.touched = tick();
    w.runs += 1;
    if !red(update) {
        w.streak.remove(&check);
        return;
    }
    w.reds += 1;
    if !w.streak.contains_key(&check) && w.streak.len() >= MAX_CHECKS {
        return;
    }
    let n = w.streak.entry(check.clone()).or_insert(0);
    *n += 1;
    if *n == REDS {
        w.due = Some((check, *n));
    }
}

/// Puts the turn's mark on its `turn_result`: `bestOfN` with the check that crossed [`REDS`] this
/// turn (`due: true`), or the longest red streak still open, and the feature's counters. Off, or
/// no check ran and none is red: the message is unchanged.
pub(super) fn stamp(session: &str, msg: &mut Value) {
    let mut all = all();
    let Some(w) = all.get_mut(session).filter(|w| w.on) else { return };
    stamp_watch(w, msg);
}

fn stamp_watch(w: &mut Watch, msg: &mut Value) {
    let open = w.streak.iter().max_by_key(|(c, n)| (**n, std::cmp::Reverse((*c).clone())));
    let mark = match (&w.due, open) {
        (Some((check, n)), _) => Some(json!({"due": true, "check": check, "reds": n})),
        (None, Some((check, n))) => Some(json!({"due": false, "check": check, "reds": n})),
        (None, None) => None,
    };
    let (runs, reds, due) = (w.runs, w.reds, u64::from(w.due.is_some()));
    w.runs = 0;
    w.reds = 0;
    w.due = None;
    if runs == 0 && mark.is_none() {
        return;
    }
    if let (Some(mark), Some(o)) = (mark, msg.as_object_mut()) {
        o.insert("bestOfN".into(), mark);
    }
    super::harness_magic::add_counter(msg, FEATURE, "checks", runs);
    super::harness_magic::add_counter(msg, FEATURE, "reds", reds);
    super::harness_magic::add_counter(msg, FEATURE, "due", due);
}

#[cfg(test)]
#[path = "best_of_n_tests.rs"]
mod tests;
