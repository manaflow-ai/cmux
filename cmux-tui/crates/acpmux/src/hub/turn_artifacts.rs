//! A turn's artifacts as one card (RFD 0158 §11, harness magic `artifactCard`, off by default):
//! the files the turn edited with their added and removed lines, the test commands it ran with
//! their pass and fail counts, and the pull requests it opened, gathered from the daemon's own
//! `tool_call` records as they pass ([`record`]) and put on the turn's `turn_result` as
//! `artifacts` when it settles ([`stamp`]). The chat draws the card from that one field, beside
//! the turn's before and after pictures (`turn_shots.rs`), so a person reads what a turn did
//! without opening its tool calls.
//!
//! Zero model tokens: nothing is sent to the agent. A turn that edited nothing, ran no test and
//! opened no PR gets no card. Fail open: a record it cannot read adds nothing.
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I put
//! in fleet wide pauses, esp when this is stuff that materially improves the app".

use regex::Regex;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};

/// The feature's name in `agents.harnessMagic.<name>.enabled` and in the `turn_result` stamp.
pub(crate) const FEATURE: &str = "artifactCard";
/// Its settings switch (off unless `true`).
const SETTING_ENABLED: &str = "agents.harnessMagic.artifactCard.enabled";
/// Chats with a card being gathered; past it the oldest gathering is dropped.
const MAX_SESSIONS: usize = 256;
/// Files, tests and pull requests kept on one card; past it the card says how many more.
const MAX_ITEMS: usize = 64;
/// Calls remembered within one turn (a call's command arrives before its output).
const MAX_CALLS: usize = 4096;
/// The output read from one call, from its end (a test summary is printed last).
const MAX_OUTPUT_BYTES: usize = 256 << 10;
/// A diff side larger than this is counted by its line counts, not diffed.
const MAX_DIFF_BYTES: usize = 1 << 20;
/// A command shown on the card is cut at this many characters.
const MAX_COMMAND_CHARS: usize = 200;

/// Whether the card is on, given the settings file and the kill switch's value: off unless the
/// setting is `true`; the kill switch (`ACPMUX_HM_ARTIFACTCARD=0`) turns it off.
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    if env.is_some_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "off"))
    {
        return false;
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED))
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

/// Whether the card is on now.
pub(crate) fn enabled() -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    let env = std::env::var(super::harness_magic::env_key(FEATURE)).ok();
    enabled_with(doc.as_ref(), env.as_deref())
}

/// One test command's outcome.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct TestRun {
    command: String,
    exit_code: Option<i64>,
    ok: bool,
    passed: Option<u64>,
    failed: Option<u64>,
}

/// What one turn of one chat gathered so far.
#[derive(Default, Debug)]
struct Gathering {
    /// The order the turn started in, to drop the oldest past [`MAX_SESSIONS`].
    born: u64,
    /// Whether the card was on when the turn started: the settings file is read once a turn,
    /// not on every record.
    on: bool,
    /// Each call's command (from its `rawInput`), by call id.
    commands: HashMap<String, String>,
    /// Lines added and removed, by (call id, path): a call's later record replaces its earlier one.
    edits: HashMap<(String, String), (u64, u64)>,
    /// Calls whose outcome is already on the card.
    settled: BTreeSet<String>,
    tests: Vec<TestRun>,
    prs: BTreeSet<String>,
}

static GATHERING: LazyLock<Mutex<HashMap<String, Gathering>>> = LazyLock::new(Default::default);
static BORN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn all() -> MutexGuard<'static, HashMap<String, Gathering>> {
    GATHERING.lock().unwrap_or_else(PoisonError::into_inner)
}

static TEST_COMMAND: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?x)\b(
            cargo\s+(\+\S+\s+)?(test|nextest)
          | cmux-ci\s+test
          | pytest | python3?\s+-m\s+(pytest|unittest)
          | (npm|pnpm|yarn|bun)\s+(run\s+)?test
          | vitest | jest | playwright\s+test
          | go\s+test | swift\s+test | xcodebuild\b.*\btest
          | make\s+test | bazel\s+test | ctest
        )\b",
    )
    .ok()
});
static PR_COMMAND: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)\bpr[\s_-]+create\b|\bpr_create\b").ok());
static PR_URL: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+").ok()
});
static CARGO_RESULT: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"test result: \w+\. (\d+) passed; (\d+) failed").ok());
static NEXTEST_RESULT: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(r"Summary \[[^\]]*\]\s+\d+ tests? run: (\d+) passed(?:[^,\n]*)?(?:, (\d+) failed)?")
        .ok()
});
static PASSED: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"\b(\d+) passed\b").ok());
static FAILED: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"\b(\d+) failed\b").ok());
static EXIT_LINE: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?m)^Exit code (\d+)\s*$").ok());

/// Whether `command` runs tests.
fn is_test_command(command: &str) -> bool {
    TEST_COMMAND.as_ref().is_some_and(|re| re.is_match(command))
}

