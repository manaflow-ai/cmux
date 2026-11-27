//! Screen Sharing's viewer looks (`CmuxNextMacScreen/MacScreenViewerLook*.swift`), as data. See `ui/mod.rs`.
//! Cards come as `card.rs`'s [`Card`]; texts and buttons as its `Text` and `Button`.
//!
//! - `viewerLook.style` `{look: "current"|"a"|"b"|"c"}` → [`Style`] (design tokens such as `space4` as
//!   strings, which Swift reads from `Metrics`; the toolbar and card surfaces stay Swift).
//! - `viewerLook.isQuietOutage` `{look, isLive, hasFrame, card?}` → bool.
//! - `viewerLook.outageOverPicture` `{isLive, hasFrame, stalled}` → bool.
//! - `viewerLook.toolbarPinned` `{look, isLive, hasCard, outage, pointerAtTop}` → bool (look A's auto-hide).
//! - `viewerLook.pictureMark` `{look, isLive, hasFrame, outage, outageMarkDue, hasCard, viewOnly,
//!   capturesKeyboard}` → `"none"|"reconnecting"|"viewOnly"|"controlling"`.
//! - `viewerLook.strip` `{card, hasFailedDetail, platform?}` → look B's strip state `{title, ink, mark:
//!   {loading}|{glyph, ink}, caption?, actions: [Button], signIn}` (`MacScreenStripState.make`).
//! - `viewerLook.fullPane` `{card, platform?, linkConnected, hasFailedDetail, cause?: {kind: "host", reason}|
//!   {kind: "link"}|{kind: "other"}, timedOut}` → look C's state `{symbol, ink, headline, why?, steps, activeStep,
//!   details?, secondary: [Button], primary?, signInPrimary}` (`makeSpec`).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::card::{
    Button, Card, Text, ask_again, close_tab, connect_again, key, keyed, open_home, reconnect,
    refused_body, refused_title, retry_connect, retry_request, scope_buttons, token, view_instead,
};
use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, a: &Value) -> Answer {
    Some(match name {
        "style" => args::<LookArgs>(a).and_then(|l| answer(&style(&l.look))),
        "isQuietOutage" => args::<StateArgs>(a).and_then(|s| answer(&is_quiet_outage(&s))),
        "outageOverPicture" => {
            args::<StateArgs>(a).and_then(|s| answer(&(s.is_live && s.has_frame && s.stalled)))
        }
        "toolbarPinned" => args::<StateArgs>(a).and_then(|s| answer(&toolbar_pinned(&s))),
        "pictureMark" => args::<StateArgs>(a).and_then(|s| answer(&picture_mark(&s))),
        "strip" => args::<StripArgs>(a).and_then(|s| answer(&strip(&s))),
        "fullPane" => args::<FullPaneArgs>(a).and_then(|f| answer(&full_pane(&f))),
        _ => return None,
    })
}

// MARK: Style

/// `MacScreenViewerStyle`: what a look changes about the viewer.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Style {
    pub toolbar_placement: &'static str,
    pub toolbar_filled: bool,
    /// Points; look A's capsule is half its row.
    pub toolbar_corner_radius: f64,
    /// A `Metrics` token (`"space4"`), or `"0"`.
    pub toolbar_inset: &'static str,
    pub backdrop: &'static str,
    pub picture_corner_radius: f64,
    pub picture_shadow: bool,
    /// A `Metrics` token (`"surfaceCornerRadius"`), a number of points, or null for the stock corner.
    pub card_corner_radius: Option<&'static str>,
    pub card_fill: &'static str,
    pub card_bordered: bool,
    pub status_strip: bool,
    pub toolbar_layout: &'static str,
    pub card_layout: &'static str,
    pub card_width: Option<f64>,
    pub card_veil_opacity: f64,
    pub quiet_outage: bool,
    pub toolbar_row_height: Option<f64>,
    pub toolbar_scope_segments: bool,
    pub toolbar_auto_hide: bool,
    pub picture_marks: bool,
    pub outage_keeps_picture: bool,
    pub card_quiet_transient: bool,
}

