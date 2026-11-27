use super::*;

#[test]
fn ik_needs_a_pinned_key_the_peers_offer_and_no_bearer_secret() {
    let resume = LinkFacts { pinned_peer: true, peer_takes_ik: true, ..LinkFacts::default() };
    assert_eq!(choose(resume), Pattern::Ik);
    assert_eq!(choose(LinkFacts { pinned_peer: false, ..resume }), Pattern::Xx);
    assert_eq!(choose(LinkFacts { peer_takes_ik: false, ..resume }), Pattern::Xx);
    assert_eq!(choose(LinkFacts { carries_bearer_secret: true, ..resume }), Pattern::Xx);
    assert_eq!(choose(LinkFacts { invitation: true, ..resume }), Pattern::XxPsk3);
    assert_eq!(choose(LinkFacts::default()), Pattern::Xx);
}

#[test]
fn lanes_open_at_once_with_a_pinned_key_unless_invited() {
    let resume = LinkFacts { pinned_peer: true, peer_takes_ik: true, ..LinkFacts::default() };
    assert!(open_lanes_at_once(resume));
    // A grant keeps each link on XX, but the key is known: still at once.
    assert!(open_lanes_at_once(LinkFacts { carries_bearer_secret: true, ..resume }));
    assert!(!open_lanes_at_once(LinkFacts { pinned_peer: false, ..resume }));
    // A first connect that pins the key but has no IK offer yet: XX on every link, at once.
    assert!(open_lanes_at_once(LinkFacts { peer_takes_ik: false, ..resume }));
    assert!(!open_lanes_at_once(LinkFacts { invitation: true, ..resume }));
    assert!(!open_lanes_at_once(LinkFacts::default()));
}

#[test]
fn early_data_rides_only_an_ik_reconnect_with_no_bearer_secret() {
    let resume = LinkFacts { pinned_peer: true, peer_takes_ik: true, ..LinkFacts::default() };
    assert!(may_send_early(resume, 1, true));
    assert!(may_send_early(resume, 9, true));
    // A first meeting, a peer that never said it takes it, and an XX link: never.
    assert!(!may_send_early(resume, 0, true));
    assert!(!may_send_early(resume, 1, false));
    assert!(!may_send_early(LinkFacts { peer_takes_ik: false, ..resume }, 1, true));
    assert!(!may_send_early(LinkFacts { pinned_peer: false, ..resume }, 1, true));
    // A grant or an invitation: never (both also keep the link off IK).
    assert!(!may_send_early(LinkFacts { carries_bearer_secret: true, ..resume }, 1, true));
    assert!(!may_send_early(LinkFacts { invitation: true, ..resume }, 1, true));
}

#[test]
fn tickets_read_across_the_early_data_capability_in_both_directions() {
    // A ticket from a build before early data: no `early_data`, so the client sends none.
    let key = "ef".repeat(32);
    let old = format!(r#"{{"v":1,"peer_static":"{key}","caps":{{"ik":true}},"issued_unix_ms":1}}"#);
    let read = ResumeTicket::decode(old.as_bytes()).unwrap();
    assert!(read.capabilities.ik && !read.capabilities.early_data);
    // A new ticket read by a build before early data: `Capabilities` as it was then.
    #[derive(Deserialize)]
    struct OldCapabilities {
        #[serde(default)]
        ik: bool,
    }
    #[derive(Deserialize)]
    struct OldTicket {
        v: u8,
        caps: OldCapabilities,
    }
    let new = ResumeTicket {
        peer_static: [0xef; 32],
        capabilities: Capabilities { ik: true, early_data: true, ..Capabilities::default() },
        issued_unix_ms: 1,
        dormant_hold_ms: None,
        dormant_since_unix_ms: None,
    };
    let bytes = new.encode();
    assert!(std::str::from_utf8(&bytes).unwrap().contains(r#""early_data":true"#));
    let old: OldTicket = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(old.v, TICKET_VERSION);
    assert!(old.caps.ik);
    assert_eq!(ResumeTicket::decode(&bytes), Some(new));
}

#[test]
fn ik_saves_a_round_trip_to_the_welcome() {
    assert_eq!(Pattern::Xx.round_trips_to_welcome(), 2);
    assert_eq!(Pattern::Ik.round_trips_to_welcome(), 1);
}

#[test]
fn a_ticket_round_trips_and_names_its_version() {
    let ticket = ResumeTicket {
        peer_static: [0xab; 32],
        capabilities: Capabilities { ik: true, ..Capabilities::default() },
        issued_unix_ms: 1_795_000_000_000,
        dormant_hold_ms: None,
        dormant_since_unix_ms: None,
    };
    let bytes = ticket.encode();
    let text = std::str::from_utf8(&bytes).unwrap();
    assert!(text.starts_with(r#"{"v":1,"peer_static":"abab"#), "{text}");
    assert!(text.contains(r#""caps":{"ik":true}"#), "{text}");
    assert_eq!(ResumeTicket::decode(&bytes), Some(ticket.clone()));
    assert!(ticket.takes_ik_for(&[0xab; 32]));
    assert!(!ticket.takes_ik_for(&[0xac; 32]));
}

#[test]
fn a_newer_or_broken_ticket_reads_as_none_and_unknown_fields_are_ignored() {
    let key = "cd".repeat(32);
    let newer = format!(r#"{{"v":2,"peer_static":"{key}","issued_unix_ms":1}}"#);
    assert_eq!(ResumeTicket::decode(newer.as_bytes()), None);
    assert_eq!(ResumeTicket::decode(b"not json"), None);
    let short = r#"{"v":1,"peer_static":"cdcd","issued_unix_ms":1}"#;
    assert_eq!(ResumeTicket::decode(short.as_bytes()), None);
    // A v1 ticket from a newer writer that added fields, and one from a writer with no caps.
    let extra = format!(
        r#"{{"v":1,"peer_static":"{key}","caps":{{"ik":true,"later":7}},"issued_unix_ms":1,"x":0}}"#
    );
    assert!(ResumeTicket::decode(extra.as_bytes()).unwrap().capabilities.ik);
    let bare = format!(r#"{{"v":1,"peer_static":"{key}","issued_unix_ms":1}}"#);
    assert!(!ResumeTicket::decode(bare.as_bytes()).unwrap().capabilities.ik);
}

#[test]
fn a_dormant_hold_round_trips_and_lapses() {
    let ticket = ResumeTicket {
        peer_static: [0x11; 32],
        capabilities: Capabilities { ik: true, wg_resume: true, ..Capabilities::default() },
        issued_unix_ms: 1_000,
        dormant_hold_ms: Some(150_000),
        dormant_since_unix_ms: Some(2_000),
    };
    let bytes = ticket.encode();
    assert_eq!(ResumeTicket::decode(&bytes), Some(ticket.clone()));
    assert!(ticket.dormant_resumable(2_000 + 149_999));
    assert!(!ticket.dormant_resumable(2_000 + 150_000));
    // No hold (an older writer, or a peer without it): the full dial.
    let plain = ResumeTicket { dormant_hold_ms: None, ..ticket };
    assert!(!plain.dormant_resumable(2_001));
    let text = String::from_utf8(plain.encode()).unwrap();
    assert!(!text.contains("dormant_hold_ms"), "{text}");
    assert!(
        !ResumeTicket { capabilities: Capabilities::default(), ..ticket }.dormant_resumable(2_001)
    );
}
