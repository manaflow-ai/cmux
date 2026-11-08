//! Conservative detection of removed tests, added skips and weakened assertions.
//!
//! Examines only edit payloads, blanks comments/string examples, and compares assertion
//! subjects rather than positional lines. Reports retain exact changed blocks and context
//! for Restore. Counts across all files in the edit suppress moved/replaced tests.

use std::collections::HashMap;
use std::sync::OnceLock;

use regex::Regex;
use serde::Serialize;
use serde_json::{Value, json};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Finding {
    pub kind: &'static str,
    /// Old-file line when supplied by the adapter; null for unlocated edit fragments.
    pub line: Option<usize>,
    pub message: &'static str,
    /// Exact changed block with one unchanged context line on either side when available.
    pub old: String,
    pub new: String,
}

#[derive(Debug, Serialize)]
struct FileReport {
    path: String,
    findings: Vec<Finding>,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Language {
    Rust,
    TypeScript,
    Python,
    Go,
    Swift,
}

struct Hunk {
    old: String,
    new: String,
    line: Option<usize>,
    old_code: String,
    new_code: String,
    old_allowlist_entries: usize,
    new_allowlist_entries: usize,
}
struct Edit {
    path: String,
    language: Language,
    hunks: Vec<Hunk>,
}

/// Structured ACP diff content. Without an explicit line, oldText may be an Edit
/// fragment anywhere in the file, so its location is intentionally unknown.
pub fn detect_diffs(diffs: &Value) -> Option<Value> {
    let edits = diffs
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|diff| {
            if diff.get("type").and_then(Value::as_str).is_some_and(|kind| kind != "diff") {
                return None;
            }
            let path = diff.get("path")?.as_str()?;
            let language = test_language(path)?;
            let old = diff.get("oldText").and_then(Value::as_str).unwrap_or("");
            let new = diff.get("newText").and_then(Value::as_str).unwrap_or("");
            let line = diff.get("line").and_then(Value::as_u64).map(|line| line as usize);
            Some(Edit {
                path: path.to_owned(),
                language,
                hunks: split_hunks(old, new, line, language),
            })
        })
        .collect();
    payload(detect_edits(edits))
}

pub fn detect_text(path: &str, old: &str, new: &str, start_line: usize) -> Vec<Finding> {
    let Some(language) = test_language(path) else { return Vec::new() };
    detect_edits(vec![Edit {
        path: path.to_owned(),
        language,
        hunks: split_hunks(old, new, Some(start_line), language),
    }])
    .into_iter()
    .flat_map(|report| report.findings)
    .collect()
}

/// Analyze every hunk together so moving code across hunks doesn't raise an alarm.
pub fn detect_unified_diff(path: &str, patch: &str) -> Vec<Finding> {
    let Some(edit) = unified_edit(path, patch) else { return Vec::new() };
    detect_edits(vec![edit]).into_iter().flat_map(|report| report.findings).collect()
}

pub fn detect_unified_files<I>(files: I) -> Option<Value>
where
    I: IntoIterator<Item = (String, String)>,
{
    payload(detect_edits(
        files.into_iter().filter_map(|(path, patch)| unified_edit(&path, &patch)).collect(),
    ))
}

fn payload(reports: Vec<FileReport>) -> Option<Value> {
    (!reports.is_empty()).then(|| {
        let count = reports.iter().map(|report| report.findings.len()).sum::<usize>();
        json!({"count": count, "files": reports})
    })
}

fn unified_edit(path: &str, patch: &str) -> Option<Edit> {
    let language = test_language(path)?;
    let (mut hunks, mut old, mut new) = (Vec::new(), Vec::new(), Vec::new());
    let (mut line, mut in_hunk) = (None, false);
    for raw in patch.lines() {
        if let Some(header) = raw.strip_prefix("@@ ") {
            if in_hunk {
                hunks.extend(split_hunks(&old.join("\n"), &new.join("\n"), line, language));
            }
            old.clear();
            new.clear();
            line = header
                .split_whitespace()
                .find_map(|part| part.strip_prefix('-'))
                .and_then(|range| range.split(',').next())
                .and_then(|value| value.parse().ok());
            in_hunk = true;
        } else if in_hunk {
            match raw.as_bytes().first().copied() {
                Some(b'-') => old.push(raw[1..].to_owned()),
                Some(b'+') => new.push(raw[1..].to_owned()),
                Some(b' ') => {
                    old.push(raw[1..].to_owned());
                    new.push(raw[1..].to_owned());
                }
                _ => {}
            }
        }
    }
    if in_hunk {
        hunks.extend(split_hunks(&old.join("\n"), &new.join("\n"), line, language));
    }
    Some(Edit { path: path.to_owned(), language, hunks })
}

