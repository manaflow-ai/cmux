//! Ported from the app's `CloudWorkspaceSetupLifecycleTests` (the scope check and the signed-out
//! continuation) and `CloudMachineRepoTests+Completion` (the bootstrap hook's steps), plus the
//! run's end as `CloudCreationFlow.run` handles it.

use super::*;
use crate::app_state::creation::Phase;

fn creation(window: Option<&str>) -> Creation {
    Creation::new("c1".into(), window.map(Into::into), None, 0)
}

fn failure(source: RefusalSource) -> RunError {
    RunError::Failed { message: "no".into(), source }
}

#[test]
fn a_start_in_a_window_shows_the_creation_at_once() {
    let mut creations = Creations::default();
    let shown = start(&mut creations, creation(Some("w1")));
    assert_eq!(shown, Some(Shown { clear_page: true, cloud_creation: "c1".into() }));
    assert_eq!(creations.all.len(), 1);
    assert_eq!(start(&mut creations, Creation::new("c2".into(), None, None, 0)), None);
    assert_eq!(creations.all.len(), 2);
}

#[test]
fn a_retry_cancels_the_run_and_restarts_the_clock() {
    let mut creation = creation(None);
    creation.apply(Event::Fail { message: "x".into(), source: RefusalSource::Other });
    let effects = retry(&mut creation, 42);
    assert!(effects.cancel_run);
    assert_eq!(creation.phase, Phase::Requesting);
    assert_eq!(creation.started_at_ms, 42);
}

#[test]
fn dismiss_ends_the_creation_and_clears_only_its_own_window() {
    let mut creations = Creations::default();
    creations.begin(creation(Some("w1")));
    creations.begin(Creation::new("c2".into(), Some("w1".into()), None, 0));
    let (ended, clear) = dismiss(&mut creations, "c1", Some("c1"));
    assert!(ended.is_some_and(|effects| effects.cancel_run) && clear);
    let (ended, clear) = dismiss(&mut creations, "c2", Some("c3"));
    assert!(ended.is_some() && !clear);
    assert!(creations.all.is_empty());
    assert_eq!(dismiss(&mut creations, "c1", None), (None, false));
}

#[test]
fn a_run_creates_only_without_a_session() {
    assert_eq!(run_plan(false, true), RunPlan { create: true, bootstrap: true });
    assert_eq!(run_plan(true, false), RunPlan { create: false, bootstrap: false });
}

#[test]
fn a_cancelled_run_ends_quietly_and_a_declined_one_leaves_the_list() {
    let mut creation = creation(Some("w"));
    assert_eq!(run_ended(&mut creation, RunError::Cancelled, false, true), RunEnd::Return);
    assert_eq!(run_ended(&mut creation, RunError::Declined, false, true), RunEnd::Remove);
    assert_eq!(run_ended(&mut creation, failure(RefusalSource::Other), true, true), RunEnd::Return);
    assert_eq!(creation.phase, Phase::Requesting, "a cancelled failure notes nothing");
}

#[test]
fn a_persons_failed_create_is_offered_its_plan_and_stays_shown() {
    let mut creation = creation(Some("w"));
    let source = RefusalSource::AppServerPlanRequired { plan: Some("max".into()) };
    let RunEnd::Failed { offer, linger_ms } =
        run_ended(&mut creation, failure(source.clone()), false, true)
    else {
        panic!("a failure")
    };
    assert_eq!(offer.map(|refusal| refusal.plan), Some("max".into()));
    assert_eq!(linger_ms, None, "a window shows it: Retry or Dismiss ends it");
    assert!(creation.phase.is_failed());
    let mut agents = Creation::new("c2".into(), Some("w".into()), None, 0);
    assert_eq!(
        run_ended(&mut agents, failure(source), false, false),
        RunEnd::Failed { offer: None, linger_ms: None },
        "an agent's create fails with the plan; its caller offers it"
    );
    assert!(agents.plan_refusal.is_some());
}

#[test]
fn a_windowless_failure_lingers_then_ends_unless_retried() {
    let mut creation = creation(None);
    let end = run_ended(&mut creation, failure(RefusalSource::Other), false, true);
    assert_eq!(end, RunEnd::Failed { offer: None, linger_ms: Some(FAILED_ROW_LINGERS_MS) });
    assert!(linger_ends(&creation, false));
    assert!(
        !linger_ends(&creation, true),
        "a Retry, Dismiss or the machine's removal cancelled the wait"
    );
    creation.apply(Event::Restart { now_ms: 1 });
    assert!(!linger_ends(&creation, false), "no longer failed");
}

#[test]
fn the_bootstrap_hook_starts_the_script_then_applies_the_config() {
    let creation = creation(None);
    assert_eq!(
        bootstrap_step(&creation, BootstrapAt::Running, false, true, true),
        BootstrapStep::StartScript
    );
    assert_eq!(
        bootstrap_step(&creation, BootstrapAt::ScriptStarted, false, false, true),
        BootstrapStep::ApplyConfig
    );
    assert_eq!(
        bootstrap_step(&creation, BootstrapAt::Running, false, false, true),
        BootstrapStep::ApplyConfig
    );
    assert_eq!(
        bootstrap_step(&creation, BootstrapAt::Running, false, false, false),
        BootstrapStep::Stop
    );
    assert_eq!(
        bootstrap_step(&creation, BootstrapAt::ScriptStarted, false, true, false),
        BootstrapStep::Stop
    );
}

