use super::*;

const KEY: &[u8] = b"0123456789abcdef0123456789abcdef";
const OTHER_KEY: &[u8] = b"fedcba9876543210fedcba9876543210";
const ISSUER: &str = "relay.cloudflare.example";

fn claims(permission: RelayPermission, role: RelayRole) -> RelayTicketClaims {
    RelayTicketClaims {
        version: RelayTicketClaims::VERSION,
        issuer: ISSUER.into(),
        permission,
        role,
        slot: "opaque-slot".into(),
        circuit: None,
        lane: None,
        generation: None,
        issued_at_unix: 100,
        expires_at_unix: 200,
        grant: None,
    }
}

fn wire_claims(issued_at_unix: u64, expires_at_unix: u64) -> RelayTicketClaims {
    serde_json::from_value(serde_json::json!({
        "version": RelayTicketClaims::VERSION,
        "issuer": ISSUER,
        "permission": "connect",
        "role": "client",
        "slot": "opaque-slot",
        "circuit": null,
        "lane": null,
        "generation": null,
        "issued_at_unix": issued_at_unix,
        "expires_at_unix": expires_at_unix,
    }))
    .unwrap()
}

fn intended_signing_payload(claims: &RelayTicketClaims, issued_at_unix: u64) -> Vec<u8> {
    let permission = match claims.permission {
        RelayPermission::Register => "register",
        RelayPermission::Connect => "connect",
        RelayPermission::Join => "join",
    };
    let role = match claims.role {
        RelayRole::Daemon => "daemon",
        RelayRole::Client => "client",
    };
    format!(
        "cmux-relay-ticket-v2\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        claims.version,
        claims.issuer,
        permission,
        role,
        claims.slot,
        claims.circuit.as_ref().map_or("", |value| value.0.as_str()),
        claims.lane.as_ref().map_or("", |value| value.0.as_str()),
        claims.generation.map_or_else(String::new, |value| value.to_string()),
        issued_at_unix,
        claims.expires_at_unix,
    )
    .into_bytes()
}

fn intended_ticket(claims: &RelayTicketClaims, issued_at_unix: u64) -> String {
    let mut wire_claims = serde_json::to_value(claims).unwrap();
    wire_claims["issued_at_unix"] = serde_json::json!(issued_at_unix);
    let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&wire_claims).unwrap());
    let mut mac = Hmac::<Sha256>::new_from_slice(KEY).unwrap();
    mac.update(&intended_signing_payload(claims, issued_at_unix));
    let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    format!("{TICKET_PREFIX}.{payload}.{signature}")
}

fn tamper_issued_at(ticket: &str, issued_at_unix: u64) -> String {
    let parts = ticket.split('.').collect::<Vec<_>>();
    let mut claims: serde_json::Value =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
    claims["issued_at_unix"] = serde_json::json!(issued_at_unix);
    let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
    format!("{}.{}.{}", parts[0], payload, parts[2])
}

fn legacy_v1_ticket() -> String {
    let claims = serde_json::json!({
        "version": 1,
        "issuer": ISSUER,
        "permission": "connect",
        "role": "client",
        "slot": "opaque-slot",
        "circuit": null,
        "lane": null,
        "generation": null,
        "expires_at_unix": 1_100,
    });
    let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
    let mut mac = Hmac::<Sha256>::new_from_slice(KEY).unwrap();
    mac.update(
        b"cmux-relay-ticket-v2\n1\nrelay.cloudflare.example\nconnect\nclient\nopaque-slot\n\n\n\n1100",
    );
    let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    format!("{TICKET_PREFIX}.{payload}.{signature}")
}

#[test]
fn uses_shared_v2_claims_and_canonical_signing_payload() {
    let mut claims = claims(RelayPermission::Connect, RelayRole::Client);
    claims.lane = Some(LaneToken("interactive".into()));
    claims.generation = Some(4);
    let ticket = issue_ticket(&claims, KEY, ISSUER).unwrap();
    assert!(ticket.starts_with("v2."));

    let verified = verify_ticket(
        &ticket,
        KEY,
        ISSUER,
        TicketExpectation {
            permission: RelayPermission::Connect,
            role: RelayRole::Client,
            slot: "opaque-slot",
            circuit: None,
            lane: Some(&LaneToken("interactive".into())),
            generation: Some(4),
            now: 100,
        },
    )
    .unwrap();
    assert_eq!(verified, claims);
}

