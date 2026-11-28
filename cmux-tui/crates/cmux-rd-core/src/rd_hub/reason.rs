//! Why a session ended (`MacScreenEndReason`), the `/end` reasons this app sends
//! (`MacScreenHubReason`) and why the hub refused a request (`MacScreenHubRefusal`).

use super::Message;
use serde::{Deserialize, Serialize};

/// Foundation's `CharacterSet.newlines`.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Foundation's `CharacterSet.whitespaces`: tab and the space separators, no newlines.
fn is_blank(c: char) -> bool {
    c.is_whitespace() && !is_newline(c)
}

/// Foundation's `CharacterSet.controlCharacters`: categories Cc and Cf.
fn is_control(c: char) -> bool {
    c.is_control()
        || matches!(c as u32,
            0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E
            | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF
            | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

/// How a session ended, as the viewer's card says it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EndReason {
    /// The host set this device's access to None (or changed it).
    PermissionRevoked,
    /// Revoked, but the access is back (or lowered): never parsed, the card decides it.
    AccessChanged,
    ViewerRemoved,
    HostRemoved,
    DeviceRemoved,
    SharingOff,
    HostStopped,
    ViewerDisconnected,
    SignedOut,
    PeerOffline,
    Failed,
    Expired,
    ApproveFailed,
    ConsentRequired,
    Moved,
    Other,
}

impl EndReason {
    pub const ALL: [EndReason; 16] = [
        EndReason::PermissionRevoked,
        EndReason::AccessChanged,
        EndReason::ViewerRemoved,
        EndReason::HostRemoved,
        EndReason::DeviceRemoved,
        EndReason::SharingOff,
        EndReason::HostStopped,
        EndReason::ViewerDisconnected,
        EndReason::SignedOut,
        EndReason::PeerOffline,
        EndReason::Failed,
        EndReason::Expired,
        EndReason::ApproveFailed,
        EndReason::ConsentRequired,
        EndReason::Moved,
        EndReason::Other,
    ];

    /// The hub's reason string (`session.revoked`, `session.ended`).
    pub fn parse(reason: Option<&str>) -> Self {
        let text = reason.unwrap_or("");
        match text {
            "permission_revoked" | "permission_changed" | "host_revoked" => {
                EndReason::PermissionRevoked
            }
            "device_removed:viewer" => EndReason::ViewerRemoved,
            "device_removed:host" => EndReason::HostRemoved,
            "device_removed" => EndReason::DeviceRemoved,
            "sharing_off" => EndReason::SharingOff,
            "host_stopped" => EndReason::HostStopped,
            "viewer_disconnected" | "tab_closed" => EndReason::ViewerDisconnected,
            t if t.starts_with("signed_out") => EndReason::SignedOut,
            t if t.starts_with("peer_offline") => EndReason::PeerOffline,
            t if Self::failure_detail(Some(t)).is_some() => EndReason::Failed,
            "expired" => EndReason::Expired,
            "approve_failed" => EndReason::ApproveFailed,
            "consent_required" => EndReason::ConsentRequired,
            "moved" => EndReason::Moved,
            _ => EndReason::Other,
        }
    }

    /// A `failed` end's detail: `""` for a bare `failed`, the host's reason for
    /// `failed: <reason>`; `None` for every other reason.
    pub fn failure_detail(reason: Option<&str>) -> Option<String> {
        let reason = reason?;
        if reason == "failed" {
            return Some(String::new());
        }
        reason.strip_prefix("failed:").map(|rest| rest.trim_matches(is_blank).to_owned())
    }

    /// Whether Connect Again makes sense: not for a device that left the user's devices.
    pub fn can_reconnect(self) -> bool {
        !matches!(
            self,
            EndReason::HostRemoved | EndReason::ViewerRemoved | EndReason::DeviceRemoved
        )
    }

    /// The viewer lost its access (a card titled Access Removed), rather than a session that ended.
    pub fn removes_access(self) -> bool {
        matches!(
            self,
            EndReason::PermissionRevoked
                | EndReason::ViewerRemoved
                | EndReason::HostRemoved
                | EndReason::DeviceRemoved
        )
    }

    /// The viewer's card text; a named one takes the host device's name (never "this Mac" for it).
    pub fn message(self) -> Message {
        match self {
            EndReason::PermissionRevoked => Message::named(
                "macScreen.hub.reason.revoked",
                "%@ removed this Mac’s access to its screen.",
            ),
            EndReason::AccessChanged => Message::named(
                "macScreen.hub.reason.accessChanged",
                "%@ changed this Mac’s access. Connect again to continue.",
            ),
            EndReason::ViewerRemoved => Message::plain(
                "macScreen.hub.reason.viewerRemoved",
                "This Mac was removed from your devices.",
            ),
            EndReason::HostRemoved => Message::named(
                "macScreen.hub.reason.hostRemoved",
                "%@ was removed from your devices.",
            ),
            EndReason::DeviceRemoved => Message::plain(
                "macScreen.hub.reason.removed",
                "A device was removed from your devices.",
            ),
            EndReason::SharingOff => {
                Message::named("macScreen.hub.reason.sharingOffNamed", "%@ turned off Mac Screen.")
            }
            EndReason::HostStopped => Message::named(
                "macScreen.hub.reason.hostStoppedNamed",
                "%@ stopped sharing its screen.",
            ),
            EndReason::ViewerDisconnected => {
                Message::plain("macScreen.hub.reason.viewer", "You disconnected.")
            }
            EndReason::SignedOut => Message::plain(
                "macScreen.hub.reason.signedOutOrQuit",
                "A Mac in this session signed out of cmux or quit it.",
            ),
            EndReason::PeerOffline => {
                Message::named("macScreen.hub.reason.offline", "%@ went offline.")
            }
            EndReason::Failed => {
                Message::plain("macScreen.hub.reason.failed", "The screen stream could not start.")
            }
            EndReason::ApproveFailed => Message::named(
                "macScreen.hub.reason.approveFailed",
                "%@ allowed the session, but it couldn’t start. Try again.",
            ),
            EndReason::Expired => {
                Message::named("macScreen.hub.reason.expired", "%@ did not answer in time.")
            }
            EndReason::ConsentRequired => Message::named(
                "macScreen.hub.reason.consentRequired",
                "%@ hasn’t allowed screen sharing from this device.",
            ),
            EndReason::Moved => Message::plain(
                "macScreen.hub.reason.moved",
                "Screen sharing moved to another device.",
            ),
            EndReason::Other => Message::plain("macScreen.hub.reason.other", "The session ended."),
        }
    }
}

/// The `/end` reasons this app sends (metadata only: they land in the audit log).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HubReason {
    /// The host's Stop Sharing.
    HostStopped,
    /// Disconnect, or the viewer's tab closed.
    ViewerDisconnected,
    SignedOut,
    /// A newer session of the same pair took over.
    Replaced,
    /// The stream could not start.
    Failed,
    /// This Mac's join consent does not allow the session.
    ConsentRequired,
}

