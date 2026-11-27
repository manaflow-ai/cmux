//! Seeded secrets through the cloud-peer probe, on the wire (cmux_egress::capture): the VM
//! acpmux's dashboard token rides only in `Authorization` and its peer token only in the peer
//! header, both on the upgrade, never in its URL. tests/egress_seeded.json names this test for
//! the `cmux_tui::remote_cli::acpmux_peer` gate site.

use cmux_egress::capture;

use super::{Tokens, probe_status};

const HOST: &str = "vm.cmux.dev";

#[test]
fn the_peer_tokens_ride_only_in_their_headers() {
    capture::install().unwrap();
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let token = "SEEDacpmuxPeerDashboard-19bc";
    let peer = "SEEDacpmuxPeerToken-d703";
    let tokens = Tokens { token: token.to_owned(), peer_token: Some(peer.to_owned()), port: 4440 };
    // The capture server answers the upgrade `200 {}`, so the probe fails after its one request.
    let _ = runtime.block_on(probe_status(&format!("wss://{HOST}/seeded-peer/acp"), &tokens));
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-peer/"))
        .collect();
    assert_eq!(sent.len(), 1, "{sent:?}");
    let places = capture::leaks(token);
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].ends_with(": header authorization"), "{places:?}");
    let header = acpmux::server::peer_auth::HEADER.to_ascii_lowercase();
    let places = capture::leaks(peer);
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].ends_with(&format!(": header {header}")), "{places:?}");
}
