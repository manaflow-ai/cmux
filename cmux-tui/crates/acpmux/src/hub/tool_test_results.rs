//! Part of `Hub`; see `hub/mod.rs`. Live test results on a test command's
//! tool call: as a `cargo test`, `pytest`, `go test`, `jest`, `vitest`,
//! `bun test`, `swift test` or nextest run prints, each of its updates gets
//! `_meta.acpmux.testResults` = `{runner, passed, failed, skipped, done,
//! failures: [{name, path?, line?, message?}], moreFailures?}`, so a client
//! draws the command row as a ticking pass/fail panel whose failures open
//! their file at the line.
//!
//! Agents send a running call's output two ways: most send the whole output
//! so far with each update (a snapshot), pi sends only what was printed since
//! the last one (`_meta.terminal_output.data`). Either way only the bytes not
//! read before are parsed: a call keeps what it counted so far, the length it
//! read and the tail of it, so a snapshot's new part is found without reading
//! the old part again. A snapshot that no longer starts with what was read
//! (cut from the front, or replaced) is found by its tail, else read again
//! from the start. The command is kept too, since later updates leave it out.
//!
//! Bounded: at most [`MAX_CALLS`] calls are followed at once (the oldest is
//! dropped), a call keeps at most [`MAX_FAILURES`] failures, and a line
//! longer than [`MAX_LINE`] is cut. A call's state goes when it ends.

use regex::Regex;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};

use super::super::turn_artifacts::{command_of, is_test_command, output_text};

/// Calls followed at once, across sessions.
const MAX_CALLS: usize = 1024;
/// Failures kept per call; the rest are counted in `moreFailures`.
const MAX_FAILURES: usize = 50;
/// A failure message's characters.
const MAX_MESSAGE_CHARS: usize = 300;
/// A line's bytes; the rest of a longer line is dropped.
const MAX_LINE: usize = 8 << 10;
/// The bytes of read output kept to find a snapshot's new part.
const TAIL: usize = 64;

#[derive(Debug, Default, Clone, PartialEq)]
pub(super) struct Failure {
    pub name: String,
    pub path: Option<String>,
    pub line: Option<u64>,
    pub message: Option<String>,
}

/// What a test run printed so far, read line by line.
#[derive(Debug, Default)]
pub(super) struct Tally {
    pub passed: u64,
    pub failed: u64,
    pub skipped: u64,
    pub failures: Vec<Failure>,
    pub more_failures: u64,
    /// The failure the next location or message lines belong to.
    pending: Option<usize>,
    /// Whether the pending failure still wants its message from the next line.
    wants_message: bool,
    /// A location printed before the failure it belongs to (bun, XCTest).
    early: Option<(String, u64, Option<String>)>,
    /// A final summary's counts, which win over the live ones.
    summary: Option<(u64, u64, u64)>,
    /// cargo's per-binary `test result:` lines, summed.
    cargo_summary: Option<(u64, u64, u64)>,
    partial: String,
    partial_cut: bool,
}

struct Call {
    born: u64,
    runner: &'static str,
    tally: Tally,
    read: usize,
    tail: String,
}

static CALLS: LazyLock<Mutex<HashMap<(String, String), Call>>> = LazyLock::new(Default::default);
static BORN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn calls() -> MutexGuard<'static, HashMap<(String, String), Call>> {
    CALLS.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Adds `_meta.acpmux.testResults` to a test command's `tool_call` or