/// The hub keeps an `/end` reason up to this many UTF-16 units (it cuts a longer one).
pub const HUB_REASON_LIMIT: usize = 100;

impl HubReason {
    pub fn raw(self) -> &'static str {
        match self {
            HubReason::HostStopped => "host_stopped",
            HubReason::ViewerDisconnected => "viewer_disconnected",
            HubReason::SignedOut => "signed_out",
            HubReason::Replaced => "replaced",
            HubReason::Failed => "failed",
            HubReason::ConsentRequired => "consent_required",
        }
    }

    /// `failed: <why>` for a session this Mac could not serve as the host: one line, no
    /// control characters, a leading `failed:` not doubled, cut to the hub's limit (the same
    /// text cmux-hub-host's `failed_reason` sends). Swift filtered and cut whole grapheme
    /// clusters; this works per scalar, the same for every reason a screen host writes.
    pub fn failure(why: &str) -> String {
        let one_line: String = why
            .chars()
            .map(|c| if is_newline(c) { ' ' } else { c })
            .filter(|&c| !is_control(c))
            .collect();
        let mut why = one_line.trim_matches(is_blank);
        while let Some(rest) = why.strip_prefix("failed:") {
            why = rest.trim_matches(is_blank);
        }
        if why.is_empty() {
            return HubReason::Failed.raw().to_owned();
        }
        let mut out = String::from("failed: ");
        let mut units = out.len();
        for c in why.chars() {
            if units + c.len_utf16() > HUB_REASON_LIMIT {
                break;
            }
            units += c.len_utf16();
            out.push(c);
        }
        out.trim_matches(is_blank).to_owned()
    }
}

