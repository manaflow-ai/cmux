//! One screen-sharing entry for a known machine, independent of the UI surface.
//! Facts come from native machine routing and the authenticated device hub,
//! never from a page's display name. Host permission and consent remain with
//! the existing actions selected by this plan.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// The native machine route. Unknown and Chief hosts never fall back to local.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MachineKind {
    Local,
    Cloud,
    Remote,
    Unsupported,
}

/// The hub record resolved by the machine's authenticated screen identity.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    pub platform: Option<String>,
    pub online: bool,
}

/// A single machine's current facts: bounded independently of fleet size.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Facts {
    pub machine_id: String,
    pub kind: MachineKind,
    pub authenticated_device_id: Option<String>,
    pub device: Option<Device>,
    /// A chat entry point supplies the native daemon's exact session summary.
    /// Machine entry points omit it because their target is already explicit.
    pub chat: Option<Chat>,
}

/// The chat's provenance, read from its daemon rather than a page label.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chat {
    pub expected_session_id: String,
    pub session_id: String,
    pub peer: Option<String>,
    pub host: Option<String>,
    pub host_kind: Option<String>,
    /// The containing remote daemon's own registry host, read from its handshake.
    pub registry_host: Option<String>,
    /// The local watch is live and includes this exact session, so absent peer is evidence.
    #[serde(default)]
    pub local_summary_current: bool,
}

/// An unavailable path stays on its machine instead of opening a generic picker.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Refusal {
    NoMachine,
    Unsupported,
    NoDevice,
    Offline,
    /// A peer chat needs an authenticated mapping to its own machine first.
    UnresolvedChatHost,
}

/// The existing action to invoke. This is a route, never a grant to view/control.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "decision", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Plan {
    ShareLocal,
    CloudDesktop { machine_id: String },
    ViewDevice { device_id: String },
    Refuse { reason: Refusal },
}

