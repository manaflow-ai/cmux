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

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{Deadline, Machine, Outcome, Request, Runner, at, fresh, make_room, run_once};

/// Declares [`Class`] and [`Class::ALL`] from one list, so `ALL` names every variant by construction.
macro_rules! classes {
    ($($(#[$doc:meta])* $name:ident,)*) => {
        /// A Cloud chat error class of the start path, read from the error's `code` (and, for the app's own
        /// `unavailable`, its words) by [`classify`].
        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub(super) enum Class {
            $($(#[$doc])* $name,)*
        }

        #[cfg(test)]
        impl Class {
            /// Every class, in declaration order.
            pub(super) const ALL: &'static [Class] = &[$(Class::$name,)*];
        }
    };
}

classes! {
    /// `cloud.machine_stuck`: a machine this run made never came up within fresh.rs's bound.
    MachineStuck,
    /// `cloud.start_pending` with no chat yet: the machine (or its create) is still on its way.
    StartPending,
    /// `cloud.list_unread`: a connected app has not loaded its Cloud machines yet (`retryable: true`).
    ListUnread,
    /// `cloud.machine_cap`: the account is at its machine cap.
    MachineCap,
    /// `cloud.spend_cap`: the account is at its spend cap.
    SpendCap,
    /// `cloud.signed_out`: the app is signed out of Cloud.
    SignedOut,
    /// `cloud.account_changed`: the app is signed in to another account than `--account`.
    AccountChanged,
    /// `cloud.app_not_connected`: the Mac app is closed, or its Mac locked or asleep.
    AppNotConnected,
    /// The app's `unavailable` "No Cloud connection serves AGENT yet": no gateway serves the agent.
    NoConnection,
    /// `auth.*` (but `auth.required`): the machine's agent is not signed in to its own account.
    AgentSignIn,
    /// `agent.limit_reached`: the agent's account is out of usage until a time.
    AgentLimit,
    /// `agent_session.*`: the machine's acpmux refused the session (bad request, untrusted folder, ...).
    AgentRefused,
    /// `cloud.start_failed`: the machine failed at a final stage, or its create failed.
    StartFailed,
    /// `cloud.name_taken`: the `--name` is another machine's.
    NameTaken,
    /// `cloud.make_room_failed` and `cloud.make_room_archiving`: `--make-room` could not free a machine now.
    MakeRoomFailed,
    /// `chat.turn_failed`: the started chat's turn failed.
    TurnFailed,
    /// `chat.wait_timeout`: `--timeout` ran out waiting on the turn.
    TurnTimeout,
    /// `chat.lost` and `chat.unreachable`: the started chat cannot be read any more.
    ChatUnreachable,
    /// `chat.send_failed`: the prompt was not taken.
    SendFailed,
    /// `chat.permission_waiting`: the turn waits on a person's permission answer.
    PermissionWaiting,
}

/// What runs on its own for a [`Class`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Action {
    /// Release the stuck machine and start on a fresh one ([`fresh::replace_stuck`], which owns its own retries).
    FreshMachine,
    /// Pause, then start again on the machine the error names (never a second new machine), within the deadline.
    RerunOnMachine,
    /// Pause, then start again from the top, within the deadline.
    Rerun,
    /// Free the machine the cap refusal offers and start again once; only with `--make-room` (cap.rs), the
    /// person's consent to delete a machine, so the default stays as it was.
    MakeRoom,
}

/// THE table: the action for each class, or `None` where only a person can act, which is the one case that falls
/// to click-through. Exhaustive on purpose: a new class needs its row here to compile.
pub(super) fn recovery(class: Class) -> Option<Action> {
    match class {
        Class::MachineStuck => Some(Action::FreshMachine),
        Class::StartPending => Some(Action::RerunOnMachine),
        Class::ListUnread => Some(Action::Rerun),
        Class::MachineCap => Some(Action::MakeRoom),
        // A person signs in, opens or unlocks the app, picks the account, or adds a Cloud connection (the
        // platform answers it `x-should-retry: false`): a rerun meets the same refusal.
        Class::SignedOut
        | Class::AccountChanged
        | Class::AppNotConnected
        | Class::NoConnection
        | Class::AgentSignIn => None,
        // Money or plan: raising a cap or waiting out an account's usage window is the person's call.
        Class::SpendCap | Class::AgentLimit => None,
        // Definitive refusals: the same request is refused again, and fresh.rs already rolls back a machine a
        // refused start made.
        Class::AgentRefused | Class::NameTaken | Class::MakeRoomFailed => None,
        // A final-stage failure is not proven to be this run's own machine from its answer alone, so starting on
        // a new one (and deleting this one) is not yet safe from here.
        Class::StartFailed => None,
        // The chat started: the machine's acpmux resumes a failed turn itself (turn_errors::resume_cause), and a
        // rerun here would start a second chat with the same prompt.
        Class::TurnFailed
        | Class::TurnTimeout
        | Class::ChatUnreachable
        | Class::SendFailed
        | Class::PermissionWaiting => None,
    }
}

/// The class of a start error, from its `code` (and the app's words for `unavailable`); `None` for a code no class
/// names, which passes through as before.
pub(super) fn classify(error: &Value) -> Option<Class> {
    let code = at(error, "code").as_str().unwrap_or_default();
    let class = match code {
        fresh::STUCK_CODE => Class::MachineStuck,
        // A start past the deadline, or one whose prompt may be on the machine, is not a machine still starting.
        "cloud.start_pending" if !chat_may_exist(error) => Class::StartPending,
        "cloud.list_unread" => Class::ListUnread,
        "cloud.machine_cap" => Class::MachineCap,
        "cloud.spend_cap" => Class::SpendCap,
        "cloud.signed_out" => Class::SignedOut,
        "cloud.account_changed" => Class::AccountChanged,
        "cloud.app_not_connected" => Class::AppNotConnected,
        "unavailable"
            if at(error, "message")
                .as_str()
                .is_some_and(|text| text.starts_with("No Cloud connection serves")) =>
        {
            Class::NoConnection
        }
        "agent.limit_reached" => Class::AgentLimit,
        "cloud.start_failed" => Class::StartFailed,
        "cloud.name_taken" => Class::NameTaken,
        "cloud.make_room_failed" | "cloud.make_room_archiving" => Class::MakeRoomFailed,
        "chat.turn_failed" => Class::TurnFailed,
        "chat.wait_timeout" => Class::TurnTimeout,
        "chat.lost" | "chat.unreachable" => Class::ChatUnreachable,
        "chat.send_failed" => Class::SendFailed,
        "chat.permission_waiting" => Class::PermissionWaiting,
        code if code.starts_with("agent_session.") => Class::AgentRefused,
        code if code.starts_with("auth.") && code != "auth.required" => Class::AgentSignIn,
        _ => return None,
    };
    Some(class)
}

/// A pending answer that may have a chat behind it: the prompt was on its way (`sent: unknown`), or a chat had
/// started (`answer` holds its ids). Starting again there could send the prompt twice.
fn chat_may_exist(error: &Value) -> bool {
    let details = at(error, "details");
    !at(details, "sent").is_null() || !at(details, "answer").is_null()
}

/// The first pause before a rerun; each next one doubles, up to [`RERUN_MAX_PAUSE`], always within the deadline.
const RERUN_PAUSE: Duration = Duration::from_secs(5);
/// The longest pause between reruns.
const RERUN_MAX_PAUSE: Duration = Duration::from_secs(30);

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
    mut outcome: Outcome,
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
        let Some(action) = classify(error).and_then(recovery) else { return outcome };
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
                let next = run_once(runner, &current);
                annotate(keep_new_machine(next, made), reruns)
            }
            // Used up: the failure stands.
            Action::FreshMachine | Action::MakeRoom => return outcome,
        };
        last = Some(action);
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