#[test]
fn a_flow_cancelled_during_the_start_applies_no_machine_config() {
    // aFlowCancelledDuringTheStartAppliesNoMachineConfig
    let creation = creation(None);
    assert_eq!(
        bootstrap_step(&creation, BootstrapAt::ScriptStarted, true, false, true),
        BootstrapStep::Stop
    );
}

#[test]
fn a_creation_torn_down_while_the_machine_binds_starts_nothing() {
    // aCreationTornDownWhileTheMachineBindsStartsNothing
    let mut creation = creation(None);
    creation.apply(Event::TearDown);
    assert_eq!(
        bootstrap_step(&creation, BootstrapAt::Running, false, true, true),
        BootstrapStep::Stop
    );
}

#[test]
fn an_account_change_ends_the_creation() {
    // accountChangeTearsDownBeforeMachineAttach
    assert!(!scope_holds(Some("before"), Some("after"), Some("team"), Some("team")));
    assert!(!scope_holds(Some("u"), Some("u"), Some("team"), Some("other")));
    assert!(!scope_holds(Some("u"), Some("u"), Some("team"), None));
    assert!(!scope_holds(None, None, None, None), "no signed-in person at the start: never holds");
    assert!(scope_holds(Some("u"), Some("u"), Some("team"), Some("team")));
    assert!(scope_holds(Some("u"), Some("u"), None, None));
}

#[test]
fn a_replaced_reservation_never_starts_authentication() {
    let mut handoff = Continuation::default();
    let old = handoff.reserve();
    handoff.reserve();
    assert!(!handoff.begin(old, false));
    assert!(handoff.is_pending(), "the newer reservation stays");
}

#[test]
fn it_resumes_the_captured_intent_once() {
    let mut handoff = Continuation::default();
    let expected = handoff.reserve();
    assert!(handoff.begin(expected, false));
    assert_eq!(handoff.finish(expected, true, false), SignedIn::Resume);
    assert!(!handoff.is_pending());
    assert_eq!(handoff.finish(expected, true, false), SignedIn::Stale, "never twice");
}

#[test]
fn a_replacement_ignores_the_late_result_of_the_original_intent() {
    let mut handoff = Continuation::default();
    let old = handoff.reserve();
    assert!(handoff.begin(old, false));
    let latest = handoff.reserve();
    assert!(handoff.begin(latest, false));
    assert_eq!(handoff.finish(old, true, false), SignedIn::Stale);
    assert!(handoff.is_pending());
    assert_eq!(handoff.finish(latest, true, false), SignedIn::Resume);
    assert!(!handoff.is_pending());
}

#[test]
fn a_sign_out_ignores_the_late_sign_in() {
    let mut handoff = Continuation::default();
    let expected = handoff.reserve();
    assert!(handoff.begin(expected, false));
    handoff.cancel();
    assert_eq!(handoff.finish(expected, true, false), SignedIn::Stale);
    assert!(!handoff.is_pending());
}

#[test]
fn a_dismissed_sign_in_never_resumes_and_clears_the_intent() {
    let mut handoff = Continuation::default();
    let expected = handoff.reserve();
    assert!(handoff.begin(expected, false));
    assert_eq!(handoff.finish(expected, false, false), SignedIn::Dropped);
    assert!(!handoff.is_pending());
}

#[test]
fn a_cancelled_waiter_cannot_resume_even_if_auth_succeeded() {
    let mut handoff = Continuation::default();
    let expected = handoff.reserve();
    assert!(handoff.begin(expected, false));
    assert_eq!(handoff.finish(expected, true, true), SignedIn::Dropped);
    assert!(!handoff.is_pending());
    let next = handoff.reserve();
    assert!(!handoff.begin(next, true), "cancelled before the sign-in");
    assert!(!handoff.is_pending(), "and cancelled with it");
}

#[test]
fn a_scope_change_the_sign_in_does_not_survive_cancels_it() {
    // accountOrTeamReplacementInvalidatesPendingSignIn; signInUserThenInitialTeamHydrationStillResumes
    let mut handoff = Continuation::default();
    let expected = handoff.reserve();
    handoff.scope_changed(true);
    assert!(handoff.is_pending());
    handoff.scope_changed(false);
    assert!(!handoff.is_pending());
    assert_eq!(handoff.finish(expected, true, false), SignedIn::Stale);
    let mut idle = Continuation::default();
    idle.scope_changed(false);
    assert_eq!(idle.generation, 0, "nothing pending: nothing to cancel");
}

#[test]
fn a_stale_cancel_leaves_the_current_reservation() {
    let mut handoff = Continuation::default();
    let old = handoff.reserve();
    let current = handoff.reserve();
    handoff.cancel_expected(old);
    assert_eq!(handoff.pending, Some(current));
    handoff.cancel_expected(current);
    assert!(!handoff.is_pending());
}