impl Default for Style {
    fn default() -> Self {
        Style {
            toolbar_placement: "topBar",
            toolbar_filled: true,
            toolbar_corner_radius: 0.0,
            toolbar_inset: "0",
            backdrop: "black",
            picture_corner_radius: 0.0,
            picture_shadow: false,
            card_corner_radius: None,
            card_fill: "popup",
            card_bordered: true,
            status_strip: false,
            toolbar_layout: "bar",
            card_layout: "standard",
            card_width: None,
            card_veil_opacity: 0.0,
            quiet_outage: false,
            toolbar_row_height: None,
            toolbar_scope_segments: false,
            toolbar_auto_hide: false,
            picture_marks: false,
            outage_keeps_picture: false,
            card_quiet_transient: false,
        }
    }
}

/// Look A's floating toolbar row (`MacScreenLookA.toolbarHeight`).
pub(crate) const LOOK_A_TOOLBAR_HEIGHT: f64 = 28.0;

/// The style of `look`; an unknown look is the current one.
pub(crate) fn style(look: &str) -> Style {
    let base = Style::default();
    match look {
        // Quiet glass, picture first.
        "a" => Style {
            toolbar_placement: "floating",
            toolbar_inset: "space4",
            toolbar_filled: false,
            toolbar_row_height: Some(LOOK_A_TOOLBAR_HEIGHT),
            toolbar_corner_radius: LOOK_A_TOOLBAR_HEIGHT / 2.0,
            toolbar_scope_segments: true,
            toolbar_auto_hide: true,
            backdrop: "page",
            picture_marks: true,
            outage_keeps_picture: true,
            card_quiet_transient: true,
            card_corner_radius: Some("surfaceCornerRadius"),
            ..base
        },
        "b" => Style { toolbar_placement: "topBar", status_strip: true, backdrop: "page", ..base },
        // Floating pill, full-pane states.
        "c" => Style {
            toolbar_placement: "floating",
            toolbar_layout: "pill",
            toolbar_filled: false,
            toolbar_inset: "space5",
            backdrop: "chrome",
            card_layout: "fullPane",
            card_fill: "page",
            card_bordered: false,
            card_corner_radius: Some("0"),
            card_width: Some(440.0),
            card_veil_opacity: 0.7,
            quiet_outage: true,
            ..base
        },
        _ => base,
    }
}

#[derive(Deserialize)]
struct LookArgs {
    #[serde(default)]
    look: String,
}

// MARK: Live state

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct StateArgs {
    pub look: String,
    pub is_live: bool,
    pub has_frame: bool,
    pub card: Option<Card>,
    pub has_card: bool,
    pub stalled: bool,
    pub outage: bool,
    pub outage_mark_due: bool,
    pub pointer_at_top: bool,
    pub view_only: bool,
    pub captures_keyboard: bool,
}

impl StateArgs {
    fn has_card(&self) -> bool {
        self.has_card || self.card.is_some()
    }
}

/// A reconnect over a live picture the look keeps quiet (no card over the picture).
pub(crate) fn is_quiet_outage(s: &StateArgs) -> bool {
    style(&s.look).quiet_outage
        && s.is_live
        && s.has_frame
        && s.card.as_ref().is_some_and(|c| c.kind == "connecting" && c.reconnecting)
}

/// Look A's toolbar stays shown when it does not auto-hide, off a live session, over a card (not an
/// outage over the picture), or while the pointer is at the top.
pub(crate) fn toolbar_pinned(s: &StateArgs) -> bool {
    !style(&s.look).toolbar_auto_hide
        || !s.is_live
        || (s.has_card() && !s.outage)
        || s.pointer_at_top
}

