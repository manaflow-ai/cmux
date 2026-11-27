//! A Screen Sharing tab's card (`CmuxNextMacScreen/MacScreenCardView.swift`), as data. See `ui/mod.rs`.
//! Rust picks the keys, buttons and which line prints; Swift localizes and draws them.
//!
//! A card arrives as [`Card`] (`MacScreenCard`):
//! `{kind, reconnecting?, scope?, refusal?, otherReason?, requested?, end?: {removesAccess, canReconnect, failed}}`,
//! `kind` one of `unsupported connecting waitingForPicture failed ended hubConnect hubRequesting hubWaiting
//! hubDeclined hubRefused hubRevoked hubAccessLowered hubEnded`; `refusal` one of `permissionNone scopeExceeds
//! hostOffline notShared notFound notSignedIn other`.
//!
//! A [`Text`] is `{key?, args: [token], token?}`: a key Swift localizes and formats with the args, or one
//! token as is. Tokens are values only Swift has: `$name` (the host), `$scopeTitle` (the card's scope),
//! `$failedDetail`, `$endText` (`EndReason.text(host:)`), `$otherReason`, `$timeoutDetail`.
//! A [`Button`] is `{title: key, run, scope?, primary, returnKey, id?}`, `run` one of `closeTab openHome
//! disconnect cancelRequest connect request`.
//!
//! - `card.content` `{card, quiet, hasFailedDetail, showsStart, platform?, retriesOnItsOwn}` → `{spinner, title, line?: {text,
//!   printed}, start, rows: [[Button]], signIn}` (`content`, `hubContent`, `refusedContent`).
//! - `card.refusedTitle` `{refusal}` / `card.refusedBody` `{refusal, otherReason?, platform?}` → Text.
//! - `card.failedDetailSource` `{card}` → `"failed"|"hub"|null` (`failedDetail`: the model's, the hub's, none).
//! - `card.isTransient` `{card}`, `card.quiet` `{card, look}` → bool.
//! - `card.setupApplies` `{card}` → bool (Start cmux only on a hub tab whose Mac is offline).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, a: &Value) -> Answer {
    Some(match name {
        "content" => args::<ContentArgs>(a).and_then(|c| answer(&content(&c))),
        "refusedTitle" => {
            args::<CardArgs>(a).and_then(|c| answer(&refused_title(c.card.refusal())))
        }
        "refusedBody" => args::<RefusedArgs>(a).and_then(|r| {
            let card =
                Card { refusal: Some(r.refusal), other_reason: r.other_reason, ..Card::default() };
            answer(&refused_body(&card, r.platform.as_deref()))
        }),
        "failedDetailSource" => {
            args::<CardArgs>(a).and_then(|c| answer(&failed_detail_source(&c.card)))
        }
        "isTransient" => args::<CardArgs>(a).and_then(|c| answer(&c.card.is_transient())),
        "quiet" => args::<QuietArgs>(a).and_then(|q| {
            answer(
                &(super::viewer_look::style(&q.look).card_quiet_transient && q.card.is_transient()),
            )
        }),
        "setupApplies" => args::<CardArgs>(a).and_then(|c| {
            answer(&(c.card.kind == "hubRefused" && c.card.refusal() == "hostOffline"))
        }),
        _ => return None,
    })
}

// MARK: Card

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct EndReason {
    pub removes_access: bool,
    pub can_reconnect: bool,
    /// `.failed`: the stream failed (the hub's failure detail may say why).
    pub failed: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Card {
    pub kind: String,
    pub reconnecting: bool,
    pub scope: Option<String>,
    pub refusal: Option<String>,
    pub other_reason: Option<String>,
    pub requested: Option<String>,
    pub end: EndReason,
}

impl Card {
    pub fn refusal(&self) -> &str {
        self.refusal.as_deref().unwrap_or("other")
    }

    fn requested(&self) -> &str {
        self.requested.as_deref().unwrap_or("view")
    }

    /// `MacScreenRefusal.canRetry`: every refusal but a removed device.
    fn can_retry(&self) -> bool {
        self.refusal() != "notFound"
    }

    /// A card that says the session is still on its way (a look may draw these quietly).
    pub fn is_transient(&self) -> bool {
        matches!(
            self.kind.as_str(),
            "connecting" | "waitingForPicture" | "hubRequesting" | "hubWaiting"
        )
    }
}

// MARK: Text and buttons

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub(crate) struct Text {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<&'static str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<&'static str>,
}

pub(crate) fn key(key: &'static str) -> Text {
    Text { key: Some(key), ..Text::default() }
}

pub(crate) fn keyed(key: &'static str, args: &[&'static str]) -> Text {
    Text { key: Some(key), args: args.to_vec(), token: None }
}

