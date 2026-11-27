//! Seeded secrets through the relay pool's socket, on the wire (cmux_egress::capture): the
//! relay ticket goes only as the first frame after the upgrade, never in the upgrade's URL or
//! headers. tests/egress_seeded.json names this test for the `cmux_weft::client::relay_pool`
//! gate site.

use cmux_egress::capture;
use tokio::sync::{mpsc, watch};

const HOST: &str = "vm.cmux.dev";

#[test]
fn the_ticket_never_rides_in_the_upgrade() {
    capture::install().unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let ticket = "SEEDweftRelayTicket-5d20";
    let (_ticket_tx, mut ticket_rx) = watch::channel(Some(ticket.to_owned()));
    let (_out_tx, mut out_rx) = mpsc::channel(1);
    let (in_tx, _in_rx) = mpsc::channel(1);
    let url = format!("wss://{HOST}/seeded-relay/v1/relay");
    runtime.block_on(async {
        // The capture server answers the upgrade `200 {}`, so the session ends before any frame.
        let _ = super::session(&url, ticket, &mut ticket_rx, &mut out_rx, &in_tx).await;
    });
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-relay/"))
        .collect();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert!(
        sent[0].headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("upgrade")),
        "{sent:?}"
    );
    let places = capture::leaks(ticket);
    assert!(places.is_empty(), "{places:?}");
}
