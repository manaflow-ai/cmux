//! Small, streaming-friendly parsers for common test-runner output.
//!
//! Test output is untrusted and can be arbitrarily large. The parser keeps only
//! the first few failures and caps every captured reason, while counts continue
//! to update as more lines arrive.

use regex::Regex;
use serde_json::Value;

const MAX_FAILURES: usize = 32;
const MAX_REASON_BYTES: usize = 240;
const MAX_JSON_BYTES: usize = 128 * 1024;

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
        self.failed = self.failed.max(1);
        if self.failures.iter().any(|old| old.name == failure.name) {
            return;
        }
        if self.failures.len() < MAX_FAILURES {
            self.failures.push(failure);
        } else {
            self.failures_truncated = true;
        }
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

    let trimmed = output.trim_start();
    let mut parsed = if trimmed.starts_with('{') || trimmed.starts_with('[') {
        parse_json(output)
    } else {
        None
    };
    if parsed.is_none() {
        parsed = parse_text(output);
    }
    parsed.filter(|result| !result.is_empty()).map(|mut result| {
        result.normalize();
        result
    })
}

fn parse_json(output: &str) -> Option<TestResults> {
    if output.len() > MAX_JSON_BYTES {
        return None;
    }
    if let Ok(value) = serde_json::from_str::<Value>(output.trim()) {
        if let Some(object) = value.as_object() {
            let has_jest_counts = object.get("numTotalTests").is_some();
            let mut result = TestResults {
                total: usize_value(object.get("numTotalTests")),
                passed: usize_value(object.get("numPassedTests")),
                failed: usize_value(object.get("numFailedTests")),
                skipped: usize_value(
                    object.get("numPendingTests").or_else(|| object.get("numTodoTests")),
                ),
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
                                file: file_from_json(assertion),
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
                result.passed = result.passed.max(usize_value(summary.get("passed")));
                result.failed = result.failed.max(usize_value(summary.get("failed")));
                result.skipped = result.skipped.max(usize_value(summary.get("skipped")));
                result.total = result.total.max(usize_value(summary.get("total")));
            }
            if let Some(tests) = object.get("tests").and_then(Value::as_array) {
                for test in tests {
                    match test.get("outcome").and_then(Value::as_str).unwrap_or("") {
                        "passed" => result.passed += 1,
                        "skipped" => result.skipped += 1,
                        "failed" => result.add_failure(TestFailure {
                            name: test
                                .get("nodeid")
                                .and_then(Value::as_str)
                                .unwrap_or("failed test")
                                .to_owned(),
                            reason: test
                                .pointer("/call/longrepr")
                                .and_then(Value::as_str)
                                .map(cap_reason)
                                .unwrap_or_default(),
                            file: test.get("filename").and_then(Value::as_str).map(str::to_owned),
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
                name: event.get("Test").and_then(Value::as_str).unwrap_or("failed test").to_owned(),
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
    let summary = Regex::new(
        r"(?i)(?:(\d+)\s+passed).*?(?:(\d+)\s+failed)?(?:.*?(\d+)\s+(?:skipped|ignored|pending))?",
    )
    .ok()?;
    let summary_alt = Regex::new(
        r"(?i)(\d+)\s+failed.*?(\d+)\s+passed(?:.*?(\d+)\s+(?:skipped|ignored|pending))?",
    )
    .ok()?;
    let cargo_case = Regex::new(r"^\s*test\s+(.+?)\s+\.\.\.\s+(FAILED|ignored|ok)\s*$").ok()?;
    let pytest_failure = Regex::new(r"^\s*FAILED\s+([^\s]+(?:::\S+)?)\s*-?\s*(.*)$").ok()?;
    let go_failure = Regex::new(r"^\s*--- FAIL:\s*(\S+)").ok()?;
    for line in output.lines() {
        if let Some(caps) = summary.captures(line).or_else(|| summary_alt.captures(line)) {
            let nums: Vec<usize> = caps
                .iter()
                .skip(1)
                .filter_map(|m| m.and_then(|m| m.as_str().parse().ok()))
                .collect();
            let lower = line.to_ascii_lowercase();
            if lower.find("failed").unwrap_or(usize::MAX)
                < lower.find("passed").unwrap_or(usize::MAX)
            {
                result.failed = nums.first().copied().unwrap_or(0);
                result.passed = nums.get(1).copied().unwrap_or(0);
            } else {
                result.passed = nums.first().copied().unwrap_or(0);
                result.failed = nums.get(1).copied().unwrap_or(0);
            }
            result.skipped = nums.get(2).copied().unwrap_or(0);
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
        if let Some(caps) = cargo_case.captures(line) {
            saw = true;
            match caps.get(2).map(|m| m.as_str()) {
                Some("ok") if !summary_seen => result.passed += 1,
                Some("ignored") if !summary_seen => result.skipped += 1,
                Some("FAILED") => result.add_failure(TestFailure {
                    name: caps[1].to_owned(),
                    reason: String::new(),
                    file: None,
                    line: None,
                }),
                _ => {}
            }
        }
        if let Some(caps) = pytest_failure.captures(line) {
            saw = true;
            let (file, line_no) = split_location(&caps[1]);
            result.add_failure(TestFailure {
                name: caps[1].to_owned(),
                reason: cap_reason(caps.get(2).map(|m| m.as_str()).unwrap_or("")),
                file,
                line: line_no,
            });
        }
        if let Some(caps) = go_failure.captures(line) {
            saw = true;
            result.add_failure(TestFailure {
                name: caps[1].to_owned(),
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
    if ancestors.is_empty() { title.to_owned() } else { format!("{ancestors} {title}") }
}
fn reason_from_json(value: &Value) -> String {
    value
        .get("failureMessages")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
        .map(|s| cap_reason(&s))
        .unwrap_or_default()
}
fn file_from_json(value: &Value) -> Option<String> {
    value.get("testFilePath").and_then(Value::as_str).map(str::to_owned)
}
fn line_from_json(value: &Value) -> Option<u32> {
    value.get("location").and_then(|l| l.get("line")).and_then(Value::as_u64).map(|n| n as u32)
}
fn cap_reason(reason: &str) -> String {
    let mut out: String = reason.split_whitespace().collect::<Vec<_>>().join(" ");
    if out.len() > MAX_REASON_BYTES {
        out.truncate(MAX_REASON_BYTES);
        out.push('…');
    }
    out
}
fn split_location(value: &str) -> (Option<String>, Option<u32>) {
    let Some((file, line)) = value.rsplit_once(':') else { return (None, None) };
    (Some(file.to_owned()), line.parse().ok())
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
}