pub(crate) fn token(token: &'static str) -> Text {
    Text { token: Some(token), ..Text::default() }
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Button {
    pub title: &'static str,
    pub run: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    pub primary: bool,
    pub return_key: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<&'static str>,
}

pub(crate) fn close_tab(id: bool) -> Button {
    Button {
        title: "macScreen.card.closeTab",
        run: "closeTab",
        id: id.then_some("macScreen.card.closeTab"),
        ..Button::default()
    }
}

pub(crate) fn cancel(run: &'static str, id: Option<&'static str>) -> Button {
    Button { title: "macScreen.card.cancel", run, id, ..Button::default() }
}

pub(crate) fn open_home() -> Button {
    Button { title: "macScreen.card.openHome", run: "openHome", primary: true, ..Button::default() }
}

pub(crate) fn retry_connect() -> Button {
    Button {
        title: "macScreen.card.retry",
        run: "connect",
        primary: true,
        return_key: true,
        id: Some("macScreen.card.retry"),
        ..Button::default()
    }
}

pub(crate) fn reconnect() -> Button {
    Button {
        title: "macScreen.card.reconnect",
        run: "connect",
        primary: true,
        return_key: true,
        id: Some("macScreen.card.reconnect"),
        ..Button::default()
    }
}

pub(crate) fn connect_again() -> Button {
    Button {
        title: "macScreen.hub.connectAgain",
        run: "connect",
        primary: true,
        id: Some("macScreen.hub.connectAgain"),
        ..Button::default()
    }
}

pub(crate) fn request(title: &'static str, scope: &str, primary: bool, id: &'static str) -> Button {
    Button {
        title,
        run: "request",
        scope: Some(scope.to_string()),
        primary,
        id: Some(id),
        ..Button::default()
    }
}

pub(crate) fn view_instead() -> Button {
    request("macScreen.hub.viewInstead", "view", true, "macScreen.hub.viewInstead")
}

pub(crate) fn ask_again(scope: &str) -> Button {
    request("macScreen.hub.askAgain", scope, true, "macScreen.hub.askAgain")
}

pub(crate) fn retry_request(scope: &str, primary: bool) -> Button {
    request("macScreen.card.retry", scope, primary, "macScreen.card.retry")
}

/// Connect's two buttons: View Only, then Full Control (the default, Return).
pub(crate) fn scope_buttons() -> [Button; 2] {
    let view = request("macScreen.hub.view", "view", false, "macScreen.hub.connectView");
    let mut full = request("macScreen.hub.control", "full", true, "macScreen.hub.connectFull");
    full.return_key = true;
    [view, full]
}

// MARK: Refusals

/// The refused card's title (`refusedTitle(_:host:)`).
pub(crate) fn refused_title(refusal: &str) -> Text {
    match refusal {
        "hostOffline" => keyed("macScreen.hub.offlineTitle", &["$name"]),
        "notShared" => key("macScreen.hub.notSharedTitle"),
        "notFound" => key("macScreen.hub.notFoundTitle"),
        "notSignedIn" => key("macScreen.hub.signedOutTitle"),
        _ => key("macScreen.card.failedTitle"),
    }
}

/// The refused card's text (`refusedBody(_:host:platform:)`): a known code's own step, else the hub's
/// words when it gave any. A Linux host's not-shared step names its screen host.
pub(crate) fn refused_body(card: &Card, platform: Option<&str>) -> Text {
    match card.refusal() {
        "hostOffline" => key("macScreen.hub.offlineBodyWaits"),
        "notShared" if platform == Some("linux") => {
            keyed("macScreen.hub.notSharedBodyLinux", &["$name"])
        }
        "notShared" => keyed("macScreen.hub.notSharedBodyNamed", &["$name"]),
        "notFound" => key("macScreen.hub.notFoundBody"),
        "notSignedIn" => key("macScreen.hub.signedOutBody"),
        "other" if card.other_reason.is_some() => {
            keyed("macScreen.hub.otherBodyReason", &["$otherReason"])
        }
        _ => key("macScreen.hub.otherBody"),
    }
}

/// Which failure detail a card shows: the failed card's, a failed hub end's (the host's reason), or none.
pub(crate) fn failed_detail_source(card: &Card) -> Option<&'static str> {
    match card.kind.as_str() {
        "failed" => Some("failed"),
        "hubEnded" | "hubRevoked" if card.end.failed => Some("hub"),
        _ => None,
    }
}

