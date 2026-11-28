use super::*;

/// Every down reason's wire word is serde's, and a note without one (an older daemon's)
/// still parses.
#[test]
fn every_down_reason_has_one_wire_word() {
    for fail in DialFail::ALL {
        assert_eq!(serde_json::to_value(fail).unwrap(), fail.as_str());
    }
    let mut note = serde_json::to_value(PeerStateChanged {
        peer: "b".into(),
        state: PeerLinkState::Reconnecting,
        link: MachineLink::Reconnecting,
        carrier: None,
        cause: Some(DownCause::PeerDown),
        since: 1,
        next_retry_at: None,
        reason: None,
        action: None,
        status: None,
        down_reason: Some(DialFail::PathChanged),
        last_seen: None,
        error: None,
        at: 2,
    })
    .unwrap();
    assert_eq!(note["downReason"], "pathChanged");
    note.as_object_mut().unwrap().remove("downReason");
    let older: PeerStateChanged = serde_json::from_value(note.clone()).unwrap();
    assert_eq!(older.down_reason, None);
    // A newer daemon's word this build does not know: the note still parses.
    note["downReason"] = "proxyBlocked".into();
    let newer: PeerStateChanged = serde_json::from_value(note).unwrap();
    assert_eq!(newer.down_reason, None);
    assert_eq!(newer.state, PeerLinkState::Reconnecting);
}

/// Every whole state folds to exactly one older word, and the wire word is serde's.
#[test]
fn every_link_state_has_one_wire_word_and_one_folded_word() {
    for link in MachineLink::ALL {
        let word = serde_json::to_value(link).unwrap();
        assert_eq!(word, serde_json::json!(link.as_str()));
        let back: MachineLink = serde_json::from_value(word).unwrap();
        assert_eq!(back, link);
        let _ = link.folded();
    }
    assert_eq!(MachineLink::Restarting.folded(), PeerLinkState::Reconnecting);
    assert_eq!(MachineLink::AuthFailed.folded(), PeerLinkState::Offline);
    assert_eq!(MachineLink::Idle.folded(), PeerLinkState::Connected);
}

/// Every reason has one wire word (the design's kebab-case words) and its own action.
#[test]
fn every_offline_reason_has_one_wire_word_and_an_action() {
    let mut actions = std::collections::HashSet::new();
    for reason in OfflineReason::ALL {
        let word = serde_json::to_value(reason).unwrap();
        assert_eq!(word, serde_json::json!(reason.as_str()));
        assert_eq!(serde_json::from_value::<OfflineReason>(word).unwrap(), reason);
        assert!(actions.insert(reason.action()), "{reason:?} shares its action");
    }
    assert_eq!(
        serde_json::to_value(OfflineReason::CredentialUnavailable.action()).unwrap(),
        serde_json::json!("reconnect")
    );
}
