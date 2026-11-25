//! `cloud journey --repo SPEC [--machine-config FILE]`: the journey of a project moved to Cloud
//! (`cmux migrate`, hq RFD 0168). Between the first exec and the agent's start it clones the repo
//! and applies the project's machine config with the plans the app runs on a new machine
//! (`cmux_cloud_start_core`'s `machine_bootstrap::start_plan` with the repo, then
//! `machine_config::apply_plan`), each write over the Cloud file API and each exec read by
//! `step_outcome`, as `cmux vm new --wait` does over the VM API (vm_bootstrap.rs). The chat then
//! starts in the checkout, so the journey's create-to-reply time is a migrated project's time to
//! its first working chat.
//!
//! Leo, 2026-11-24: "we ought to be able to have good migration capabilities all around for people
//! of all stages any and all levels of technical sophistication and teams and organizations of any
//! size and demand to move to autocloud"

use std::time::{Duration, Instant};

use cmux_cloud_start_core::machine_bootstrap::{
    self, ExecAnswer, Kind, Outcome, Payload, Plan, Repo, Run, StartRequest, Step, WaitRead,
};
use cmux_cloud_start_core::machine_config::{self, ApplyRequest};
use cmux_cloud_start_core::machine_repo;
use serde_json::{Value, json};

use super::{Exec, Journey, random_hex, tail};

/// The clone and the setup's own bound (a migrated project's `bun install` included).
const SETUP_BUDGET: Duration = Duration::from_secs(900);
/// Each plan exec's limit; a wait read blocks up to 15 s on the runner's lock.
const STEP_EXEC_MS: u64 = 30_000;
/// The bootstrap's script when the journey only clones: the runner still needs one.
const NO_SCRIPT: &[u8] = b"#!/usr/bin/env bash\nexit 0\n";

/// `--repo`'s spec as the app's start takes it (`owner/name`, a GitHub or https git URL, `#ref`).
pub(super) fn parse_repo(spec: &str) -> Result<Repo, String> {
    machine_repo::parse(spec).map_err(|invalid| match invalid {
        machine_repo::Invalid::CredentialsInUrl => {
            "--repo carries a token or password: give the URL without it".to_owned()
        }
        machine_repo::Invalid::InvalidRef => format!("--repo {spec}: the ref after # is not valid"),
        machine_repo::Invalid::Unrecognized => {
            format!("--repo {spec}: OWNER/NAME, a GitHub URL or an https git URL")
        }
    })
}

/// Clones `repo` and applies the machine config (the file given, else the checkout's own
/// `.cmux/machine.toml` when it has one). Answers the checkout's path on the machine.
pub(super) async fn repo_steps(
    j: &mut Journey,
    exec: &mut Exec<'_>,
    repo: &Repo,
    config: Option<&[u8]>,
) -> Result<String, ()> {
    // clone repo
    let t0 = Instant::now();
    let deadline = t0 + SETUP_BUDGET;
    let plan = machine_bootstrap::start_plan(&StartRequest {
        kind: Kind::Plain,
        name: None,
        repo: Some(repo.clone()),
        start_id: random_hex(16),
    });
    let started = run_plan(exec, &plan, NO_SCRIPT, config.unwrap_or_default()).await;
    if started.status == "failed" {
        j.fail("clone repo", t0, &format!("start: {}", started.reason.unwrap_or_default()));
        return Err(());
    }
    let checkout = match wait_run(exec, repo, deadline).await {
        Run::Finished { repo_path: Some(path) } => path,
        Run::Finished { repo_path: None } => repo.directory(),
        other => {
            j.fail("clone repo", t0, &run_words(&other));
            return Err(());
        }
    };
    let head = exec
        .run(
            &format!("git -C {} rev-parse --short HEAD 2>/dev/null", super::shq(&checkout)),
            20_000,
        )
        .await
        .map(|r| r.stdout.trim().to_owned())
        .unwrap_or_default();
    j.pass("clone repo", t0, &format!("{} at {head} in {checkout}", repo.display()));

    // machine config: the given file, else the checkout's own, else none to apply.
    let t0 = Instant::now();
    let in_repo = format!("{checkout}/.cmux/machine.toml");
    let has_own = config.is_none()
        && exec
            .run(&format!("test -f {} && echo has-config", super::shq(&in_repo)), 20_000)
            .await
            .is_ok_and(|r| r.stdout.contains("has-config"));
    if config.is_none() && !has_own {
        j.record(
            "machine config",
            super::Status::Skip,
            t0,
            "no --machine-config and no .cmux/machine.toml in the checkout",
        );
        return Ok(checkout);
    }
    let plan = machine_config::apply_plan(&ApplyRequest {
        uploaded: config.is_some(),
        now_ms: now_ms(),
        nonce: random_hex(16),
    });
    let started = run_plan(exec, &plan, NO_SCRIPT, config.unwrap_or_default()).await;
    if started.status == "failed" {
        j.fail("machine config", t0, &format!("start: {}", started.reason.unwrap_or_default()));
        return Err(());
    }
    match wait_config(exec, deadline).await {
        Ok(status) => {
            j.pass(
                "machine config",
                t0,
                &config_words(&status, if has_own { &in_repo } else { "--machine-config" }),
            );
            Ok(checkout)
        }
        Err(status) => {
            j.fail("machine config", t0, &config_words(&status, "the machine config"));
            Err(())
        }
    }
}

