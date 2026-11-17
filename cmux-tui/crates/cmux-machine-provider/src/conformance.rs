//! The machine lifecycle conformance suite: the same six steps against any
//! provider, timed, with one table per provider.
//!
//! | step | a cloud machine | an own machine |
//! | --- | --- | --- |
//! | attach | create it, wait for running | start (or find) its cmux daemon |
//! | connect | a daemon hello over the provider's route | the same, over its socket or SSH |
//! | agent turn | one prompt, its reply checked | the same |
//! | pause, resume | where the provider has them | not applicable |
//! | detach | delete it | stop the daemon session it started |
//!
//! A provider is a profile: a shell command per step (`{name}` placeholders
//! filled from `--set name=value` and `{tag}`, a per-run id), an optional
//! text its output must contain, and a timeout. Detach always runs, so a
//! failed run cleans up. A provider whose own harness already times these
//! steps (the Cloud journey) is imported from its record instead
//! ([`import_journey`]).

use cmux_process::{Command, Stdio};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Step {
    Attach,
    Connect,
    AgentTurn,
    Pause,
    Resume,
    Detach,
}

impl Step {
    pub const ALL: [Step; 6] =
        [Step::Attach, Step::Connect, Step::AgentTurn, Step::Pause, Step::Resume, Step::Detach];

