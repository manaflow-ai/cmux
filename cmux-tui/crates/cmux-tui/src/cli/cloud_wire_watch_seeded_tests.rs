//! Seeded-secret test for `cmux cloud wire-watch` (cmux_egress::capture): the access token rides
//! only in `Authorization` on the ticket mint, and the socket upgrade carries the ticket and the
//! team in its subprotocol and never the token. tests/egress_seeded.json names this test for the
//! `cmux_tui::cli::cloud_wire_watch` gate site.

use cmux_egress::capture;
use serde_json::json;

use super::{mint_ticket, open, parse};

const HOST: &str = "cloud-api.cmux.dev";

#[tokio::test]
async fn the_token_rides_only_on_the_ticket_mint_and_the_ticket_only_in_the_subprotocol() {
    capture::install().unwrap();
    let access = "SEEDwireWatchAccess-5c21";
    let ticket = "SEEDwireWatchTicket-8e07";
    let wire = parse(
        json!({"api": format!("https://{HOST}"), "access": access, "team": "team_seeded", "version": "1.0"})
            .to_string()
            .as_bytes(),
    )
    .unwrap();
    // The capture server answers `200 {}`: no ticket, and no 101 for the upgrade.
    assert!(mint_ticket(&wire).await.is_err());
    assert!(open(&wire, ticket).await.is_err());
    let sent = capture::requests_to(HOST);
    let mint: Vec<_> = sent.iter().filter(|r| r.target == "/v1/wire/ticket").collect();
    let upgrade: Vec<_> = sent.iter().filter(|r| r.target == "/v1/wire/cloud").collect();
    assert_eq!(mint.len(), 1, "the ticket mint reached capture: {sent:?}");
    assert_eq!(upgrade.len(), 1, "the upgrade reached capture: {sent:?}");
    assert_eq!(mint[0].carries(access), ["header authorization"], "{:?}", capture::leaks(access));
    assert!(upgrade[0].carries(access).is_empty(), "{:?}", capture::leaks(access));
    assert_eq!(upgrade[0].carries(ticket), ["header sec-websocket-protocol"]);
    assert!(mint[0].carries(ticket).is_empty());
}
