//! Seeded secrets on the wire (cmux_egress::capture) for the cloud wire socket.
//! tests/egress_seeded.json names this test for the `cmux_tui::cli::cloud_wire_watch` gate
//! site. The capture server answers every request `200 {}`, so it mints no ticket; the socket
//! is opened here with a seeded ticket, as `watch` does after the mint. What capture sees is the
//! upgrade request: the ticket and team ride only in `Sec-WebSocket-Protocol`, and the person's
//! access token (the mint's bearer) is not on the upgrade at all.

use cmux_egress::capture;
use serde_json::json;

use super::{connect_and_relay, parse};

const HOST: &str = "cloud-api.cmux.dev";

#[tokio::test]
async fn the_upgrade_carries_the_ticket_and_team_only_in_the_subprotocol() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    capture::install().unwrap();
    let access = "SEEDwireAccessToken-5e09";
    let ticket = "SEEDwireTicket-a7c2";
    let team = "SEEDwireTeam-14bd";
    let input = json!({"api": format!("https://{HOST}"), "access": access, "team": team});
    let wire = parse(input.to_string().as_bytes()).unwrap();
    let last = connect_and_relay(&wire, ticket, &mut |_| {}).await;
    assert!(last.get("error").is_some(), "the capture server never upgrades: {last}");
    let sent = capture::requests_to(HOST);
    assert!(
        sent.iter().any(|r| r.target == "/v1/wire/cloud"),
        "the upgrade reached capture: {sent:?}"
    );
    assert!(capture::leaks(access).is_empty(), "{:?}", capture::leaks(access));
    for secret in [ticket, team] {
        assert_eq!(
            capture::leaks(secret),
            [format!("{HOST} GET /v1/wire/cloud: header sec-websocket-protocol")],
            "{secret} rides only in the subprotocol header"
        );
    }
}