/// `tool_call_update` record. Any other record is left as it is.
pub(super) fn add_test_results(session: &str, kind: &str, msg: &mut Value) {
    if !matches!(kind.strip_suffix(".replay").unwrap_or(kind), "tool_call" | "tool_call_update") {
        return;
    }
    let Some(update) = msg.pointer_mut("/params/update").and_then(Value::as_object_mut) else {
        return;
    };
    // A record already read (a replayed one keeps what it was given).
    if update.get("_meta").and_then(|m| m.pointer("/acpmux/testResults")).is_some() {
        return;
    }
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
    let key = (session.to_owned(), id.to_owned());
    let status = update.get("status").and_then(Value::as_str).unwrap_or_default();
    let done = matches!(status, "completed" | "failed");
    let mut all = calls();
    if !all.contains_key(&key) {
        let Some(command) = command_of(update).filter(|c| is_test_command(c)) else { return };
        if all.len() >= MAX_CALLS
            && let Some(oldest) = all.iter().min_by_key(|(_, c)| c.born).map(|(k, _)| k.clone())
        {
            all.remove(&oldest);
        }
        let born = BORN.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        all.insert(
            key.clone(),
            Call {
                born,
                runner: runner(&command),
                tally: Tally::default(),
                read: 0,
                tail: String::new(),
            },
        );
    }
    let Some(call) = all.get_mut(&key) else { return };
    match update
        .get("_meta")
        .and_then(|m| m.pointer("/terminal_output/data"))
        .and_then(Value::as_str)
    {
        Some(delta) => call.tally.feed(delta),
        None => {
            let snapshot = output_text(update);
            call.read_snapshot(&snapshot);
        }
    }
    if done {
        call.tally.finish();
    }
    let results = call.tally.to_json(call.runner, done);
    if done {
        all.remove(&key);
    }
    drop(all);
    let Some(results) = results else { return };
    let meta = update.entry("_meta").or_insert_with(|| Value::Object(Map::new()));
    let Some(meta) = meta.as_object_mut() else { return };
    let acpmux = meta.entry("acpmux").or_insert_with(|| Value::Object(Map::new()));
    if let Some(acpmux) = acpmux.as_object_mut() {
        acpmux.insert("testResults".into(), results);
    }
}

impl Call {
    /// Reads the part of `snapshot` (the whole output so far) not read before.
    fn read_snapshot(&mut self, snapshot: &str) {
        if snapshot.is_empty() {
            return;
        }
        let fresh = if self.read == 0 {
            Some(0)
        } else if snapshot.len() >= self.read
            && snapshot.is_char_boundary(self.read)
            && snapshot[..self.read].ends_with(self.tail.as_str())
        {
            Some(self.read)
        } else if !self.tail.is_empty() {
            snapshot.rfind(self.tail.as_str()).map(|at| at + self.tail.len())
        } else {
            None
        };
        let start = match fresh {
            Some(start) => start,
            None => {
                // Not the output read so far: read this one from its start.
                self.tally = Tally::default();
                0
            }
        };
        self.tally.feed(&snapshot[start..]);
        self.read = snapshot.len();
        let mut cut = snapshot.len().saturating_sub(TAIL);
        while !snapshot.is_char_boundary(cut) {
            cut += 1;
        }
        self.tail = snapshot[cut..].to_owned();
    }
}

/// The runner a command names, for the panel's label.
fn runner(command: &str) -> &'static str {
    let has =
        |word: &str| command.split(|c: char| c.is_whitespace() || c == '/').any(|w| w == word);
    if command.contains("nextest") {
        "nextest"
    } else if has("cargo") {
        "cargo"
    } else if command.contains("pytest") || command.contains("unittest") {
        "pytest"
    } else if has("vitest") {
        "vitest"
    } else if has("jest") {
        "jest"
    } else if has("playwright") {
        "playwright"
    } else if has("bun") {
        "bun"
    } else if has("go") {
        "go"
    } else if has("swift") || has("xcodebuild") {
        "swift"
    } else {
        "tests"
    }
}

fn re(pattern: &str) -> Option<Regex> {
    Regex::new(pattern).ok()
}

macro_rules! regex {
    ($name:ident, $pattern:expr) => {
        static $name: LazyLock<Option<Regex>> = LazyLock::new(|| re($pattern));
    };
}

