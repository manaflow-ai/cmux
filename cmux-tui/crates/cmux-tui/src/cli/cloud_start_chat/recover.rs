//! The one recovery table of `cmux cloud start-chat`: every Cloud chat error class the start path answers, and the
//! action that runs on its own for it, with no click (Leo, goals/cloud-errors-self-recover: "Fix the cause"). A
//! class with no action ([`recovery`] answers `None`) is the only one that reaches the person, who then clicks
//! through (signs in, opens the app, adds a connection); the error passes through unchanged.
//!
//! [`run`](super::run) answers every first outcome through [`recover`], which looks the failure's class up here and
//! runs its action until the start answers, an action is used up, or the run's deadline leaves no time. The fresh
//! machine of fresh.rs and `--make-room` of cap.rs run from here, so a new automatic action is one row, never a
//! second ad-hoc retry beside `run`.
//!
//! [`recovery`] is one exhaustive `match`: a new [`Class`] without a row does not compile, and the table test
//! (recover_tests.rs) injects every class in [`Class::ALL`] and checks the start path recovers or passes it through.

use std::time::Instant;

use serde_json::{Value, json};

// The table itself is cmux-cloud-start-core's, shared with the app's chat pane start (`CloudStartChat.reply`, op
// `cloud_start_pane_recovery`): one table for both starts, so a class added there is a row both answer.
pub(super) use cmux_cloud_start_core::recover::{Action, Class, recovery};
use cmux_cloud_start_core::recover::{RERUN_MAX_PAUSE, RERUN_PAUSE};

use super::{
    Deadline, Machine, Outcome, Request, Runner, at, fresh, make_room, run_once, start_fault,
};

/// The class of a start error, from its `code` (and the app's words for `unavailable`); `None` for a code no class
/// names, which passes through as before (cmux-cloud-start-core `recover::classify`).
pub(super) fn classify(error: &Value) -> Option<Class> {
    let code = at(error, "code").as_str().unwrap_or_default();
    let message = at(error, "message").as_str().unwrap_or_default();
    cmux_cloud_start_core::recover::classify(code, message, chat_may_exist(error))
}

/// A pending answer that may have a chat behind it: the prompt was on its way (`sent: unknown`), or a chat had
/// started (`answer` holds its ids). Starting again there could send the prompt twice.
fn chat_may_exist(error: &Value) -> bool {
    let details = at(error, "details");
    !at(details, "sent").is_null() || !at(details, "answer").is_null()
}

/// Runs the table on `outcome`, the start's first answer: while it is a failure whose class has an action that is
/// not used up, that action runs and its answer is the next outcome. A class with no action, an unclassified code,
/// and an action that is used up pass the failure through unchanged (click-through).
///
/// Bounds: [`Action::FreshMachine`] runs once per start it follows (fresh.rs retries inside it), [`Action::MakeRoom`]
/// once per command, and a rerun only while the run's deadline has time for its pause, so the loop always ends. A
/// run with no deadline (no `--wait` with a prompt, no caller's `until`) asked for an answer now: it is not rerun.
pub(super) fn recover(
    runner: &mut dyn Runner,
    request: &Request,
    began: Instant,
    outcome: Outcome,
) -> Outcome {
    let mut steps = Vec::new();
    let outcome = run_table(runner, request, began, outcome, &mut steps);
    record(outcome, &steps)
}

/// [`recover`]'s loop; each action it ran is pushed to `steps` as `(class, action)`, in order.
fn run_table(
    runner: &mut dyn Runner,
    request: &Request,
    began: Instant,
    mut outcome: Outcome,
    steps: &mut Vec<(Class, Action)>,
) -> Outcome {
    // The run's one deadline: a rerun keeps it, as fresh.rs and make_room do.
    let until = request.until.or(Deadline::of(request, began).0);
    let mut current = request.clone();
    let mut last = None;
    let mut made_room = false;
    let mut pause = RERUN_PAUSE;
    let mut reruns = 0_u32;
    loop {
        let Outcome::Failed { error, .. } = &outcome else { return outcome };
        let Some(class) = classify(error) else { return outcome };
        let Some(action) = recovery(class) else { return outcome };
        outcome = match action {
            Action::FreshMachine if last != Some(Action::FreshMachine) => {
                fresh::replace_stuck(runner, &current, began, outcome)
            }
            Action::MakeRoom if current.make_room && !made_room => {
                made_room = true;
                current = Request { make_room: false, until, ..current };
                make_room(runner, &current, began, outcome)
            }
            Action::RerunOnMachine | Action::Rerun => {
                let Some(again) = rerun_request(action, &current, error, until) else {
                    return outcome;
                };
                // Only a run with a deadline (`--wait` with a prompt, or a caller's `until`) waits here: one
                // without asked for an answer now, and its error says the same command again (the default stays).
                let Some(end) = until else { return outcome };
                let left = end.saturating_duration_since(runner.now());
                if left <= pause {
                    return outcome;
                }
                let made = made_machine(error);
                runner.pause(pause);
                pause = pause.saturating_mul(2).min(RERUN_MAX_PAUSE);
                reruns = reruns.saturating_add(1);
                current = again;
                let next = start_fault::take().map_or_else(
                    || run_once(runner, &current),
                    |class| start_fault::error(class, &current),
                );
                annotate(keep_new_machine(next, made), reruns)
            }
            // Used up: the failure stands.
            Action::FreshMachine | Action::MakeRoom => return outcome,
        };
        steps.push((class, action));
        last = Some(action);
    }
}