/// Selects an existing host action without I/O, discovery, or a focus fallback.
pub fn plan(facts: &Facts) -> Plan {
    if facts.machine_id.trim().is_empty() {
        return Plan::Refuse { reason: Refusal::NoMachine };
    }
    if let Some(chat) = &facts.chat {
        let named = |value: &Option<String>| value.as_deref().is_some_and(|v| !v.trim().is_empty());
        if chat.expected_session_id.is_empty() || chat.session_id != chat.expected_session_id {
            return Plan::Refuse { reason: Refusal::NoMachine };
        }
        // A peer's chat is not on the containing daemon. Without its authenticated
        // machine mapping, never turn its name into this Mac or the focused host.
        if named(&chat.peer)
            || chat.host.as_deref().is_some_and(|h| h.starts_with("chief:"))
            || chat.host_kind.as_deref() == Some("chief")
            || (facts.kind == MachineKind::Local
                && (chat.host_kind.as_deref() != Some("local") || !chat.local_summary_current))
            || (matches!(facts.kind, MachineKind::Cloud | MachineKind::Remote)
                && (!named(&chat.registry_host) || chat.registry_host != chat.host))
        {
            return Plan::Refuse { reason: Refusal::UnresolvedChatHost };
        }
    }
    match facts.kind {
        MachineKind::Local => Plan::ShareLocal,
        MachineKind::Cloud => Plan::CloudDesktop { machine_id: facts.machine_id.clone() },
        MachineKind::Unsupported => Plan::Refuse { reason: Refusal::Unsupported },
        MachineKind::Remote => {
            let authenticated =
                facts.authenticated_device_id.as_deref().and_then(|id| Uuid::parse_str(id).ok());
            let Some(device) = &facts.device else {
                return Plan::Refuse { reason: Refusal::NoDevice };
            };
            let registered = Uuid::parse_str(&device.id).ok();
            let Some(id) = authenticated.filter(|id| Some(*id) == registered && !id.is_nil())
            else {
                return Plan::Refuse { reason: Refusal::NoDevice };
            };
            // The current device-hub viewer supports macOS. Linux desktop hosts
            // use the Cloud route above; Windows support needs its host port.
            if device.platform.as_deref() != Some("macos") {
                return Plan::Refuse { reason: Refusal::Unsupported };
            }
            if !device.online {
                return Plan::Refuse { reason: Refusal::Offline };
            }
            Plan::ViewDevice { device_id: id.to_string() }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEVICE: &str = "550e8400-e29b-41d4-a716-446655440000";

    fn remote() -> Facts {
        Facts {
            machine_id: "machine:remote".into(),
            kind: MachineKind::Remote,
            authenticated_device_id: Some(DEVICE.into()),
            device: Some(Device {
                id: DEVICE.into(),
                platform: Some("macos".into()),
                online: true,
            }),
            chat: None,
        }
    }

    #[test]
    fn screen_share_preserves_the_authenticated_target() {
        let mut facts = remote();
        facts.authenticated_device_id = Some(DEVICE.to_uppercase());
        assert_eq!(plan(&facts), Plan::ViewDevice { device_id: DEVICE.into() });
        facts.device.as_mut().unwrap().id = "af705ab4-b378-4c30-8836-4c9297d2968f".into();
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::NoDevice });
    }

    #[test]
    fn screen_share_never_guesses_removed_or_invalid_device_identity() {
        for identity in [
            None,
            Some(""),
            Some("My Mac"),
            Some("local"),
            Some("00000000-0000-0000-0000-000000000000"),
        ] {
            let mut facts = remote();
            facts.authenticated_device_id = identity.map(str::to_owned);
            assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::NoDevice });
        }
        let mut facts = remote();
        facts.device = None;
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::NoDevice });
    }

    #[test]
    fn screen_share_offline_and_unsupported_devices_do_not_open_local() {
        let mut facts = remote();
        facts.device.as_mut().unwrap().online = false;
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::Offline });
        for platform in [None, Some("linux"), Some("windows"), Some("ios")] {
            facts.device.as_mut().unwrap().platform = platform.map(str::to_owned);
            assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::Unsupported });
        }
    }

    #[test]
    fn screen_share_local_cloud_and_unknown_are_distinct() {
        let mut facts = remote();
        facts.kind = MachineKind::Cloud;
        facts.authenticated_device_id = None;
        facts.device = None;
        assert_eq!(plan(&facts), Plan::CloudDesktop { machine_id: facts.machine_id.clone() });
        facts.kind = MachineKind::Local;
        assert_eq!(plan(&facts), Plan::ShareLocal);
        facts.kind = MachineKind::Unsupported;
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::Unsupported });
        facts.machine_id.clear();
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::NoMachine });
    }

    #[test]
    fn a_peer_chat_never_shares_its_containing_daemons_screen() {
        let mut facts = remote();
        facts.chat = Some(Chat {
            expected_session_id: "chat-a".into(),
            session_id: "chat-a".into(),
            peer: Some("studio".into()),
            host: Some("studio".into()),
            host_kind: Some("ssh".into()),
            registry_host: Some("registry:host-a".into()),
            local_summary_current: true,
        });
        for kind in [MachineKind::Local, MachineKind::Cloud, MachineKind::Remote] {
            facts.kind = kind;
            assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::UnresolvedChatHost });
        }
        let chat = facts.chat.as_mut().unwrap();
        chat.peer = None;
        chat.host = Some("chief:home".into());
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::UnresolvedChatHost });
    }

    #[test]
    fn local_chat_requires_a_current_summary_without_a_remote_host() {
        let mut facts = remote();
        facts.kind = MachineKind::Local;
        facts.chat = Some(Chat {
            expected_session_id: "chat-a".into(),
            session_id: "chat-a".into(),
            peer: None,
            host: None,
            host_kind: Some("local".into()),
            registry_host: None,
            local_summary_current: true,
        });
        assert_eq!(plan(&facts), Plan::ShareLocal);
        facts.chat.as_mut().unwrap().host_kind = None;
        facts.chat.as_mut().unwrap().host = Some("studio".into());
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::UnresolvedChatHost });
        facts.chat.as_mut().unwrap().host_kind = Some("local".into());
        assert_eq!(plan(&facts), Plan::ShareLocal);
        facts.chat.as_mut().unwrap().session_id = "different-chat".into();
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::NoMachine });
    }

    #[test]
    fn a_missing_local_watch_is_not_evidence_that_a_chat_is_local() {
        let mut facts = remote();
        facts.kind = MachineKind::Local;
        facts.chat = Some(Chat {
            expected_session_id: "chat-a".into(),
            session_id: "chat-a".into(),
            peer: None,
            host: Some("install:here".into()),
            host_kind: Some("local".into()),
            registry_host: None,
            local_summary_current: false,
        });
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::UnresolvedChatHost });
        facts.chat.as_mut().unwrap().local_summary_current = true;
        assert_eq!(plan(&facts), Plan::ShareLocal);
    }

    #[test]
    fn a_cloud_chat_must_belong_to_the_daemon_not_just_be_listed_by_it() {
        let mut facts = remote();
        facts.kind = MachineKind::Cloud;
        facts.chat = Some(Chat {
            expected_session_id: "chat-a".into(),
            session_id: "chat-a".into(),
            peer: None,
            host: Some("registry:host-a".into()),
            host_kind: Some("remote".into()),
            registry_host: Some("registry:host-a".into()),
            local_summary_current: false,
        });
        assert_eq!(plan(&facts), Plan::CloudDesktop { machine_id: facts.machine_id.clone() });
        facts.chat.as_mut().unwrap().host = Some("registry:host-b".into());
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::UnresolvedChatHost });
        facts.chat.as_mut().unwrap().registry_host = None;
        assert_eq!(plan(&facts), Plan::Refuse { reason: Refusal::UnresolvedChatHost });
    }
}