/// Unique line anchors split whole-file payloads in linear space/time. Common
/// edges become context; each reported block excludes distant unrelated changes.
fn split_hunks(old: &str, new: &str, line: Option<usize>, language: Language) -> Vec<Hunk> {
    let old_lines: Vec<&str> = old.lines().collect();
    let new_lines: Vec<&str> = new.lines().collect();
    let old_code = code_only(old, language);
    let new_code = code_only(new, language);
    let old_code_lines: Vec<&str> = old_code.lines().collect();
    let new_code_lines: Vec<&str> = new_code.lines().collect();
    let old_allowlists = allowlist_line_weights(&old_code);
    let new_allowlists = allowlist_line_weights(&new_code);
    let mut positions: HashMap<&str, (usize, usize)> = HashMap::new();
    for (index, text) in new_lines.iter().enumerate() {
        let entry = positions.entry(text).or_insert((index, 0));
        entry.1 += 1;
    }
    let mut old_counts: HashMap<&str, usize> = HashMap::new();
    for text in &old_lines {
        *old_counts.entry(text).or_default() += 1;
    }
    let (mut anchors, mut floor) = (Vec::new(), 0);
    for (index, text) in old_lines.iter().enumerate() {
        if old_counts.get(text) == Some(&1)
            && let Some(&(other, 1)) = positions.get(text)
            && other >= floor
        {
            anchors.push((index, other));
            floor = other + 1;
        }
    }
    anchors.push((old_lines.len(), new_lines.len()));
    let (mut result, mut old_start, mut new_start) = (Vec::new(), 0, 0);
    for (old_end, new_end) in anchors {
        while old_start < old_end
            && new_start < new_end
            && old_lines[old_start] == new_lines[new_start]
        {
            old_start += 1;
            new_start += 1;
        }
        let (mut oe, mut ne) = (old_end, new_end);
        while oe > old_start && ne > new_start && old_lines[oe - 1] == new_lines[ne - 1] {
            oe -= 1;
            ne -= 1;
        }
        if old_start < oe || new_start < ne {
            let before = usize::from(
                old_start > 0
                    && new_start > 0
                    && old_lines[old_start - 1] == new_lines[new_start - 1],
            );
            let after = usize::from(
                oe < old_lines.len() && ne < new_lines.len() && old_lines[oe] == new_lines[ne],
            );
            result.push(Hunk {
                old: old_lines[old_start - before..oe + after].join("\n"),
                new: new_lines[new_start - before..ne + after].join("\n"),
                line: line.map(|line| line + old_start),
                old_code: old_code_lines.get(old_start..oe).unwrap_or(&[]).join("\n"),
                new_code: new_code_lines.get(new_start..ne).unwrap_or(&[]).join("\n"),
                old_allowlist_entries: old_allowlists
                    .get(old_start..oe)
                    .unwrap_or(&[])
                    .iter()
                    .sum(),
                new_allowlist_entries: new_allowlists
                    .get(new_start..ne)
                    .unwrap_or(&[])
                    .iter()
                    .sum(),
            });
        }
        old_start = old_end.saturating_add(1);
        new_start = new_end.saturating_add(1);
    }
    result
}

