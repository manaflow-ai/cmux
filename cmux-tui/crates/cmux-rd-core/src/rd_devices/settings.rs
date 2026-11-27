//! Settings > Devices' rules (`MacScreenDevicesSettings.swift`): the card's status, a device row's words,
//! the History table's rows, relay drafts and Check Relay results, and what a failed gesture says. The
//! hub, the relay check, sealing and date formatting stay in Swift.

use super::Words;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A status line and its tone.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub text: Words,
    pub tone: String,
}

fn status(key: &str, text: &str, tone: &str) -> Status {
    Status { text: Words::t(key, text), tone: tone.to_owned() }
}

/// The hub client's state (`DeviceHub.status`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HubStatus {
    Idle,
    Starting,
    Failed,
    Ready,
}

/// The hub socket's state (`DeviceHubSocket.State`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Connection {
    Disconnected,
    Connecting,
    Reconnecting,
    Connected,
    Replaced,
    Removed,
    SignedOut,
}

/// A link state that ends without anyone acting: not up yet, coming up, or backing off to redial.
pub fn redials(connection: Connection) -> bool {
    matches!(
        connection,
        Connection::Disconnected | Connection::Connecting | Connection::Reconnecting
    )
}

/// Whether the card's status may be held back as a redial (only once the hub is ready).
pub fn redialing(hub: HubStatus, connection: Connection) -> bool {
    hub == HubStatus::Ready && redials(connection)
}

/// The card's status with a hub.
pub fn hub_status(hub: HubStatus, connection: Connection) -> Status {
    match hub {
        HubStatus::Idle => status("devices.status.idle", "Not connected", "neutral"),
        HubStatus::Starting => status("devices.status.starting", "Signing in…", "attention"),
        HubStatus::Failed => status(
            "devices.status.failed",
            "Couldn’t reach the device hub. cmux keeps trying.",
            "danger",
        ),
        HubStatus::Ready => match connection {
            Connection::Connected => status("devices.status.connected", "Connected", "success"),
            Connection::Removed => {
                status("devices.status.removed", "This Mac left your devices.", "danger")
            }
            _ => status("devices.status.connecting", "Connecting…", "attention"),
        },
    }
}

/// What the card reads with no hub.
#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq, Eq)]
#[serde(default)]
pub struct NoHub {
    /// The Device Hub Address is valid (or unset).
    pub configured: bool,
    pub startup_message: Option<String>,
    /// The saved sign-in restores, or the hub is still starting.
    pub restoring: bool,
    /// This Mac left the hub and may sign in again.
    pub can_sign_in: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct NoHubCard {
    pub available: bool,
    pub status: Status,
    pub sign_in: Option<Words>,
    /// The startup message as the card's error (the gesture error otherwise stays).
    pub startup_error: Option<String>,
}

pub fn no_hub_card(i: &NoHub) -> NoHubCard {
    if !i.configured {
        return NoHubCard {
            available: false,
            status: status(
                "devices.status.invalidHubAddress",
                "The Device Hub Address in Settings › Development is not a valid web address. Fix it, or clear it to use the built-in hub.",
                "neutral",
            ),
            sign_in: None,
            startup_error: None,
        };
    }
    if let Some(message) = &i.startup_message {
        return NoHubCard {
            available: true,
            status: Status { text: Words::said(message.clone()), tone: "danger".into() },
            sign_in: None,
            startup_error: Some(message.clone()),
        };
    }
    if i.restoring {
        return NoHubCard {
            available: true,
            status: status("macScreen.home.devicesLoading", "Loading your devices…", "neutral"),
            sign_in: None,
            startup_error: None,
        };
    }
    let (sign_in, status) = if i.can_sign_in {
        (
            Some(Words::t("devices.signIn", "Sign In to Your Devices")),
            status("devices.status.removed", "This Mac left your devices.", "neutral"),
        )
    } else {
        (
            None,
            status("devices.status.signedOut", "Sign in to cmux to see your devices.", "neutral"),
        )
    };
    NoHubCard { available: true, status, sign_in, startup_error: None }
}

/// The hub's device platform.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Platform {
    Macos,
    Ios,
    Linux,
    Windows,
}