/// The recovered event: on an answer the table won, `recovered` lists each `{class, action}` that ran, in order,
/// so the probe counts a self-heal per class (shadow-leo 2f60d9d6e4cd: "log recovered events"); on a failure an
/// action ran for and lost, `details.recovery_tried` lists the same. A start the table never acted on is unchanged.
fn record(outcome: Outcome, steps: &[(Class, Action)]) -> Outcome {
    if steps.is_empty() {
        return outcome;
    }
    let list = json!(
        steps
            .iter()
            .map(|(class, action)| json!({"class": format!("{class:?}"), "action": format!("{action:?}")}))
            .collect::<Vec<_>>()
    );
    match outcome {
        Outcome::Done(mut answer) => {
            if let Some(fields) = answer.as_object_mut() {
                fields.insert("recovered".to_owned(), list);
            }
            Outcome::Done(answer)
        }
        Outcome::Failed { mut error, exit } => {
            if let Some(details) = error.get_mut("details").and_then(Value::as_object_mut) {
                details.insert("recovery_tried".to_owned(), list);
            }
            Outcome::Failed { error, exit }
        }
    }
}

/// The request a rerun starts: the same one from the top ([`Action::Rerun`]), or on the machine the pending error
/// names ([`Action::RerunOnMachine`]): its id, else its name, with `--environment` dropped since that machine is in
/// it. A pending start that names no machine is not rerun when the run asked for a new one, which would make a
/// second machine.
fn rerun_request(
    action: Action,
    request: &Request,
    error: &Value,
    until: Option<Instant>,
) -> Option<Request> {
    let again = Request { until, ..request.clone() };
    if action == Action::Rerun {
        return Some(again);
    }
    let details = at(error, "details");
    let id = at(details, "machine_id").as_str().filter(|id| !id.is_empty() && *id != "ID");
    let name = at(details, "machine_name").as_str().filter(|name| !name.is_empty());
    let machine = match (id, name, &request.machine) {
        (Some(id), _, _) => Machine::Target(id.to_owned()),
        (None, Some(name), _) => Machine::Named(name.to_owned()),
        (None, None, Machine::New) => return None,
        (None, None, other) => other.clone(),
    };
    let environment = if machine == request.machine { request.environment.clone() } else { None };
    Some(Request { machine, environment, ..again })
}

/// The machine id a failure says this run made (`details.new_machine`), so the rerun's answer on it still says so.
fn made_machine(error: &Value) -> Option<String> {
    let details = at(error, "details");
    (at(details, "new_machine").as_bool() == Some(true))
        .then(|| at(details, "machine_id").as_str().map(str::to_owned))
        .flatten()
}

fn keep_new_machine(outcome: Outcome, made: Option<String>) -> Outcome {
    match (outcome, made) {
        (Outcome::Done(mut answer), Some(id))
            if at(&answer, "machine_id").as_str() == Some(id.as_str()) =>
        {
            if let Some(fields) = answer.as_object_mut() {
                fields.insert("new_machine".to_owned(), json!(true));
            }
            Outcome::Done(answer)
        }
        (outcome, _) => outcome,
    }
}

/// How many reruns the table ran, on the answer (`recovered_reruns`), as fresh.rs says `fresh_retry`.
fn annotate(outcome: Outcome, reruns: u32) -> Outcome {
    match outcome {
        Outcome::Done(mut answer) => {
            if let Some(fields) = answer.as_object_mut() {
                fields.insert("recovered_reruns".to_owned(), json!(reruns));
            }
            Outcome::Done(answer)
        }
        Outcome::Failed { mut error, exit } => {
            if let Some(details) = error.get_mut("details").and_then(Value::as_object_mut) {
                details.insert("recovered_reruns".to_owned(), json!(reruns));
            }
            Outcome::Failed { error, exit }
        }
    }
}