/// Each step of `plan` in order (vm_bootstrap.rs `run_plan`, the app's `Plan.run`), writes over
/// the Cloud file API.
async fn run_plan(exec: &mut Exec<'_>, plan: &Plan, script: &[u8], config: &[u8]) -> Outcome {
    for step in &plan.steps {
        match step {
            Step::Write { path, mode, text, payload } => {
                let bytes = match (text, payload) {
                    (Some(text), _) => text.as_bytes(),
                    (None, Some(Payload::Config)) => config,
                    (None, _) => script,
                };
                if let Err(error) = exec.write(path, bytes, *mode).await {
                    return Outcome::failed(error);
                }
            }
            Step::Exec { command, said } => match exec.run(command, STEP_EXEC_MS).await {
                Ok(ran) => {
                    let ran = ExecAnswer {
                        exit_code: ran.exit_code.into(),
                        stdout: ran.stdout,
                        stderr: ran.stderr,
                    };
                    if let Some(outcome) = machine_bootstrap::step_outcome(&ran, said) {
                        return outcome;
                    }
                }
                Err(error) => return Outcome::failed(error),
            },
        }
    }
    Outcome::failed("the plan ended without a start".to_owned())
}

/// vm_bootstrap.rs `wait_run`, async: `wait_command` reads until the run ends.
async fn wait_run(exec: &mut Exec<'_>, repo: &Repo, deadline: Instant) -> Run {
    let command = machine_bootstrap::wait_command();
    let mut failures = 0;
    loop {
        let mut read = WaitRead { answer: None, error: None, failures, repo: Some(repo.clone()) };
        match exec.run(&command, STEP_EXEC_MS).await {
            Ok(r) => {
                read.answer = Some(ExecAnswer {
                    exit_code: r.exit_code.into(),
                    stdout: r.stdout,
                    stderr: r.stderr,
                });
            }
            Err(error) => read.error = Some(error),
        }
        let next = machine_bootstrap::wait_next(&read);
        if let Some(ended) = next.ended {
            return ended;
        }
        if let Some(unreachable) = next.unreachable {
            return unreachable;
        }
        failures = next.failures;
        if Instant::now() >= deadline {
            return Run::StillRunning;
        }
    }
}

/// vm_bootstrap.rs `wait_config`, async: the applier's status file until `done` or `failed`.
async fn wait_config(exec: &mut Exec<'_>, deadline: Instant) -> Result<Value, Value> {
    let command = format!("cat {} 2>/dev/null || true", machine_config::status_path());
    let mut last = Value::Null;
    loop {
        if let Ok(r) = exec.run(&command, 20_000).await
            && let Ok(status) = serde_json::from_str::<Value>(r.stdout.trim())
        {
            match status.get("state").and_then(Value::as_str) {
                Some("done") => return Ok(status),
                Some("failed") => return Err(status),
                _ => last = status,
            }
        }
        if Instant::now() >= deadline {
            return Err(json!({ "state": "timeout", "last": last }));
        }
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}

fn run_words(run: &Run) -> String {
    match run {
        Run::Finished { .. } => "finished".to_owned(),
        Run::NeedsGitHub { repo } => {
            format!("{repo} needs GitHub access on the machine (connect GitHub in cmux)")
        }
        Run::RepoFailed { repo } => format!("cloning {repo} failed"),
        Run::ScriptFailed { exit_code } => format!("the bootstrap exited {exit_code}"),
        Run::RunnerNeverCame => "the bootstrap runner never started".to_owned(),
        Run::Stopped => "the bootstrap runner stopped without an end".to_owned(),
        Run::StillRunning => format!("still cloning after {} s", SETUP_BUDGET.as_secs()),
        Run::Unreachable { error } => {
            format!("the machine stopped answering: {}", tail(error, 200))
        }
    }
}

/// The applier's status in a line: setup commands run, the first failing one, missing secret
/// names (names only: the status file never holds a value).
fn config_words(status: &Value, source: &str) -> String {
    let state = status.get("state").and_then(Value::as_str).unwrap_or("?");
    let setup = status.get("setup");
    let ran = setup.and_then(|s| s.get("ran")).and_then(Value::as_u64);
    let failing = setup.and_then(|s| s.get("failing_index")).and_then(Value::as_i64);
    let missing: Vec<&str> = status
        .pointer("/secrets/missing")
        .and_then(Value::as_array)
        .map(|names| names.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let mut words = format!("{source}: {state}");
    if let Some(ran) = ran {
        words.push_str(&format!(", {ran} setup commands"));
    }
    if let Some(index) = failing {
        words.push_str(&format!(", setup command {index} failed"));
    }
    if !missing.is_empty() {
        words.push_str(&format!(", secrets not delivered yet: {}", missing.join(", ")));
    }
    if state == "timeout" {
        words.push_str(&format!(" after {} s", SETUP_BUDGET.as_secs()));
    }
    words
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}
