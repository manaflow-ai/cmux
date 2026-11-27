//! Parity with the app's `CloudCreateRetryKeyTests`, `CloudPersonCreateApprovalTests`,
//! `CloudApprovalHoldRaceTests`, `CloudCreationProOfferTests`, `CloudEnvironmentBootFlowTests`
//! and `CloudCreateWithoutAskingTests`, plus a case for every branch.

use super::*;

const TIMEOUT_MS: u64 = 120_000; // `CloudAppOpRunner.timeout`

/// A backend that holds the create for approval until it is answered, then
/// finishes it `ready_ms` after the answer; `pending` names the request it reports.
struct Backend {
    pending: Vec<String>,
    answered_at: Option<u64>,
    ready_ms: u64,
    calls: usize,
}

#[derive(Debug, PartialEq, Eq)]
enum End {
    Machine,
    Failed(Failure),
}

struct Run {
    end: End,
    pauses: Vec<u64>,
    answered: Vec<String>,
    recorded: Vec<String>,
    asked: Vec<String>,
    elapsed_ms: u64,
}

fn drive(
    backend: &mut Backend,
    confirmed: bool,
    earlier: Option<&str>,
    yes: bool,
    outcome: ApproveOutcome,
) -> Run {
    let mut now = 0u64;
    let (mut pauses, mut answered, mut recorded, mut asked) = (vec![], vec![], vec![], vec![]);
    let mut step = step(
        Approval::default(),
        Event::Start {
            confirmed,
            earlier: earlier.map(str::to_owned),
            patience_ms: TIMEOUT_MS,
            now_ms: now,
        },
    );
    loop {
        let mut next = None;
        for effect in step.effects.clone() {
            match effect {
                Effect::Call => {
                    let index = backend.calls.min(backend.pending.len() - 1);
                    backend.calls += 1;
                    let ready = backend.answered_at.is_some_and(|at| now >= at + backend.ready_ms);
                    next = Some(if ready {
                        Event::Answered
                    } else {
                        Event::Pending {
                            request: Some(backend.pending[index].clone()),
                            now_ms: now,
                        }
                    });
                }
                Effect::Done => {
                    return Run {
                        end: End::Machine,
                        pauses,
                        answered,
                        recorded,
                        asked,
                        elapsed_ms: now,
                    };
                }
                Effect::Fail { failure } => {
                    return Run {
                        end: End::Failed(failure),
                        pauses,
                        answered,
                        recorded,
                        asked,
                        elapsed_ms: now,
                    };
                }
                Effect::Ask { request } => {
                    asked.push(request);
                    next = Some(Event::Asked { yes });
                }
                Effect::Approve { request } => {
                    if outcome == ApproveOutcome::Done {
                        answered.push(request);
                    }
                    backend.answered_at.get_or_insert(now);
                    next = Some(Event::Approved { outcome, now_ms: now });
                }
                Effect::RecordApproved { request } => recorded.push(request),
                Effect::Pause { ms, .. } => {
                    pauses.push(ms);
                    now += ms;
                    next = Some(Event::Paused);
                }
            }
        }
        step = super::step(step.state, next.expect("a step names what to do"));
    }
}

fn backend(ready_ms: u64) -> Backend {
    Backend { pending: vec!["req_1".into()], answered_at: None, ready_ms, calls: 0 }
}

#[test]
fn an_approved_create_the_server_takes_a_minute_over_is_waited_for() {
    let mut backend = backend(60_000);
    let run = drive(&mut backend, true, None, true, ApproveOutcome::Done);
    assert_eq!(run.end, End::Machine);
    assert!(run.elapsed_ms >= 60_000);
    assert_eq!(run.pauses[..5], [250, 500, 1000, 1000, 1000]);
    assert!(run.pauses.iter().all(|&ms| ms <= 1000));
    assert_eq!(run.answered, ["req_1"]);
    assert_eq!(run.recorded, ["req_1"]);
}

#[test]
fn an_approved_create_the_server_finishes_soon_is_seen_within_a_second() {
    let mut backend = backend(8_000);
    let run = drive(&mut backend, true, None, true, ApproveOutcome::Done);
    assert_eq!(run.end, End::Machine);
    assert!((8_000..=9_000).contains(&run.elapsed_ms), "{}", run.elapsed_ms);
}

#[test]
fn the_retries_fill_the_patience_and_no_more() {
    let waits = waits(TIMEOUT_MS);
    let pauses: u64 = (1..waits).map(backoff_ms).sum();
    assert!(
        pauses >= TIMEOUT_MS && pauses < TIMEOUT_MS + 2_000,
        "{waits} waits add up to {pauses}"
    );
    assert_eq!(super::waits(0), 1);
}

