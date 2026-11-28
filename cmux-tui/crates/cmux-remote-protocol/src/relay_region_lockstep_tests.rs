use super::*;

#[derive(Debug, PartialEq, Deserialize)]
struct OldClaims {
    version: u8,
    issuer: String,
    permission: RelayPermission,
    role: RelayRole,
    slot: String,
    circuit: Option<CircuitId>,
    lane: Option<LaneToken>,
    generation: Option<u64>,
    #[serde(default)]
    issued_at_unix: u64,
    expires_at_unix: u64,
    #[serde(default)]
    grant: Option<String>,
}

fn join(region: Option<&str>) -> RelayTicketClaims {
    RelayTicketClaims {
        version: RelayTicketClaims::VERSION,
        issuer: "issuer".into(),
        permission: RelayPermission::Join,
        role: RelayRole::Client,
        slot: "slot-a".into(),
        circuit: Some(CircuitId("ab".repeat(32))),
        lane: Some(LaneToken("lane".into())),
        generation: Some(3),
        issued_at_unix: 1_000,
        expires_at_unix: 1_300,
        grant: None,
        region: region.map(str::to_owned),
    }
}

#[test]
fn an_old_ticket_decodes_on_new_with_no_region_and_the_same_signing_bytes() {
    let old_wire = serde_json::json!({
        "version": 2, "issuer": "issuer", "permission": "join", "role": "client",
        "slot": "slot-a", "circuit": "ab".repeat(32), "lane": "lane", "generation": 3,
        "issued_at_unix": 1000, "expires_at_unix": 1300,
    });
    let new: RelayTicketClaims = serde_json::from_value(old_wire).unwrap();
    assert_eq!(new, join(None));
    assert_eq!(
        new.signing_payload(),
        format!(
            "cmux-relay-ticket-v2\n2\nissuer\njoin\nclient\nslot-a\n{}\nlane\n3\n1000\n1300",
            "ab".repeat(32)
        )
        .into_bytes()
    );
    assert!(serde_json::to_value(&new).unwrap().get("region").is_none());
}

#[test]
fn a_new_ticket_with_a_region_decodes_on_old_and_is_signed_by_the_region() {
    let with = join(Some("weur"));
    let wire = serde_json::to_value(&with).unwrap();
    assert_eq!(wire["region"], "weur");
    // Old claims decoding ignores the extra key: no decoder in this crate refuses unknown fields.
    let old: OldClaims = serde_json::from_value(wire).unwrap();
    assert_eq!(old.slot, "slot-a");
    assert_eq!(old.generation, Some(3));
    // The region is signed: it cannot be changed or dropped without breaking the signature,
    // and an old verifier (which signs without it) rejects it rather than trust it.
    assert!(with.signing_payload().ends_with(b"\n1300\nregion:weur"));
    assert_ne!(with.signing_payload(), join(None).signing_payload());
    assert_ne!(with.signing_payload(), join(Some("enam")).signing_payload());
}

#[test]
fn grant_and_region_sign_in_a_fixed_order() {
    let mut both = join(Some("apac"));
    both.grant = Some("digest".into());
    assert!(both.signing_payload().ends_with(b"\n1300\ngrant:digest\nregion:apac"));
}
