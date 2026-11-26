//! hq#8003 step 4: a daemon that serves agent chats advertises `cloud-mobile-chat-v1`, and hostd's
//! own handshake (`cmux-mobile-host` `services.rs` `cloud_mobile_handshake`) passes on a carrier
//! stream; the connection is then a phone's (phone_carrier.rs).

use super::agent_session_attach_tests::{Client, FakeAcpmux, mux_with, terminal_pane};
use super::*;

fn capabilities(identity: &Value) -> Vec<String> {
    identity["data"]["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|cap| cap.as_str().map(str::to_owned))
        .collect()
}

#[test]
fn hostds_handshake_passes_on_a_carrier_stream_and_the_stream_becomes_a_phones() {
    let fake = FakeAcpmux::start("cloud-mobile-cap");
    let mux = mux_with(&fake, "cloud-mobile-cap");
    let mut client = Client::connect(&mux, "cloud-mobile-cap");
    assert_eq!(client.request(json!({"cmd":"carrier-role","vmk":"owner"}))["ok"], json!(true));
    // hostd's two frames, as it sends them.
    let identity = client.request(json!({"cmd":"identify","id":"cloud-mobile-identify"}));
    assert!(capabilities(&identity).contains(&"cloud-mobile-chat-v1".to_owned()), "{identity}");
    let info = client.request(json!({"cmd":"set-client-info","id":"cloud-mobile-host",
        "kind":"ios","device_kind":"iphone",
        "capabilities":["cloud-mobile-chat-v1","conversation-tabs-v1","agent-session-tabs-v1"]}));
    assert_eq!(info["ok"], json!(true), "{info}");
    // The capability it negotiated holds it to the adapter's commands.
    let (_, pane) = terminal_pane(&mux);
    let refused = client.request(json!({"cmd":"new-tab","pane":pane}));
    assert_eq!(refused["error_code"], json!("remote_denied"), "{refused}");
}

#[test]
fn a_daemon_that_serves_no_agent_chats_does_not_advertise_it() {
    let mux = Mux::new_for_test("cloud-mobile-cap-none", crate::SurfaceOptions::default());
    assert!(
        !identify_capabilities(&mux).contains(&agent_session_attach::CLOUD_MOBILE_CHAT_CAPABILITY)
    );
}
