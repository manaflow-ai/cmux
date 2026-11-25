//! `cmux notification banners` and `cmux notification open <id>`: the macOS
//! banners the cmux app asked for, read and clicked from outside the app.
//!
//! ```text
//! cmux notification banners
//! cmux notification open <banner-id>
//! ```
//!
//! `banners` answers the app's `notifications.banners`: `{banners: [{id,
//! title, subtitle, body, surface, reply, approval, category}],
//! authorization}`, newest last, the last banners the app asked for (an
//! incognito window's as it showed, naming nothing of the window, its surface
//! included). It moves no focus. `open` answers `notifications.open`: it shows
//! the banner's own tab, as a click on it does, so it moves the app's focus
//! there, and answers `{opened, surface}`; an id the app lists no banner for
//! is `not_found` and opens nothing. Only a tab's banner opens (a page's click
//! handler never runs): a passkey, pairing, attention or Run banner acts on
//! the person's own click and is `person_required`. Both are app
//! methods every build serves (release builds included, unlike
//! `debug.notifications`), so a probe can check a Nightly: one banner per
//! agent turn, and its click opens the chat. The daemon's notification rows
//! stay `notification list|create|clear|ack` (`command/notification.rs`).

use serde_json::{Value, json};

use super::{GlobalArgs, wire};

const BANNERS_METHOD: &str = "notifications.banners";
const OPEN_METHOD: &str = "notifications.open";

#[derive(Debug, PartialEq, Eq)]
enum Plan {
    Banners,
    Open(String),
}

/// `cmux notification banners|open …` from the full argv. `None` for any
/// other command, the daemon's `notification` verbs included.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    if super::has_help_option(&command) {
        return None;
    }
    let (verb, rest) = match command.as_slice() {
        [scope, verb, rest @ ..]
            if scope == "notification" && matches!(verb.as_str(), "banners" | "open") =>
        {
            (verb.as_str(), rest)
        }
        _ => return None,
    };
    Some(match parse(verb, rest) {
        Ok(plan) => run(&global, &plan),
        Err(message) => wire::print_local_error(
            &json!({"code": "usage.invalid", "message": message}),
            global.output,
            2,
        ),
    })
}

fn parse(verb: &str, rest: &[String]) -> Result<Plan, String> {
    let messages = &crate::localization::catalog().notification_banners;
    match (verb, rest) {
        ("banners", []) => Ok(Plan::Banners),
        ("banners", [word, ..]) => Err(messages.banners_takes_nothing(word)),
        ("open", [id]) if !id.is_empty() && !id.starts_with('-') => Ok(Plan::Open(id.clone())),
        ("open", []) => Err(messages.open_needs_id.to_owned()),
        _ => Err(messages.open_one_id.to_owned()),
    }
}

/// The app method and params `plan` sends.
fn request(plan: &Plan) -> (&'static str, Value) {
    match plan {
        Plan::Banners => (BANNERS_METHOD, json!({})),
        Plan::Open(id) => (OPEN_METHOD, json!({"id": id})),
    }
}

fn run(global: &GlobalArgs, plan: &Plan) -> i32 {
    let (method, params) = request(plan);
    match super::mcp::agent_app(global, method, params, super::app::READ_TIMEOUT, None) {
        Ok(answer) => wire::print_local_success(&answer, global.output),
        Err(error) => wire::print_local_error(&error, global.output, 1),
    }
}

#[cfg(test)]
#[path = "notification_banners_tests.rs"]
mod tests;
