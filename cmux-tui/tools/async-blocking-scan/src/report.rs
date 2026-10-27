//! Output: one line per finding and the queue counts, or one JSON document.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use serde::Serialize;

use crate::finding::{Finding, Kind};
use crate::{Outcome, Request};

/// The JSON document `--json` prints.
#[derive(Debug, Serialize)]
pub struct JsonReport<'a> {
    pub roots: Vec<String>,
    pub kinds: Vec<Kind>,
    /// The `--diff` revision; `findings` then holds only the new ones.
    pub base: Option<&'a str>,
    pub files: usize,
    /// Reported findings per kind.
    pub counts: BTreeMap<Kind, usize>,
    /// Reported findings per stability queue (Q11, Q12, Q20).
    pub queues: BTreeMap<&'static str, usize>,
    /// Reported findings per crate and kind.
    pub by_crate: BTreeMap<&'a str, BTreeMap<Kind, usize>>,
    pub exempt_count: usize,
    pub base_findings: Option<usize>,
    pub findings: &'a [Finding],
    pub exempt: &'a [Finding],
    pub parse_errors: Vec<String>,
}

pub fn json_report<'a>(request: &'a Request, outcome: &'a Outcome) -> JsonReport<'a> {
    let reported = outcome.reported();
    JsonReport {
        roots: request.roots.iter().map(|r| r.to_string_lossy().into_owned()).collect(),
        kinds: request.kinds.iter().copied().collect(),
        base: request.diff_base.as_deref(),
        files: outcome.head.files,
        counts: counts(request, reported),
        queues: queues(request, reported),
        by_crate: by_crate(reported),
        exempt_count: outcome.head.exempt.len(),
        base_findings: outcome.base_findings,
        findings: reported,
        exempt: &outcome.head.exempt,
        parse_errors: outcome.head.parse_errors.iter().map(ToString::to_string).collect(),
    }
}

/// Every selected kind, with 0 when it has no finding.
pub fn counts(request: &Request, findings: &[Finding]) -> BTreeMap<Kind, usize> {
    let mut counts: BTreeMap<Kind, usize> = request.kinds.iter().map(|k| (*k, 0)).collect();
    for finding in findings {
        *counts.entry(finding.kind).or_default() += 1;
    }
    counts
}

/// Every queue a selected kind feeds, with 0 when it has no finding.
pub fn queues(request: &Request, findings: &[Finding]) -> BTreeMap<&'static str, usize> {
    let mut queues: BTreeMap<&'static str, usize> =
        request.kinds.iter().map(|k| (k.queue(), 0)).collect();
    for finding in findings {
        *queues.entry(finding.kind.queue()).or_default() += 1;
    }
    queues
}

fn by_crate(findings: &[Finding]) -> BTreeMap<&str, BTreeMap<Kind, usize>> {
    let mut out: BTreeMap<&str, BTreeMap<Kind, usize>> = BTreeMap::new();
    for finding in findings {
        *out.entry(finding.krate.as_str()).or_default().entry(finding.kind).or_default() += 1;
    }
    out
}

/// The text report: findings as `file:line:col`, then the counts.
pub fn text_report(request: &Request, outcome: &Outcome, show_exempt: bool) -> String {
    let reported = outcome.reported();
    let mut out = String::new();
    for finding in reported {
        line(&mut out, finding, None);
    }
    if show_exempt {
        for finding in &outcome.head.exempt {
            line(&mut out, finding, finding.exempt.as_deref());
        }
    }
    for error in &outcome.head.parse_errors {
        let _ = writeln!(out, "error: {error}");
    }
    if !out.is_empty() {
        out.push('\n');
    }
    let scope = match &request.diff_base {
        Some(rev) => format!("new since {rev}"),
        None => "all".to_string(),
    };
    let _ = writeln!(out, "async-blocking-scan: {} files, {scope}", outcome.head.files);
    let counts = counts(request, reported);
    for (queue, total) in queues(request, reported) {
        let kinds: Vec<String> = counts
            .iter()
            .filter(|(kind, _)| kind.queue() == queue)
            .map(|(kind, n)| format!("{kind} {n}"))
            .collect();
        let _ = writeln!(out, "{queue}: {total} ({})", kinds.join(", "));
    }
    let _ = writeln!(out, "exempt: {}", outcome.head.exempt.len());
    if !outcome.head.parse_errors.is_empty() {
        let _ = writeln!(out, "unparsed files: {}", outcome.head.parse_errors.len());
    }
    out
}

fn line(out: &mut String, finding: &Finding, reason: Option<&str>) {
    let function = if finding.function.is_empty() {
        String::new()
    } else {
        format!(" in {}", finding.function)
    };
    let exempt = reason.map(|r| format!(" [exempt: {r}]")).unwrap_or_default();
    let _ = writeln!(
        out,
        "{}:{}:{}: {}/{}{function}: {}{exempt}",
        finding.file, finding.line, finding.column, finding.kind, finding.rule, finding.message
    );
}