#[test]
fn the_backoff_is_250_500_then_1000() {
    assert_eq!([0, 1, 2, 3, 9].map(backoff_ms), [250, 250, 500, 1000, 1000]);
}

#[test]
fn an_approved_create_still_pending_after_two_minutes_ends_still_pending() {
    let mut backend = backend(u64::MAX / 2);
    let run = drive(&mut backend, true, None, true, ApproveOutcome::Done);
    assert_eq!(run.end, End::Failed(Failure::StillPending { request: "req_1".into() }));
    assert_eq!(run.answered, ["req_1"]);
    assert!((120_000..130_000).contains(&run.elapsed_ms), "{}", run.elapsed_ms);
}

#[test]
fn a_pending_answer_for_another_request_after_the_approval_fails_at_once() {
    let mut backend = Backend {
        pending: vec!["req_1".into(), "req_2".into()],
        answered_at: None,
        ready_ms: u64::MAX / 2,
        calls: 0,
    };
    let run = drive(&mut backend, true, None, true, ApproveOutcome::Done);
    assert_eq!(run.end, End::Failed(Failure::StillPending { request: "req_2".into() }));
    assert!(run.pauses.is_empty(), "it waited for a request nobody answered: {:?}", run.pauses);
    assert_eq!(backend.calls, 2);
}

#[test]
fn a_retry_while_the_approved_create_still_runs_waits_instead_of_answering_again() {
    let mut backend = backend(10_000);
    backend.answered_at = Some(0);
    let run = drive(&mut backend, true, Some("req_1"), true, ApproveOutcome::Done);
    assert_eq!(run.end, End::Machine);
    assert!(run.answered.is_empty(), "the Retry answered the closed approval again");
    assert!(run.recorded.is_empty());
}

#[test]
fn an_earlier_approval_for_another_request_is_answered_anew() {
    let mut backend = backend(0);
    let run = drive(&mut backend, true, Some("req_0"), true, ApproveOutcome::Done);
    assert_eq!(run.end, End::Machine);
    assert_eq!(run.answered, ["req_1"]);
}

#[test]
fn an_answer_it_never_recorded_waits_instead_of_failing() {
    let mut backend = backend(1_000);
    let run = drive(&mut backend, true, None, true, ApproveOutcome::AlreadyAnswered);
    assert_eq!(run.end, End::Machine);
    assert_eq!(
        run.recorded,
        ["req_1"],
        "an already answered approval is recorded like a new answer"
    );
}

#[test]
fn an_approval_answered_elsewhere_is_waited_for_and_not_recorded() {
    let mut backend = backend(1_000);
    let run = drive(&mut backend, true, None, true, ApproveOutcome::AnsweredElsewhere);
    assert_eq!(run.end, End::Machine);
    assert!(run.recorded.is_empty());
    assert_eq!(run.pauses[0], 250, "the call after the answer is the first same-key retry");
}

#[test]
fn an_unconfirmed_call_asks_and_a_no_sends_nothing_more() {
    let mut backend = backend(0);
    let run = drive(&mut backend, false, None, false, ApproveOutcome::Done);
    assert_eq!(run.end, End::Failed(Failure::Declined));
    assert_eq!(run.asked, ["req_1"]);
    assert!(run.answered.is_empty());
    assert_eq!(backend.calls, 1);
}

#[test]
fn an_unconfirmed_call_asks_once_and_a_yes_answers() {
    let mut backend = backend(0);
    let run = drive(&mut backend, false, None, true, ApproveOutcome::Done);
    assert_eq!(run.end, End::Machine);
    assert_eq!(run.asked, ["req_1"]);
    assert_eq!(run.answered, ["req_1"]);
}

#[test]
fn a_confirmed_create_never_asks() {
    let mut backend = backend(0);
    let run = drive(&mut backend, true, None, false, ApproveOutcome::Done);
    assert_eq!(run.end, End::Machine);
    assert!(run.asked.is_empty());
}

#[test]
fn an_answered_call_returns_at_once() {
    let first = step(
        Approval::default(),
        Event::Start { confirmed: true, earlier: None, patience_ms: TIMEOUT_MS, now_ms: 5 },
    );
    assert_eq!(first.effects, [Effect::Call]);
    assert_eq!(first.state.waits, waits(TIMEOUT_MS));
    assert_eq!(step(first.state, Event::Answered).effects, [Effect::Done]);
}

#[test]
fn a_pending_answer_without_its_request_is_a_protocol_break() {
    let first = step(
        Approval::default(),
        Event::Start { confirmed: true, earlier: None, patience_ms: TIMEOUT_MS, now_ms: 0 },
    );
    let next = step(first.state, Event::Pending { request: None, now_ms: 0 });
    assert_eq!(next.effects, [Effect::Fail { failure: Failure::NoApprovalRequest }]);
}