// MARK: Content

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct ContentArgs {
    pub card: Card,
    pub quiet: bool,
    /// The shown failure detail (`failedDetail`) is not empty.
    pub has_failed_detail: bool,
    /// The offline card's Start cmux shows (`MacScreenDeviceSetupRow.showsStart`).
    pub shows_start: bool,
    pub platform: Option<String>,
    /// The pane retries this card's failure on its own (`MacScreenPaneModel.retriesOnItsOwn`), so the card offers no
    /// Try Again or Reconnect (#50358); Close Tab stays.
    pub retries_on_its_own: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub(crate) struct Line {
    pub text: Text,
    /// Printed under the title (a cause a side named); else it hangs on the info circle.
    pub printed: bool,
}

#[derive(Debug, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Content {
    pub spinner: bool,
    pub title: Text,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<Line>,
    /// Start cmux on NAME, on its own line before the buttons.
    pub start: bool,
    pub buttons: Vec<Button>,
    /// The row ends with the shared Sign In button.
    pub sign_in: bool,
}

/// The card's spinner, status line, its one explanation and buttons.
pub(crate) fn content(c: &ContentArgs) -> Content {
    let card = &c.card;
    // `detail`: an explanation on the info circle; a quiet card has none.
    let detail = |text: Text| (!c.quiet).then_some(Line { text, printed: false });
    // `reason`: a cause a side named prints; else the guess goes on the circle.
    let reason = |named: bool, guess: Option<Text>| {
        if named && !c.quiet {
            Some(Line { text: token("$failedDetail"), printed: true })
        } else {
            guess.and_then(detail)
        }
    };
    let scope = card.scope.as_deref().unwrap_or("view");
    let mut out = Content::default();
    match card.kind.as_str() {
        "unsupported" => {
            out.title = key("macScreen.card.linksGoneTitle");
            out.line = detail(key("macScreen.card.linksGoneBody"));
            out.buttons = vec![close_tab(true), open_home()];
        }
        "connecting" => {
            out.spinner = true;
            out.title = if card.reconnecting {
                key("macScreen.card.reconnecting")
            } else {
                keyed("macScreen.card.connecting", &["$name"])
            };
            out.buttons = vec![cancel("disconnect", None)];
        }
        "waitingForPicture" => {
            out.spinner = true;
            out.title = key("macScreen.card.waiting");
        }
        "failed" => {
            out.title = key("macScreen.card.failedTitle");
            out.line = reason(c.has_failed_detail, None);
            out.buttons = again_row(c, retry_connect());
        }
        "ended" => {
            out.title = key("macScreen.card.endedTitle");
            out.buttons = again_row(c, reconnect());
        }
        "hubConnect" => {
            out.title = keyed("macScreen.hub.connectTitle", &["$name"]);
            out.line = detail(key("macScreen.hub.connectBody"));
            out.buttons = scope_buttons().to_vec();
        }
        "hubRequesting" => {
            out.spinner = true;
            out.title = keyed("macScreen.hub.requesting", &["$name"]);
            out.line = detail(token("$scopeTitle"));
            out.buttons = vec![cancel("cancelRequest", Some("macScreen.hub.cancel"))];
        }
        "hubWaiting" => {
            out.spinner = true;
            out.title = keyed("macScreen.hub.waitingTitle", &["$name"]);
            out.line = detail(keyed("macScreen.hub.waitingOwnerBody", &["$scopeTitle"]));
            out.buttons = vec![cancel("cancelRequest", Some("macScreen.hub.cancel"))];
        }
        "hubDeclined" => {
            out.title = key("macScreen.hub.declinedTitle");
            out.line = detail(keyed("macScreen.hub.declinedBody", &["$name"]));
            out.buttons = vec![close_tab(false), ask_again(scope)];
        }
        "hubRefused" => refused_content(c, &mut out),
        "hubRevoked" | "hubEnded" => {
            // Ends from either side come as revocations too: only a lost permission or device reads as removed access.
            out.title = if card.end.removes_access {
                key("macScreen.hub.revokedTitle")
            } else {
                key("macScreen.card.endedTitle")
            };
            out.line = reason(c.has_failed_detail, Some(token("$endText")));
            out.buttons = vec![close_tab(false)];
            if card.end.can_reconnect && card.kind == "hubRevoked" {
                // The host revoked or changed this Mac's access; a new session is the person's choice.
                out.buttons.push(connect_again());
            } else if card.end.can_reconnect {
                out.buttons = again_row(c, reconnect());
            }
        }
        "hubAccessLowered" => {
            out.title = key("macScreen.hub.loweredTitle");
            out.line = detail(keyed("macScreen.hub.loweredBody", &["$name"]));
            out.buttons = vec![close_tab(false), view_instead()];
        }
        _ => {}
    }
    out
}

