//! Who serves a host ticket: decided once, by the daemon, for every ticket the hub pushes to
//! this Mac's device. A Mac (cmux.rd/1) viewer is the daemon's; an iPhone (WebRTC) viewer is the
//! app's while an app is attached to the device channel, and is ended `app_required` when none
//! is. The daemon applies the gate the app applies (`JoinConsent+App.swift` `macScreenGate`):
//! with join consent on (`labs.machineJoin`), View Only needs Screen sharing and Full Control
//! needs Control too, read from acpmux's consent record (`cli/machine_consent.rs`) as
//! `_acpmux/machine_consent_get` answers it. A refusal ends the session `failed`, as the app does.

use cmux_hub_host::session::Ticket;
use serde_json::Value;

/// Who serves a ticket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Route {
    /// A session process of this daemon; whether view only.
    Daemon { view_only: bool },
    /// The app's in-app WebRTC host.
    App,
    /// Nobody: end the session with this reason.
    End(&'static str),
}

impl Route {
    /// What the relayed copy of the ticket says in `servedBy`: who acts on it.
    pub(crate) fn served_by(self) -> &'static str {
        match self {
            Self::App => "app",
            Self::Daemon { .. } | Self::End(_) => "daemon",
        }
    }
}

/// This Mac's join consent as the app's gate reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Consent {
    /// The Labs switch `labs.machineJoin`: off, everything is served as before.
    pub enabled: bool,
    /// acpmux's `consentRequired`: false on a Mac acpmux does not read as joined.
    pub required: bool,
    pub screen: bool,
    pub control: bool,
}

impl Consent {
    /// `allowsMacScreen(control:)` with the switch on; everything with it off.
    pub(crate) fn allows(self, control: bool) -> bool {
        !self.enabled || !self.required || (self.screen && (!control || self.control))
    }

    /// The consent now: the settings file's switch (a file that cannot be read keeps the gate
    /// on) and acpmux's consent record.
    pub(crate) fn read() -> Self {
        use crate::user_settings::{self, Settings};
        let enabled = match user_settings::read() {
            Settings::Parsed(doc) => {
                user_settings::value(&doc, "labs.machineJoin") == Some(Value::Bool(true))
            }
            Settings::Missing => false,
            Settings::Unreadable(_) => true,
        };
        Self::from_status(enabled, &crate::cli::cloud_join::consent_status_for(&Value::Null))
    }

    /// The consent in a `_acpmux/machine_consent_get` answer. An answer that does not say
    /// `consentRequired: false` requires it.
    pub(crate) fn from_status(enabled: bool, status: &Value) -> Self {
        let granted = |surface: &str| {
            status.get("consent").and_then(|c| c.get(surface)).and_then(Value::as_str)
                == Some("granted")
        };
        Self {
            enabled,
            required: status.get("consentRequired") != Some(&Value::Bool(false)),
            screen: granted("screen"),
            control: granted("control"),
        }
    }

    /// The surface a refusal of a `control` session asks the person for.
    pub(crate) fn missing(self) -> &'static str {
        if self.screen { "control" } else { "screen" }
    }
}

/// Who serves `ticket` from a viewer of `viewer_platform` (the hub's `platform` of its device,
/// when known), with an app attached to the device channel or not, under `consent`.
pub(crate) fn route(
    ticket: &Ticket,
    viewer_platform: Option<&str>,
    app_attached: bool,
    consent: Consent,
) -> Route {
    let control = ticket.scope == "full";
    if viewer_platform == Some("ios") {
        // The app's own gate decides an iPhone viewer it serves.
        return if app_attached { Route::App } else { Route::End("app_required") };
    }
    if !consent.allows(control) {
        return Route::End("failed");
    }
    Route::Daemon { view_only: !control }
}

/// The push as the app's device channel gets it: a host ticket says who serves it.
pub(crate) fn annotate(push: &Value, served_by: &str) -> String {
    let mut copy = push.clone();
    if let Some(fields) = copy.as_object_mut() {
        fields.insert("servedBy".into(), Value::String(served_by.to_owned()));
    }
    copy.to_string()
}
