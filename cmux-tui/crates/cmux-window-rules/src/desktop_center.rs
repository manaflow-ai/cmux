//! The macOS notification center's launch and banner rules: whether this
//! launch uses the system center, asks for permission and starts without the
//! banners an earlier run left; which category a banner is filed under and
//! what an incognito window's banner leaves out; and what a click on a
//! banner's action does.
//!
//! The app keeps the `UNUserNotificationCenter` calls and reads the facts it
//! alone knows (whether this is an automation launch, a DEBUG build's rule;
//! whether the action is the system's default one).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// The launch variable an automation launch sets to post real system banners.
pub const NATIVE_NOTIFICATIONS_VARIABLE: &str = "CMUX_NEXT_NATIVE_NOTIFICATIONS";
/// The variables that mark a GUI job (a banner would catch its clicks).
pub const GUI_JOB_VARIABLES: [&str; 2] = ["NX_REMOTE", "CMUX_TEST_REQUIRE_GUI"];

/// The category of banners with a Reply field, and its action.
pub const REPLY_CATEGORY: &str = "cmux.notification.reply";
pub const REPLY_ACTION: &str = "cmux.notification.reply.send";
/// Every other app banner's category: Open and Mark as Read.
pub const DEFAULT_CATEGORY: &str = "cmux.notification.default";
pub const OPEN_ACTION: &str = "cmux.notification.open";
pub const MARK_READ_ACTION: &str = "cmux.notification.markRead";
/// Needs you banners' category, and its Show action.
pub const ATTENTION_CATEGORY: &str = "cmux.notification.attention";
pub const SHOW_ACTION: &str = "cmux.notification.attention.show";
/// A permission prompt's banner categories (with and without Always Allow) and its actions.
pub const APPROVAL_CATEGORY: &str = "cmux.notification.approval";
pub const APPROVAL_ALWAYS_CATEGORY: &str = "cmux.notification.approval.always";
pub const ALLOW_ACTION: &str = "cmux.notification.approval.allow-once";
pub const ALWAYS_ACTION: &str = "cmux.notification.approval.allow-always";
pub const DENY_ACTION: &str = "cmux.notification.approval.deny";
/// The iPhone pairing banner's Review action: it opens, as a click does.
pub const IPHONE_PAIR_REVIEW_ACTION: &str = "cmux.iphone.pair.review";

/// How this launch uses the system notification center.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Center {
    /// Every launch but an automation one, and an automation one that sets
    /// `CMUX_NEXT_NATIVE_NOTIFICATIONS=1`.
    pub uses_system_center: bool,
    /// One that uses the system center asks macOS for permission (and answers
    /// `notifications.status` / `notifications.request`), unless it is a GUI
    /// job (`NX_REMOTE=1`, `CMUX_TEST_REQUIRE_GUI=1`) that did not opt in.
    pub asks_permission: bool,
    /// Only an automation launch that opted in removes this bundle's delivered
    /// banners when it first uses the center, never a user's launch.
    pub starts_without_delivered_banners: bool,
}

fn set(environment: &HashMap<String, String>, name: &str) -> bool {
    environment.get(name).is_some_and(|value| value == "1")
}

/// How a launch with `environment` uses the center; `automation`: the app's
/// `WindowDrawPolicy.isAutomationLaunch` for it.
pub fn center(environment: &HashMap<String, String>, automation: bool) -> Center {
    let opts_in = set(environment, NATIVE_NOTIFICATIONS_VARIABLE);
    let gui_job = GUI_JOB_VARIABLES.iter().any(|name| set(environment, name));
    let uses_system_center = opts_in || !automation;
    Center {
        uses_system_center,
        asks_permission: uses_system_center && (opts_in || !gui_job),
        starts_without_delivered_banners: opts_in && automation,
    }
}

/// A banner the app asks to post.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BannerAsk {
    /// A permission prompt's banner (Allow, Deny).
    pub approval: bool,
    /// Its prompt offers Always Allow.
    pub always_allow: bool,
    /// It has a Reply field.
    pub reply: bool,
    /// Its tab is in an incognito window.
    pub incognito: bool,
    /// The poster's own category, which wins.
    pub category: Option<String>,
}

/// What the banner shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BannerShape {
    pub category: String,
    /// It carries the prompt's answers: never in an incognito window.
    pub approval: bool,
    /// It names nothing of its window: the app's incognito title and body, no
    /// subtitle, no attachment.
    pub redacted: bool,
}

/// The category and redaction of a banner.
pub fn banner(ask: &BannerAsk) -> BannerShape {
    let approval = ask.approval && !ask.incognito;
    let fallback = if approval {
        if ask.always_allow { APPROVAL_ALWAYS_CATEGORY } else { APPROVAL_CATEGORY }
    } else if ask.reply {
        REPLY_CATEGORY
    } else {
        DEFAULT_CATEGORY
    };
    BannerShape {
        category: ask.category.clone().unwrap_or_else(|| fallback.to_owned()),
        approval,
        redacted: ask.incognito,
    }
}

/// What a click on a banner's action does (any number of these; usually one).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Response {
    /// Opens the banner's tab: the banner itself, Open, Show, or the iPhone
    /// pairing banner's Review.
    pub open: bool,
    /// Sends the typed text to the terminal.
    pub reply: bool,
    /// Answers the permission prompt once: true allows, false denies.
    pub approve: Option<bool>,
    /// Allows it always.
    pub always: bool,
    pub mark_read: bool,
}

/// What `action` does; `system_default`: it is the system's default action
/// (a click on the banner itself).
pub fn response(action: &str, system_default: bool) -> Response {
    Response {
        open: system_default
            || [IPHONE_PAIR_REVIEW_ACTION, OPEN_ACTION, SHOW_ACTION].contains(&action),
        reply: action == REPLY_ACTION,
        approve: match action {
            ALLOW_ACTION => Some(true),
            DENY_ACTION => Some(false),
            _ => None,
        },
        always: action == ALWAYS_ACTION,
        mark_read: action == MARK_READ_ACTION,
    }
}

#[cfg(test)]
#[path = "desktop_center_tests.rs"]
mod tests;
