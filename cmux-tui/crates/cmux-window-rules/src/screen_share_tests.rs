use super::*;

const DEVICE: &str = "550e8400-e29b-41d4-a716-446655440000";

fn remote() -> Facts {
    Facts {
        machine_id: "machine:remote".into(),
        kind: MachineKind::Remote,
        authenticated_device_id: Some(DEVICE.into()),
        device: Some(Device { id: DEVICE.into(), platform: Some("macos".into()), online: true }),
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