impl Platform {
    /// Macs and Linux desktops host a screen this Mac views.
    pub fn hosts_screen(self) -> bool {
        matches!(self, Self::Macos | Self::Linux)
    }
}

/// A row's platform label (a device from before platforms reads as a Mac).
pub fn platform_label(platform: Option<Platform>) -> Words {
    match platform {
        Some(Platform::Ios) => Words::t("devices.platform.ios", "iPhone"),
        Some(Platform::Linux) => Words::t("devices.platform.linux", "Linux"),
        Some(Platform::Windows) => Words::t("devices.platform.windows", "Windows"),
        Some(Platform::Macos) | None => Words::t("devices.platform.mac", "Mac"),
    }
}

/// A device row's presence: online (this Mac always is), offline with when it was seen (Swift's
/// relative date), or offline.
pub fn presence(online: bool, seen: Option<&str>) -> Words {
    match (online, seen) {
        (true, _) => Words::t("devices.online", "Online"),
        (false, Some(seen)) => {
            Words::with("devices.offlineSeen", "Offline · seen %@", Words::said(seen))
        }
        (false, None) => Words::t("devices.offline", "Offline"),
    }
}

/// The Remove confirmation.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Confirm {
    pub title: Words,
    pub body: Words,
    pub confirm: Words,
}

pub fn remove_confirm(this_device: bool, name: &str) -> Confirm {
    let confirm = Words::t("devices.removeConfirm", "Remove");
    if this_device {
        Confirm {
            title: Words::t("devices.removeThisTitle", "Remove This Mac from your devices?"),
            body: Words::t(
                "devices.removeThisBody",
                "This Mac signs out of your devices: its Mac Screen sessions end and your other devices no longer see it. Sign in again to add it back as a new device.",
            ),
            confirm,
        }
    } else {
        Confirm {
            title: Words::with(
                "devices.removeTitle",
                "Remove %@ from your devices?",
                Words::said(name),
            ),
            body: Words::t(
                "devices.removeBody",
                "Its Mac Screen sessions end and it can no longer see or share screens. It comes back as a new device when it signs in again.",
            ),
            confirm,
        }
    }
}

/// A row's screen button: Share on this Mac, View screen on another (disabled while it is offline).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ScreenAction {
    pub kind: String,
    pub title: Words,
    pub disabled: bool,
}

pub fn screen_action(
    platform: Option<Platform>,
    this_device: bool,
    online: bool,
) -> Option<ScreenAction> {
    if !platform.is_some_and(Platform::hosts_screen) {
        return None;
    }
    Some(if this_device {
        ScreenAction {
            kind: "share".into(),
            title: Words::t("devices.shareScreen", "Share"),
            disabled: false,
        }
    } else {
        ScreenAction {
            kind: "view".into(),
            title: Words::t("devices.viewScreen", "View screen"),
            disabled: !online,
        }
    })
}

/// Why Open Screen cannot open a device, if it cannot.
pub fn open_screen_refusal(
    listed: bool,
    this_device: bool,
    platform: Option<Platform>,
    online: bool,
) -> Option<Words> {
    if !listed {
        return Some(gone());
    }
    if this_device || !platform.is_some_and(Platform::hosts_screen) {
        return Some(Words::t(
            "devices.error.invalidAction",
            "That action is not available for this device.",
        ));
    }
    (!online).then(|| Words::t("devices.error.offline", "That Mac is offline."))
}

/// A rename's name: trimmed, none when empty.
pub fn rename_name(name: Option<&str>) -> Option<String> {
    name.map(str::trim).filter(|n| !n.is_empty()).map(str::to_owned)
}

fn gone() -> Words {
    Words::t("devices.error.gone", "That device is no longer in your devices.")
}

