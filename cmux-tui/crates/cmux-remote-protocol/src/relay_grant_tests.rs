use super::*;

fn connect_claims(grant: Option<&str>) -> RelayTicketClaims {
    RelayTicketClaims {
        version: RelayTicketClaims::VERSION,
        issuer: "issuer".into(),
        permission: RelayPermission::Connect,
        role: RelayRole::Client,
        slot: "slot-a".into(),
        circuit: None,
        lane: None,
        generation: None,
        issued_at_unix: 1_000,
        expires_at_unix: 1_300,
        grant: grant.map(str::to_owned),
    }
}

#[test]
fn a_ticket_without_a_grant_signs_to_the_v2_bytes() {
    assert_eq!(
        connect_claims(None).signing_payload(),
        b"cmux-relay-ticket-v2\n2\nissuer\nconnect\nclient\nslot-a\n\n\n\n1000\n1300".to_vec()
    );
    let wire = serde_json::to_value(connect_claims(None)).unwrap();
    assert!(wire.get("grant").is_none());
}

#[test]
fn a_ticket_naming_a_grant_signs_it() {
    let named = connect_claims(Some("digest-a"));
    assert!(named.signing_payload().ends_with(b"\n1300\ngrant:digest-a"));
    assert_ne!(named.signing_payload(), connect_claims(Some("digest-b")).signing_payload());
    let back: RelayTicketClaims =
        serde_json::from_value(serde_json::to_value(&named).unwrap()).unwrap();
    assert_eq!(back, named);
}

#[test]
fn a_connect_carries_its_grant_only_when_set_and_never_prints_it() {
    let connect = |grant: Option<&str>| RelayControl::Connect {
        protocol: 1,
        slot: "slot-a".into(),
        ticket: "ticket".into(),
        lane: LaneToken("lane".into()),
        generation: 1,
        accepts_parked: false,
        grant: grant.map(str::to_owned),
        inline: false,
    };
    let bare = serde_json::to_value(connect(None)).unwrap();
    assert!(bare.get("grant").is_none());
    let legacy: RelayControl = serde_json::from_value(bare).unwrap();
    assert_eq!(legacy, connect(None));
    let with = connect(Some("header.claims.signature"));
    let wire = serde_json::to_value(&with).unwrap();
    assert_eq!(wire["grant"], "header.claims.signature");
    assert!(!format!("{with:?}").contains("header.claims.signature"));
}
