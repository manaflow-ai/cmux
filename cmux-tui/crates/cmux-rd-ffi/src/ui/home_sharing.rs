//! Allow Mac Screen on This Mac (`CmuxNextMacScreen/MacScreenHomeView+Sharing.swift`), as data. See
//! `ui/mod.rs`. Texts are `card.rs`'s `Text` (`$viewerName` is the connected device's name).
//!
//! - `homeSharing.status` `{session?: {connected, scope: "view"|"full", viewerName}, screenRecordingGranted,
//!   accessibilityGranted, isSharing, busy}` → [`Status`]: the status line and dot, the simple look's switch
//!   detail, the connected row, the Grant Access row, the permissions row's button, the status look's title.
//! - `homeSharing.sessionText` `{session?}` → Text (`MacScreenHomeView.sessionText`).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::card::{Text, key, keyed};
use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, a: &Value) -> Answer {
    Some(match name {
        "status" => args::<Sharing>(a).and_then(|s| answer(&status(&s))),
        "sessionText" => args::<Sharing>(a).and_then(|s| answer(&session_text(s.session.as_ref()))),
        _ => return None,
    })
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Session {
    pub connected: bool,
    pub scope: String,
}

/// `MacScreenHomeSnapshot.Sharing`'s inputs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Sharing {
    pub session: Option<Session>,
    pub screen_recording_granted: bool,
    pub accessibility_granted: bool,
    pub is_sharing: bool,
    pub busy: bool,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Connected {
    pub text: Text,
    /// The dot: lit once connected, attention while connecting.
    pub ink: &'static str,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Grant {
    pub title: Text,
    pub detail: Text,
    /// What Grant Access asks macOS for first: `"screenRecording"` or `"accessibility"`.
    pub request: &'static str,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Status {
    pub status_text: Text,
    pub status_ink: &'static str,
    /// The simple look's switch detail.
    pub simple_detail: Text,
    /// Who is connected (a row while sharing with a session).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connected: Option<Connected>,
    /// The one Grant Access step while sharing and a permission is missing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grant: Option<Grant>,
    /// The permissions row's Open System Settings target, or null when both are allowed ("Allowed").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub open_settings: Option<&'static str>,
    /// The status look's switch title.
    pub status_title: Text,
    pub switch_enabled: bool,
}

/// Who is connected, else that the devices can connect.
pub(crate) fn session_text(session: Option<&Session>) -> Text {
    match session {
        None => key("macScreen.home.hubReady"),
        Some(s) if !s.connected => keyed("macScreen.home.hubConnecting", &["$viewerName"]),
        Some(s) if s.scope == "view" => keyed("macScreen.indicator.viewing", &["$viewerName"]),
        Some(_) => keyed("macScreen.indicator.controlling", &["$viewerName"]),
    }
}

/// The status line: who is connected, else what the permissions let a device do. Without Screen
/// Recording no device can see this Mac; without Accessibility a device can only watch.
fn status_text(s: &Sharing) -> Text {
    if s.session.is_some() {
        session_text(s.session.as_ref())
    } else if !s.screen_recording_granted {
        key("macScreen.home.hubNeedsScreenRecording")
    } else if !s.accessibility_granted {
        key("macScreen.home.hubViewOnly")
    } else {
        session_text(None)
    }
}

fn status_ink(s: &Sharing) -> &'static str {
    match &s.session {
        Some(session) if session.connected => "litGlyph",
        None if !s.screen_recording_granted => "attention",
        _ => "success",
    }
}

fn connected(session: &Session) -> Connected {
    let text = if !session.connected {
        keyed("macScreen.home.hubConnecting", &["$viewerName"])
    } else if session.scope == "view" {
        keyed("macScreen.home.connectedViewing", &["$viewerName"])
    } else {
        keyed("macScreen.home.connectedControlling", &["$viewerName"])
    };
    Connected { text, ink: if session.connected { "litGlyph" } else { "attention" } }
}

fn grant(s: &Sharing) -> Option<Grant> {
    if s.screen_recording_granted && s.accessibility_granted {
        return None;
    }
    let screen_recording = !s.screen_recording_granted;
    let title = if screen_recording && !s.accessibility_granted {
        key("macScreen.home.grantBoth")
    } else if screen_recording {
        key("macScreen.home.screenRecording")
    } else {
        key("macScreen.home.accessibility")
    };
    let detail = if screen_recording {
        key("macScreen.home.grantDetail")
    } else {
        key("macScreen.home.grantAccessibilityDetail")
    };
    Some(Grant {
        title,
        detail,
        request: if screen_recording { "screenRecording" } else { "accessibility" },
    })
}

pub(crate) fn status(s: &Sharing) -> Status {
    let simple_detail = if !s.is_sharing {
        key("macScreen.home.shareThisMacOff")
    } else if s.session.is_some() {
        key("macScreen.home.shareThisMacOn")
    } else {
        status_text(s)
    };
    let open_settings = if s.screen_recording_granted && s.accessibility_granted {
        None
    } else if !s.screen_recording_granted {
        Some("screenRecording")
    } else {
        Some("accessibility")
    };
    Status {
        status_text: status_text(s),
        status_ink: status_ink(s),
        simple_detail,
        connected: s.session.as_ref().filter(|_| s.is_sharing).map(connected),
        grant: if s.is_sharing { grant(s) } else { None },
        open_settings,
        status_title: if s.is_sharing {
            status_text(s)
        } else {
            key("macScreen.home.allowToggleShort")
        },
        switch_enabled: !s.busy,
    }
}

#[cfg(test)]
#[path = "home_sharing_tests.rs"]
mod tests;