/// What failed, as Swift classifies the error.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum Failure {
    NotSignedIn,
    NotConfigured,
    Transport,
    /// A hub error with the protocol's code.
    Hub {
        code: Option<String>,
    },
    /// Not a hub error.
    Other,
}

/// What a failed gesture says (never a secret).
pub fn failure_message(failure: &Failure) -> Words {
    let generic = || Words::t("devices.error.generic", "That didn’t work. Try again.");
    match failure {
        Failure::NotSignedIn | Failure::NotConfigured => {
            Words::t("devices.error.signedOut", "Sign in to cmux first.")
        }
        Failure::Transport => Words::t(
            "devices.error.network",
            "Couldn’t reach the device hub. Check your connection and try again.",
        ),
        Failure::Hub { code }
            if matches!(code.as_deref(), Some("device_removed" | "not_found")) =>
        {
            gone()
        }
        Failure::Hub { .. } | Failure::Other => generic(),
    }
}

// MARK: Relays

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RelayAuthMode {
    SharedSecret,
    Static,
}

pub fn mode_text(mode: RelayAuthMode) -> Words {
    match mode {
        RelayAuthMode::SharedSecret => Words::t("devices.relay.modeShared", "Shared secret"),
        RelayAuthMode::Static => Words::t("devices.relay.modeStatic", "Username and password"),
    }
}

/// A relay's secret.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "mode")]
pub enum RelaySecret {
    SharedSecret { secret: String },
    Static { username: String, password: String },
}

/// A relay the person edits (`DevicesRun.relay`).
#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq, Eq)]
#[serde(default)]
pub struct RelayDraft {
    pub id: Option<String>,
    pub name: String,
    pub urls: Vec<String>,
    pub mode: String,
    pub secret: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub enabled: bool,
    pub priority: i64,
}

/// The secret a draft names, or (editing) the one this Mac holds when the fields are left empty.
pub fn draft_secret(draft: &RelayDraft, existing: Option<&RelaySecret>) -> Option<RelaySecret> {
    if draft.mode == "shared_secret" {
        if let Some(secret) = draft.secret.as_deref().filter(|s| !s.is_empty()) {
            return Some(RelaySecret::SharedSecret { secret: secret.to_owned() });
        }
        return existing.filter(|e| matches!(e, RelaySecret::SharedSecret { .. })).cloned();
    }
    let username = draft.username.as_deref().unwrap_or_default();
    let password = draft.password.as_deref().unwrap_or_default();
    if !username.is_empty() || !password.is_empty() {
        if username.is_empty() || password.is_empty() {
            return None;
        }
        return Some(RelaySecret::Static {
            username: username.to_owned(),
            password: password.to_owned(),
        });
    }
    existing.filter(|e| matches!(e, RelaySecret::Static { .. })).cloned()
}

/// The draft's TURN URLs, trimmed, empty ones dropped.
pub fn draft_urls(draft: &RelayDraft) -> Vec<String> {
    draft.urls.iter().map(|u| u.trim()).filter(|u| !u.is_empty()).map(str::to_owned).collect()
}

/// A draft ready to save.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct RelaySave {
    pub name: String,
    pub urls: Vec<String>,
    pub secret: RelaySecret,
}

/// Save Relay's checks: a name, TURN or STUN URLs, a secret (or the saved one).
pub fn validate_relay(
    draft: &RelayDraft,
    existing: Option<&RelaySecret>,
) -> Result<RelaySave, Words> {
    let name = draft.name.trim().to_owned();
    let urls = draft_urls(draft);
    if name.is_empty() {
        return Err(Words::t("devices.error.name", "Enter a name."));
    }
    let schemes = ["turn:", "turns:", "stun:"];
    if urls.is_empty() || !urls.iter().all(|u| schemes.iter().any(|s| u.starts_with(s))) {
        return Err(Words::t(
            "devices.error.urls",
            "Enter at least one TURN URL, like turns:turn.example.com:5349.",
        ));
    }
    let Some(secret) = draft_secret(draft, existing) else {
        return Err(if draft.mode == "shared_secret" {
            Words::t("devices.error.secret", "Enter the relay’s shared secret.")
        } else {
            Words::t("devices.error.credentials", "Enter the relay’s username and password.")
        });
    };
    Ok(RelaySave { name, urls, secret })
}

