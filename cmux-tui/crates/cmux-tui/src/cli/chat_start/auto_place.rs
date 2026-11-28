//! A new chat's Auto place (acpmux `place_mode`): the mode of every chat whose
//! start names no target (no `--on`, `CMUX_ON` or `chat.on`), and `--on auto`. This Mac when
//! acpmux's placement says it has room, as before; when it is busy and AutoCloud is on here
//! (`cloud.autoCloud`, default off), a machine its owner enrolled in AutoCloud that is idle
//! (`autocloud_enroll.rs`); else a new Cloud VM (the hybrid start where it is on). Never a
//! machine that is not enrolled. With Cloud off or signed out, or no answer from acpmux, the
//! chat starts here as before. The same `place_mode::decide` as acpmux's `_acpmux/chat_place`,
//! from the same verdict (its host rows carry `autoCloud` since chat_place v2).

use acpmux::place_mode::{self, Facts, Place, PlaceMode};
use cmux_cloud_start_core::hybrid::Account;
use serde_json::Value;

use super::super::cloud_start_chat::Machine;
use super::super::{GlobalArgs, OutputMode};
use super::{Route, Start, hybrid_start};

/// The `--on` word that asks for Auto by name.
pub(super) const AUTO: &str = "auto";

/// Whether Auto weighs this start: it names no target, and nothing in it is this Mac's own (a
/// clone, a folder here, an environment, files to attach), so a Cloud VM would run it the same.
pub(super) fn applies(start: &Start) -> bool {
    start.on.is_none()
        && start.repo.is_none()
        && start.cwd.is_none()
        && start.from_folder.is_none()
        && start.environment.is_none()
        && !start.no_folder
        && start.attach.is_empty()
}

/// Auto's route from the placement verdict and the account (read only when this Mac is busy),
/// and why. None: here, as before.
pub(super) fn pick(
    verdict: Result<Value, String>,
    account: impl FnOnce() -> Account,
    auto_cloud: bool,
) -> (Option<Route>, String) {
    let Ok(verdict) = verdict else {
        return (None, "acpmux did not say whether this Mac has room, so it starts here".into());
    };
    let local = place_mode::local_of(&verdict);
    let account = if local.busy.is_some() { account() } else { Account::default() };
    let enrolled = if auto_cloud { place_mode::enrolled_of(&verdict) } else { Vec::new() };
    let facts = Facts { local, account, enrolled, ..Facts::default() };
    let decision = place_mode::decide(&PlaceMode::Auto, &facts);
    // Auto leaves a busy Mac only where the hybrid start is on for the account (its flag or a
    // plan that grants it): nobody without it gets a Cloud VM they did not pick.
    match decision.place {
        Place::Cloud { hybrid: true } => (Some(Route::Cloud(Machine::New)), decision.why),
        // AutoCloud's enrolled tier: a peer of the app's acpmux, by name.
        Place::Machine { id } => (Some(Route::Peer(id)), decision.why),
        Place::Cloud { hybrid: false } => (
            None,
            "this Mac is busy, and hybrid chats are not on for this account, so it starts here"
                .into(),
        ),
        _ => (None, decision.why),
    }
}

/// The route Auto gives `start`, or `Route::Here`. A Cloud route says why on stderr.
pub(super) fn route(global: &GlobalArgs, start: &Start) -> Route {
    if !applies(start) {
        return Route::Here;
    }
    // Signed in and Cloud allowed, read with the start's own machine list; the plan is the
    // hybrid start's own read, so none here.
    let account = || hybrid_start::account_now(global);
    let verdict = super::super::agents::chat::chat_place_verdict(global);
    let (route, why) = pick(verdict, account, acpmux::placement::auto_cloud_on());
    match route {
        Some(route) => {
            if global.output == OutputMode::Human {
                eprintln!("Auto: {why}");
            }
            route
        }
        None => Route::Here,
    }
}

#[cfg(test)]
#[path = "auto_place_tests.rs"]
mod tests;
