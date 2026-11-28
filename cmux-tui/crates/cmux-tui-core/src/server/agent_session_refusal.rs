//! The refusal codes of an agent session attachment (the attachment is in
//! `agent_session_attach.rs`).

use super::*;

/// Refusal codes (`error_code`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refusal {
    NotTrusted,
    Unavailable,
    BadRequest,
    UnknownTab,
    NotAttached,
    Limit,
    Timeout,
    Refused,
    /// acpmux's session list could not be read whole (`LinkError::BadList`).
    BadList,
    UnknownPermission,
    /// `agent-session-start`: the tab already has a session.
    Bound,
    /// `agent-session-start`: acpmux is not running and could not be started.
    AcpmuxUnavailable,
    /// `agent-session-start`: the agent has no mode that asks before acting.
    NotAsking,
    /// `agent-session-start`: the folder is not trusted on this machine.
    UntrustedFolder,
    /// `agent-session-start`: this daemon runs on a team VM.
    TeamVmBlocked,
    /// A personal model credential can be delivered only to the owner's own VM.
    PersonalConnectionOnTeamVm,
    ConnectionKeyRefused,
    /// `agent-session-start`: a Cloud VM daemon that cannot tell its kind.
    HostUnverified,
    /// `agent-session-trust`: a folder above the home folder.
    AboveHome,
    /// `agent-session-trust`: the home folder without the person's choice of it.
    HomeUnconfirmed,
    /// `agent-session-start` with `require_person_key`: acpmux holds no
    /// person key for the caller's run (cx-0w0jj).
    NeedsKeyedStart,
    ReadOnly,
    ModeConflict,
    /// A proxied teammate's frame for a surface that shows another chat than the shared one.
    NotShared,
    /// A link guest's frame for anything but the shared chat's guest verbs.
    ScopeNotGranted,
    /// A link guest whose share expired or was revoked, or who was removed.
    ShareEnded,
    /// A Cloud team member's answer to a permission ask, or approval of a held prompt: the
    /// chat's owner decides what runs on their machine.
    OwnerOnly,
    /// `agent-session-start`: the agent answered that it is not signed in on this machine
    /// (acpmux `agent.sign_in_required`); `data` names the harness (hq#11225).
    SignInRequired,
    /// `agent-session-start`: the agent asked for is not in this machine's acpmux catalog (not
    /// installed there); `data` names the harness (hq#11225).
    HarnessMissing,
    /// `agent-session-start`: the agent's model route cannot serve it on this machine (acpmux
    /// `route.*`); `data` names the route's reason and the harness (hq#11225).
    RouteUnavailable,
}

impl Refusal {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent_session.not_trusted",
            Self::Unavailable => "agent_session.unavailable",
            Self::BadRequest => "agent_session.bad_request",
            Self::UnknownTab => "agent_session.unknown_tab",
            Self::NotAttached => "agent_session.not_attached",
            Self::Limit => "agent_session.limit",
            Self::Timeout => "agent_session.timeout",
            Self::Refused => "agent_session.refused",
            Self::BadList => "agent_session.bad_list",
            Self::UnknownPermission => "agent_session.unknown_permission",
            Self::Bound => "agent_session.bound",
            Self::AcpmuxUnavailable => "agent_session.acpmux_unavailable",
            Self::NotAsking => "agent_session.not_asking",
            Self::UntrustedFolder => "agent_session.untrusted_folder",
            Self::TeamVmBlocked => "agent_session.team_vm_blocked",
            Self::PersonalConnectionOnTeamVm => "agent_session.personal_connection_on_team_vm",
            Self::ConnectionKeyRefused => "agent_session.connection_key_refused",
            Self::HostUnverified => "agent_session.host_unverified",
            Self::AboveHome => "agent_session.above_home",
            Self::HomeUnconfirmed => "agent_session.home_unconfirmed",
            Self::NeedsKeyedStart => "agent_session.needs_keyed_start",
            Self::ReadOnly => "agent_session.read_only",
            Self::ModeConflict => "agent_session.mode_conflict",
            Self::NotShared => "agent_session.not_shared",
            Self::ScopeNotGranted => "agent_session.scope_not_granted",
            Self::ShareEnded => "agent_session.share_ended",
            Self::OwnerOnly => "agent_session.owner_only",
            Self::SignInRequired => "agent_session.sign_in_required",
            Self::HarnessMissing => "agent_session.harness_missing",
            Self::RouteUnavailable => "agent_session.route_unavailable",
        }
    }

    pub(super) fn message(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent session attach needs a trusted local connection",
            Self::Unavailable => "this daemon has no acpmux to attach to",
            Self::BadRequest => "bad request",
            Self::UnknownTab => "not an agent tab with a session in this daemon",
            Self::NotAttached => "the tab is not attached on this connection",
            Self::Limit => "the agent tab could not attach now; try again",
            Self::Timeout => "acpmux did not answer in time",
            Self::Refused => "acpmux refused the request",
            Self::BadList => "acpmux's session list could not be read whole",
            Self::UnknownPermission => "no such pending permission request on this attachment",
            Self::Bound => "the agent tab already has a session",
            Self::AcpmuxUnavailable => {
                "acpmux is not running on this machine and could not be started"
            }
            Self::NotAsking => "this agent has no mode that asks before each action",
            Self::UntrustedFolder => "the folder is not trusted on this machine",
            Self::TeamVmBlocked => "agent chats cannot be started remotely on a team VM",
            Self::PersonalConnectionOnTeamVm => {
                "Personal connections run only on your own Cloud machine."
            }
            Self::ConnectionKeyRefused => {
                "The connection key was refused. Replace it in Settings > Models."
            }
            Self::HostUnverified => {
                "this machine cannot tell whether it is a team VM, so it starts no remote chat"
            }
            Self::AboveHome => "a folder above the home folder is never trusted from here",
            Self::HomeUnconfirmed => {
                "the home folder is trusted only after the person chose it as the chat's folder"
            }
            Self::NeedsKeyedStart => {
                "acpmux on this machine holds no person key for this caller; restart it with one first"
            }
            Self::ReadOnly => "this agent session attachment is read-only",
            Self::ModeConflict => {
                "this connection already has the same surface attached in another mode"
            }
            Self::NotShared => "the surface does not show the chat that was shared",
            Self::ScopeNotGranted => "a link guest only watches and writes to the shared chat",
            Self::ShareEnded => "the share ended, or the owner removed this guest",
            Self::OwnerOnly => "only the chat's owner answers its asks and approves held prompts",
            Self::SignInRequired => "the agent is not signed in on this machine",
            Self::HarnessMissing => "this agent is not installed on this machine",
            Self::RouteUnavailable => "the agent's model route cannot serve it on this machine",
        }
    }

    pub(super) fn of(error: LinkError) -> Self {
        match error {
            LinkError::Closed => Self::Unavailable,
            LinkError::Timeout => Self::Timeout,
            LinkError::Rpc(..) | LinkError::MethodNotFound(_) => Self::Refused,
            LinkError::BadList(_) => Self::BadList,
        }
    }
}