/// Check Relay's outcome (`ICERelayCheck.Outcome`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CheckOutcome {
    Relayed,
    RefusedCredentials,
    Unreachable,
    NoRelayCandidate,
    Failed,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Check {
    pub tone: String,
    pub text: Words,
}

pub fn check_result(outcome: CheckOutcome) -> Check {
    let (tone, key, text) = match outcome {
        CheckOutcome::Relayed => (
            "success",
            "devices.relay.checkOK",
            "The relay works: it gave this Mac a relay address.",
        ),
        CheckOutcome::RefusedCredentials => (
            "danger",
            "devices.relay.checkRefused",
            "The relay refused the credentials. Check the shared secret, or the username and password.",
        ),
        CheckOutcome::Unreachable => (
            "danger",
            "devices.relay.checkUnreachable",
            "The relay can’t be reached. Check its URLs and that its port is open.",
        ),
        CheckOutcome::NoRelayCandidate => (
            "danger",
            "devices.relay.checkNone",
            "No relay address within 10 seconds. Check the URLs, the secret and that the port is open.",
        ),
        CheckOutcome::Failed => {
            ("danger", "devices.relay.checkFailed", "The check could not start.")
        }
    };
    Check { tone: tone.to_owned(), text: Words::t(key, text) }
}

// MARK: History

/// One hub audit entry (the hub's metadata; `ts` stays in Swift, which formats it).
#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct AuditEntry {
    pub id: String,
    pub event: String,
    pub viewer_id: Option<String>,
    pub host_id: Option<String>,
    pub device_id: Option<String>,
    pub viewer_name: Option<String>,
    pub host_name: Option<String>,
    pub device_name: Option<String>,
    pub scope: Option<String>,
    pub detail: Option<String>,
    #[serde(alias = "duration_s")]
    pub duration_s: Option<f64>,
}

/// Why a session ended (`MacScreenEndReason`).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EndReason {
    PermissionRevoked,
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

/// A `failed` end's detail: empty for a bare `failed`, the reason of `failed: <reason>`, else none.
pub fn failure_detail(reason: &str) -> Option<&str> {
    if reason == "failed" {
        return Some("");
    }
    reason.strip_prefix("failed:").map(str::trim)
}

impl EndReason {
    pub fn of(reason: Option<&str>) -> Self {
        let reason = reason.unwrap_or_default();
        match reason {
            "permission_revoked" | "permission_changed" | "host_revoked" => Self::PermissionRevoked,
            "device_removed:viewer" => Self::ViewerRemoved,
            "device_removed:host" => Self::HostRemoved,
            "device_removed" => Self::DeviceRemoved,
            "sharing_off" => Self::SharingOff,
            "host_stopped" => Self::HostStopped,
            "viewer_disconnected" | "tab_closed" => Self::ViewerDisconnected,
            r if r.starts_with("signed_out") => Self::SignedOut,
            r if r.starts_with("peer_offline") => Self::PeerOffline,
            r if failure_detail(r).is_some() => Self::Failed,
            "expired" => Self::Expired,
            "approve_failed" => Self::ApproveFailed,
            "consent_required" => Self::ConsentRequired,
            "moved" => Self::Moved,
            _ => Self::Other,
        }
    }
}

/// A device in History: a listed device's name, the name the entry kept, a removed device, or none.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Name {
    None,
    Removed,
    Named(String),
}

impl Name {
    fn of(id: Option<&str>, kept: Option<&str>, names: &HashMap<String, String>) -> Self {
        let Some(id) = id else { return Self::None };
        match names.get(id).map(String::as_str).or(kept.filter(|k| !k.is_empty())) {
            Some(name) => Self::Named(name.to_owned()),
            None => Self::Removed,
        }
    }