/// Look A's mark in the picture's corner (`nextMark`).
pub(crate) fn picture_mark(s: &StateArgs) -> &'static str {
    if !style(&s.look).picture_marks || !s.is_live || !s.has_frame {
        return "none";
    }
    if s.outage {
        return if s.outage_mark_due { "reconnecting" } else { "none" };
    }
    if s.has_card() {
        "none"
    } else if s.view_only {
        "viewOnly"
    } else if s.captures_keyboard {
        "controlling"
    } else {
        "none"
    }
}

// MARK: Look B's strip

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct StripArgs {
    pub card: Card,
    pub has_failed_detail: bool,
    pub platform: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Mark {
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub loading: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub glyph: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ink: Option<&'static str>,
}

fn loading() -> Mark {
    Mark { loading: true, glyph: None, ink: None }
}

fn glyph(name: &'static str, ink: &'static str) -> Mark {
    Mark { loading: false, glyph: Some(name), ink: Some(ink) }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Strip {
    pub title: Text,
    /// The title's ink: danger only for a failure or lost access, attention while someone must act.
    pub ink: &'static str,
    pub mark: Mark,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caption: Option<Text>,
    pub actions: Vec<Button>,
    pub sign_in: bool,
}

fn strip_state(
    title: Text,
    ink: &'static str,
    mark: Mark,
    caption: Option<Text>,
    actions: Vec<Button>,
) -> Strip {
    Strip { title, ink, mark, caption, actions, sign_in: false }
}

/// The strip's state for a card, in the card's words.
pub(crate) fn strip(s: &StripArgs) -> Strip {
    let card = &s.card;
    let close = close_tab(true);
    let cancel = super::card::cancel("disconnect", None);
    let hub_cancel = super::card::cancel("cancelRequest", Some("macScreen.hub.cancel"));
    let scope = card.scope.as_deref().unwrap_or("view");
    match card.kind.as_str() {
        "unsupported" => strip_state(
            key("macScreen.card.linksGoneTitle"),
            "attention",
            glyph("link.badge.plus", "attention"),
            Some(key("macScreen.card.linksGoneBody")),
            vec![close, open_home()],
        ),
        "connecting" => strip_state(
            if card.reconnecting {
                key("macScreen.card.reconnecting")
            } else {
                keyed("macScreen.card.connecting", &["$name"])
            },
            "secondary",
            loading(),
            None,
            vec![cancel],
        ),
        "waitingForPicture" => {
            strip_state(key("macScreen.card.waiting"), "secondary", loading(), None, vec![cancel])
        }
        "failed" => strip_state(
            key("macScreen.card.failedTitle"),
            "danger",
            glyph("exclamationmark.triangle", "attention"),
            Some(token("$failedDetail")),
            vec![close, retry_connect()],
        ),
        "ended" => strip_state(
            key("macScreen.card.endedTitle"),
            "secondary",
            glyph("display", "secondary"),
            None,
            vec![close, reconnect()],
        ),
        "hubConnect" => strip_state(
            keyed("macScreen.hub.connectTitle", &["$name"]),
            "secondary",
            glyph("desktopcomputer", "secondary"),
            Some(key("macScreen.hub.connectBody")),
            scope_buttons().to_vec(),
        ),
        "hubRequesting" => strip_state(
            keyed("macScreen.hub.requesting", &["$name"]),
            "secondary",
            loading(),
            Some(token("$scopeTitle")),
            vec![hub_cancel],
        ),
        "hubWaiting" => strip_state(
            keyed("macScreen.hub.waitingTitle", &["$name"]),
            "attention",
            loading(),
            Some(keyed("macScreen.hub.waitingOwnerBody", &["$scopeTitle"])),
            vec![hub_cancel],
        ),
        "hubDeclined" => strip_state(
            key("macScreen.hub.declinedTitle"),
            "attention",
            glyph("hand.raised", "attention"),
            Some(keyed("macScreen.hub.declinedBody", &["$name"])),
            vec![close, ask_again(scope)],
        ),
        "hubRefused" => strip_refused(s, close),
        "hubRevoked" | "hubEnded" => {
            let removed = card.end.removes_access;
            let mut actions = vec![close];
            if card.end.can_reconnect && card.kind == "hubRevoked" {
                actions.push(connect_again());
            } else if card.end.can_reconnect {
                actions.push(reconnect());
            }
            let ink = if removed { "danger" } else { "secondary" };
            strip_state(
                if removed {
                    key("macScreen.hub.revokedTitle")
                } else {
                    key("macScreen.card.endedTitle")
                },
                ink,
                glyph(if removed { "lock" } else { "display" }, ink),
                Some(token(if s.has_failed_detail { "$failedDetail" } else { "$endText" })),
                actions,
            )
        }
        "hubAccessLowered" => strip_state(
            key("macScreen.hub.loweredTitle"),
            "attention",
            glyph("eye", "attention"),
            Some(keyed("macScreen.hub.loweredBody", &["$name"])),
            vec![close, view_instead()],
        ),
        _ => strip_state(Text::default(), "secondary", loading(), None, vec![]),
    }
}

fn strip_refused(s: &StripArgs, close: Button) -> Strip {
    let card = &s.card;
    let refusal = card.refusal();
    match refusal {
        "permissionNone" => strip_state(
            key("macScreen.hub.noneTitle"),
            "danger",
            glyph("nosign", "danger"),
            Some(keyed("macScreen.hub.noneBodyBlocked", &["$name", "$name"])),
            vec![close],
        ),
        "scopeExceeds" => strip_state(
            key("macScreen.hub.viewOnlyTitle"),
            "attention",
            glyph("eye", "attention"),
            Some(keyed("macScreen.hub.viewOnlyBody", &["$name"])),
            vec![close, view_instead()],
        ),
        _ => {
            let mut actions = vec![close];
            let signed_out = refusal == "notSignedIn";
            if signed_out || refusal != "notFound" {
                // Not signed in: Try Again stays plain, the body offers the shared Sign In button.
                actions
                    .push(retry_request(card.requested.as_deref().unwrap_or("view"), !signed_out));
            }
            Strip {
                title: refused_title(refusal),
                ink: "attention",
                mark: glyph(
                    if refusal == "hostOffline" {
                        "wifi.slash"
                    } else {
                        "exclamationmark.triangle"
                    },
                    "attention",
                ),
                caption: Some(refused_body(card, s.platform.as_deref())),
                actions,
                sign_in: signed_out,
            }
        }
    }
}

// MARK: Look C's full-pane states

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Cause {
    pub kind: String,
    pub reason: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct FullPaneArgs {
    pub card: Card,
    pub platform: Option<String>,
    pub link_connected: bool,
    pub has_failed_detail: bool,
    pub cause: Option<Cause>,
    /// The session timed out at a stage (`timedOutStage`), which has its own detail.
    pub timed_out: bool,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FullPane {
    pub symbol: &'static str,
    pub ink: &'static str,
    pub headline: Text,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub why: Option<Text>,
    /// The connect steps in order (keys with `$name`), and the one under way.
    pub steps: Vec<Text>,
    pub active_step: usize,
    /// Faint words below; `$failedDetail` is dropped when it equals the why.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Text>,
    pub secondary: Vec<Button>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary: Option<Button>,
    /// The primary is the shared Sign In button.
    pub sign_in_primary: bool,
}

fn hub_steps() -> Vec<Text> {
    vec![
        keyed("macScreen.full.stepAsking", &["$name"]),
        keyed("macScreen.full.stepWaiting", &["$name"]),
        keyed("macScreen.full.stepReaching", &["$name"]),
        key("macScreen.full.stepPicture"),
    ]
}

fn session_steps() -> Vec<Text> {
    vec![
        keyed("macScreen.full.stepAsking", &["$name"]),
        keyed("macScreen.full.stepReaching", &["$name"]),
        key("macScreen.full.stepPicture"),
    ]
}

/// Look C's state for a card: a symbol, a headline, why, the connect steps and the buttons.
pub(crate) fn full_pane(f: &FullPaneArgs) -> FullPane {
    let card = &f.card;
    // A laptop or a desktop for a Mac, a display for anything else.
    let symbol = if f.platform.as_deref() == Some("linux") { "display" } else { "desktopcomputer" };
    let scope = card.scope.as_deref().unwrap_or("view");
    let hub_cancel = super::card::cancel("cancelRequest", Some("macScreen.hub.cancel"));
    let base = FullPane { symbol, ink: "secondary", ..FullPane::default() };
    let connecting = keyed("macScreen.full.connectingTitle", &["$name"]);
    match card.kind.as_str() {
        "unsupported" => FullPane {
            symbol: "link.badge.plus",
            ink: "attention",
            headline: key("macScreen.card.linksGoneTitle"),
            why: Some(key("macScreen.card.linksGoneBody")),
            secondary: vec![close_tab(true)],
            primary: Some(open_home()),
            ..base
        },
        "connecting" => FullPane {
            headline: keyed(
                if card.reconnecting {
                    "macScreen.full.reconnectingTitle"
                } else {
                    "macScreen.full.connectingTitle"
                },
                &["$name"],
            ),
            steps: session_steps(),
            active_step: if f.link_connected { 2 } else { 1 },
            secondary: vec![super::card::cancel("disconnect", None)],
            ..base
        },
        "waitingForPicture" => FullPane {
            headline: connecting,
            steps: session_steps(),
            active_step: 2,
            secondary: vec![super::card::cancel("disconnect", None)],
            ..base
        },
        "failed" => failed(f, base),
        "ended" => FullPane {
            headline: keyed("macScreen.full.endedTitle", &["$name"]),
            secondary: vec![close_tab(false)],
            primary: Some(reconnect()),
            ..base
        },
        "hubConnect" => {
            let [view, full] = scope_buttons();
            FullPane {
                headline: keyed("macScreen.hub.connectTitle", &["$name"]),
                why: Some(key("macScreen.hub.connectBody")),
                secondary: vec![view],
                primary: Some(full),
                ..base
            }
        }
        "hubRequesting" => FullPane {
            headline: connecting,
            why: Some(token("$scopeTitle")),
            steps: hub_steps(),
            active_step: 0,
            secondary: vec![hub_cancel],
            ..base
        },
        "hubWaiting" => FullPane {
            headline: connecting,
            why: Some(keyed("macScreen.hub.waitingOwnerBody", &["$scopeTitle"])),
            steps: hub_steps(),
            active_step: 1,
            secondary: vec![hub_cancel],
            ..base
        },
        "hubDeclined" => FullPane {
            symbol: "hand.raised",
            ink: "attention",
            headline: key("macScreen.hub.declinedTitle"),
            why: Some(keyed("macScreen.hub.declinedBody", &["$name"])),
            secondary: vec![close_tab(false)],
            primary: Some(ask_again(scope)),
            ..base
        },
        "hubRefused" => refused(f, base),
        "hubRevoked" | "hubEnded" => {
            let removed = card.end.removes_access;
            let again = if card.kind == "hubRevoked" { connect_again() } else { reconnect() };
            FullPane {
                symbol: if removed { "lock" } else { symbol },
                ink: if removed { "danger" } else { "secondary" },
                headline: if removed {
                    key("macScreen.hub.revokedTitle")
                } else {
                    keyed("macScreen.full.endedTitle", &["$name"])
                },
                why: Some(token(if f.has_failed_detail { "$failedDetail" } else { "$endText" })),
                secondary: vec![close_tab(false)],
                primary: card.end.can_reconnect.then_some(again),
                ..base
            }
        }
        "hubAccessLowered" => FullPane {
            symbol: "eye",
            ink: "attention",
            headline: key("macScreen.hub.loweredTitle"),
            why: Some(keyed("macScreen.hub.loweredBody", &["$name"])),
            secondary: vec![close_tab(false)],
            primary: Some(view_instead()),
            ..base
        },
        _ => base,
    }
}

/// A failed session, said as what happened: asleep, locked, no picture, or an error with its details.
fn failed(f: &FullPaneArgs, base: FullPane) -> FullPane {
    let base =
        FullPane { secondary: vec![close_tab(false)], primary: Some(retry_connect()), ..base };
    let detail = Some(token("$failedDetail"));
    // The host gives a reason as words only (no code): sleep and lock are read from them.
    if let Some(Cause { reason: Some(reason), .. }) = f.cause.as_ref().filter(|c| c.kind == "host")
    {
        let lowered = reason.to_lowercase();
        if lowered.contains("sleep") {
            return FullPane {
                symbol: "moon.zzz",
                headline: keyed("macScreen.full.asleepTitle", &["$name"]),
                why: Some(key("macScreen.full.asleepBody")),
                details: detail,
                ..base
            };
        }
        if lowered.contains("lock") {
            return FullPane {
                symbol: "lock",
                headline: keyed("macScreen.full.lockedTitle", &["$name"]),
                why: Some(key("macScreen.full.lockedBody")),
                details: detail,
                ..base
            };
        }
    }
    if f.cause.is_none() && !f.timed_out && f.link_connected {
        return FullPane {
            symbol: "display",
            headline: keyed("macScreen.full.noPictureTitle", &["$name"]),
            why: Some(key("macScreen.full.noPictureBody")),
            ..base
        };
    }
    // The why is one plain line; a link failure's own words (which can be long) go faint below it.
    let link = f.cause.as_ref().is_some_and(|c| c.kind == "link");
    let (why, details) = if link {
        let why = if f.timed_out {
            token("$timeoutDetail")
        } else {
            keyed("macScreen.card.failedHub", &["$name"])
        };
        (why, detail)
    } else {
        (token("$failedDetail"), None)
    };
    FullPane {
        symbol: "exclamationmark.triangle",
        ink: "attention",
        headline: keyed("macScreen.full.errorTitle", &["$name"]),
        why: Some(why),
        details,
        ..base
    }
}

fn refused(f: &FullPaneArgs, base: FullPane) -> FullPane {
    let card = &f.card;
    let refusal = card.refusal();
    let requested = card.requested.as_deref().unwrap_or("view");
    match refusal {
        "permissionNone" => FullPane {
            symbol: "nosign",
            ink: "danger",
            headline: key("macScreen.hub.noneTitle"),
            why: Some(keyed("macScreen.hub.noneBodyBlocked", &["$name", "$name"])),
            primary: Some(close_tab(false)),
            ..base
        },
        "scopeExceeds" => FullPane {
            symbol: "eye",
            ink: "attention",
            headline: key("macScreen.hub.viewOnlyTitle"),
            why: Some(keyed("macScreen.hub.viewOnlyBody", &["$name"])),
            secondary: vec![close_tab(false)],
            primary: Some(view_instead()),
            ..base
        },
        _ => {
            let mut spec = FullPane {
                symbol: if refusal == "hostOffline" {
                    "wifi.slash"
                } else {
                    "exclamationmark.triangle"
                },
                ink: "attention",
                headline: refused_title(refusal),
                why: Some(refused_body(card, f.platform.as_deref())),
                secondary: vec![close_tab(false)],
                ..base
            };
            if refusal == "notSignedIn" {
                spec.secondary.push(retry_request(requested, false));
                spec.sign_in_primary = true;
            } else if refusal != "notFound" {
                spec.primary = Some(retry_request(requested, true));
            }
            spec
        }
    }
}

#[cfg(test)]
#[path = "viewer_look_tests.rs"]
mod tests;