/// Close Tab, and `again` only when the pane does not retry the card on its own (`retryRow`).
fn again_row(c: &ContentArgs, again: Button) -> Vec<Button> {
    if c.retries_on_its_own { vec![close_tab(false)] } else { vec![close_tab(false), again] }
}

fn refused_content(c: &ContentArgs, out: &mut Content) {
    let card = &c.card;
    let detail = |text: Text| (!c.quiet).then_some(Line { text, printed: false });
    match card.refusal() {
        "permissionNone" => {
            out.title = key("macScreen.hub.noneTitle");
            out.line = detail(keyed("macScreen.hub.noneBodyBlocked", &["$name", "$name"]));
            out.buttons = vec![close_tab(false)];
        }
        "scopeExceeds" => {
            out.title = key("macScreen.hub.viewOnlyTitle");
            out.line = detail(keyed("macScreen.hub.viewOnlyBody", &["$name"]));
            out.buttons = vec![close_tab(false), view_instead()];
        }
        refusal => {
            out.title = refused_title(refusal);
            // The hub's own words for a refusal stay on the card; the stock explanations go on the circle.
            let body = refused_body(card, c.platform.as_deref());
            out.line = if refusal == "other" && card.other_reason.is_some() && !c.quiet {
                Some(Line { text: body, printed: true })
            } else {
                detail(body)
            };
            let offline_start = refusal == "hostOffline" && c.shows_start;
            out.start = offline_start;
            out.buttons = vec![close_tab(false)];
            if refusal == "notSignedIn" {
                // Sign In only: the pane asks again on its own once it is signed in.
                out.sign_in = true;
            } else if card.can_retry() && !c.retries_on_its_own && offline_start {
                // The host's permission is Ask, so asking again prompts the person at that Mac.
                out.buttons.push(retry_request(card.requested(), false));
            } else if card.can_retry() && !c.retries_on_its_own {
                out.buttons.push(retry_request(card.requested(), true));
            }
        }
    }
}

#[derive(Deserialize)]
struct CardArgs {
    #[serde(default)]
    card: Card,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RefusedArgs {
    refusal: String,
    #[serde(default)]
    other_reason: Option<String>,
    #[serde(default)]
    platform: Option<String>,
}

#[derive(Deserialize)]
struct QuietArgs {
    #[serde(default)]
    card: Card,
    #[serde(default)]
    look: String,
}

#[cfg(test)]
#[path = "card_tests.rs"]
mod tests;