fn detect_edits(edits: Vec<Edit>) -> Vec<FileReport> {
    let mut totals: HashMap<Language, (String, String)> = HashMap::new();
    for edit in &edits {
        let (old, new) = totals.entry(edit.language).or_default();
        for hunk in &edit.hunks {
            old.push_str(&hunk.old_code);
            old.push('\n');
            new.push_str(&hunk.new_code);
            new.push('\n');
        }
    }
    // Parse each language's batch once even when an edit touches many files.
    let summaries: HashMap<_, _> = totals
        .iter()
        .map(|(&language, (old, new))| {
            let new_assertions = assertions(language, new);
            let fewer_assertions = assertions(language, old).len() > new_assertions.len();
            let fewer_tests = test_markers(language, old) > test_markers(language, new);
            let more_skips = skips(language, new) > skips(language, old);
            (
                language,
                (
                    fewer_tests,
                    fewer_assertions,
                    more_skips,
                    new_assertions,
                    move_signature(old),
                    move_signature(new),
                ),
            )
        })
        .collect();
    let mut reports = Vec::new();
    let mut allowlist_totals: HashMap<Language, (usize, usize)> = HashMap::new();
    for edit in &edits {
        let total = allowlist_totals.entry(edit.language).or_default();
        for hunk in &edit.hunks {
            total.0 += hunk.old_allowlist_entries;
            total.1 += hunk.new_allowlist_entries;
        }
    }
    for edit in &edits {
        let (fewer_tests, fewer_assertions, more_skips, all_new_assertions, old_moves, new_moves) =
            &summaries[&edit.language];
        let mut findings = Vec::new();
        for hunk in &edit.hunks {
            let old_assertions = assertions(edit.language, &hunk.old_code);
            let new_assertions = assertions(edit.language, &hunk.new_code);
            let reason = if *fewer_tests
                && test_markers(edit.language, &hunk.old_code)
                    > test_markers(edit.language, &hunk.new_code)
                && !new_moves.contains(&move_signature(&hunk.old_code))
            {
                Some(("removed-test", "A test was removed from this edit."))
            } else if *more_skips
                && skips(edit.language, &hunk.new_code) > skips(edit.language, &hunk.old_code)
                && !(test_markers(edit.language, &hunk.new_code) > 0
                    && old_moves.contains(&move_signature(&hunk.new_code)))
            {
                Some(("introduced-skip", "This edit introduces a test skip or ignore."))
            } else if allowlist_totals[&edit.language].1 > allowlist_totals[&edit.language].0
                && hunk.new_allowlist_entries > hunk.old_allowlist_entries
            {
                Some(("allowlist-bypass", "This edit adds an entry to a failure allowlist."))
            } else if old_assertions.iter().any(|old| {
                !all_new_assertions.contains(old)
                    && new_assertions.iter().any(|new| weakens(old, new))
            }) {
                Some((
                    "weakened-assertion",
                    "An exact assertion was replaced with a weaker predicate.",
                ))
            } else if *fewer_assertions
                && new_assertions.is_empty()
                && old_assertions.iter().any(|old| !all_new_assertions.contains(old))
            {
                Some(("removed-assertion", "An assertion was removed while the test remained."))
            } else {
                None
            };
            if let Some((kind, message)) = reason {
                findings.push(Finding {
                    kind,
                    line: hunk.line,
                    message,
                    old: hunk.old.clone(),
                    new: hunk.new.clone(),
                });
            }
        }
        if !findings.is_empty() {
            reports.push(FileReport { path: edit.path.clone(), findings });
        }
    }
    reports
}

fn test_language(path: &str) -> Option<Language> {
    let lower = path.replace('\\', "/").to_ascii_lowercase();
    let file = lower.rsplit('/').next().unwrap_or(&lower);
    let directory = lower.split('/').any(|part| matches!(part, "tests" | "test" | "__tests__"));
    match file.rsplit('.').next()? {
        "rs" if directory
            || matches!(file, "test.rs" | "tests.rs")
            || file.ends_with("_test.rs")
            || file.ends_with("_tests.rs") =>
        {
            Some(Language::Rust)
        }
        "ts" | "tsx" | "mts" | "cts" | "js" | "jsx" | "mjs" | "cjs"
            if directory || file.contains(".test.") || file.contains(".spec.") =>
        {
            Some(Language::TypeScript)
        }
        "py" if directory || file.starts_with("test_") || file.ends_with("_test.py") => {
            Some(Language::Python)
        }
        "go" if file.ends_with("_test.go") => Some(Language::Go),
        "swift" if directory || file.ends_with("tests.swift") || file.ends_with("test.swift") => {
            Some(Language::Swift)
        }
        _ => None,
    }
}
fn pattern(slot: &'static OnceLock<Regex>, text: &str) -> &'static Regex {
    slot.get_or_init(|| Regex::new(text).expect("fixed test-tampering pattern"))
}
fn test_markers(language: Language, code: &str) -> usize {
    static RUST: OnceLock<Regex> = OnceLock::new();
    static TS: OnceLock<Regex> = OnceLock::new();
    static PY: OnceLock<Regex> = OnceLock::new();
    static GO: OnceLock<Regex> = OnceLock::new();
    static SWIFT: OnceLock<Regex> = OnceLock::new();
    let re = match language {
        Language::Rust => pattern(&RUST, r"#\[\s*(?:test|(?:[\w]+::)+test)(?:\s*\]|\s*\()"),
        Language::TypeScript => {
            pattern(&TS, r"\b(?:test|it|xit|xtest)(?:\.(?:only|skip|todo|each))?\s*\(")
        }
        Language::Python => pattern(&PY, r"(?m)^\s*(?:async\s+)?def\s+test_\w*\s*\("),
        Language::Go => pattern(&GO, r"\bfunc\s+Test\w+\s*\([^)]*\*testing\.T\b"),
        Language::Swift => pattern(&SWIFT, r"@Test\b|\bfunc\s+test\w*\s*\("),
    };
    re.find_iter(code).count()
}
fn skips(language: Language, code: &str) -> usize {
    static RUST: OnceLock<Regex> = OnceLock::new();
    static TS: OnceLock<Regex> = OnceLock::new();
    static PY: OnceLock<Regex> = OnceLock::new();
    static GO: OnceLock<Regex> = OnceLock::new();
    static SWIFT: OnceLock<Regex> = OnceLock::new();
    let re = match language {
        Language::Rust => pattern(&RUST, r"#\[\s*ignore(?:\s*\]|\s*[=(])"),
        Language::TypeScript => pattern(
            &TS,
            r"\b(?:(?:test|it|describe)\s*\.\s*skip\s*\(|(?:xit|xtest|xdescribe)\s*\()",
        ),
        Language::Python => pattern(
            &PY,
            r"\b(?:pytest\.mark\.skip(?:if)?\b|unittest\.skip(?:If|Unless)?\s*\(|pytest\.skip\s*\()",
        ),
        Language::Go => pattern(&GO, r"\b(?:t|tb)\.Skip(?:Now|f)?\s*\("),
        Language::Swift => pattern(&SWIFT, r"\bXCTSkip(?:If|Unless)?\s*\(|\.disabled\s*\("),
    };
    re.find_iter(code).count()
}
fn allowlist_line_weights(code: &str) -> Vec<usize> {
    let mut array_depth = 0isize;
    code.lines()
        .map(|line| {
            let line = compact(line);
            let lower = line.to_ascii_lowercase();
            let named =
                lower.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_').any(|word| {
                    word.contains("allowlist")
                        && ["fail", "flaky", "skip", "ignore", "quarantine"]
                            .iter()
                            .any(|name| word.contains(name))
                });
            let mutation =
                [".push(", ".insert(", ".add(", "append("].iter().any(|call| lower.contains(call));
            let relevant = array_depth > 0 || (named && (mutation || lower.contains('=')));
            if !relevant {
                return 0;
            }
            // The lexer retains only opaque quote pairs, never string contents.
            let entries = line.matches("\"\"").count();
            if array_depth > 0 || (named && lower.contains('=')) {
                array_depth += line.bytes().filter(|byte| *byte == b'[').count() as isize;
                array_depth -= line.bytes().filter(|byte| *byte == b']').count() as isize;
                array_depth = array_depth.max(0);
            }
            entries.max(usize::from(mutation))
        })
        .collect()
}