    fn known(&self) -> bool {
        matches!(self, Self::Named(_))
    }

    fn words(&self) -> Words {
        match self {
            Self::None => Words::said("—"),
            Self::Removed => Words::t("devices.history.removedDevice", "Removed device"),
            Self::Named(name) => Words::said(name.clone()),
        }
    }
}

/// An access scope's title (`MacScreenAccess.title`).
pub fn access_title(scope: &str) -> Option<Words> {
    Some(match scope {
        "none" => Words::t("macScreen.access.none", "None"),
        "ask" => Words::t("macScreen.access.ask", "Ask"),
        "view" => Words::t("macScreen.access.view", "View Only"),
        "full" => Words::t("macScreen.access.full", "Full Control"),
        _ => return None,
    })
}

fn scope_words(scope: Option<&str>) -> Words {
    match scope {
        Some("view") => Words::t("macScreen.scope.view", "View Only"),
        Some("full") => Words::t("macScreen.scope.full", "Full Control"),
        Some(other) => access_title(other).unwrap_or_else(|| Words::said(other)),
        None => Words::said("—"),
    }
}

pub fn event_text(event: &str) -> Words {
    let (key, text) = match event {
        "shared" => ("devices.event.shared", "Shared"),
        "unshared" => ("devices.event.unshared", "Stopped sharing"),
        "requested" => ("devices.event.requested", "Requested"),
        "approved" => ("devices.event.approved", "Approved"),
        "denied" => ("devices.event.denied", "Denied"),
        "started" => ("devices.event.started", "Started"),
        "ended" => ("devices.event.ended", "Ended"),
        "permission_changed" => ("devices.event.permission", "Access changed"),
        "device_added" => ("devices.event.added", "Device added"),
        "device_removed" => ("devices.event.removed", "Device removed"),
        "agents_allowed" => {
            return Words::in_table(
                "CmuxRemote",
                "remote.agents.history.allowed",
                "Agents allowed to share",
            );
        }
        "agents_disallowed" => {
            return Words::in_table(
                "CmuxRemote",
                "remote.agents.history.disallowed",
                "Agents ask before sharing",
            );
        }
        other => return Words::said(other),
    };
    Words::t(key, text)
}

pub fn event_tone(event: &str) -> &'static str {
    match event {
        "approved" | "started" | "shared" | "device_added" => "success",
        "denied" | "device_removed" => "danger",
        "requested" | "permission_changed" => "attention",
        _ => "neutral",
    }
}

fn some_device_removed() -> Words {
    Words::t("devices.history.someDeviceRemoved", "A device was removed")
}

fn was_removed(name: &Name) -> Words {
    if name.known() {
        Words::with("devices.history.deviceRemoved", "%@ was removed", name.words())
    } else {
        some_device_removed()
    }
}

fn end_text(reason: EndReason, viewer: &Name, host: &Name) -> Words {
    let with = |key: &str, text: &str, name: &Name| Words::with(key, text, name.words());
    match reason {
        EndReason::PermissionRevoked | EndReason::AccessChanged => {
            with("devices.history.revoked", "%@ removed the access", host)
        }
        EndReason::ViewerRemoved => was_removed(viewer),
        EndReason::HostRemoved => was_removed(host),
        EndReason::DeviceRemoved => some_device_removed(),
        EndReason::SharingOff => {
            with("devices.history.sharingOff", "%@ turned off Mac Screen", host)
        }
        EndReason::HostStopped => with("devices.history.hostStopped", "%@ stopped sharing", host),
        EndReason::ViewerDisconnected => {
            with("devices.history.viewerDisconnected", "%@ disconnected", viewer)
        }
        EndReason::SignedOut => {
            Words::t("devices.history.signedOutOrQuit", "A device signed out or quit cmux")
        }
        EndReason::PeerOffline => Words::t("devices.history.offline", "A device went offline"),
        EndReason::Failed => Words::t("devices.history.failed", "The stream could not start"),
        EndReason::Expired => Words::t("devices.history.expired", "No answer in time"),
        EndReason::ConsentRequired => {
            with("devices.history.consentRequired", "%@ hasn’t allowed screen sharing", host)
        }
        EndReason::ApproveFailed => {
            Words::t("devices.history.approveFailed", "Approved, but the session couldn’t start")
        }
        EndReason::Moved => Words::t("devices.history.moved", "Moved to another device"),
        EndReason::Other => Words::t("devices.history.other", "Ended"),
    }
}