/// A device hub failure as the app's `DeviceHubError` carries it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "error", rename_all = "snake_case")]
pub enum HubError {
    /// No usable hub address: the feature is off.
    NotConfigured,
    /// No account token (signed out), or the server refused it.
    NotSignedIn,
    /// The protocol's `{error:{code, message}}` with its HTTP status.
    Server {
        status: i64,
        code: String,
        message: String,
    },
    /// An HTTP error without the protocol's error body.
    Http {
        status: i64,
    },
    Transport {
        detail: String,
    },
    Decoding {
        detail: String,
    },
    Identity {
        detail: String,
    },
}

/// Why the hub refused a viewer's request, as the viewer's card says it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "refusal", rename_all = "snake_case")]
pub enum Refusal {
    PermissionNone,
    ScopeExceeds,
    HostOffline,
    NotShared,
    NotFound,
    NotSignedIn,
    /// Anything else, with the hub's own words when it gave any.
    Other {
        reason: Option<String>,
    },
}

impl Refusal {
    /// The refusal for a failed `POST /v1/sessions`.
    pub fn from_error(error: &HubError) -> Self {
        if let HubError::Server { code, .. } = error {
            match code.as_str() {
                "permission_none" => return Refusal::PermissionNone,
                "scope_exceeds_permission" => return Refusal::ScopeExceeds,
                "host_offline" => return Refusal::HostOffline,
                "not_shared" => return Refusal::NotShared,
                "not_found" | "device_removed" => return Refusal::NotFound,
                "unauthorized" => return Refusal::NotSignedIn,
                _ => {}
            }
        }
        match error {
            HubError::NotSignedIn | HubError::NotConfigured => Refusal::NotSignedIn,
            _ => Refusal::Other { reason: Self::reason(error) },
        }
    }

