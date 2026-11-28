//! The conformance suite's verdicts (`exec_conformance.rs`): one [`Row`] per case, from
//! [`compare`], and the [`Summary`] over them.

use std::collections::BTreeMap;

use serde::Serialize;

use super::exec_conformance::{Case, Outcome, Streams, normalize_case};
use super::exec_conformance_tree::{tree_diff, tree_digest};

/// One side's numbers in a row.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Pair<T> {
    pub local: T,
    pub routed: T,
}

/// One case's result: one JSON row of `acpmux --json exec-router conformance`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub case: String,
    pub command: String,
    /// Exit, output and tree all the same.
    pub identical: bool,
    /// What differed: `exit`, `stdout`, `stderr`, `tree`.
    pub diffs: Vec<String>,
    /// Why it did not run (a program it needs is not on `PATH`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skipped: Option<String>,
    /// Where the routed side really ran: `fork` or `here`.
    pub routed_ran: String,
    /// Why the routed side ran here, when it did.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub routed_cause: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit: Option<Pair<i32>>,
    /// The two trees' [`tree_digest`]s.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tree: Option<Pair<String>>,
    /// The paths that differ, when the trees do.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tree_paths: Vec<String>,
    /// Both sides' stdout (normalized, cut to [`EXCERPT`] bytes), when it differs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stdout: Option<Pair<String>>,
    /// Both sides' stderr, when it differs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stderr: Option<Pair<String>>,
}

/// How much of a differing output a row shows.
pub const EXCERPT: usize = 2000;

fn excerpt(bytes: &[u8]) -> String {
    let cut = bytes.get(..EXCERPT).unwrap_or(bytes);
    let mut s = String::from_utf8_lossy(cut).into_owned();
    if bytes.len() > EXCERPT {
        s.push_str(&format!("... ({} bytes)", bytes.len()));
    }
    s
}

impl Row {
    pub(crate) fn skipped(case: &Case, why: String) -> Self {
        Row {
            case: case.name.to_owned(),
            command: case.command.to_owned(),
            identical: false,
            diffs: Vec::new(),
            skipped: Some(why),
            routed_ran: "none".to_owned(),
            routed_cause: None,
            exit: None,
            tree: None,
            tree_paths: Vec::new(),
            stdout: None,
            stderr: None,
        }
    }

    /// The row's text line.
    pub fn line(&self) -> String {
        if let Some(why) = &self.skipped {
            return format!("skip  {}: {why}", self.case);
        }
        let verdict = if self.identical { "ok   " } else { "DIFF " };
        let mut line = format!("{verdict} {}", self.case);
        if !self.diffs.is_empty() {
            line.push_str(&format!(" ({})", self.diffs.join(", ")));
        }
        if self.routed_ran != "fork" {
            line.push_str(&format!(
                " [routed side ran here: {}]",
                self.routed_cause.as_deref().unwrap_or("no run VM")
            ));
        }
        line
    }
}

/// Compare one case's two sides.
pub fn compare(
    case: &Case,
    local: &Outcome,
    routed: &Outcome,
    trees: (&BTreeMap<String, String>, &BTreeMap<String, String>),
) -> Row {
    let mut diffs = Vec::new();
    if local.exit != routed.exit {
        diffs.push("exit".to_owned());
    }
    let (lo, ro) = (normalize_case(case, &local.stdout), normalize_case(case, &routed.stdout));
    let stdout = (lo != ro).then(|| {
        diffs.push("stdout".to_owned());
        if case.env_listing {
            diffs.extend(env_diff(&lo, &ro));
        }
        Pair { local: excerpt(&lo), routed: excerpt(&ro) }
    });
    let (le, re) = (normalize_case(case, &local.stderr), normalize_case(case, &routed.stderr));
    let stderr = (case.streams == Streams::Split && le != re).then(|| {
        diffs.push("stderr".to_owned());
        Pair { local: excerpt(&le), routed: excerpt(&re) }
    });
    let tree_paths = tree_diff(trees.0, trees.1);
    if !tree_paths.is_empty() {
        diffs.push("tree".to_owned());
    }
    Row {
        case: case.name.to_owned(),
        command: case.command.to_owned(),
        identical: diffs.is_empty(),
        diffs,
        skipped: None,
        routed_ran: routed.ran.to_owned(),
        routed_cause: routed.cause.clone(),
        exit: Some(Pair { local: local.exit, routed: routed.exit }),
        tree: Some(Pair { local: tree_digest(trees.0), routed: tree_digest(trees.1) }),
        tree_paths,
        stdout,
        stderr,
    }
}

