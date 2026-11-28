//! Ported from the app's `CloudMachineRepoTests+Completion` and `CloudWorkspaceSetupLifecycleTests`
//! (the creation's own state), plus the registry's rules.

use super::*;
use serde_json::json;

const ID: &str = "6F9619FF-8B86-D011-B42D-00C04FC964FF";

fn outcome(status: &str, reason: Option<&str>) -> Outcome {
    Outcome { status: status.into(), reason: reason.map(Into::into) }
}

fn creation(window: Option<&str>) -> Creation {
    Creation::new(ID.into(), window.map(Into::into), None, 1_000)
}

fn failed(reason: &str) -> Completion {
    Completion::Failed { reason: FailReason::StartFailed { reason: reason.into() } }
}

fn attempt(creation: &mut Creation) -> u64 {
    creation.apply(Event::BeginBootstrapAttempt).attempt.expect("an attempt")
}

#[test]
fn the_row_id_is_the_prefix_and_the_lowercase_uuid() {
    assert_eq!(creation(None).row_id(), "cloud-creation:6f9619ff-8b86-d011-b42d-00c04fc964ff");
}

#[test]
fn a_creation_with_a_session_starts_created_and_one_without_requesting() {
    assert_eq!(creation(None).phase, Phase::Requesting);
    let existing = Creation::new(ID.into(), None, Some("m1".into()), 0);
    assert_eq!(existing.phase, Phase::Created);
    assert!(existing.has_session);
}

#[test]
fn elapsed_runs_until_ready_then_stays() {
    let mut creation = creation(None);
    assert_eq!(creation.elapsed_ms(1_500), 500);
    creation.apply(Event::MarkReady { now_ms: 3_000 });
    creation.apply(Event::MarkReady { now_ms: 9_000 });
    assert_eq!(creation.ready_after_ms, Some(2_000), "ready is marked once");
    assert_eq!(creation.elapsed_ms(60_000), 2_000);
}

#[test]
fn retry_after_a_failure_clears_it_on_its_existing_machine() {
    // retryAfterCopyFailureClearsTheFailureOnItsExistingMachine
    let mut creation = creation(Some("w"));
    creation.apply(Event::Attach { machine_id: "m1".into() });
    creation.apply(Event::MarkReady { now_ms: 2_000 });
    creation.apply(Event::Fail {
        message: "copy failed".into(),
        source: RefusalSource::AppServerPlanRequired { plan: None },
    });
    assert!(creation.phase.is_failed());
    assert!(creation.plan_refusal.is_some());
    creation.apply(Event::Restart { now_ms: 5_000 });
    assert_eq!(creation.phase, Phase::Created);
    assert_eq!(creation.plan_refusal, None);
    assert_eq!(creation.ready_after_ms, None);
    assert_eq!(creation.started_at_ms, 5_000);
    let mut fresh = Creation::new(ID.into(), None, None, 0);
    fresh.apply(Event::Note { phase: Phase::Creating });
    fresh.apply(Event::Restart { now_ms: 1 });
    assert_eq!(fresh.phase, Phase::Requesting);
}

#[test]
fn each_refusal_names_its_plan() {
    let legacy = RefusalSource::PlanRequired {
        message: Some("needs max".into()),
        upgrade_url: Some("https://cmux.com/pricing".into()),
        plan: "max".into(),
    };
    assert_eq!(
        pro_refusal(&legacy),
        Some(ProRefusal {
            message: Some("needs max".into()),
            upgrade_url: Some("https://cmux.com/pricing".into()),
            plan: "max".into(),
            offered: false
        })
    );
    let gate = pro_refusal(&RefusalSource::FreePlanGate).expect("the gate's plan");
    assert!(gate.offered && gate.plan == "pro" && gate.message.is_none());
    for (plan, want) in [(Some("max"), "max"), (Some("team"), "pro"), (None, "pro")] {
        let refusal =
            pro_refusal(&RefusalSource::AppServerPlanRequired { plan: plan.map(Into::into) })
                .expect("a plan");
        assert_eq!(refusal.plan, want);
        assert_eq!(refusal.message, None, "the dialog's own copy stands in");
    }
    assert_eq!(pro_refusal(&RefusalSource::Other), None);
}

#[test]
fn a_start_that_returns_after_the_tear_down_starts_no_wait() {
    let mut creation = creation(None);
    let attempt = attempt(&mut creation);
    let effects = creation.apply(Event::TearDown);
    assert!(effects.cancel_run && !effects.cancel_wait);
    let effects =
        creation.apply(Event::BootstrapStarted { outcome: outcome("started", None), attempt });
    assert_eq!(effects, Effects::default());
    assert!(!creation.waiting);
    assert_eq!(creation.bootstrap_completion, None);
    assert_eq!(creation.bootstrap, None);
}