fn detail_text(entry: &AuditEntry, viewer: &Name, host: &Name, subject: &Name) -> Words {
    if entry.event == "device_added" || entry.event == "device_removed" {
        let name = [subject, viewer, host].into_iter().find(|n| n.known());
        return match (name, entry.event == "device_added") {
            (None, true) => Words::said(""),
            (None, false) => some_device_removed(),
            (Some(name), true) => {
                Words::with("devices.history.deviceAdded", "%@ was added", name.words())
            }
            (Some(name), false) => was_removed(name),
        };
    }
    let Some(detail) = entry.detail.as_deref().filter(|d| !d.is_empty()) else {
        return Words::said("");
    };
    match entry.event.as_str() {
        "permission_changed" => {
            let parts: Vec<&str> = detail.split("->").collect();
            if parts.len() != 2 {
                return Words::said(detail);
            }
            let mut args =
                parts.iter().map(|p| access_title(p.trim()).unwrap_or_else(|| Words::said(*p)));
            let (from, to) = (
                args.next().unwrap_or_else(|| Words::said("")),
                args.next().unwrap_or_else(|| Words::said("")),
            );
            Words { key: None, text: "%@ → %@".into(), table: None, args: vec![from, to] }
        }
        "approved" | "denied" => match detail {
            "once" => Words::t("macScreen.approval.once", "Allow Once"),
            "always" => Words::t("devices.history.always", "Always Allow"),
            "deny" => Words::t("macScreen.approval.deny", "Deny"),
            _ => Words::said(detail),
        },
        "ended" if detail == "bye" => Words::t("devices.history.bye", "Disconnected"),
        "ended" => end_text(EndReason::of(Some(detail)), viewer, host),
        _ => Words::said(detail),
    }
}

/// "22m 27s", "1h 4m", "8s".
pub fn duration_text(seconds: f64) -> String {
    let total = seconds.round().max(0.0) as i64;
    let (hours, minutes, rest) = (total / 3600, (total % 3600) / 60, total % 60);
    if hours > 0 {
        format!("{hours}h {minutes}m")
    } else if minutes > 0 {
        format!("{minutes}m {rest}s")
    } else {
        format!("{rest}s")
    }
}

/// One History row (Swift adds `time`).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct HistoryRow {
    pub id: String,
    pub event: String,
    pub event_text: Words,
    pub tone: String,
    pub device: Words,
    pub host: Words,
    pub scope: Words,
    pub detail: Words,
    pub duration: String,
}

/// One audit entry as History shows it; `names`: the listed devices' and the ones seen before, by id.
pub fn history_row(entry: &AuditEntry, names: &HashMap<String, String>) -> HistoryRow {
    let viewer = Name::of(entry.viewer_id.as_deref(), entry.viewer_name.as_deref(), names);
    let host = Name::of(entry.host_id.as_deref(), entry.host_name.as_deref(), names);
    let subject = entry
        .device_id
        .as_deref()
        .map(|id| Name::of(Some(id), entry.device_name.as_deref(), names));
    let device = subject.clone().unwrap_or_else(|| viewer.clone());
    HistoryRow {
        id: entry.id.clone(),
        event: entry.event.clone(),
        event_text: event_text(&entry.event),
        tone: event_tone(&entry.event).to_owned(),
        device: device.words(),
        host: host.words(),
        scope: scope_words(entry.scope.as_deref()),
        detail: detail_text(entry, &viewer, &host, &subject.unwrap_or(Name::None)),
        duration: entry.duration_s.map(duration_text).unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests;
