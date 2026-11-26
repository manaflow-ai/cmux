//! Seeded secrets through the chat-share room client, on the wire (cmux_egress::capture): the
//! share token rides only in `Authorization`, on the room's HTTP calls and on the host socket's
//! upgrade, never in a URL or body. tests/egress_seeded.json names this test for the
//! `cmux_tui_core::server::agent_session_share_room` gate site.

use std::time::Duration;

use cmux_egress::capture;
use serde_json::json;

use super::{call, connect};

const HOST: &str = "share.cmux.dev";

#[test]
fn the_share_token_rides_only_in_authorization() {
    capture::install().unwrap();
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_build_space::init_process(Ok(None));
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let token = "SEEDshareRoomToken-2a8e";
    let origin = format!("https://{HOST}/seeded-room");
    let body = json!({"title": "seeded"});
    runtime.block_on(async {
        let timeout = Duration::from_secs(10);
        let _ = call(
            reqwest::Method::POST,
            &format!("{origin}/v1/chat-shares"),
            token,
            Some(&body),
            timeout,
        )
        .await;
        let _ = call(
            reqwest::Method::GET,
            &format!("{origin}/v1/chat-shares/seeded"),
            token,
            None,
            timeout,
        )
        .await;
        // The capture server answers the upgrade `200 {}`, so the socket never opens.
        let _ = connect(&origin, "seeded", token, timeout).await;
    });
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-room/"))
        .collect();
    assert_eq!(sent.len(), 3, "{sent:?}");
    let places = capture::leaks(token);
    assert_eq!(places.len(), 3, "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
}