#[derive(Debug, PartialEq, Eq)]
struct Assertion {
    subject: String,
    strength: &'static str,
    signature: String,
}
fn compact(text: &str) -> String {
    text.chars().filter(|ch| !ch.is_whitespace()).collect()
}
fn move_signature(code: &str) -> String {
    static NAME: OnceLock<Regex> = OnceLock::new();
    // Renaming a function doesn't change the behavior of a moved test.
    compact(&pattern(&NAME, r"\b(fn|def|func)\s+\w+").replace_all(code, "$1 _"))
}
fn assertions(language: Language, code: &str) -> Vec<Assertion> {
    if language == Language::Python {
        return code
            .lines()
            .filter_map(|line| {
                let expression = line.trim_start().strip_prefix("assert ")?;
                let expression = compact(expression.split(',').next().unwrap_or(expression));
                let (subject, strength) = predicate(&expression, "python");
                Some(Assertion { subject, strength, signature: expression })
            })
            .collect();
    }
    let code = compact(code);
    let mut result = Vec::new();
    let names: &[&str] = match language {
        Language::Rust => &["assert_eq!", "assert_ne!", "assert!"],
        Language::TypeScript => &["expect"],
        Language::Go => &[
            "require.Equal",
            "assert.Equal",
            "require.NotNil",
            "assert.NotNil",
            "require.True",
            "assert.True",
            "t.Errorf",
            "t.Fatal",
            "t.Fatalf",
        ],
        Language::Swift => {
            &["XCTAssertEqual", "XCTAssertNotNil", "XCTAssertTrue", "XCTAssertFalse", "#expect"]
        }
        Language::Python => &[],
    };
    for name in names {
        for (start, end, args) in calls(&code, name) {
            let args = arguments(args);
            let first = args.first().copied().unwrap_or("");
            let (subject, strength) = match language {
                Language::TypeScript => {
                    let matcher = code[end + 1..]
                        .strip_prefix('.')
                        .unwrap_or("")
                        .split('(')
                        .next()
                        .unwrap_or("");
                    let strength = match matcher {
                        "toEqual" | "toStrictEqual" | "toBe" => "exact",
                        "toBeTruthy"
                        | "toBeDefined"
                        | "toBeGreaterThan"
                        | "toBeGreaterThanOrEqual"
                        | "toBeLessThan"
                        | "toBeLessThanOrEqual" => "weak",
                        _ => "other",
                    };
                    (first.to_owned(), strength)
                }
                Language::Rust if *name == "assert_eq!" => (first.to_owned(), "exact"),
                Language::Rust if *name == "assert!" => predicate(first, "rust"),
                Language::Go if name.ends_with(".Equal") && args.len() >= 3 => {
                    (args[2].to_owned(), "exact")
                }
                Language::Go if name.ends_with(".NotNil") && args.len() >= 2 => {
                    (args[1].to_owned(), "weak")
                }
                Language::Go if name.ends_with(".True") && args.len() >= 2 => {
                    predicate(args[1], "go")
                }
                Language::Swift if *name == "XCTAssertEqual" => (first.to_owned(), "exact"),
                Language::Swift if *name == "XCTAssertNotNil" => (first.to_owned(), "weak"),
                Language::Swift if *name == "#expect" || *name == "XCTAssertTrue" => {
                    predicate(first, "swift")
                }
                _ => (first.to_owned(), "other"),
            };
            let signature = if language == Language::TypeScript {
                code[start..=end].to_owned() + code[end + 1..].split('(').next().unwrap_or("")
            } else {
                code[start..=end].to_owned()
            };
            result.push(Assertion { subject, strength, signature });
        }
    }
    result
}
fn predicate(expression: &str, language: &str) -> (String, &'static str) {
    if let Some((subject, _)) = expression.split_once("==") {
        return (subject.to_owned(), "exact");
    }
    for suffix in match language {
        "rust" => &[".is_some()", ".is_ok()"][..],
        "python" => &["isnotNone"][..],
        "swift" => &["!=nil"][..],
        _ => &[][..],
    } {
        if let Some(subject) = expression.strip_suffix(suffix) {
            return (subject.to_owned(), "weak");
        }
    }
    for operator in [">=", "<=", ">", "<"] {
        if let Some((subject, _)) = expression.split_once(operator) {
            return (subject.to_owned(), "weak");
        }
    }
    if !expression.contains(['=', '!', '&', '|', ':']) {
        return (expression.to_owned(), "weak");
    }
    (expression.to_owned(), "other")
}
fn weakens(old: &Assertion, new: &Assertion) -> bool {
    old.strength == "exact"
        && new.strength == "weak"
        && !old.subject.is_empty()
        && old.subject == new.subject
}
fn calls<'a>(code: &'a str, name: &str) -> Vec<(usize, usize, &'a str)> {
    let mut result = Vec::new();
    for (start, _) in code.match_indices(&(name.to_owned() + "(")) {
        if start > 0
            && (code.as_bytes()[start - 1].is_ascii_alphanumeric()
                || code.as_bytes()[start - 1] == b'_')
        {
            continue;
        }
        let open = start + name.len();
        let mut depth = 0;
        for (offset, byte) in code.as_bytes()[open..].iter().enumerate() {
            match byte {
                b'(' => depth += 1,
                b')' => {
                    depth -= 1;
                    if depth == 0 {
                        let end = open + offset;
                        result.push((start, end, &code[open + 1..end]));
                        break;
                    }
                }
                _ => {}
            }
        }
    }
    result
}
fn arguments(code: &str) -> Vec<&str> {
    let (mut result, mut depth, mut start) = (Vec::new(), 0, 0);
    for (index, byte) in code.bytes().enumerate() {
        match byte {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b',' if depth == 0 => {
                result.push(&code[start..index]);
                start = index + 1;
            }
            _ => {}
        }
    }
    result.push(&code[start..]);
    result
}

