//! `CMUX_CLOUD_FAULT=CLASS[,CLASS…]`: the start-path fault drill of goals/cloud-errors-self-recover (Leo: "Fix the
//! cause"). It measures the recovery table; it fixes nothing. Unset (every person's run), [`take`] answers `None` and
//! the start runs as it always did.
//!
//! Set, each start attempt of this process takes the next listed class in turn: [`super::run`]'s first attempt, then
//! each rerun the table (recover.rs) runs. That attempt does not run; it answers [`error`], the error the start path
//! builds for that class, so the table's own row decides what happens next. The cmuxterm-hq probe
//! `app-chat-fault-production` runs the production chat journey once per class with this set, and passes only on a
//! reply that came with no click. A class with no row ends the run with its error unchanged: the named fallback list.
//!
//! A class is named by its [`Class`] variant, in any case, with `_` or `-` between words or none: `machine_stuck`,
//! `MachineStuck`, `machine-stuck`. An unknown name is ignored (the drill never fails a person's start by itself), and
//! each class is fired at most as many times as it is listed.
//!
//! Every injected error says `details.injected: true`. Where a class's real error names a machine, the injected one
//! names one no machine has ([`super::fresh_machine_name`]), or the request's own `--name`/`--target`, so an action
//! never deletes or starts on a machine the run did not ask for:
//! - `MachineStuck`: fresh.rs releases a name no machine has (nothing to delete) and starts on a fresh machine.
//! - `StartPending`: the rerun starts on the named machine, which the rerun creates for a new-machine run.
//! - `MachineCap`: the error offers no machine to free, so even `--make-room` deletes nothing; it passes through.

use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};

use serde_json::{Value, json};

use super::recover::Class;
use super::{Machine, Outcome, Request, fresh, fresh_machine_name};

/// The variable the probe sets.
pub(super) const VAR: &str = "CMUX_CLOUD_FAULT";

/// The classes still to fire, read from [`VAR`] once per process.
fn queue() -> &'static Mutex<VecDeque<Class>> {
    static QUEUE: OnceLock<Mutex<VecDeque<Class>>> = OnceLock::new();
    QUEUE.get_or_init(|| Mutex::new(parse(&std::env::var(VAR).unwrap_or_default())))
}

/// The next class to fire in place of a start attempt; `None` once none is left, and always when [`VAR`] is unset.
pub(super) fn take() -> Option<Class> {
    queue().lock().ok()?.pop_front()
}

/// The classes `text` names, in order; unknown names are dropped.
pub(super) fn parse(text: &str) -> VecDeque<Class> {
    text.split(',').filter_map(|word| class_named(word.trim())).collect()
}

fn fold(name: &str) -> String {
    name.chars().filter(|c| *c != '_' && *c != '-').flat_map(char::to_lowercase).collect()
}

/// The class `name` names ([`Class::NAMES`], folded), or `None`.
pub(super) fn class_named(name: &str) -> Option<Class> {
    if name.is_empty() {
        return None;
    }
    let wanted = fold(name);
    Class::NAMES
        .iter()
        .zip(Class::ALL)
        .find(|(known, _)| fold(known) == wanted)
        .map(|(_, &class)| class)
}

/// The machine name a machine-naming error carries: the request's own, else one no machine has.
fn machine_name(request: &Request) -> String {
    match &request.machine {
        Machine::Named(name) => name.clone(),
        Machine::Target(_) | Machine::New => fresh_machine_name(),
    }
}

/// The failure the start path answers for `class`, with `details.injected: true`. Exhaustive on purpose: a new class
/// needs its injected error here to compile, so the drill always covers every row of the table.
pub(super) fn error(class: Class, request: &Request) -> Outcome {
    let failed = |code: &str, message: String, mut details: Value, retryable: bool| {
        if let Some(map) = details.as_object_mut() {
            map.insert("injected".into(), json!(true));
        }
        Outcome::Failed {
            error: json!({"code": code, "message": message, "details": details, "retryable": retryable}),
            exit: 1,
        }
    };
    let plain = |code: &str, message: &str| failed(code, message.to_owned(), json!({}), false);
    match class {
        Class::MachineStuck => {
            let name = fresh_machine_name();
            failed(
                fresh::STUCK_CODE,
                format!(
                    "Machine `{name}` didn't connect or start its agent within {} s",
                    fresh::START_BOUND.as_secs()
                ),
                json!({"machine_name": name, "bound_ms": fresh::START_BOUND.as_millis(), "why": "bound"}),
                false,
            )
        }
        Class::StartPending => {
            let mut details = json!({"machine_name": machine_name(request), "stage": {}});
            if let Machine::Target(id) = &request.machine {
                if let Some(map) = details.as_object_mut() {
                    map.insert("machine_id".into(), json!(id));
                }
            }
            failed(
                "cloud.start_pending",
                "The machine is still starting".to_owned(),
                details,
                false,
            )
        }
        Class::ListUnread => failed(
            "cloud.list_unread",
            "The app has not loaded its Cloud machines yet".to_owned(),
            json!({"last_error": null}),
            true,
        ),
        Class::MachineCap => plain("cloud.machine_cap", "The account is at its machine cap"),
        Class::SpendCap => plain("cloud.spend_cap", "The account is at its spend cap"),
        Class::SignedOut => plain("cloud.signed_out", "The app is signed out of Cloud"),
        Class::AccountChanged => {
            plain("cloud.account_changed", "The app is signed in to another account")
        }
        Class::AppNotConnected => plain("cloud.app_not_connected", "The Mac app is not connected"),
        Class::NoConnection => plain(
            "unavailable",
            &format!(
                "No Cloud connection serves {} yet. Add one in Settings > Cloud",
                request.agent
            ),
        ),
        Class::AgentSignIn => plain("auth.token", "The machine's agent is not signed in"),
        Class::AgentLimit => plain("agent.limit_reached", "The agent's account is out of usage"),
        Class::AgentRefused => {
            plain("agent_session.bad_request", "The machine refused the session")
        }
        Class::StartFailed => plain("cloud.start_failed", "The machine failed at a final stage"),
        Class::NameTaken => plain("cloud.name_taken", "The name is another machine's"),
        Class::MakeRoomFailed => plain("cloud.make_room_failed", "No machine could be freed now"),
        Class::TurnFailed => plain("chat.turn_failed", "The turn failed"),
        Class::TurnTimeout => plain("chat.wait_timeout", "The turn did not finish in time"),
        Class::ChatUnreachable => plain("chat.unreachable", "The chat cannot be read"),
        Class::SendFailed => plain("chat.send_failed", "The prompt was not taken"),
        Class::PermissionWaiting => {
            plain("chat.permission_waiting", "The turn waits on a permission answer")
        }
    }
}