    pub fn label(self) -> &'static str {
        match self {
            Step::Attach => "attach / create",
            Step::Connect => "connect",
            Step::AgentTurn => "agent turn",
            Step::Pause => "pause",
            Step::Resume => "resume",
            Step::Detach => "detach / delete",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Pass,
    Fail,
    /// An earlier step failed, so this one did not run.
    Skipped,
    /// The provider has no such step (an own machine has no pause).
    NotApplicable,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StepResult {
    pub step: Step,
    pub status: Status,
    pub ms: u64,
    /// The failure's reason, or what the step's command printed last.
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Run {
    pub provider: String,
    pub iteration: u32,
    pub steps: Vec<StepResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StepSpec {
    /// Run with `sh -c`, placeholders filled.
    pub run: String,
    /// Text the output (stdout and stderr) must contain to pass.
    #[serde(default)]
    pub expect: Option<String>,
    #[serde(default = "default_timeout")]
    pub timeout_s: u64,
}

fn default_timeout() -> u64 {
    180
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    /// `own:huge-blue`, `freestyle:staging`.
    pub provider: String,
    #[serde(default)]
    pub about: String,
    /// A step left out is not applicable for this provider.
    pub steps: BTreeMap<Step, StepSpec>,
}

impl Profile {
    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
    }
}

/// Fill `{name}` placeholders; an unfilled one is an error, never a literal
/// brace in a command.
pub fn fill(template: &str, values: &BTreeMap<String, String>) -> Result<String, String> {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        let close = after.find('}').ok_or_else(|| format!("unclosed {{ in {template:?}"))?;
        let name = &after[..close];
        let value = values
            .get(name)
            .ok_or_else(|| format!("no value for {{{name}}}: pass --set {name}=..."))?;
        out.push_str(value);
        rest = &after[close + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// Run one profile once: every step in order, detach always.
pub fn run_profile(
    profile: &Profile,
    values: &BTreeMap<String, String>,
    iteration: u32,
    scratch: &Path,
) -> Run {
    let mut steps = Vec::new();
    let mut failed = false;
    for step in Step::ALL {
        let Some(spec) = profile.steps.get(&step) else {
            steps.push(StepResult {
                step,
                status: Status::NotApplicable,
                ms: 0,
                detail: String::new(),
            });
            continue;
        };
        if failed && step != Step::Detach {
            steps.push(StepResult { step, status: Status::Skipped, ms: 0, detail: String::new() });
            continue;
        }
        let result = run_step(step, spec, values, scratch);
        failed |= result.status == Status::Fail;
        steps.push(result);
    }
    Run { provider: profile.provider.clone(), iteration, steps }
}

fn run_step(
    step: Step,
    spec: &StepSpec,
    values: &BTreeMap<String, String>,
    scratch: &Path,
) -> StepResult {
    let fail = |ms, detail: String| StepResult { step, status: Status::Fail, ms, detail };
    let command = match fill(&spec.run, values) {
        Ok(command) => command,
        Err(e) => return fail(0, e),
    };
    let log = scratch.join(format!(
        "{}.log",
        serde_json::to_string(&step).unwrap_or_default().trim_matches('"')
    ));
    let (out, err) = match std::fs::File::create(&log).and_then(|f| Ok((f.try_clone()?, f))) {
        Ok(pair) => pair,
        Err(e) => return fail(0, format!("{}: {e}", log.display())),
    };
    let started = Instant::now();
    let child = Command::new("sh")
        .args(["-c", &command])
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        .process_group(0)
        .spawn();
    let mut child = match child {
        Ok(child) => child,
        Err(e) => return fail(0, format!("sh: {e}")),
    };
    let waited = child.wait_timeout(Duration::from_secs(spec.timeout_s));
    let ms = started.elapsed().as_millis() as u64;
    let output = std::fs::read_to_string(&log).unwrap_or_default();
    let tail = last_line(&output);
    match waited {
        Ok(Some(status)) if status.success() => match &spec.expect {
            Some(want) if !output.contains(want.as_str()) => {
                fail(ms, format!("exit 0 but no {want:?} in the output; last line: {tail}"))
            }
            _ => StepResult { step, status: Status::Pass, ms, detail: tail },
        },
        Ok(Some(status)) => fail(ms, format!("{status}; last line: {tail}")),
        // Dropping the child ends its process group.
        Ok(None) => fail(ms, format!("timed out after {} s; last line: {tail}", spec.timeout_s)),
        Err(e) => fail(ms, format!("wait: {e}")),
    }
}

fn last_line(text: &str) -> String {
    let line = text.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    line.chars().take(200).collect()
}

/// The Cloud journey's record (`cloud-journey.ts --out DIR`, `journey.json`)
/// as one conformance run: its steps summed into ours.
pub fn import_journey(provider: &str, journey: &Value) -> Result<Run, String> {
    let rows = journey.get("steps").and_then(Value::as_array).ok_or("journey.json has no steps")?;
    let named = |n: &str| rows.iter().any(|r| r.get("step").and_then(Value::as_str) == Some(n));
    // A journey whose turn fails skips its later steps and deletes the
    // machine in its cleanup instead: that delete is the run's detach.
    let detach: &[&str] = if named("delete") { &["delete"] } else { &["delete (cleanup)"] };
    let parts: [(Step, &[&str]); 6] = [
        (Step::Attach, &["create machine", "running (status)"]),
        (Step::Connect, &["connect (carrier dial)"]),
        (Step::AgentTurn, &["send chat", "reply"]),
        (Step::Pause, &["pause"]),
        (Step::Resume, &["resume"]),
        (Step::Detach, detach),
    ];
    let mut steps = Vec::new();
    for (step, names) in parts {
        let found: Vec<&Value> = names
            .iter()
            .filter_map(|n| rows.iter().find(|r| r.get("step").and_then(Value::as_str) == Some(n)))
            .collect();
        if found.len() != names.len() {
            let missing: Vec<_> = names.iter().filter(|n| !named(n)).collect();
            // The journey stops its later steps at a failure (connect,
            // pause and resume run after the reply).
            let why = if rows.iter().any(|r| status_of(r) == "fail") {
                "not run after an earlier failure"
            } else {
                "not in the journey"
            };
            steps.push(StepResult {
                step,
                status: Status::Skipped,
                ms: 0,
                detail: format!("{why}: {missing:?}"),
            });
            continue;
        }
        let ms =
            found.iter().map(|r| r.get("ms").and_then(Value::as_f64).unwrap_or(0.0)).sum::<f64>();
        let status = if found.iter().all(|r| status_of(r) == "pass") {
            Status::Pass
        } else if found.iter().any(|r| status_of(r) == "fail") {
            Status::Fail
        } else {
            Status::Skipped
        };
        let detail = found
            .iter()
            .filter(|r| status_of(r) != "pass")
            .filter_map(|r| r.get("detail").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("; ");
        steps.push(StepResult { step, status, ms: ms.round() as u64, detail });
    }
    Ok(Run { provider: provider.to_owned(), iteration: 1, steps })
}

/// One markdown table per provider: passes of runs, p50 and max ms, and
/// each failure's reason once.
pub fn table(runs: &[Run]) -> String {
    let mut providers: Vec<&str> = runs.iter().map(|r| r.provider.as_str()).collect();
    providers.dedup();
    let mut out = String::new();
    for provider in providers {
        let mine: Vec<&Run> = runs.iter().filter(|r| r.provider == provider).collect();
        out.push_str(&format!(
            "**{provider}** ({} run{})\n\n",
            mine.len(),
            if mine.len() == 1 { "" } else { "s" }
        ));
        out.push_str(
            "| step | passed | p50 ms | max ms | failures |\n| --- | ---: | ---: | ---: | --- |\n",
        );
        for step in Step::ALL {
            let results: Vec<&StepResult> =
                mine.iter().flat_map(|r| r.steps.iter().filter(move |s| s.step == step)).collect();
            if results.iter().all(|s| s.status == Status::NotApplicable) {
                out.push_str(&format!("| {} | n/a | | | |\n", step.label()));
                continue;
            }
            let passed = results.iter().filter(|s| s.status == Status::Pass).count();
            let mut times: Vec<u64> =
                results.iter().filter(|s| s.status == Status::Pass).map(|s| s.ms).collect();
            times.sort_unstable();
            let p50 =
                times.get(times.len().saturating_sub(1) / 2).map_or(String::new(), u64::to_string);
            let max = times.last().map_or(String::new(), u64::to_string);
            let mut reasons: Vec<String> = results
                .iter()
                .filter(|s| matches!(s.status, Status::Fail | Status::Skipped))
                .map(|s| {
                    let what = if s.status == Status::Fail { "fail" } else { "skipped" };
                    format!("{what}: {}", s.detail.replace('|', "\\|"))
                })
                .collect();
            reasons.dedup();
            out.push_str(&format!(
                "| {} | {passed}/{} | {p50} | {max} | {} |\n",
                step.label(),
                results.len(),
                reasons.join("<br>")
            ));
        }
        out.push('\n');
    }
    out
}

/// Every step that ran passed, in every run.
pub fn green(runs: &[Run]) -> bool {
    runs.iter()
        .all(|r| r.steps.iter().all(|s| matches!(s.status, Status::Pass | Status::NotApplicable)))
}

fn status_of(row: &Value) -> &str {
    row.get("status").and_then(Value::as_str).unwrap_or("")
}