// cargo: `test a::b ... ok`, `... FAILED`, `... ignored`.
regex!(CARGO_TEST, r"^test (.+?) \.\.\. (ok|FAILED|ignored)");
// cargo: `test result: FAILED. 3 passed; 1 failed; 2 ignored; ...`.
regex!(CARGO_RESULT, r"^test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored");
// cargo: `thread 'a::b' panicked at src/lib.rs:10:5:` (new) or `... at 'msg', src/lib.rs:10:5` (old).
regex!(
    CARGO_PANIC,
    r"^thread '([^']+)' (?:\(\d+\) )?panicked at (?:'(.*)', )?([^\s:][^:]*):(\d+):\d+:?$"
);
// nextest: `        PASS [   0.004s] crate tests::a`.
regex!(NEXTEST_TEST, r"^\s+(PASS|FAIL|SKIP|SIGSEGV|SIGABRT|TIMEOUT) \[[^\]]*\] (.+)$");
regex!(NEXTEST_SUMMARY, r"^\s*Summary \[[^\]]*\]\s+\d+ tests? run: (.*)$");
// go: `--- PASS: TestA (0.00s)`; its log lines: `    a_test.go:12: msg`.
regex!(GO_TEST, r"^\s*--- (PASS|FAIL|SKIP): (\S+)");
regex!(GO_LOCATION, r"^\s+([\w./-]+_test\.go):(\d+): ?(.*)$");
// pytest: `tests/test_a.py::test_b PASSED`, progress `tests/test_a.py ..F.s [ 50%]`,
// failure headers `____ test_b ____`, `tests/test_a.py:12: AssertionError`,
// `FAILED tests/test_a.py::test_b - msg`, `=== 1 failed, 2 passed in 0.1s ===`.
regex!(PYTEST_VERBOSE, r"^(\S+\.py::\S+) (PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS)\b");
regex!(PYTEST_PROGRESS, r"^(\S+\.py) ([.FEsxX]+)\s*(?:\[\s*\d+%\])?$");
regex!(PYTEST_HEADER, r"^_{3,} (.+?) _{3,}$");
regex!(PYTEST_LOCATION, r"^([\w./-]+\.py):(\d+): (\w+.*)$");
regex!(PYTEST_SHORT, r"^(?:FAILED|ERROR) (\S+?\.py)::(\S+)(?: - (.*))?$");
regex!(PYTEST_SUMMARY, r"^=+ (.*\d+ (?:passed|failed|skipped|errors?).*) in [\d.]+s.* =+$");
// jest: `  ✓ adds (3 ms)`, `  ✕ fails`, `  ○ skipped`, `  ● Suite › name`,
// `      at Object.<anonymous> (src/a.test.ts:10:5)`, `Tests:  1 failed, 3 passed, 4 total`.
regex!(JEST_TEST, r"^\s+(✓|√|✕|×|○|↓) (.+?)(?: \(\d+(?:\.\d+)? ?m?s\))?$");
regex!(JEST_HEADER, r"^\s+● (.+)$");
regex!(STACK_LOCATION, r"\(?((?:/|\.{0,2}/)?[\w@./-]+\.[cm]?[jt]sx?):(\d+):\d+\)?\s*$");
regex!(TESTS_SUMMARY, r"^\s*Tests:?\s+(.*\d+ (?:passed|failed).*)$");
// vitest: ` ✓ src/a.test.ts (3 tests | 1 failed) 5ms`, ` FAIL  src/a.test.ts > suite > name`,
// ` ❯ src/a.test.ts:10:5`.
regex!(VITEST_FILE, r"^\s*(✓|❯|×|↓) (\S+) \((\d+) tests?((?: \| \d+ \w+)*)\)");
regex!(VITEST_HEADER, r"^\s*FAIL\s+(\S+) > (.+)$");
regex!(VITEST_LOCATION, r"^\s*❯ ([\w@./-]+):(\d+):\d+\s*$");
// bun: `(pass) suite > name [0.1ms]`, ` 3 pass`, ` 1 fail`, ` 0 skip`.
regex!(BUN_TEST, r"^\((pass|fail|skip|todo)\) (.+?)(?: \[[\d.]+m?s\])?$");
regex!(BUN_COUNT, r"^\s*(\d+) (pass|fail|skip)$");
// XCTest: `Test Case '-[M.T testA]' passed (0.001 seconds).`,
// `/p/T.swift:12: error: -[M.T testA] : XCTAssertEqual failed: ...`.
regex!(XCTEST_CASE, r"^Test Case '(.+?)' (passed|failed|skipped)");
regex!(XCTEST_ERROR, r"^(/\S+\.swift):(\d+): error: (.+?) : (.*)$");
// Swift Testing: `✔ Test a() passed after 0.1 seconds.`, `✘ Test a() failed after ...`,
// `✘ Test a() recorded an issue at T.swift:12:5: Expectation failed: ...`.
regex!(SWIFT_TEST, r"^[✔✘➜] Test (.+?) (passed|failed|skipped)\b");
regex!(SWIFT_ISSUE, r"^✘ Test (.+?) recorded an issue at ([^\s:]+):(\d+):\d+: (.*)$");
regex!(COUNT_WORD, r"(\d+) (passed|failed|skipped|ignored|errors?|todo|pending)");

fn caps<'a>(re: &Option<Regex>, line: &'a str) -> Option<regex::Captures<'a>> {
    re.as_ref()?.captures(line)
}

fn short_message(text: &str) -> Option<String> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    Some(match text.char_indices().nth(MAX_MESSAGE_CHARS) {
        Some((cut, _)) => format!("{}…", &text[..cut]),
        None => text.to_owned(),
    })
}