#[test]
fn provider_ticket_can_be_slot_wide_but_cannot_cross_permission() {
    let claims = claims(RelayPermission::Connect, RelayRole::Client);
    let ticket = issue_ticket(&claims, KEY, ISSUER).unwrap();
    let lane = LaneToken("bulk".into());
    let expectation = TicketExpectation {
        permission: RelayPermission::Connect,
        role: RelayRole::Client,
        slot: "opaque-slot",
        circuit: None,
        lane: Some(&lane),
        generation: Some(9),
        now: 100,
    };
    assert!(verify_ticket(&ticket, KEY, ISSUER, expectation).is_ok());

    let wrong_permission = TicketExpectation {
        permission: RelayPermission::Register,
        role: RelayRole::Daemon,
        ..expectation
    };
    assert_eq!(verify_ticket(&ticket, KEY, ISSUER, wrong_permission), Err(TicketError::Scope));
}

#[test]
fn join_tickets_are_role_and_route_bound() {
    let circuit = CircuitId("circuit".into());
    let lane = LaneToken("lane".into());
    let mut client = claims(RelayPermission::Join, RelayRole::Client);
    client.circuit = Some(circuit.clone());
    client.lane = Some(lane.clone());
    client.generation = Some(7);
    let mut daemon = client.clone();
    daemon.role = RelayRole::Daemon;

    let client_ticket = issue_ticket(&client, KEY, ISSUER).unwrap();
    let daemon_ticket = issue_ticket(&daemon, KEY, ISSUER).unwrap();
    assert_ne!(client_ticket, daemon_ticket);

    let expected = TicketExpectation {
        permission: RelayPermission::Join,
        role: RelayRole::Client,
        slot: "opaque-slot",
        circuit: Some(&circuit),
        lane: Some(&lane),
        generation: Some(7),
        now: 100,
    };
    assert!(verify_ticket(&client_ticket, KEY, ISSUER, expected).is_ok());
    assert_eq!(
        verify_ticket(
            &client_ticket,
            KEY,
            ISSUER,
            TicketExpectation { generation: Some(8), ..expected },
        ),
        Err(TicketError::Scope)
    );
    assert_eq!(
        verify_ticket(
            &client_ticket,
            KEY,
            ISSUER,
            TicketExpectation { role: RelayRole::Daemon, ..expected },
        ),
        Err(TicketError::Scope)
    );
}

#[test]
fn rejects_wrong_key_issuer_and_expiry() {
    let claims = claims(RelayPermission::Connect, RelayRole::Client);
    let ticket = issue_ticket(&claims, KEY, ISSUER).unwrap();
    let expected = TicketExpectation {
        permission: RelayPermission::Connect,
        role: RelayRole::Client,
        slot: "opaque-slot",
        circuit: None,
        lane: None,
        generation: None,
        now: 100,
    };
    assert_eq!(verify_ticket(&ticket, OTHER_KEY, ISSUER, expected), Err(TicketError::Signature));
    assert_eq!(verify_ticket(&ticket, KEY, "other-relay", expected), Err(TicketError::Claims));
    assert_eq!(
        verify_ticket(&ticket, KEY, ISSUER, TicketExpectation { now: 200, ..expected },),
        Err(TicketError::Expired)
    );
}

#[test]
fn rejects_ticket_lifetime_over_five_minutes() {
    let claims = wire_claims(1_000, 1_301);
    let ticket = intended_ticket(&claims, 1_000);
    assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000), Err(TicketError::Claims));
}

#[test]
fn rejects_ticket_issued_more_than_five_minutes_ago() {
    let claims = wire_claims(699, 1_001);
    let ticket = intended_ticket(&claims, 699);
    assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000), Err(TicketError::Claims));
}

#[test]
fn rejects_ticket_issued_beyond_clock_skew() {
    let claims = wire_claims(1_031, 1_100);
    let ticket = intended_ticket(&claims, 1_031);
    assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000), Err(TicketError::Claims));
}

#[test]
fn accepts_lifetime_and_clock_skew_boundaries() {
    for (issued_at_unix, expires_at_unix) in [(1_000, 1_300), (1_030, 1_300)] {
        let claims = wire_claims(issued_at_unix, expires_at_unix);
        let ticket = intended_ticket(&claims, issued_at_unix);
        assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000).unwrap(), claims);
    }
}

#[test]
fn issued_at_is_covered_by_signature() {
    let claims = wire_claims(1_000, 1_100);
    let ticket = intended_ticket(&claims, 1_000);
    assert_eq!(verify_ticket_claims(&ticket, KEY, ISSUER, 1_000).unwrap(), claims);
    assert_eq!(
        verify_ticket_claims(&tamper_issued_at(&ticket, 1_001), KEY, ISSUER, 1_000),
        Err(TicketError::Signature)
    );
}

#[test]
fn rejects_legacy_claims_version_explicitly() {
    let error = verify_ticket_claims(&legacy_v1_ticket(), KEY, ISSUER, 1_000)
        .expect_err("legacy claims must be rejected");
    assert!(error.to_string().contains("version"));
}