/// The suite's verdict.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    /// `identical N/M`.
    pub identical: String,
    /// Cases that ran (not skipped).
    pub total: usize,
    pub identical_count: usize,
    /// Cases whose routed side really ran on a run VM.
    pub on_run_vm: usize,
    /// Cases that differ: the router is wrong. Every case must match; there is no list of
    /// differences a run may have.
    pub unexpected: Vec<String>,
    /// Cases whose routed side ran here (the comparison proves nothing for them).
    pub not_routed: Vec<String>,
    pub skipped: Vec<String>,
    pub exempt: Vec<String>,
    pub normalized: Vec<String>,
    /// Every case that ran was routed, and none differed unexpectedly.
    pub ok: bool,
}

impl Summary {
    /// The verdict over `rows`.
    pub fn of(rows: &[Row]) -> Self {
        let mut s = Summary {
            exempt: super::exec_conformance::EXEMPT
                .iter()
                .map(|(p, why)| format!("{p}: {why}"))
                .collect(),
            normalized: super::exec_conformance::NORMALIZED
                .iter()
                .map(|n| (*n).to_owned())
                .collect(),
            ..Default::default()
        };
        for row in rows {
            if row.skipped.is_some() {
                s.skipped.push(row.case.clone());
                continue;
            }
            s.total += 1;
            if row.identical {
                s.identical_count += 1;
            }
            if row.routed_ran == "fork" {
                s.on_run_vm += 1;
            } else {
                s.not_routed.push(row.case.clone());
            }
            if !row.identical {
                s.unexpected.push(row.case.clone());
            }
        }
        s.identical = format!("{}/{}", s.identical_count, s.total);
        s.ok = s.total > 0 && s.unexpected.is_empty() && s.not_routed.is_empty();
        s
    }

    /// The summary's text line.
    pub fn line(&self) -> String {
        let mut line =
            format!("identical {}; on a run VM {}/{}", self.identical, self.on_run_vm, self.total);
        if !self.unexpected.is_empty() {
            line.push_str(&format!("; UNEXPECTED: {}", self.unexpected.join(", ")));
        }
        if !self.not_routed.is_empty() {
            line.push_str(&format!(
                "; routed side ran here (proves nothing): {}",
                self.not_routed.join(", ")
            ));
        }
        if !self.skipped.is_empty() {
            line.push_str(&format!("; skipped: {}", self.skipped.join(", ")));
        }
        line
    }
}

/// For an `env -0` listing, the names whose entries differ: `env NAME` for each, so a row names
/// the variable, not a cut-off excerpt of 5 kB of environment.
fn env_diff(local: &[u8], routed: &[u8]) -> Vec<String> {
    let entries = |b: &[u8]| -> BTreeMap<String, Vec<u8>> {
        b.split(|c| *c == 0)
            .filter(|e| !e.is_empty())
            .map(|e| {
                let at = e.iter().position(|c| *c == b'=').unwrap_or(e.len());
                let (name, value) = e.split_at(at);
                (String::from_utf8_lossy(name).into_owned(), value.to_vec())
            })
            .collect()
    };
    let (l, r) = (entries(local), entries(routed));
    let mut names: Vec<&String> = l.keys().chain(r.keys()).collect();
    names.sort();
    names.dedup();
    names.into_iter().filter(|n| l.get(*n) != r.get(*n)).map(|n| format!("env {n}")).collect()
}
