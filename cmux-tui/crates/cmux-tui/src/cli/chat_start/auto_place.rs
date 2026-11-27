//! A new chat's Auto place (acpmux `place_mode`): the mode of every chat whose
//! start names no target (no `--on`, `CMUX_ON` or `chat.on`), and `--on auto`. This Mac when
//! acpmux's placement says it has room, as before; when it is busy, a new Cloud VM (the hybrid
//! start where it is on), never another of the person's machines. With Cloud off or signed out,
//! or no answer from acpmux, the chat starts here as before.

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
) -> (Option<Route>, String) {
    let Ok(verdict) = verdict else {
        return (None, "acpmux did not say whether this Mac has room, so it starts here".into());
    };
    let local = place_mode::local_of(&verdict);
    let account = if local.busy.is_some() { account() } else { Account::default() };
    let decision =
        place_mode::decide(&PlaceMode::Auto, &Facts { local, account, machines: vec![] });
    // Auto leaves a busy Mac only where the hybrid start is on for the account (its flag or a
    // plan that grants it): nobody without it gets a Cloud VM they did not pick.
    match decision.place {
        Place::Cloud { hybrid: true } => (Some(Route::Cloud(Machine::New)), decision.why),
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
    let (route, why) = pick(super::super::agents::chat::chat_place_verdict(global), account);
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
mod tests {
    use super::*;
    use serde_json::json;

    fn start(list: &[&str]) -> Start {
        let words: Vec<String> = list.iter().map(|w| (*w).to_owned()).collect();
        match super::super::parse(&words, None).unwrap() {
            super::super::Parsed::Run(start) => start,
            super::super::Parsed::Help => panic!("help"),
        }
    }

    fn verdict(busy: bool) -> Value {
        json!({"hosts": [{"name": "mac", "local": true, "room": if busy { 0.0 } else { 3.0 },
            "load": busy, "refused": busy.then_some("no room: RAM is the limit")}]})
    }

    fn signed_in() -> Account {
        Account { signed_in: true, flag: Some(true), ..Account::default() }
    }

    /// A chat nobody placed: here with room (the account is never read), a new Cloud VM when
    /// this Mac is busy and Cloud takes it, here when it cannot or acpmux gave no verdict.
    #[test]
    fn auto_starts_here_with_room_else_on_a_new_cloud_vm() {
        let (route, why) = pick(Ok(verdict(false)), || panic!("read the account with room"));
        assert_eq!(route, None);
        assert_eq!(why, "this Mac has room (for 3 more)");
        let (route, why) = pick(Ok(verdict(true)), signed_in);
        assert_eq!(route, Some(Route::Cloud(Machine::New)));
        assert!(why.starts_with("this Mac is busy (no room: RAM is the limit)"), "{why}");
        assert_eq!(pick(Ok(verdict(true)), Account::default).0, None);
        let disabled = || Account { cloud_disabled: true, ..signed_in() };
        assert_eq!(pick(Ok(verdict(true)), disabled).0, None);
        assert_eq!(pick(Err("no acpmux".into()), signed_in).0, None);
        let no_hybrid = || Account { flag: Some(false), ..signed_in() };
        let (route, why) = pick(Ok(verdict(true)), no_hybrid);
        assert_eq!(route, None);
        assert!(why.contains("hybrid chats are not on"), "{why}");
    }

    /// Auto weighs only a start a Cloud VM runs the same: no target named, nothing of this
    /// Mac's own in it.
    #[test]
    fn auto_weighs_only_a_start_with_nothing_of_this_macs_own() {
        assert!(applies(&start(&["--prompt", "hi"])));
        assert!(applies(&start(&[])));
        assert!(!applies(&start(&["--on", "here", "--prompt", "hi"])));
        assert!(!applies(&start(&["--on", "vm:new", "--prompt", "hi"])));
        assert!(!applies(&start(&["--cwd", "/tmp", "--prompt", "hi"])));
        assert!(!applies(&start(&["--environment", "env_1", "--prompt", "hi"])));
    }
}
