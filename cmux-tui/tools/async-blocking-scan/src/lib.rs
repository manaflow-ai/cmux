//! async-blocking-scan: a lexical (syn) scan of cmux's Rust code for the
//! stability queues of plans/cmux-next/chrome-parity/p10-stability.md:
//!
//! - `blocking` (Q11): a blocking call lexically inside async code that is
//!   not handed to spawn_blocking / block_in_place, and a std lock guard held
//!   across an `.await` (Chromium: base/threading/scoped_blocking_call.h).
//! - `spawn` (Q12): a statement that drops a tokio JoinHandle, and a thread
//!   started outside `cmux_panic_log::supervise*`.
//! - `pre_exec` (Q20): a call in a `pre_exec` closure that is not
//!   async-signal-safe (Chromium: base/process/launch_posix.cc).
//! - `child` (Q20): a spawned Child that is never awaited, waited, stored or
//!   kill_on_drop (Chromium: base/process/kill.h EnsureProcessTerminated).
//! - `unbounded` (Q20): an unbounded channel without `// unbounded-allow:`.
//!
//! Test-only code (`#[cfg(test)]`, `#[test]`, `tests/`, `*_tests.rs`) is
//! skipped. The rules live in `blocking-paths.toml`.

pub mod attrs;
pub mod child;
pub mod config;
pub mod expand;
pub mod finding;
pub mod guards;
pub mod pre_exec;
pub mod report;
pub mod resolve;
pub mod scan;
pub mod source;

use std::collections::{BTreeSet, HashMap};
use std::fmt;
use std::path::PathBuf;

use crate::config::Config;
use crate::finding::{Finding, Kind};
use crate::scan::{FileInput, ParseError, scan_file};
use crate::source::{SourceError, SourceFile, Tree, collect};

/// What one run scans and how it compares.
#[derive(Debug, Clone)]
pub struct Request {
    pub roots: Vec<PathBuf>,
    pub kinds: BTreeSet<Kind>,
    /// Report only findings that are not at this git revision.
    pub diff_base: Option<String>,
}

/// The findings of one tree (the worktree or a revision).
#[derive(Debug, Default)]
pub struct TreeScan {
    /// Findings without an allow comment.
    pub findings: Vec<Finding>,
    /// Findings an allow comment exempts, with its reason.
    pub exempt: Vec<Finding>,
    pub parse_errors: Vec<ParseError>,
    pub files: usize,
}

/// The result of a run: the worktree's findings, filtered to those new
/// against the base when `--diff` is given.
#[derive(Debug)]
pub struct Outcome {
    pub head: TreeScan,
    /// Findings of the head that the base does not have (only with a base).
    pub new: Option<Vec<Finding>>,
    pub base_findings: Option<usize>,
}

impl Outcome {
    /// The findings the run reports: the new ones with a base, else all.
    pub fn reported(&self) -> &[Finding] {
        self.new.as_deref().unwrap_or(&self.head.findings)
    }
}

#[derive(Debug)]
pub enum RunError {
    Source(SourceError),
    Config(config::ConfigError),
    NoRoots,
}

impl fmt::Display for RunError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RunError::Source(e) => e.fmt(f),
            RunError::Config(e) => e.fmt(f),
            RunError::NoRoots => f.write_str("no --root given"),
        }
    }
}

impl std::error::Error for RunError {}

impl From<SourceError> for RunError {
    fn from(e: SourceError) -> Self {
        RunError::Source(e)
    }
}

impl From<config::ConfigError> for RunError {
    fn from(e: config::ConfigError) -> Self {
        RunError::Config(e)
    }
}

/// Scans the worktree (and the base revision with `diff_base`).
pub fn run(cfg: &Config, request: &Request) -> Result<Outcome, RunError> {
    if request.roots.is_empty() {
        return Err(RunError::NoRoots);
    }
    let head = scan_tree(cfg, request, &Tree::Worktree)?;
    let Some(rev) = &request.diff_base else {
        return Ok(Outcome { head, new: None, base_findings: None });
    };
    let base = scan_tree(cfg, request, &Tree::Git { rev: rev.clone() })?;
    let new = new_findings(&base.findings, &head.findings);
    Ok(Outcome { head, new: Some(new), base_findings: Some(base.findings.len()) })
}

/// Every file under every root of one tree, scanned and filtered to the kinds.
pub fn scan_tree(cfg: &Config, request: &Request, tree: &Tree) -> Result<TreeScan, RunError> {
    let mut files: Vec<SourceFile> = Vec::new();
    for root in &request.roots {
        files.extend(collect(&cfg.scan, root, tree)?);
    }
    let mut out = TreeScan { files: files.len(), ..TreeScan::default() };
    for result in scan_files(cfg, &files) {
        match result {
            Ok(findings) => {
                for finding in findings.into_iter().filter(|f| request.kinds.contains(&f.kind)) {
                    if finding.exempt.is_some() {
                        out.exempt.push(finding);
                    } else {
                        out.findings.push(finding);
                    }
                }
            }
            Err(e) => out.parse_errors.push(e),
        }
    }
    Ok(out)
}

/// Scans files one after another, in the files' order (the whole of
/// cmux-tui/crates parses in seconds, so no worker pool).
fn scan_files(cfg: &Config, files: &[SourceFile]) -> Vec<Result<Vec<Finding>, ParseError>> {
    files
        .iter()
        .map(|f| scan_file(cfg, &FileInput { file: &f.display, krate: &f.krate, text: &f.text }))
        .collect()
}

/// The head findings beyond the base's count of the same identity
/// (`Finding::diff_key`): moved code is not new, a second copy is.
pub fn new_findings(base: &[Finding], head: &[Finding]) -> Vec<Finding> {
    let mut remaining: HashMap<_, usize> = HashMap::new();
    for finding in base {
        *remaining.entry(finding.diff_key()).or_default() += 1;
    }
    head.iter()
        .filter(|finding| match remaining.get_mut(&finding.diff_key()) {
            Some(count) if *count > 0 => {
                *count -= 1;
                false
            }
            _ => true,
        })
        .cloned()
        .collect()
}