#[test]
fn a_clock_that_stands_still_ends_at_the_wait_count() {
    // Every pause takes no time: `attempt < waits` ends it, not the clock.
    let mut state = step(
        Approval::default(),
        Event::Start { confirmed: true, earlier: Some("r".into()), patience_ms: 1_000, now_ms: 0 },
    )
    .state;
    let mut pauses = 0;
    loop {
        let next = step(state, Event::Pending { request: Some("r".into()), now_ms: 0 });
        match next.effects.as_slice() {
            [Effect::Pause { .. }] => {
                pauses += 1;
                let after = step(next.state, Event::Paused);
                assert_eq!(after.effects, [Effect::Call]);
                state = after.state;
            }
            [Effect::Fail { failure: Failure::StillPending { request } }] => {
                assert_eq!(request, "r");
                break;
            }
            other => panic!("{other:?}"),
        }
    }
    assert_eq!(pauses, waits(1_000));
}

#[test]
fn the_loop_ends_still_pending_after_its_last_pass() {
    let state = Approval { waits: 2, passes: 3, approved: Some("r".into()), ..Approval::default() };
    let next = step(state, Event::Paused);
    assert_eq!(
        next.effects,
        [Effect::Fail { failure: Failure::StillPending { request: "r".into() } }]
    );
    let state = Approval { waits: -1, passes: 1, ..Approval::default() };
    assert_eq!(
        step(state, Event::Paused).effects,
        [Effect::Fail { failure: Failure::StillPending { request: String::new() } }]
    );
}

#[test]
fn the_gate() {
    assert_eq!(gate(None, false), Gate::Allowed);
    let free = Limits { max_active_vms: Some(0), active_vm_count: 0, plan_id: None };
    assert_eq!(gate(Some(&free), true), Gate::FreePlan);
    let named_free =
        Limits { max_active_vms: Some(3), active_vm_count: 0, plan_id: Some("FREE".into()) };
    assert_eq!(gate(Some(&named_free), false), Gate::FreePlan);
    let full = Limits { max_active_vms: Some(2), active_vm_count: 2, plan_id: Some("pro".into()) };
    assert_eq!(gate(Some(&full), false), Gate::AtLimit { max: 2 });
    assert_eq!(gate(Some(&full), true), Gate::Allowed, "a cap the server makes room at");
    let room = Limits { max_active_vms: Some(2), active_vm_count: 1, plan_id: Some("pro".into()) };
    assert_eq!(gate(Some(&room), false), Gate::Allowed);
    let unlimited =
        Limits { max_active_vms: None, active_vm_count: 99, plan_id: Some("max".into()) };
    assert_eq!(gate(Some(&unlimited), false), Gate::Allowed);
}

#[test]
fn the_default_machine_trims_its_name() {
    assert_eq!(named(Some("  box \n")).name.as_deref(), Some("box"));
    assert_eq!(named(Some(" \n")).name, None);
    assert_eq!(named(None), Machine { name: None, cpu: 2, memory_mb: 4096, disk_mb: 20480 });
}