/// Preserve byte offsets/newlines while blanking comments, quoted examples,
/// Python docstrings, JS templates and Rust raw-string fixtures.
fn code_only(text: &str, language: Language) -> String {
    let input = text.as_bytes();
    let mut output = input.to_vec();
    let mut index = 0;
    while index < input.len() {
        let mut end = None;
        let mut literal = false;
        if (language == Language::Python && input[index] == b'#')
            || (language != Language::Python && input[index..].starts_with(b"//"))
        {
            end = Some(
                input[index..]
                    .iter()
                    .position(|byte| *byte == b'\n')
                    .map_or(input.len(), |offset| index + offset),
            );
        } else if language != Language::Python && input[index..].starts_with(b"/*") {
            let (mut cursor, mut depth) = (index + 2, 1);
            while cursor < input.len() && depth > 0 {
                if input[cursor..].starts_with(b"/*") {
                    depth += 1;
                    cursor += 2;
                } else if input[cursor..].starts_with(b"*/") {
                    depth -= 1;
                    cursor += 2;
                } else {
                    cursor += 1;
                }
            }
            end = Some(cursor);
        } else if language == Language::Rust && input[index] == b'r' {
            let mut quote = index + 1;
            while quote < input.len() && input[quote] == b'#' {
                quote += 1;
            }
            if quote < input.len() && input[quote] == b'"' {
                let hashes = quote - index - 1;
                let mut cursor = quote + 1;
                while cursor < input.len() {
                    if input[cursor] == b'"'
                        && input
                            .get(cursor + 1..cursor + 1 + hashes)
                            .is_some_and(|suffix| suffix.iter().all(|byte| *byte == b'#'))
                    {
                        cursor += 1 + hashes;
                        break;
                    }
                    cursor += 1;
                }
                end = Some(cursor);
                literal = true;
            }
        }
        if end.is_none() && matches!(input[index], b'"' | b'\'' | b'`') {
            let quote = input[index];
            // A Rust lifetime isn't a char/string literal.
            if !(language == Language::Rust
                && quote == b'\''
                && input.get(index + 2) != Some(&b'\''))
            {
                let width =
                    if input.get(index..index + 3).is_some_and(|prefix| prefix == [quote; 3]) {
                        3
                    } else {
                        1
                    };
                let mut cursor = index + width;
                while cursor < input.len() {
                    if input[cursor] == b'\\' {
                        cursor = (cursor + 2).min(input.len());
                    } else if input
                        .get(cursor..cursor + width)
                        .is_some_and(|suffix| suffix.iter().all(|byte| *byte == quote))
                    {
                        cursor += width;
                        break;
                    } else {
                        cursor += 1;
                    }
                }
                end = Some(cursor);
                literal = true;
            }
        }
        if let Some(end) = end {
            for byte in &mut output[index..end] {
                if *byte != b'\n' && *byte != b'\r' {
                    *byte = b' ';
                }
            }
            if literal && end > index + 1 {
                output[index] = b'"';
                output[end - 1] = b'"';
            }
            index = end;
        } else {
            index += 1;
        }
    }
    String::from_utf8(output).expect("code preserves UTF-8")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixtures_cover_true_and_false_cases_in_every_language() {
        let cases = [
            (
                "tests/tamper.rs",
                include_str!("../tests/fixtures/test-tampering/rust_remove.diff"),
                Some("removed-test"),
            ),
            (
                "tests/tamper.test.ts",
                include_str!("../tests/fixtures/test-tampering/typescript_weaken.diff"),
                Some("weakened-assertion"),
            ),
            (
                "tests/tamper.py",
                include_str!("../tests/fixtures/test-tampering/python_skip.diff"),
                Some("introduced-skip"),
            ),
            (
                "tests/tamper_test.go",
                include_str!("../tests/fixtures/test-tampering/go_allowlist.diff"),
                Some("allowlist-bypass"),
            ),
            (
                "Tests/TamperTests.swift",
                include_str!("../tests/fixtures/test-tampering/swift_weaken.diff"),
                Some("weakened-assertion"),
            ),
            (
                "tests/rename.rs",
                include_str!("../tests/fixtures/test-tampering/rust_rename.diff"),
                None,
            ),
            (
                "tests/equivalent.rs",
                include_str!("../tests/fixtures/test-tampering/rust_equivalent.diff"),
                None,
            ),
            (
                "tests/move.rs",
                include_str!("../tests/fixtures/test-tampering/rust_move.diff"),
                None,
            ),
            (
                "tests/move_ignored.rs",
                include_str!("../tests/fixtures/test-tampering/rust_move_ignored.diff"),
                None,
            ),
            (
                "tests/rename.test.ts",
                include_str!("../tests/fixtures/test-tampering/typescript_stronger.diff"),
                None,
            ),
            (
                "tests/insert.test.ts",
                include_str!("../tests/fixtures/test-tampering/typescript_insert.diff"),
                Some("weakened-assertion"),
            ),
            (
                "tests/keep.py",
                include_str!("../tests/fixtures/test-tampering/python_keep.diff"),
                None,
            ),
            (
                "tests/examples.py",
                include_str!("../tests/fixtures/test-tampering/python_examples.diff"),
                None,
            ),
            (
                "tests/keep_test.go",
                include_str!("../tests/fixtures/test-tampering/go_keep.diff"),
                None,
            ),
            (
                "tests/allowlist_test.go",
                include_str!("../tests/fixtures/test-tampering/go_unrelated_allowlist.diff"),
                None,
            ),
            (
                "Tests/KeepTests.swift",
                include_str!("../tests/fixtures/test-tampering/swift_keep.diff"),
                None,
            ),
            (
                "Tests/NotEqualTests.swift",
                include_str!("../tests/fixtures/test-tampering/swift_not_equal.diff"),
                None,
            ),
        ];
        for (path, patch, expected) in cases {
            let findings = detect_unified_diff(path, patch);
            assert_eq!(
                findings.first().map(|finding| finding.kind),
                expected,
                "{path}: {findings:?}"
            );
        }
    }

    #[test]
    fn language_patterns_detect_removal_skip_and_weakening() {
        let cases = [
            (
                "tests/a.rs",
                "#[test]\nfn a() {}",
                "#[test]\n#[ignore]\nfn a() {}",
                "introduced-skip",
            ),
            (
                "tests/a.rs",
                "assert_eq!(count(), 10);",
                "assert!(count() >= 1);",
                "weakened-assertion",
            ),
            (
                "tests/a.rs",
                "assert_eq!(result(), Ok(()));",
                "assert!(result().is_ok());",
                "weakened-assertion",
            ),
            ("tests/a.ts", "test('x', () => {});", "xit('x', () => {});", "introduced-skip"),
            (
                "tests/a.ts",
                "expect(count()).toBe(10);",
                "expect(count()).toBeGreaterThan(0);",
                "weakened-assertion",
            ),
            ("test_a.py", "assert upload() == 'ok'", "assert upload()", "weakened-assertion"),
            (
                "test_a.py",
                "def test_a():\n    assert True",
                "def test_a():\n    pass",
                "removed-assertion",
            ),
            (
                "a_test.go",
                "func TestA(t *testing.T) {}",
                "func TestA(t *testing.T) { t.Skip(\"flaky\") }",
                "introduced-skip",
            ),
            (
                "a_test.go",
                "require.Equal(t, 10, count())",
                "require.NotNil(t, count())",
                "weakened-assertion",
            ),
            (
                "ATests.swift",
                "XCTAssertEqual(count(), 10)",
                "XCTAssertTrue(count() >= 1)",
                "weakened-assertion",
            ),
            (
                "ATests.swift",
                "@Test func a() {}",
                "@Test(.disabled(\"flaky\")) func a() {}",
                "introduced-skip",
            ),
        ];
        for (path, old, new, kind) in cases {
            let findings = detect_text(path, old, new, 10);
            assert_eq!(
                findings.first().map(|finding| finding.kind),
                Some(kind),
                "{path}: {old} -> {new}: {findings:?}"
            );
        }
    }

    #[test]
    fn code_examples_and_equivalent_or_stronger_replacements_stay_quiet() {
        let cases = [
            ("tests/a.rs", "assert_eq!(value(), 10);", "assert!(value() == 10);"),
            ("tests/a.rs", "#[test]\nfn test_old() {}", "#[test]\nfn renamed() {}"),
            (
                "tests/a.rs",
                "let example = r#\"#[test] assert_eq!(x, 1)\"#;",
                "let example = r#\"#[ignore] assert!(x)\"#;",
            ),
            ("tests/a.rs", "/* #[test]\nassert_eq!(x, 1) */", "/* #[ignore]\nassert!(x) */"),
            (
                "tests/a.ts",
                "const example = 'test(\"a\", () => expect(x).toEqual(1))';",
                "const example = 'test.skip(\"a\", () => expect(x).toBeTruthy())';",
            ),
            ("tests/a.ts", "expect(first()).toEqual(10);", "expect(second()).toBeTruthy();"),
            ("tests/a.ts", "emit('before');", "emit('after');"),
            ("test_a.py", "# assert x == 1", "# assert x\n# @pytest.mark.skip"),
            ("test_a.py", "assert count() == 10", "assert count() == 11"),
            ("a_test.go", "require.Equal(t, 10, count())", "require.True(t, count() == 10)"),
            ("ATests.swift", "#expect(count() == 10)", "#expect(count() != 11)"),
            ("ATests.swift", "XCTAssertEqual(count(), 10)", "XCTAssertTrue(count() == 10)"),
        ];
        for (path, old, new) in cases {
            assert!(detect_text(path, old, new, 1).is_empty(), "{path}: {old} -> {new}");
        }
    }

    #[test]
    fn paths_are_test_conventions_only() {
        for (path, old) in [
            ("./tests/a.rs", "#[test]\nfn a() {}"),
            ("src/tests.rs", "#[test]\nfn a() {}"),
            ("src/parser_tests.rs", "#[test]\nfn a() {}"),
            ("/workspace/tests/a.rs", "#[test]\nfn a() {}"),
            ("test/a.py", "def test_old():\n    assert True"),
            ("__tests__/a.mjs", "test('old', () => {})"),
            ("Tests/ATests.swift", "@Test func a() {}"),
        ] {
            assert!(!detect_text(path, old, "", 1).is_empty(), "{path}");
        }
        assert!(detect_text("src/lib.rs", "#[test]\nfn a() {}", "", 1).is_empty());
        assert!(detect_text("src/test_helpers.ts", "test('a', () => {})", "", 1).is_empty());
        assert!(detect_text("tests/helpers.go", "func TestA(t *testing.T) {}", "", 1).is_empty());
    }

    #[test]
    fn cross_file_move_and_stronger_replacement_are_not_removals() {
        let value = json!([
            {"type": "diff", "path": "tests/a.rs", "oldText": "#[test]\nfn old() { assert_eq!(x, 1); }", "newText": ""},
            {"type": "diff", "path": "tests/b.rs", "oldText": "", "newText": "#[test]\nfn renamed() { assert!(x == 1); }"}
        ]);
        assert!(detect_diffs(&value).is_none());
        // Swapping assertions between two locations changes neither assertion.
        let swapped = json!([
            {"path": "tests/a.rs", "oldText": "assert_eq!(x, 10);", "newText": "assert!(x > 0);"},
            {"path": "tests/b.rs", "oldText": "assert!(x > 0);", "newText": "assert_eq!(x, 10);"}
        ]);
        assert!(detect_diffs(&swapped).is_none());
        let mixed = json!([
            {"path": "tests/moved.rs", "oldText": "#[test]\nfn old() { assert_eq!(x, 1); }", "newText": ""},
            {"path": "tests/renamed.rs", "oldText": "", "newText": "#[test]\nfn renamed() { assert_eq!(x, 1); }"},
            {"path": "tests/removed.rs", "oldText": "#[test]\nfn gone() { assert_eq!(y, 2); }", "newText": ""}
        ]);
        let report = detect_diffs(&mixed).expect("real removal");
        assert_eq!(report["files"].as_array().unwrap().len(), 1);
        assert_eq!(report["files"][0]["path"], "tests/removed.rs");
    }

    #[test]
    fn reports_are_exact_local_blocks_with_context_and_honest_lines() {
        let old = "fn a() {\n    assert_eq!(value(), 10);\n}\nconst ANCHOR: u8 = 1;\nfn unrelated() {\n    let color = 10;\n}";
        let new = "fn a() {\n}\nconst ANCHOR: u8 = 1;\nfn unrelated() {\n    let color = 20;\n}";
        let findings = detect_text("tests/a.rs", old, new, 40);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].line, Some(41));
        assert_eq!(findings[0].old, "fn a() {\n    assert_eq!(value(), 10);\n}");
        assert_eq!(findings[0].new, "fn a() {\n}");
        assert!(!findings[0].old.contains("color"));
        let report = detect_diffs(&json!([{"path": "tests/a.rs", "oldText": old, "newText": new}]))
            .expect("report");
        assert!(report["files"][0]["findings"][0]["line"].is_null());
        assert_eq!(report["count"], 1);
    }

    #[test]
    fn hunks_use_patch_lines_and_do_not_compare_shifted_assertions() {
        let patch = "@@ -20,3 +20,4 @@\n fn a() {\n+    setup();\n-    assert_eq!(value(), 10);\n+    assert!(value() >= 1);\n }\n";
        let findings = detect_unified_diff("tests/a.rs", patch);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].line, Some(21));
        assert_eq!(findings[0].kind, "weakened-assertion");
    }

    #[test]
    fn allowlist_entries_are_counted_without_reading_string_examples_as_code() {
        for (old, new) in [
            ("const flakyAllowlist = ['old'];", "const flakyAllowlist = ['old', 'new'];"),
            (
                "const failureAllowlist = [\n  'old',\n];",
                "const failureAllowlist = [\n  'old',\n  'new',\n];",
            ),
        ] {
            let findings = detect_text("a.test.ts", old, new, 1);
            assert_eq!(findings.first().map(|finding| finding.kind), Some("allowlist-bypass"));
        }
        for (old, new) in [
            ("", "const failureAllowlist = [];"),
            ("const flakyAllowlist = ['old'];", "const flakyAllowlist = ['old']; // 'example'"),
            ("const trafficAllowlist = ['old'];", "const trafficAllowlist = ['old', 'new'];"),
            (
                "const example = 'flakyAllowlist.push(1)';",
                "const example = 'flakyAllowlist.push(2)';",
            ),
        ] {
            assert!(detect_text("a.test.ts", old, new, 1).is_empty(), "{new}");
        }
    }
}