impl Tally {
    /// Reads `text`, the next part of the output, a line at a time.
    pub(super) fn feed(&mut self, text: &str) {
        let mut rest = text;
        while let Some(at) = rest.find('\n') {
            self.push_partial(&rest[..at]);
            let line = std::mem::take(&mut self.partial);
            self.partial_cut = false;
            self.line(line.trim_end_matches('\r'));
            rest = &rest[at + 1..];
        }
        self.push_partial(rest);
    }

    /// Reads the last line, which ended without a newline.
    pub(super) fn finish(&mut self) {
        if !self.partial.is_empty() {
            let line = std::mem::take(&mut self.partial);
            self.line(line.trim_end_matches('\r'));
        }
    }

    fn push_partial(&mut self, text: &str) {
        if self.partial_cut {
            return;
        }
        let room = MAX_LINE.saturating_sub(self.partial.len());
        if text.len() <= room {
            self.partial.push_str(text);
            return;
        }
        let mut cut = room;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        self.partial.push_str(&text[..cut]);
        self.partial_cut = true;
    }

    /// The failure named `name`, added if it is not there; `None` once the list is full.
    fn failure(&mut self, name: &str) -> Option<usize> {
        if let Some(at) = self.failures.iter().position(|f| f.name == name) {
            return Some(at);
        }
        if self.failures.len() >= MAX_FAILURES {
            self.more_failures += 1;
            return None;
        }
        self.failures.push(Failure { name: name.to_owned(), ..Failure::default() });
        Some(self.failures.len() - 1)
    }

    /// A failure seen live: counted, kept, and given a location printed just before it.
    fn failed_test(&mut self, name: &str) {
        self.failed += 1;
        let at = self.failure(name);
        if let (Some(at), Some((path, line, message))) = (at, self.early.take()) {
            let f = &mut self.failures[at];
            if f.path.is_none() {
                f.path = Some(path);
                f.line = Some(line);
            }
            if f.message.is_none() {
                f.message = message;
            }
        }
        self.pending = at;
    }

    fn locate(&mut self, path: &str, line: Option<u64>, message: Option<&str>) {
        let Some(at) = self.pending else { return };
        let f = &mut self.failures[at];
        if f.path.is_none() {
            f.path = Some(path.to_owned());
            f.line = line;
        }
        if f.message.is_none() {
            f.message = message.and_then(short_message);
        }
    }

