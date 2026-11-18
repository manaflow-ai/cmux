//! Which of a pull request's red checks are its own: the base-red classifier of the app's
//! Session Info (`AgentPanePullRequest.swift` `counted`, `latestRuns`, `failing`, `identity`,
//! `outcome`), ported whole so the draft leaves out exactly the reds the row dims.
//!
//! Every judgement errs one way: it can fail to excuse a red, never excuse one wrongly. A
//! cancelled base run is no evidence, nor one still running; a check matches across the two
//! commits only by its workflow and its name, never its name alone (job names repeat across
//! workflows).

use serde_json::Value;
use std::collections::{HashMap, HashSet};

fn text<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(Value::as_str)
}

/// A check run's `conclusion` or a commit status's `state`, upper-cased; empty when neither.
pub(crate) fn conclusion_of(check: &Value) -> String {
    text(check, "conclusion").or_else(|| text(check, "state")).unwrap_or_default().to_uppercase()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Outcome {
    Passed,
    Failed,
    Pending,
}

/// One check's outcome. A stale run was superseded by one not reported yet, as `gh pr checks`
/// reads it; a cancelled one is a failure (a cancellation a person asked for is a red).
pub(crate) fn outcome(check: &Value) -> Outcome {
    if let Some(status) = text(check, "status")
        && !status.eq_ignore_ascii_case("COMPLETED")
    {
        return Outcome::Pending;
    }
    match conclusion_of(check).as_str() {
        "SUCCESS" | "SKIPPED" | "NEUTRAL" => Outcome::Passed,
        "PENDING" | "EXPECTED" | "STALE" | "" => Outcome::Pending,
        _ => Outcome::Failed,
    }
}

/// A check's name, whichever kind of context it is.
pub(crate) fn name(check: &Value) -> String {
    text(check, "name").or_else(|| text(check, "context")).unwrap_or("check").to_owned()
}

/// The workflow a context belongs to and the run it came from; None for a context of no run (a
/// commit status).
pub(crate) fn run_of(check: &Value) -> Option<(String, i64)> {
    let run = check.pointer("/checkSuite/workflowRun")?;
    let id = run.get("databaseId")?.as_i64()?;
    let workflow = run.get("workflow").and_then(|w| {
        w.get("databaseId")
            .and_then(Value::as_i64)
            .map(|n| n.to_string())
            .or_else(|| text(w, "name").map(str::to_owned))
    });
    Some((workflow.unwrap_or_default(), id))
}

/// The workflow's name, for the draft.
pub(crate) fn workflow_name(check: &Value) -> Option<String> {
    check
        .pointer("/checkSuite/workflowRun/workflow/name")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// A check's identity across two commits: its workflow and its name.
pub(crate) fn identity(check: &Value) -> String {
    format!("{}\u{0}{}", run_of(check).map(|r| r.0).unwrap_or_default(), name(check))
}

/// `rollup` without the contexts of a run a newer run of the same workflow replaced. One-way:
/// only [`failing`] uses it, on a base tip.
fn latest_runs(rollup: &[Value]) -> Vec<&Value> {
    let mut newest: HashMap<String, i64> = HashMap::new();
    for check in rollup {
        if let Some((workflow, run)) = run_of(check) {
            let n = newest.entry(workflow).or_insert(run);
            *n = (*n).max(run);
        }
    }
    rollup
        .iter()
        .filter(|check| {
            run_of(check)
                .is_none_or(|(workflow, run)| run >= newest.get(&workflow).copied().unwrap_or(run))
        })
        .collect()
}

/// The identity of every check a commit's own newest runs report as failed, cancelled ones
/// aside.
pub(crate) fn failing(rollup: &[Value]) -> HashSet<String> {
    latest_runs(rollup)
        .into_iter()
        .filter(|c| outcome(c) == Outcome::Failed && conclusion_of(c) != "CANCELLED")
        .map(identity)
        .collect()
}

/// The check a context is a run of: its workflow, the event that started its run, and its name;
/// None unless all three were read.
fn supersession_key(check: &Value) -> Option<String> {
    let (workflow, _) = run_of(check)?;
    let event = check.pointer("/checkSuite/workflowRun/event").and_then(Value::as_str)?;
    let name = text(check, "name")?;
    (!workflow.is_empty() && !event.is_empty())
        .then(|| format!("{workflow}\u{0}{event}\u{0}{name}"))
}

/// A pull request's own rollup as it is counted: skipped contexts left out, and every run a
/// newer run of the very same check (workflow, event and name) proves superseded.
pub(crate) fn counted(rollup: &[Value]) -> Vec<&Value> {
    let ran: Vec<&Value> = rollup.iter().filter(|c| conclusion_of(c) != "SKIPPED").collect();
    let mut newest: HashMap<String, i64> = HashMap::new();
    for check in &ran {
        if let (Some(key), Some((_, run))) = (supersession_key(check), run_of(check)) {
            let n = newest.entry(key).or_insert(run);
            *n = (*n).max(run);
        }
    }
    ran.into_iter()
        .filter(|check| match (supersession_key(check), run_of(check)) {
            (Some(key), Some((_, run))) => run >= newest.get(&key).copied().unwrap_or(run),
            _ => true,
        })
        .collect()
}

/// A head's checks split the way the draft needs them.
#[derive(Debug, Default)]
pub(crate) struct Split<'a> {
    /// Failing at the head and not at the base tip: this branch's own.
    pub own: Vec<&'a Value>,
    /// Failing at the head and at the base tip too.
    pub on_base: Vec<&'a Value>,
    pub pending: usize,
}

pub(crate) fn split<'a>(head: &'a [Value], base: &[Value]) -> Split<'a> {
    let base_red = failing(base);
    let mut out = Split::default();
    for check in counted(head) {
        match outcome(check) {
            Outcome::Failed if base_red.contains(&identity(check)) => out.on_base.push(check),
            Outcome::Failed => out.own.push(check),
            Outcome::Pending => out.pending += 1,
            Outcome::Passed => {}
        }
    }
    out
}