#[test]
fn a_retry_drops_the_earlier_starts_late_outcome() {
    let mut creation = creation(None);
    let first_try = attempt(&mut creation);
    creation.apply(Event::BootstrapStarted {
        outcome: outcome("failed", Some("x")),
        attempt: first_try,
    });
    assert!(creation.bootstrap_completion.is_some());
    let first = attempt(&mut creation);
    assert_eq!(
        creation.bootstrap_completion, None,
        "a new start clears the last completion before it goes out"
    );
    let second = attempt(&mut creation);
    let effects = creation
        .apply(Event::BootstrapStarted { outcome: outcome("started", None), attempt: first });
    assert_eq!(effects.start_wait, None);
    assert!(!creation.waiting);
    assert_eq!(creation.bootstrap.as_ref().map(|o| o.status.as_str()), Some("failed"));
    creation
        .apply(Event::BootstrapStarted { outcome: outcome("failed", Some("y")), attempt: second });
    assert_eq!(creation.bootstrap_completion, Some(failed("y")));
}

#[test]
fn a_start_that_failed_ends_at_once_with_its_reason() {
    let mut creation = creation(None);
    let attempt = attempt(&mut creation);
    let effects = creation
        .apply(Event::BootstrapStarted { outcome: outcome("failed", Some("no sudo")), attempt });
    assert_eq!(creation.bootstrap_completion, Some(failed("no sudo")));
    assert_eq!(effects.start_wait, None);
    assert!(!creation.waiting);
    let mut silent = Creation::new(ID.into(), None, None, 0);
    let attempt = silent.apply(Event::BeginBootstrapAttempt).attempt.unwrap_or_default();
    silent.apply(Event::BootstrapStarted { outcome: outcome("failed", None), attempt });
    assert_eq!(silent.bootstrap_completion, Some(failed("")), "no reason: an empty one");
}

#[test]
fn a_started_bootstrap_waits_and_its_completion_lands() {
    let mut creation = creation(None);
    let attempt = attempt(&mut creation);
    let effects =
        creation.apply(Event::BootstrapStarted { outcome: outcome("started", None), attempt });
    assert_eq!(effects.start_wait, Some(attempt));
    assert!(creation.waiting);
    assert_eq!(creation.bootstrap_completion, None);
    let done = Completion::Finished { repo_path: Some("/home/cmux/work/r".into()) };
    creation.apply(Event::BootstrapCompleted { completion: done.clone(), attempt });
    assert_eq!(creation.bootstrap_completion, Some(done));
    assert!(!creation.waiting);
}

#[test]
fn tearing_the_creation_down_stops_the_wait_and_publishes_no_completion() {
    // tearingTheCreationDownStopsTheWait, aCallerWaitingOnTheCompletionWakesWhenTheCreationEnds
    let mut creations = Creations::default();
    creations.begin(creation(None));
    let creation = creations.creation_mut(ID).expect("listed");
    let attempt = attempt(creation);
    creation.apply(Event::BootstrapStarted { outcome: outcome("started", None), attempt });
    let mut held = creation.clone();
    let effects = held.apply(Event::TearDown);
    assert!(effects.cancel_wait && effects.cancel_run);
    assert!(held.torn_down && held.bootstrap_completion.is_none());
    held.apply(Event::BootstrapCompleted {
        completion: Completion::Finished { repo_path: None },
        attempt,
    });
    assert_eq!(held.bootstrap_completion, None, "a torn-down creation publishes no completion");
    let ended = creations.end(ID).expect("ended");
    assert!(ended.cancel_wait && ended.cancel_run);
    assert!(creations.all.is_empty());
}

#[test]
fn the_wait_outlives_the_rows_removal() {
    // theFlowOpensWithoutWaitingAndTheWaitOutlivesTheRow
    let mut creations = Creations::default();
    creations.begin(creation(None));
    let creation = creations.creation_mut(ID).expect("listed");
    let attempt = attempt(creation);
    creation.apply(Event::BootstrapStarted { outcome: outcome("started", None), attempt });
    let mut removed = creations.remove(ID).expect("removed");
    assert!(creations.all.is_empty());
    assert!(removed.waiting && !removed.torn_down, "the row's removal keeps the wait");
    let clone = Completion::Finished { repo_path: Some("/home/cmux/work/r".into()) };
    removed.apply(Event::BootstrapCompleted { completion: clone.clone(), attempt });
    assert_eq!(removed.bootstrap_completion, Some(clone));
}

