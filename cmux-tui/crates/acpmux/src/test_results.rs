//! Small, streaming-friendly parsers for common test-runner output.
//!
//! Test output is untrusted and can be arbitrarily large. The parser keeps only
//! the first few failures and caps every captured reason, while counts continue
//! to update as more lines arrive.

use regex::Regex;
use serde_json::Value;
use std::sync::OnceLock;

const MAX_FAILURES: usize = 32;
const MAX_REASON_BYTES: usize = 240;
const MAX_JSON_BYTES: usize = 128 * 1024;
const MAX_SCAN_BYTES: usize = 256 * 1024;
const MAX_NAME_BYTES: usize = 320;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestFailure {
    pub name: String,
    pub reason: String,
    pub file: Option<String>,
    pub line: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TestResults {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub skipped: usize,
    pub failures: Vec<TestFailure>,
    pub failures_truncated: bool,
    counts_reported: bool,
}

impl TestResults {
    pub fn is_empty(&self) -> bool {
        self.total == 0
            && self.passed == 0
            && self.failed == 0
            && self.skipped == 0
            && self.failures.is_empty()
    }

    pub fn label(&self) -> String {
        let mut parts = Vec::new();
        if self.passed > 0 {
            parts.push(format!("{} passed", self.passed));
        }
        if self.failed > 0 {
            parts.push(format!("{} failed", self.failed));
        }
        if self.skipped > 0 {
            parts.push(format!("{} skipped", self.skipped));
        }
        if parts.is_empty() && self.total > 0 {
            parts.push(format!("{} tests", self.total));
        }
        if parts.is_empty() { "tests".into() } else { format!("tests {}", parts.join(", ")) }
    }

    fn normalize(&mut self) {
        self.total = self.total.max(self.passed + self.failed + self.skipped);
        if self.failures.len() > MAX_FAILURES {
            self.failures.truncate(MAX_FAILURES);
            self.failures_truncated = true;
        }
    }

    fn add_failure(&mut self, failure: TestFailure) {
        if self.failures.iter().any(|old| old.name == failure.name) {
            return;
        }
        if !self.counts_reported {
            self.failed += 1;
        }
        self.retain_failure(failure);
    }

    fn retain_failure(&mut self, failure: TestFailure) {
        if self.failures.iter().any(|old| old.name == failure.name) {
            return;
        }
        if self.failures.len() < MAX_FAILURES {
            self.failures.push(failure);
        } else {
            self.failures_truncated = true;
        }
    }

    pub(crate) fn merge(&mut self, other: TestResults) {
        if self.counts_reported || other.counts_reported {
            self.passed = self.passed.max(other.passed);
            self.failed = self.failed.max(other.failed);
            self.skipped = self.skipped.max(other.skipped);
            self.total = self.total.max(other.total);
            self.counts_reported = true;
        } else {
            self.passed += other.passed;
            self.failed += other.failed;
            self.skipped += other.skipped;
            self.total += other.total;
        }
        for failure in other.failures {
            self.retain_failure(failure);
        }
        self.failures_truncated |= other.failures_truncated;
        self.normalize();
    }

    pub(crate) fn merge_snapshot(&mut self, other: TestResults) {
        self.passed = self.passed.max(other.passed);
        self.failed = self.failed.max(other.failed);
        self.skipped = self.skipped.max(other.skipped);
        self.total = self.total.max(other.total);
        self.counts_reported |= other.counts_reported;
        for failure in other.failures {
            self.retain_failure(failure);
        }
        self.failures_truncated |= other.failures_truncated;
        self.normalize();
    }
}

/// Parse the current output of an executable tool. A command is used only as a
/// hint, so a plain test runner still works and non-test commands are ignored.
pub fn parse(command: &str, output: &str) -> Option<TestResults> {
    let command = command.trim();
    let lower = command.to_ascii_lowercase();
    let looks_like_tests = command.is_empty()
        || ["test", "pytest", "jest", "vitest", "cargo", "nextest", "go test", "mocha", "rspec"]
            .iter()
            .any(|word| lower.contains(word));
    if !looks_like_tests || output.trim().is_empty() {
        return None;
    }

    let output = bounded_tail(output);
    let mut parsed = parse_json(output);
    if parsed.is_none() {
        parsed = parse_text(output);
    }
    parsed.filter(|result| !result.is_empty()).map(|mut result| {
        result.normalize();
        result
    })
}

fn parse_json(output: &str) -> Option<TestResults> {
    if output.len() <= MAX_JSON_BYTES
        && let Ok(value) = serde_json::from_str::<Value>(output.trim())
    {
        if let Some(object) = value.as_object() {
            let has_jest_counts = object.get("numTotalTests").is_some();
            let pending = usize_value(object.get("numPendingTests"));
            let todo = usize_value(object.get("numTodoTests"));
            let mut result = TestResults {
                total: usize_value(object.get("numTotalTests")),
                passed: usize_value(object.get("numPassedTests")),
                failed: usize_value(object.get("numFailedTests")),
                skipped: pending + todo,
                counts_reported: has_jest_counts,
                ..Default::default()
            };
            if let Some(suites) = object.get("testResults").and_then(Value::as_array) {
                for suite in suites {
                    for assertion in suite
                        .get("assertionResults")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                    {
                        let status = assertion.get("status").and_then(Value::as_str).unwrap_or("");
                        let name = assertion_name(assertion);
                        match status {
                            "passed" if !has_jest_counts => result.passed += 1,
                            "failed" => result.add_failure(TestFailure {
                                name,
                                reason: reason_from_json(assertion),
                                file: file_from_json(
                                    assertion,
                                    suite.get("name").and_then(Value::as_str),
                                ),
                                line: line_from_json(assertion),
                            }),
                            "pending" | "skipped" | "todo" if !has_jest_counts => {
                                result.skipped += 1
                            }
                            _ => {}
                        }
                    }
                }
            }
            if let Some(summary) = object.get("summary").and_then(Value::as_object) {
                result.counts_reported = true;
                result.passed = result.passed.max(usize_value(summary.get("passed")));
                result.failed = result.failed.max(usize_value(summary.get("failed")));
                result.skipped = result.skipped.max(usize_value(summary.get("skipped")));
                result.total = result.total.max(usize_value(summary.get("total")));
            }
            if let Some(tests) = object.get("tests").and_then(Value::as_array) {
                for test in tests {
                    match test.get("outcome").and_then(Value::as_str).unwrap_or("") {
                        "passed" if !result.counts_reported => result.passed += 1,
                        "skipped" if !result.counts_reported => result.skipped += 1,
                        "failed" => result.add_failure(TestFailure {
                            name: cap_text(
                                test.get("nodeid").and_then(Value::as_str).unwrap_or("failed test"),
                            ),
                            reason: test
                                .pointer("/call/longrepr")
                                .and_then(Value::as_str)
                                .map(cap_reason)
                                .unwrap_or_default(),
                            file: test.get("filename").and_then(Value::as_str).map(cap_text),
                            line: test.get("lineno").and_then(Value::as_u64).map(|n| n as u32),
                        }),
                        _ => {}
                    }
                }
            }
            return (!result.is_empty()).then_some(result);
        }
    }

    let mut result = TestResults::default();
    let mut saw = false;
    for line in output.lines() {
        if line.len() > MAX_JSON_BYTES {
            continue;
        }
        let Ok(event) = serde_json::from_str::<Value>(line) else { continue };
        let action = event.get("Action").and_then(Value::as_str).unwrap_or("");
        if !matches!(action, "pass" | "fail" | "skip") || event.get("Test").is_none() {
            continue;
        }
        saw = true;
        match action {
            "pass" => result.passed += 1,
            "skip" => result.skipped += 1,
            "fail" => result.add_failure(TestFailure {
                name: cap_text(event.get("Test").and_then(Value::as_str).unwrap_or("failed test")),
                reason: String::new(),
                file: None,
                line: None,
            }),
            _ => {}
        }
    }
    saw.then_some(result)
}

fn parse_text(output: &str) -> Option<TestResults> {
    let mut result = TestResults::default();
    let mut saw = false;
    let summary_seen = output.lines().any(|line| {
        let lower = line.to_ascii_lowercase();
        lower.contains("test result:")
            || lower.starts_with("tests:")
            || (lower.contains(" passed")
                && (lower.contains(" failed") || lower.contains(" skipped")))
    });
    let patterns = text_patterns();
    for line in output.lines() {
        for caps in patterns.summary.captures_iter(line) {
            let count = caps[1].parse().unwrap_or(0);
            match caps[2].to_ascii_lowercase().as_str() {
                "passed" => result.passed = result.passed.max(count),
                "failed" => result.failed = result.failed.max(count),
                "skipped" | "ignored" | "pending" => result.skipped = result.skipped.max(count),
                _ => {}
            }
            result.counts_reported = true;
            saw = true;
        }
        let lower = line.to_ascii_lowercase();
        if lower.contains("test result:")
            || lower.starts_with("tests:")
            || (lower.contains(" passed")
                && (lower.contains(" failed") || lower.contains(" skipped")))
        {
            saw = true;
        }
        if let Some(caps) = patterns.cargo_case.captures(line) {
            saw = true;
            match caps.get(2).map(|m| m.as_str()) {
                Some("ok") if !summary_seen => result.passed += 1,
                Some("ignored") if !summary_seen => result.skipped += 1,
                Some("FAILED") => result.add_failure(TestFailure {
                    name: cap_text(&caps[1]),
                    reason: String::new(),
                    file: None,
                    line: None,
                }),
                _ => {}
            }
        }
        if let Some(caps) = patterns.pytest_failure.captures(line) {
            saw = true;
            let (file, line_no) = split_location(&caps[1]);
            result.add_failure(TestFailure {
                name: cap_text(&caps[1]),
                reason: cap_reason(caps.get(2).map(|m| m.as_str()).unwrap_or("")),
                file,
                line: line_no,
            });
        }
        if let Some(caps) = patterns.go_failure.captures(line) {
            saw = true;
            result.add_failure(TestFailure {
                name: cap_text(&caps[1]),
                reason: String::new(),
                file: None,
                line: None,
            });
        }
    }
    saw.then_some(result)
}

fn usize_value(value: Option<&Value>) -> usize {
    value.and_then(Value::as_u64).unwrap_or(0) as usize
}
fn assertion_name(value: &Value) -> String {
    let ancestors = value
        .get("ancestorTitles")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
        .unwrap_or_default();
    let title = value.get("title").and_then(Value::as_str).unwrap_or("failed test");
    if ancestors.is_empty() { cap_text(title) } else { cap_text(&format!("{ancestors} {title}")) }
}
fn reason_from_json(value: &Value) -> String {
    value
        .get("failureMessages")
        .and_then(Value::as_array)
        .map(|a| cap_reason_parts(a.iter().filter_map(Value::as_str)))
        .unwrap_or_default()
}
fn file_from_json(value: &Value, suite_name: Option<&str>) -> Option<String> {
    value.get("testFilePath").and_then(Value::as_str).or(suite_name).map(cap_text)
}
fn line_from_json(value: &Value) -> Option<u32> {
    value.get("location").and_then(|l| l.get("line")).and_then(Value::as_u64).map(|n| n as u32)
}
fn cap_reason(reason: &str) -> String {
    cap_reason_parts(std::iter::once(reason))
}
fn cap_reason_parts<'a>(parts: impl IntoIterator<Item = &'a str>) -> String {
    let mut out = String::new();
    for part in parts {
        for word in part.split_whitespace() {
            let extra = usize::from(!out.is_empty()) + word.len();
            if out.len() + extra > MAX_REASON_BYTES {
                out.push('…');
                return out;
            }
            if !out.is_empty() {
                out.push(' ');
            }
            out.push_str(word);
        }
    }
    out
}
fn cap_text(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        if out.len() + ch.len_utf8() > MAX_NAME_BYTES {
            out.push('…');
            break;
        }
        out.push(ch);
    }
    out
}
fn bounded_tail(value: &str) -> &str {
    if value.len() <= MAX_SCAN_BYTES {
        return value;
    }
    let mut start = value.len() - MAX_SCAN_BYTES;
    while start < value.len() && !value.is_char_boundary(start) {
        start += 1;
    }
    &value[start..]
}
struct TextPatterns {
    summary: Regex,
    cargo_case: Regex,
    pytest_failure: Regex,
    go_failure: Regex,
}
fn text_patterns() -> &'static TextPatterns {
    static PATTERNS: OnceLock<TextPatterns> = OnceLock::new();
    PATTERNS.get_or_init(|| TextPatterns {
        summary: Regex::new(r"(?i)(\d+)\s+(passed|failed|skipped|ignored|pending)").unwrap(),
        cargo_case: Regex::new(r"^\s*test\s+(.+?)\s+\.\.\.\s+(FAILED|ignored|ok)\s*$").unwrap(),
        pytest_failure: Regex::new(r"^\s*FAILED\s+([^\s]+(?:::\S+)?)\s*-?\s*(.*)$").unwrap(),
        go_failure: Regex::new(r"^\s*--- FAIL:\s*(\S+)").unwrap(),
    })
}
fn split_location(value: &str) -> (Option<String>, Option<u32>) {
    let Some((file, line)) = value.rsplit_once(':') else { return (None, None) };
    (Some(cap_text(file)), line.parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cargo_text_and_failures() {
        let output = include_str!("../tests/fixtures/test-results/cargo.txt");
        let result = parse("cargo test", output).unwrap();
        assert_eq!((result.passed, result.failed, result.skipped), (142, 2, 1));
        assert_eq!(result.failures.len(), 2);
        assert!(result.failures[0].name.contains("parser::rejects"));
    }

    #[test]
    fn parses_jest_json_with_locations() {
        let output = include_str!("../tests/fixtures/test-results/jest.json");
        let result = parse("vitest --reporter=json", output).unwrap();
        assert_eq!((result.passed, result.failed, result.skipped), (3, 1, 1));
        assert_eq!(result.failures[0].line, Some(27));
    }

    #[test]
    fn parses_pytest_summary_and_reason() {
        let output = include_str!("../tests/fixtures/test-results/pytest.txt");
        let result = parse("pytest", output).unwrap();
        assert_eq!((result.passed, result.failed, result.skipped), (8, 1, 2));
        assert!(!result.failures[0].reason.is_empty());
    }

    #[test]
    fn parses_go_json_lines() {
        let output = include_str!("../tests/fixtures/test-results/go.jsonl");
        let result = parse("go test -json ./...", output).unwrap();
        assert_eq!((result.passed, result.failed, result.skipped), (2, 1, 1));
    }

    #[test]
    fn caps_unicode_reasons_without_panicking() {
        let reason = "é".repeat(200);
        let result = parse("pytest", &format!("FAILED tests/test.py::bad - {reason}")).unwrap();
        assert!(result.failures[0].reason.len() <= MAX_REASON_BYTES + 3);
    }

    #[test]
    fn parses_pytest_json_without_double_counting_summary() {
        let output = r#"{"summary":{"passed":2,"failed":1,"skipped":1,"total":4},"tests":[{"outcome":"passed"},{"outcome":"passed"},{"outcome":"skipped"},{"outcome":"failed","nodeid":"tests/test.py::bad"}]}"#;
        let result = parse("pytest --json", output).unwrap();
        assert_eq!((result.passed, result.failed, result.skipped), (2, 1, 1));
    }

    #[test]
    fn merges_delta_counts_without_resetting() {
        let mut result = parse("cargo test", "test parser::one ... ok").unwrap();
        result.merge(parse("cargo test", "test parser::two ... ok").unwrap());
        assert_eq!(result.passed, 2);
    }

    #[test]
    fn uses_jest_suite_name_and_adds_todo_count() {
        let output = r#"{"numTotalTests":3,"numPassedTests":1,"numFailedTests":1,"numPendingTests":0,"numTodoTests":1,"testResults":[{"name":"src/parser.test.ts","assertionResults":[{"title":"rejects","status":"failed","failureMessages":["bad"],"location":{"line":9}}]}]}"#;
        let result = parse("jest --json", output).unwrap();
        assert_eq!(result.skipped, 1);
        assert_eq!(result.failures[0].file.as_deref(), Some("src/parser.test.ts"));
    }
}