    fn line(&mut self, line: &str) {
        // A message line right after a failure's header (jest, vitest, new cargo panics).
        if self.wants_message && !line.trim().is_empty() {
            self.wants_message = false;
            if let Some(at) = self.pending
                && self.failures[at].message.is_none()
                && !line.trim_start().starts_with("at ")
            {
                self.failures[at].message = short_message(line);
                return;
            }
        }
        if let Some(c) = caps(&CARGO_TEST, line) {
            match &c[2] {
                "ok" => self.passed += 1,
                "ignored" => self.skipped += 1,
                _ => self.failed_test(&c[1]),
            }
            return;
        }
        if let Some(c) = caps(&CARGO_RESULT, line) {
            let n = |i: usize| c[i].parse::<u64>().unwrap_or(0);
            let s = self.cargo_summary.get_or_insert((0, 0, 0));
            s.0 += n(1);
            s.1 += n(2);
            s.2 += n(3);
            return;
        }
        if let Some(c) = caps(&CARGO_PANIC, line) {
            let name = c[1].to_owned();
            let at = self.failure(&name);
            if let Some(at) = at {
                let f = &mut self.failures[at];
                f.path.get_or_insert_with(|| c[3].to_owned());
                f.line = f.line.or(c[4].parse().ok());
                if let Some(old) = c.get(2) {
                    f.message = f.message.take().or_else(|| short_message(old.as_str()));
                }
            }
            self.pending = at;
            self.wants_message = c.get(2).is_none();
            return;
        }
        if let Some(c) = caps(&NEXTEST_TEST, line) {
            let name = c[2].trim().to_owned();
            match &c[1] {
                "PASS" => self.passed += 1,
                "SKIP" => self.skipped += 1,
                _ => self.failed_test(&name),
            }
            return;
        }
        if let Some(c) = caps(&NEXTEST_SUMMARY, line) {
            self.summary = Some(words(&c[1]));
            return;
        }
        if let Some(c) = caps(&GO_TEST, line) {
            match &c[1] {
                "PASS" => self.passed += 1,
                "SKIP" => self.skipped += 1,
                _ => self.failed_test(&c[2]),
            }
            return;
        }
        if let Some(c) = caps(&GO_LOCATION, line) {
            self.locate(&c[1], c[2].parse().ok(), Some(&c[3]));
            return;
        }
        if let Some(c) = caps(&PYTEST_VERBOSE, line) {
            match &c[2] {
                "PASSED" | "XPASS" => self.passed += 1,
                "SKIPPED" | "XFAIL" => self.skipped += 1,
                _ => {
                    let name = c[1].rsplit("::").next().unwrap_or(&c[1]).to_owned();
                    self.failed_test(&name);
                    let path = c[1].split("::").next().map(str::to_owned);
                    if let (Some(at), Some(path)) = (self.pending, path) {
                        self.failures[at].path.get_or_insert(path);
                    }
                }
            }
            return;
        }
        if let Some(c) = caps(&PYTEST_PROGRESS, line) {
            for mark in c[2].chars() {
                match mark {
                    '.' | 'X' => self.passed += 1,
                    's' | 'x' => self.skipped += 1,
                    _ => self.failed += 1,
                }
            }
            return;
        }
        if let Some(c) = caps(&PYTEST_SUMMARY, line) {
            self.summary = Some(words(&c[1]));
            return;
        }
        if let Some(c) = caps(&PYTEST_SHORT, line) {
            let name = c[2].rsplit("::").next().unwrap_or(&c[2]).to_owned();
            if let Some(at) = self.failure(&name) {
                let f = &mut self.failures[at];
                f.path.get_or_insert_with(|| c[1].to_owned());
                if f.message.is_none() {
                    f.message = c.get(3).and_then(|m| short_message(m.as_str()));
                }
            }
            return;
        }
        if let Some(c) = caps(&PYTEST_HEADER, line) {
            let name = c[1].rsplit(['.', ' ']).next().unwrap_or(&c[1]).to_owned();
            self.pending = self.failure(&name);
            return;
        }
        if let Some(c) = caps(&PYTEST_LOCATION, line) {
            if let Some(at) = self.pending {
                let f = &mut self.failures[at];
                // The last frame is the test's line: a later one replaces an earlier.
                f.path = Some(c[1].to_owned());
                f.line = c[2].parse().ok();
                f.message.get_or_insert_with(|| short_message(&c[3]).unwrap_or_default());
            }
            return;
        }
        if let Some(c) = caps(&BUN_TEST, line) {
            match &c[1] {
                "pass" => self.passed += 1,
                "fail" => self.failed_test(&c[2]),
                _ => self.skipped += 1,
            }
            // bun prints each failure's stack before its line: the next stack is the next test's.
            self.early = None;
            self.pending = None;
            return;
        }
        if let Some(c) = caps(&BUN_COUNT, line) {
            let n = c[1].parse().unwrap_or(0);
            let s = self.summary.get_or_insert((self.passed, self.failed, self.skipped));
            match &c[2] {
                "pass" => s.0 = n,
                "fail" => s.1 = n,
                _ => s.2 = n,
            }
            return;
        }
        if let Some(c) = caps(&XCTEST_ERROR, line) {
            self.early = Some((c[1].to_owned(), c[2].parse().unwrap_or(0), short_message(&c[4])));
            return;
        }
        if let Some(c) = caps(&XCTEST_CASE, line) {
            match &c[2] {
                "passed" => self.passed += 1,
                "skipped" => self.skipped += 1,
                _ => self.failed_test(&c[1]),
            }
            self.early = None;
            return;
        }
        if let Some(c) = caps(&SWIFT_ISSUE, line) {
            let name = c[1].to_owned();
            if let Some(at) = self.failure(&name) {
                let f = &mut self.failures[at];
                f.path.get_or_insert_with(|| c[2].to_owned());
                f.line = f.line.or(c[3].parse().ok());
                if f.message.is_none() {
                    f.message = short_message(&c[4]);
                }
            }
            return;
        }
        if let Some(c) = caps(&SWIFT_TEST, line) {
            if c[1].starts_with("run with") {
                return;
            }
            match &c[2] {
                "passed" => self.passed += 1,
                "skipped" => self.skipped += 1,
                _ => self.failed_test(&c[1].to_owned()),
            }
            return;
        }
        if let Some(c) = caps(&VITEST_FILE, line) {
            let total: u64 = c[3].parse().unwrap_or(0);
            let (mut failed, mut skipped) = (0, 0);
            for part in c[4].split('|').map(str::trim).filter(|p| !p.is_empty()) {
                let mut it = part.split_whitespace();
                let n: u64 = it.next().and_then(|n| n.parse().ok()).unwrap_or(0);
                match it.next() {
                    Some("failed") => failed += n,
                    Some("skipped" | "todo") => skipped += n,
                    _ => {}
                }
            }
            if &c[1] == "↓" && failed == 0 && skipped == 0 {
                skipped = total;
            }
            self.passed += total.saturating_sub(failed + skipped);
            self.failed += failed;
            self.skipped += skipped;
            return;
        }
        if let Some(c) = caps(&VITEST_HEADER, line) {
            let name = c[2].trim().to_owned();
            let at = self.failure(&name);
            if let Some(at) = at {
                self.failures[at].path.get_or_insert_with(|| c[1].to_owned());
                self.failures[at].line = None;
            }
            self.pending = at;
            self.wants_message = true;
            return;
        }
        if let Some(c) = caps(&VITEST_LOCATION, line) {
            if let Some(at) = self.pending
                && self.failures[at].line.is_none()
            {
                self.failures[at].path = Some(c[1].to_owned());
                self.failures[at].line = c[2].parse().ok();
            }
            return;
        }
        if let Some(c) = caps(&TESTS_SUMMARY, line) {
            self.summary = Some(words(&c[1]));
            return;
        }
        if let Some(c) = caps(&JEST_HEADER, line) {
            let name = c[1].trim().to_owned();
            // The `✕ name` line named it without its suites: give it the header's whole name.
            let last = name.rsplit(" › ").next().unwrap_or(&name);
            if let Some(f) = self.failures.iter_mut().find(|f| f.name == last) {
                f.name = name.clone();
            }
            self.pending = self.failure(&name);
            self.wants_message = true;
            return;
        }
        if let Some(c) = caps(&JEST_TEST, line) {
            match &c[1] {
                "✓" | "√" => self.passed += 1,
                "○" | "↓" => self.skipped += 1,
                _ => {
                    self.failed += 1;
                    let _ = self.failure(c[2].trim());
                }
            }
            return;
        }
        if line.trim_start().starts_with("at ")
            && let Some(c) = caps(&STACK_LOCATION, line)
        {
            if c[1].contains("node_modules") {
                return;
            }
            let (path, number) = (c[1].to_owned(), c[2].parse().unwrap_or(0));
            match self.pending {
                Some(at) if self.failures[at].line.is_none() => {
                    self.failures[at].path = Some(path);
                    self.failures[at].line = Some(number);
                }
                Some(_) => {}
                // bun prints a failure's stack before its `(fail)` line.
                None => {
                    self.early.get_or_insert((path, number, None));
                }
            }
        }
    }