/// The pass and fail counts a test command printed: cargo's per-binary results summed, else
/// nextest's summary, else the last `N passed` and `N failed` (pytest, jest, vitest).
fn counts(output: &str) -> (Option<u64>, Option<u64>) {
    let mut cargo = (0u64, 0u64, false);
    for c in CARGO_RESULT.iter().flat_map(|re| re.captures_iter(output)) {
        cargo.0 += c[1].parse::<u64>().unwrap_or(0);
        cargo.1 += c[2].parse::<u64>().unwrap_or(0);
        cargo.2 = true;
    }
    if cargo.2 {
        return (Some(cargo.0), Some(cargo.1));
    }
    if let Some(c) = NEXTEST_RESULT.iter().flat_map(|re| re.captures_iter(output)).last() {
        let passed = c[1].parse().ok();
        let failed = c.get(2).and_then(|m| m.as_str().parse().ok()).or(Some(0));
        return (passed, failed);
    }
    let last = |re: &Option<Regex>| {
        re.iter().flat_map(|re| re.captures_iter(output)).last().and_then(|c| c[1].parse().ok())
    };
    let passed = last(&*PASSED);
    let failed = last(&*FAILED);
    match (passed, failed) {
        (None, None) => (None, None),
        (p, f) => (p.or(Some(0)), f.or(Some(0))),
    }
}

/// Lines added and removed going from `old` to `new`.
fn line_delta(old: &str, new: &str) -> (u64, u64) {
    let lines = |s: &str| s.lines().count() as u64;
    if old.is_empty() {
        return (lines(new), 0);
    }
    if old.len() > MAX_DIFF_BYTES || new.len() > MAX_DIFF_BYTES {
        let (o, n) = (lines(old), lines(new));
        return (n.saturating_sub(o), o.saturating_sub(n));
    }
    let patch = diffy::create_patch(old, new);
    let (mut added, mut removed) = (0, 0);
    for hunk in patch.hunks() {
        for line in hunk.lines() {
            match line {
                diffy::Line::Insert(_) => added += 1,
                diffy::Line::Delete(_) => removed += 1,
                diffy::Line::Context(_) => {}
            }
        }
    }
    (added, removed)
}

