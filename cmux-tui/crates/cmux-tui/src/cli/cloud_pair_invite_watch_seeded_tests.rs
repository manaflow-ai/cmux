//! Seeded secrets on the wire (cmux_egress::capture) for the pair invite watch socket.
//! tests/egress_seeded.json names this test for the `cmux_tui::cli::cloud_pair_invite_watch`
//! gate site. The capture server answers the upgrade with `200 {}`, so what it sees is the
//! upgrade request: the watch secret rides only in `Sec-WebSocket-Protocol`, never the URL.

use cmux_egress::capture;
use serde_json::json;

use super::watch;

const HOST: &str = "cloud-api.cmux.dev";

#[tokio::test]
async fn the_watch_secret_rides_only_in_the_subprotocol_header() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    capture::install().unwrap();
    let secret = "SEEDpairInviteWatchSecret-3c71";
    let invite = "SEEDinvite8d24";
    let input = json!({"api": format!("https://{HOST}"), "invite": invite, "secret": secret});
    let last = watch(input.to_string().as_bytes(), &mut |_| {}).await;
    assert!(last.get("error").is_some(), "the capture server never upgrades: {last}");
    let target = format!("/v1/pair/invite/wait?invite={invite}");
    let sent = capture::requests_to(HOST);
    assert!(sent.iter().any(|r| r.target == target), "the upgrade reached capture: {sent:?}");
    assert_eq!(
        capture::leaks(secret),
        [format!("{HOST} GET {target}: header sec-websocket-protocol")],
        "the secret rides only in the subprotocol header"
    );
}