#[test]
fn each_end_becomes_its_reason() {
    let log = machine_bootstrap::log_path();
    let cases = [
        (
            Run::Finished { repo_path: Some("/c".into()) },
            json!({"end": "finished", "repoPath": "/c"}),
        ),
        (Run::Finished { repo_path: None }, json!({"end": "finished", "repoPath": null})),
        (
            Run::NeedsGitHub { repo: "o/r".into() },
            json!({"end": "failed", "reason": {"why": "needsGitHub", "repo": "o/r"}}),
        ),
        (
            Run::RepoFailed { repo: "o/r".into() },
            json!({"end": "failed", "reason": {"why": "repoFailed", "repo": "o/r", "log": log}}),
        ),
        (
            Run::ScriptFailed { exit_code: 7 },
            json!({"end": "failed", "reason": {"why": "scriptFailed", "exitCode": 7, "log": log}}),
        ),
        (Run::RunnerNeverCame, json!({"end": "failed", "reason": {"why": "runnerNeverCame"}})),
        (Run::Stopped, json!({"end": "failed", "reason": {"why": "stopped", "log": log}})),
        (
            Run::StillRunning,
            json!({"end": "failed", "reason": {"why": "stillRunning", "log": log}}),
        ),
        (
            Run::Unreachable { error: "timed out".into() },
            json!({"end": "failed", "reason": {"why": "unreachable", "error": "timed out"}}),
        ),
    ];
    for (run, want) in cases {
        assert_eq!(serde_json::to_value(completion(&run)).expect("json"), want, "{run:?}");
    }
}

#[test]
fn a_row_finds_its_creation_only_with_the_prefix() {
    let mut creations = Creations::default();
    creations.begin(creation(Some("w1")));
    let row = row_id(ID);
    assert_eq!(creations.by_row(&row).map(|c| c.id.as_str()), Some(ID));
    assert!(creations.by_row(&row.replace(ROW_PREFIX, "workspace:")).is_none());
    assert!(creations.by_row(ID).is_none());
}

#[test]
fn a_window_shown_creation_keeps_its_opened_workspace() {
    let mut creations = Creations::default();
    creations.begin(creation(Some("w1"))).apply(Event::Opened { workspace_id: "ws1".into() });
    assert!(creations.opens(Some("ws1"), Some(ID)));
    assert!(!creations.opens(Some("ws2"), Some(ID)));
    assert!(!creations.opens(None, Some(ID)));
    assert!(!creations.opens(Some("ws1"), None));
    assert!(!creations.opens(Some("ws1"), Some("other")));
}

#[test]
fn a_window_lists_its_own_creations_oldest_first() {
    let mut creations = Creations::default();
    for (id, window) in [("a", Some("w1")), ("b", Some("w2")), ("c", Some("w1")), ("d", None)] {
        creations.begin(Creation::new(id.into(), window.map(Into::into), None, 0));
    }
    let ids: Vec<&str> = creations.shown_in("w1").iter().map(|c| c.id.as_str()).collect();
    assert_eq!(ids, ["a", "c"]);
    assert!(creations.shown_in("w3").is_empty());
}

#[test]
fn a_removed_machine_ends_its_creations() {
    let mut creations = Creations::default();
    creations.begin(Creation::new("a".into(), None, Some("m1".into()), 0));
    creations.begin(Creation::new("b".into(), None, Some("m2".into()), 0));
    creations
        .begin(Creation::new("c".into(), None, None, 0))
        .apply(Event::Attach { machine_id: "m1".into() });
    let ended: Vec<String> =
        creations.machine_removed("m1").into_iter().map(|(id, _)| id).collect();
    assert_eq!(ended, ["a", "c"]);
    assert_eq!(creations.all.len(), 1);
    assert!(creations.machine_removed("m9").is_empty());
}

#[test]
fn a_creation_round_trips_its_json() {
    let mut creation = creation(Some("w"));
    creation.apply(Event::Fail { message: "no".into(), source: RefusalSource::FreePlanGate });
    let value = serde_json::to_value(&creation).expect("json");
    assert_eq!(value["phase"], json!({"phase": "failed", "message": "no"}));
    assert_eq!(value["planRefusal"]["offered"], json!(true));
    let back: Creation = serde_json::from_value(value).expect("back");
    assert_eq!(back, creation);
    let minimal: Creation = serde_json::from_value(
        json!({"id": "x", "phase": {"phase": "requesting"}, "startedAtMs": 3}),
    )
    .expect("minimal");
    assert_eq!(minimal.bootstrap_attempt, 0);
}