/// The text a call returned, at most [`MAX_OUTPUT_BYTES`] from its end: `rawOutput` (a string, or
/// its `output`, `stdout`, `stderr`, `formatted_output` or `content`) and each text content item.
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
            for key in
                ["output", "stdout", "stderr", "formatted_output", "aggregated_output", "content"]
            {
                if let Some(s) = o.get(key).and_then(Value::as_str) {
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

/// A call's exit code: the one `tool_shell.rs` put on `rawOutput`, else Claude's `Exit code N`
/// line, else none.
fn exit_code(update: &Map<String, Value>, output: &str) -> Option<i64> {
    let raw = update.get("rawOutput").and_then(Value::as_object);
    raw.and_then(|o| o.get("exit_code").or_else(|| o.get("exitCode")))
        .and_then(Value::as_i64)
        .or_else(|| EXIT_LINE.as_ref()?.captures(output).and_then(|c| c[1].parse().ok()))
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

fn short(command: &str) -> String {
    let one_line = command.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= MAX_COMMAND_CHARS {
        return one_line;
    }
    let mut cut: String = one_line.chars().take(MAX_COMMAND_CHARS - 1).collect();
    cut.push('…');
    cut
}

/// Gathers one record of `session` into its turn's card: `turn_started` begins a new card (and
/// reads the switch, once a turn); a `tool_call` or `tool_call_update` adds its diffs, its test
/// outcome once it finished, and the pull request URLs a `pr create` printed. Off, or a turn this
/// daemon did not see start: nothing is kept.
pub(super) fn record(session: &str, kind: &str, msg: &Value) {
    match kind {
        "turn_started" => begin(session, enabled()),
        "tool_call" | "tool_call_update" => gather(session, msg),
        _ => {}
    }
}

/// Starts `session`'s turn card, gathering only when `on`.
fn begin(session: &str, on: bool) {
    let mut all = all();
    if !all.contains_key(session) && all.len() >= MAX_SESSIONS {
        let oldest = all.iter().min_by_key(|(_, g)| g.born).map(|(k, _)| k.clone());
        if let Some(oldest) = oldest {
            all.remove(&oldest);
        }
    }
    let born = BORN.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    all.insert(session.to_owned(), Gathering { born, on, ..Default::default() });
}

/// Adds one tool record to `session`'s card, when its turn's card is on.
fn gather(session: &str, msg: &Value) {
    let Some(update) = msg.pointer("/params/update").and_then(Value::as_object) else { return };
    let mut all = all();
    let Some(g) = all.get_mut(session).filter(|g| g.on) else { return };
    let id = update.get("toolCallId").and_then(Value::as_str).unwrap_or_default().to_owned();
    if let Some(command) = command_of(update)
        && !id.is_empty()
        && g.commands.len() < MAX_CALLS
    {
        g.commands.insert(id.clone(), command);
    }
    for diff in update.get("content").and_then(Value::as_array).into_iter().flatten() {
        if diff.get("type").and_then(Value::as_str) != Some("diff") {
            continue;
        }
        let path = diff
            .pointer("/_meta/acpmux/canonicalPath")
            .or_else(|| diff.get("path"))
            .and_then(Value::as_str);
        let Some(path) = path else { continue };
        let old = diff.get("oldText").and_then(Value::as_str).unwrap_or_default();
        let new = diff.get("newText").and_then(Value::as_str).unwrap_or_default();
        if g.edits.len() < MAX_CALLS {
            g.edits.insert((id.clone(), path.to_owned()), line_delta(old, new));
        }
    }
    let status = update.get("status").and_then(Value::as_str);
    if !matches!(status, Some("completed" | "failed")) || g.settled.contains(&id) {
        return;
    }
    let title = update.get("title").and_then(Value::as_str).unwrap_or_default();
    let command = g.commands.get(&id).cloned().unwrap_or_default();
    let tested = is_test_command(&command);
    let opened_pr =
        PR_COMMAND.as_ref().is_some_and(|re| re.is_match(&command) || re.is_match(title));
    if !tested && !opened_pr {
        return;
    }
    let output = output_text(update);
    if !id.is_empty() {
        g.settled.insert(id);
    }
    if opened_pr {
        let urls = PR_URL.iter().flat_map(|re| re.find_iter(&output));
        g.prs.extend(urls.map(|m| m.as_str().to_owned()));
    }
    if tested {
        let exit = exit_code(update, &output);
        let (passed, failed) = counts(&output);
        let ok = status == Some("completed")
            && exit.is_none_or(|c| c == 0)
            && failed.is_none_or(|f| f == 0);
        g.tests.push(TestRun { command: short(&command), exit_code: exit, ok, passed, failed });
    }
}

/// The card of a gathering, or `None` when it holds nothing to show.
fn card(g: Gathering) -> Option<Value> {
    let mut files: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    for ((_, path), (a, r)) in g.edits {
        let f = files.entry(path).or_default();
        f.0 += a;
        f.1 += r;
    }
    if files.is_empty() && g.tests.is_empty() && g.prs.is_empty() {
        return None;
    }
    let (added, removed) = files.values().fold((0, 0), |s, f| (s.0 + f.0, s.1 + f.1));
    let file_count = files.len();
    let files: Vec<Value> = files
        .into_iter()
        .take(MAX_ITEMS)
        .map(|(path, (a, r))| json!({"path": path, "added": a, "removed": r}))
        .collect();
    let test_count = g.tests.len();
    let tests: Vec<Value> = g
        .tests
        .into_iter()
        .rev()
        .take(MAX_ITEMS)
        .rev()
        .map(|t| {
            let mut o = Map::new();
            o.insert("command".into(), json!(t.command));
            o.insert("ok".into(), json!(t.ok));
            if let Some(c) = t.exit_code {
                o.insert("exitCode".into(), json!(c));
            }
            if let Some(p) = t.passed {
                o.insert("passed".into(), json!(p));
            }
            if let Some(f) = t.failed {
                o.insert("failed".into(), json!(f));
            }
            Value::Object(o)
        })
        .collect();
    let prs: Vec<&String> = g.prs.iter().take(MAX_ITEMS).collect();
    Some(json!({
        "diff": {"files": file_count, "added": added, "removed": removed},
        "files": files,
        "tests": tests,
        "testRuns": test_count,
        "prs": prs,
    }))
}

/// Puts the turn's card on its `turn_result` as `artifacts`, with the feature's counters, and
/// forgets the gathering. Off, or nothing gathered: the message is unchanged.
pub(super) fn stamp(session: &str, msg: &mut Value) {
    let Some(g) = all().remove(session).filter(|g| g.on) else { return };
    stamp_card(g, msg);
}

fn stamp_card(g: Gathering, msg: &mut Value) {
    let Some(card) = card(g) else { return };
    let files = card.pointer("/diff/files").and_then(Value::as_u64).unwrap_or(0);
    let tests = card.get("testRuns").and_then(Value::as_u64).unwrap_or(0);
    let prs = card.get("prs").and_then(Value::as_array).map_or(0, Vec::len) as u64;
    let Some(o) = msg.as_object_mut() else { return };
    o.insert("artifacts".into(), card);
    super::harness_magic::add_counter(msg, FEATURE, "cards", 1);
    super::harness_magic::add_counter(msg, FEATURE, "files", files);
    super::harness_magic::add_counter(msg, FEATURE, "tests", tests);
    super::harness_magic::add_counter(msg, FEATURE, "prs", prs);
}

#[cfg(test)]
#[path = "turn_artifacts_tests.rs"]
mod tests;