    /// The hub's words for a refusal with no card of its own: the server's message (else its
    /// code), the HTTP status, or the transport's own error; `None` when there is nothing to say.
    pub fn reason(error: &HubError) -> Option<String> {
        let text = match error {
            HubError::Server { code, message, .. } => {
                if message.trim().is_empty() {
                    code.clone()
                } else {
                    message.clone()
                }
            }
            HubError::Http { status } => format!("HTTP {status}"),
            HubError::Transport { detail }
            | HubError::Decoding { detail }
            | HubError::Identity { detail } => detail.clone(),
            HubError::NotConfigured | HubError::NotSignedIn => String::new(),
        };
        let trimmed = text.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_owned())
    }

    /// Whether Try Again makes sense: not for a device that left the user's devices.
    pub fn can_retry(&self) -> bool {
        *self != Refusal::NotFound
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server(status: i64, code: &str, message: &str) -> HubError {
        HubError::Server { status, code: code.into(), message: message.into() }
    }

    // MacScreenHubTests.endReasonsReadTheProtocolsAuthoritativeReasons
    #[test]
    fn end_reasons_read_the_protocols_authoritative_reasons() {
        let cases = [
            ("permission_revoked", EndReason::PermissionRevoked),
            ("permission_changed", EndReason::PermissionRevoked),
            ("host_revoked", EndReason::PermissionRevoked),
            ("device_removed:viewer", EndReason::ViewerRemoved),
            ("device_removed:host", EndReason::HostRemoved),
            ("device_removed", EndReason::DeviceRemoved),
            ("sharing_off", EndReason::SharingOff),
            ("host_stopped", EndReason::HostStopped),
            ("viewer_disconnected", EndReason::ViewerDisconnected),
            ("tab_closed", EndReason::ViewerDisconnected),
            ("signed_out", EndReason::SignedOut),
            ("signed_out:quit", EndReason::SignedOut),
            ("peer_offline", EndReason::PeerOffline),
            ("failed", EndReason::Failed),
            ("expired", EndReason::Expired),
            ("approve_failed", EndReason::ApproveFailed),
            ("consent_required", EndReason::ConsentRequired),
            ("moved", EndReason::Moved),
            ("bye", EndReason::Other),
        ];
        for (text, reason) in cases {
            assert_eq!(EndReason::parse(Some(text)), reason, "{text}");
        }
        assert_eq!(EndReason::parse(None), EndReason::Other);
        assert!(EndReason::ApproveFailed.message().english("Mac mini 2").contains("Mac mini 2"));
        assert_eq!(HubReason::HostStopped.raw(), "host_stopped");
        assert_eq!(HubReason::ViewerDisconnected.raw(), "viewer_disconnected");
        assert_eq!(HubReason::SignedOut.raw(), "signed_out");
        // The serde names are the raw values.
        assert_eq!(serde_json::to_value(HubReason::ConsentRequired).unwrap(), "consent_required");
    }

    // MacScreenHubTests.endTextsNameTheHost
    #[test]
    fn end_texts_name_the_host() {
        for reason in [
            EndReason::PermissionRevoked,
            EndReason::HostRemoved,
            EndReason::SharingOff,
            EndReason::HostStopped,
            EndReason::PeerOffline,
        ] {
            assert!(reason.message().english("Mac mini 2").contains("Mac mini 2"));
        }
        assert_ne!(EndReason::HostStopped.message(), EndReason::Other.message());
        assert!(
            EndReason::PermissionRevoked.removes_access()
                && EndReason::ViewerRemoved.removes_access()
        );
        assert!(
            !EndReason::HostStopped.removes_access() && !EndReason::SharingOff.removes_access()
        );
        // Every key is distinct, and a named text has its `%@`.
        let mut keys: Vec<_> = EndReason::ALL.iter().map(|r| r.message().key).collect();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(keys.len(), EndReason::ALL.len());
        for r in EndReason::ALL {
            assert_eq!(r.message().names, r.message().text.contains("%@"));
        }
    }

    // MacScreenHubTests.reGrantedAccessIsNotRemoved, removedDevicesOfferNoReconnect
    #[test]
    fn reconnect_and_removed_access() {
        assert!(
            !EndReason::AccessChanged.removes_access() && EndReason::AccessChanged.can_reconnect()
        );
        assert!(
            !EndReason::HostRemoved.can_reconnect() && !EndReason::ViewerRemoved.can_reconnect()
        );
        assert!(!EndReason::DeviceRemoved.can_reconnect());
        assert!(
            EndReason::HostStopped.can_reconnect() && EndReason::PermissionRevoked.can_reconnect()
        );
    }

    // MacScreenFailureReasonTests.theHubsFailedEndCarriesTheHostsReason
    #[test]
    fn the_hubs_failed_end_carries_the_hosts_reason() {
        assert_eq!(
            EndReason::parse(Some("failed: no Screen Sharing helper: none installed")),
            EndReason::Failed
        );
        assert_eq!(EndReason::parse(Some("failed")), EndReason::Failed);
        assert_eq!(
            EndReason::failure_detail(Some("failed: the screen host stopped")).as_deref(),
            Some("the screen host stopped")
        );
        assert_eq!(EndReason::failure_detail(Some("failed")).as_deref(), Some(""));
        assert_eq!(EndReason::failure_detail(Some("host_stopped")), None);
        assert_eq!(EndReason::failure_detail(None), None);
        // `failedx` is neither `failed` nor `failed:`.
        assert_eq!(EndReason::parse(Some("failedx")), EndReason::Other);
    }

    // MacScreenFailureReasonTests.theHostsEndTextFitsTheHub
    #[test]
    fn the_hosts_end_text_fits_the_hub() {
        assert_eq!(HubReason::failure(""), "failed");
        assert_eq!(
            HubReason::failure("the screen host could not start: x"),
            "failed: the screen host could not start: x"
        );
        assert_eq!(HubReason::failure("failed: capture\nline two"), "failed: capture line two");
        let long = HubReason::failure(&"é".repeat(300));
        assert!(long.encode_utf16().count() <= HUB_REASON_LIMIT);
        assert!(long.starts_with("failed: é"));
        assert_eq!(long.encode_utf16().count(), HUB_REASON_LIMIT);
        // Round trip: the viewer reads back what the host sent.
        assert_eq!(
            EndReason::failure_detail(Some(&HubReason::failure("capture: denied"))).as_deref(),
            Some("capture: denied")
        );
        // A leading `failed:` is never doubled, control characters go, blanks trim.
        assert_eq!(HubReason::failure(" failed: failed:  x\u{7}\u{200B}y \t"), "failed: xy");
        assert_eq!(HubReason::failure("failed:"), "failed");
        // A surrogate pair never splits at the limit.
        let emoji = HubReason::failure(&"😀".repeat(60));
        assert_eq!((emoji.encode_utf16().count(), emoji.chars().count()), (100, 8 + 46));
        let odd = HubReason::failure(&format!("a{}", "😀".repeat(60)));
        assert_eq!(odd.encode_utf16().count(), 99);
    }

    // MacScreenHubTests.refusalsFollowTheProtocolsCodes
    #[test]
    fn refusals_follow_the_protocols_codes() {
        let refusal = |code: &str, status: i64| Refusal::from_error(&server(status, code, ""));
        assert_eq!(refusal("permission_none", 403), Refusal::PermissionNone);
        assert_eq!(refusal("scope_exceeds_permission", 403), Refusal::ScopeExceeds);
        assert_eq!(refusal("host_offline", 409), Refusal::HostOffline);
        assert_eq!(refusal("not_shared", 403), Refusal::NotShared);
        assert_eq!(refusal("not_found", 404), Refusal::NotFound);
        assert_eq!(refusal("device_removed", 410), Refusal::NotFound);
        assert_eq!(refusal("unauthorized", 401), Refusal::NotSignedIn);
        assert_eq!(refusal("internal", 500), Refusal::Other { reason: Some("internal".into()) });
        assert_eq!(Refusal::from_error(&HubError::NotSignedIn), Refusal::NotSignedIn);
        assert_eq!(Refusal::from_error(&HubError::NotConfigured), Refusal::NotSignedIn);
        assert_eq!(
            Refusal::from_error(&HubError::Transport { detail: "offline".into() }),
            Refusal::Other { reason: Some("offline".into()) }
        );
    }

    // MacScreenHubTests.anUnknownRefusalKeepsTheHubsReason, notFoundOffersNoRetry
    #[test]
    fn an_unknown_refusal_keeps_the_hubs_reason() {
        let rate_limited =
            Refusal::from_error(&server(429, "rate_limited", "too many requests; wait a minute"));
        assert_eq!(
            rate_limited,
            Refusal::Other { reason: Some("too many requests; wait a minute".into()) }
        );
        assert_eq!(
            Refusal::from_error(&server(403, "new_code", " ")),
            Refusal::Other { reason: Some("new_code".into()) }
        );
        assert_eq!(
            Refusal::from_error(&HubError::Http { status: 502 }),
            Refusal::Other { reason: Some("HTTP 502".into()) }
        );
        assert_eq!(
            Refusal::from_error(&HubError::Decoding { detail: "missing session".into() }),
            Refusal::Other { reason: Some("missing session".into()) }
        );
        assert_eq!(
            Refusal::from_error(&HubError::Transport { detail: String::new() }),
            Refusal::Other { reason: None }
        );
        assert!(rate_limited.can_retry());
        assert!(!Refusal::NotFound.can_retry());
        assert!(Refusal::HostOffline.can_retry() && Refusal::NotShared.can_retry());
        let json = serde_json::to_value(&rate_limited).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"refusal": "other", "reason": "too many requests; wait a minute"})
        );
        let error: HubError = serde_json::from_value(
            serde_json::json!({"error": "server", "status": 409, "code": "host_offline", "message": ""}),
        )
        .unwrap();
        assert_eq!(Refusal::from_error(&error), Refusal::HostOffline);
    }
}
