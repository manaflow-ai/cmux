use super::*;

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
