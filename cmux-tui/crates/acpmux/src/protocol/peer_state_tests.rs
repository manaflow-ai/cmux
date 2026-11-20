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