#[test]
fn a_plain_create_sends_its_size_and_name() {
    let params =
        create_params(&CreateInput { name: Some(" box ".into()), ..CreateInput::default() });
    assert_eq!(params.op, "cloud.machine.create");
    assert_eq!(
        params.args,
        json!({ "name": "box", "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 20480 } })
    );
    assert_eq!(params.options, params.args);
}

#[test]
fn an_environment_boot_sends_the_environment() {
    let params =
        create_params(&CreateInput { environment: Some("env_1".into()), ..CreateInput::default() });
    assert_eq!(params.op, "cloud.environment.boot");
    assert_eq!(params.args["environment"], "env_1");
    assert!(params.args.get("name").is_none());
}

#[test]
fn the_options_carry_what_the_op_does_not() {
    let input = CreateInput {
        cpu: Some(4),
        memory_mb: Some(8192),
        disk_mb: Some(65536),
        size_name: Some("lg".into()),
        persistent: true,
        script: Some(Script {
            kind: "shell".into(),
            contents_base64: "ZWNobw==".into(),
            repo: Some("o/r".into()),
        }),
        machine_config_base64: Some(String::new()),
        ..CreateInput::default()
    };
    let params = create_params(&input);
    assert_eq!(params.args, json!({ "size": { "cpu": 4, "memory_mb": 8192, "disk_mb": 65536 } }));
    assert_eq!(params.options["size_name"], "lg");
    assert_eq!(params.options["idle_seconds"], 0);
    assert_eq!(
        params.options["bootstrap"],
        json!({ "kind": "shell", "contents_base64": "ZWNobw==", "repo": "o/r" })
    );
    assert_eq!(params.options["machine_config_base64"], "");
    let no_repo = create_params(&CreateInput {
        script: Some(Script { kind: "k".into(), contents_base64: String::new(), repo: None }),
        ..CreateInput::default()
    });
    assert_eq!(no_repo.options["bootstrap"]["repo"], Value::Null);
    assert!(no_repo.options.get("idle_seconds").is_none());
}

#[test]
fn which_failure_offers_an_upgrade() {
    assert_eq!(
        pro_offer(&RefusalInput::FreePlan, PLAN_REQUIRED_CODE),
        Some(ProOffer { plan: "pro", offered: true })
    );
    let max = RefusalInput::OpFailure { code: PLAN_REQUIRED_CODE.into(), plan: Some("max".into()) };
    assert_eq!(pro_offer(&max, PLAN_REQUIRED_CODE), Some(ProOffer { plan: "max", offered: false }));
    let pro = RefusalInput::OpFailure { code: PLAN_REQUIRED_CODE.into(), plan: None };
    assert_eq!(pro_offer(&pro, PLAN_REQUIRED_CODE), Some(ProOffer { plan: "pro", offered: false }));
    let other =
        RefusalInput::OpFailure { code: "cloud.approval_pending".into(), plan: Some("max".into()) };
    assert_eq!(pro_offer(&other, PLAN_REQUIRED_CODE), None);
    assert_eq!(pro_offer(&RefusalInput::AtLimit, PLAN_REQUIRED_CODE), None);
    assert_eq!(pro_offer(&RefusalInput::PlanRequired, PLAN_REQUIRED_CODE), None);
    assert_eq!(pro_offer(&RefusalInput::Other, PLAN_REQUIRED_CODE), None);
}

#[test]
fn the_bootstrap_left_to_do() {
    let none = Part::default();
    let unstarted = Part { requested: true, status: None };
    let failed = Part { requested: true, status: Some("failed".into()) };
    let running = Part { requested: true, status: Some("running".into()) };
    assert_eq!(
        bootstrap_needs(&none, &none),
        Needs { script: false, machine_config: false, bootstrap: false }
    );
    assert_eq!(
        bootstrap_needs(&unstarted, &none),
        Needs { script: true, machine_config: false, bootstrap: true }
    );
    assert_eq!(
        bootstrap_needs(&running, &failed),
        Needs { script: false, machine_config: true, bootstrap: true }
    );
    assert_eq!(bootstrap_needs(&running, &running).bootstrap, false);
}

fn key(name: &str) -> CreateKey {
    CreateKey { idempotency_key: name.into(), ..CreateKey::default() }
}

#[test]
fn the_creation_keeps_its_key_and_team_across_sends() {
    let sent = change_key(
        key("k1"),
        KeyChange::Sent { team: Some("team_a".into()), route: "relay".into() },
    );
    let again =
        change_key(sent, KeyChange::Sent { team: Some("team_b".into()), route: "direct".into() });
    assert_eq!(again.idempotency_key, "k1");
    assert_eq!(again.team.as_deref(), Some("team_a"), "a later send re-pinned the team");
    assert_eq!(again.route.as_deref(), Some("relay"));
    assert!(again.was_sent);
}

#[test]
fn a_refusal_that_made_no_machine_gives_the_retry_a_new_key() {
    let sent = change_key(
        key("k1"),
        KeyChange::Sent { team: Some("team_a".into()), route: "relay".into() },
    );
    let approved = change_key(sent, KeyChange::Approved { request: "r".into(), key: "k1".into() });
    let answering =
        change_key(approved, KeyChange::Answering { request: "r".into(), key: "k1".into() });
    assert_eq!(answering.approved_request.as_deref(), Some("r"));
    assert_eq!(answering.answering_request.as_deref(), Some("r"));
    let renewed =
        change_key(answering, KeyChange::Renew { key: "k1".into(), new_key: "k2".into() });
    assert_eq!(renewed.idempotency_key, "k2");
    assert!(
        !renewed.was_sent
            && renewed.team.is_none()
            && renewed.approved_request.is_none()
            && renewed.answering_request.is_none()
    );
    assert!(renewed.route.is_none(), "a new key's first send picks its route again");
}

#[test]
fn a_late_refusal_or_approval_for_an_older_key_leaves_the_current_key_alone() {
    let current = change_key(
        key("k2"),
        KeyChange::Sent { team: Some("team_a".into()), route: "relay".into() },
    );
    let after = [
        KeyChange::Renew { key: "k1".into(), new_key: "k3".into() },
        KeyChange::Approved { request: "r".into(), key: "k1".into() },
        KeyChange::Answering { request: "r".into(), key: "k1".into() },
    ]
    .into_iter()
    .fold(current.clone(), change_key);
    assert_eq!(after, current);
}

#[test]
fn a_restart_goes_back_to_its_phase() {
    assert_eq!(restart_phase(false), "requesting");
    assert_eq!(restart_phase(true), "created");
}