    /// The counts so far: a final summary's, else cargo's summed results, else the live ones.
    pub(super) fn counts(&self) -> (u64, u64, u64) {
        self.summary.or(self.cargo_summary).unwrap_or((self.passed, self.failed, self.skipped))
    }

    /// `testResults`, or `None` for a finished run that printed no result.
    pub(super) fn to_json(&self, runner: &str, done: bool) -> Option<Value> {
        let (passed, failed, skipped) = self.counts();
        if done && passed + failed + skipped == 0 && self.failures.is_empty() {
            return None;
        }
        let failures: Vec<Value> = self
            .failures
            .iter()
            .map(|f| {
                let mut v = json!({"name": f.name});
                if let Some(path) = &f.path {
                    v["path"] = json!(path);
                }
                if let Some(line) = f.line.filter(|l| *l > 0) {
                    v["line"] = json!(line);
                }
                if let Some(message) = &f.message {
                    v["message"] = json!(message);
                }
                v
            })
            .collect();
        let mut out = json!({
            "runner": runner, "passed": passed, "failed": failed, "skipped": skipped,
            "done": done, "failures": failures,
        });
        if self.more_failures > 0 {
            out["moreFailures"] = json!(self.more_failures);
        }
        Some(out)
    }
}

/// `(passed, failed, skipped)` from a summary's words: `1 failed, 3 passed, 2 skipped`.
fn words(text: &str) -> (u64, u64, u64) {
    let mut out = (0, 0, 0);
    for c in COUNT_WORD.iter().flat_map(|re| re.captures_iter(text)) {
        let n: u64 = c[1].parse().unwrap_or(0);
        match &c[2] {
            "passed" => out.0 += n,
            "failed" | "error" | "errors" => out.1 += n,
            _ => out.2 += n,
        }
    }
    out
}

#[cfg(test)]
#[path = "tool_test_results_tests.rs"]
mod tests;
