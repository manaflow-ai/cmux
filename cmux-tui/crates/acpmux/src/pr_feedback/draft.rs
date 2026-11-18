//! The messages a person sends their agent, built from what was read: the failing checks that
//! are this branch's own (each with its failing step and the end of its log) and the review
//! threads nobody resolved. Plain Markdown the composer shows as typed text; the person edits it
//! and sends it, or not. Pure, so the page and the CLI word it the same way.

use serde::Serialize;

/// Log lines a tail keeps, ending at the last `##[error]` line.
pub(crate) const TAIL_LINES: usize = 40;
/// The most characters of one log line, of one comment body.
const LINE_CHARS: usize = 300;
const BODY_CHARS: usize = 2_000;

/// One red check of this branch's own.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Red {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workflow: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The job's first failed step.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub log_tail: Option<String>,
    /// Why there is no log: a commit status, too many reds, or a read that failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub log_note: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub(crate) struct Comment {
    pub author: String,
    pub body: String,
}

/// One unresolved review thread.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub(crate) struct Thread {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub outdated: bool,
    pub comments: Vec<Comment>,
}

/// Which pull request, as the drafts name it.
#[derive(Debug, Clone, Default)]
pub(crate) struct Pr {
    pub repo: String,
    pub number: u64,
    pub head: String,
    pub base: String,
}

impl Pr {
    fn reference(&self) -> String {
        format!("{}#{}", self.repo, self.number)
    }
    fn short_head(&self) -> &str {
        self.head.get(..8).unwrap_or(&self.head)
    }
}

fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let mut out: String = text.chars().take(max).collect();
    out.push('…');
    out
}

/// A log line without the timestamp GitHub puts first (`2026-11-18T10:00:00.1234567Z `).
fn untimed(line: &str) -> &str {
    let b = line.as_bytes();
    let stamped = b.len() > 20
        && b.first().is_some_and(u8::is_ascii_digit)
        && b.get(4) == Some(&b'-')
        && b.get(10) == Some(&b'T');
    if !stamped {
        return line;
    }
    match line.find("Z ") {
        Some(at) if at < 40 => &line[at + 2..],
        _ => line,
    }
}

/// The end of a job's log, where it failed: the `TAIL_LINES` lines up to and with the last
/// `##[error]` line (after it come the post steps' cleanup), else the last lines; timestamps and
/// group markers off, each line clipped.
pub(crate) fn log_tail(log: &str) -> String {
    let lines: Vec<&str> = log.lines().map(untimed).collect();
    let end = lines.iter().rposition(|l| l.contains("##[error]")).map_or(lines.len(), |i| i + 1);
    let start = end.saturating_sub(TAIL_LINES);
    lines[start..end]
        .iter()
        .filter(|l| !l.starts_with("##[endgroup]"))
        .map(|l| clip(l.trim_start_matches("##[group]"), LINE_CHARS))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The longest run of backticks in `text`, so a fence around it is one longer.
fn fence_for(text: &str) -> String {
    let (mut longest, mut run) = (0, 0);
    for c in text.chars() {
        run = if c == '`' { run + 1 } else { 0 };
        longest = longest.max(run);
    }
    "`".repeat((longest + 1).max(3))
}

fn names(list: &[String]) -> String {
    const SHOWN: usize = 5;
    let mut shown: Vec<String> = list.iter().take(SHOWN).cloned().collect();
    if list.len() > SHOWN {
        shown.push(format!("{} more", list.len() - SHOWN));
    }
    shown.join(", ")
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// The sentence on what was left out: the reds the base tip shares, and the checks still running.
fn left_out(pr: &Pr, on_base: &[String], pending: usize) -> Vec<String> {
    let mut out = Vec::new();
    if !on_base.is_empty() {
        out.push(format!(
            "Left out: {} that also {} on {}'s tip, so not this branch's ({}).",
            plural(on_base.len(), "failing check", "failing checks"),
            if on_base.len() == 1 { "fails" } else { "fail" },
            if pr.base.is_empty() { "the base branch" } else { pr.base.as_str() },
            names(on_base)
        ));
    }
    if pending > 0 {
        out.push(format!("{} still running.", plural(pending, "check is", "checks are")));
    }
    out
}

/// The checks message; None when no red is this branch's own (then [`no_reds`] says why).
pub(crate) fn checks(pr: &Pr, own: &[Red], on_base: &[String], pending: usize) -> Option<String> {
    if own.is_empty() {
        return None;
    }
    let mut out = format!(
        "Fix the failing checks on {} (head {}). {} on this branch only:\n",
        pr.reference(),
        pr.short_head(),
        if own.len() == 1 {
            "This one fails".to_owned()
        } else {
            format!("These {} fail", own.len())
        }
    );
    for red in own {
        out.push_str(&format!("\n### {}", red.name));
        if let Some(workflow) = &red.workflow {
            out.push_str(&format!(" ({workflow})"));
        }
        out.push('\n');
        if let Some(step) = &red.step {
            out.push_str(&format!("Failing step: {step}\n"));
        }
        if let Some(url) = &red.url {
            out.push_str(&format!("{url}\n"));
        }
        match (&red.log_tail, &red.log_note) {
            (Some(tail), _) if !tail.is_empty() => {
                let fence = fence_for(tail);
                out.push_str(&format!("{fence}text\n{tail}\n{fence}\n"));
            }
            (_, Some(note)) => out.push_str(&format!("({note})\n")),
            _ => {}
        }
    }
    let notes = left_out(pr, on_base, pending);
    if !notes.is_empty() {
        out.push('\n');
        out.push_str(&notes.join("\n"));
        out.push('\n');
    }
    Some(out)
}

/// Why there is nothing to send about checks.
pub(crate) fn no_reds(pr: &Pr, on_base: &[String], pending: usize) -> String {
    let mut out = format!("No failing check on {} is this branch's own.", pr.reference());
    for note in left_out(pr, on_base, pending) {
        out.push(' ');
        out.push_str(&note);
    }
    out
}

/// The review comments message; None when no thread is unresolved.
pub(crate) fn comments(pr: &Pr, threads: &[Thread], resolved: usize) -> Option<String> {
    if threads.is_empty() {
        return None;
    }
    let mut out = format!(
        "Address the unresolved review comments on {} (head {}):\n",
        pr.reference(),
        pr.short_head()
    );
    for (i, thread) in threads.iter().enumerate() {
        let place = match (&thread.path, thread.line) {
            (Some(path), Some(line)) => format!("`{path}:{line}`"),
            (Some(path), None) => format!("`{path}`"),
            _ => "The pull request".to_owned(),
        };
        out.push_str(&format!("\n{}. {place}", i + 1));
        if thread.outdated {
            out.push_str(" (outdated: the code moved since)");
        }
        if let Some(url) = &thread.url {
            out.push_str(&format!(" {url}"));
        }
        out.push('\n');
        for c in &thread.comments {
            let body = clip(c.body.trim(), BODY_CHARS);
            let quoted = body.lines().collect::<Vec<_>>().join("\n   > ");
            out.push_str(&format!("   > **{}**: {quoted}\n", c.author));
        }
    }
    if resolved > 0 {
        out.push_str(&format!(
            "\nLeft out: {} already resolved.\n",
            plural(resolved, "thread", "threads")
        ));
    }
    Some(out)
}

pub(crate) fn no_comments(pr: &Pr, resolved: usize) -> String {
    if resolved > 0 {
        format!(
            "No unresolved review comments on {} ({} resolved).",
            pr.reference(),
            plural(resolved, "thread", "threads")
        )
    } else {
        format!("No review comments on {}.", pr.reference())
    }
}
