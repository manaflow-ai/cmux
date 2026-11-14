use std::sync::Arc;

use crate::SurfaceOptions;
use crate::server::origin_gate::{
    app_process, set_page_for_test, set_peer_key_for_test, set_role_for_test,
    set_verified_app_for_test,
};
use crate::server::{BoundedOutbound, ClientTransport, MessageWriter, QueuedSink};

use super::Mux;

fn connection(mux: &Arc<Mux>, transport: ClientTransport, peer: &str) -> u64 {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    let client = mux.control_clients.register(transport, writer);
    set_peer_key_for_test(mux, client, peer);
    client
}

/// Review F1 on #37377: an agent or script on the socket reads no feed; the app's verified
/// main connection and a page relay of the same process do.
#[test]
fn only_the_apps_own_process_reads_the_feed() {
    let mux = Mux::new_for_test("feed-app-process", SurfaceOptions::default());
    let script = connection(&mux, ClientTransport::Unix, "pid:2");
    assert!(!app_process(&mux, script), "a plain local connection");
    let relay = connection(&mux, ClientTransport::Unix, "pid:1");
    set_role_for_test(&mux, relay, "page_relay");
    assert!(!app_process(&mux, relay), "a page relay with no verified app in its process");
    let app = connection(&mux, ClientTransport::Unix, "pid:1");
    set_role_for_test(&mux, app, "main");
    assert!(!app_process(&mux, app), "a main connection that did not prove itself");
    set_verified_app_for_test(&mux, app, true);
    assert!(app_process(&mux, app), "the verified app");
    assert!(app_process(&mux, relay), "the app's own page relay");
    let other_relay = connection(&mux, ClientTransport::Unix, "pid:2");
    set_role_for_test(&mux, other_relay, "page_relay");
    assert!(!app_process(&mux, other_relay), "a page relay of another process");
    let agent = connection(&mux, ClientTransport::Unix, "pid:1");
    set_role_for_test(&mux, agent, "main");
    set_verified_app_for_test(&mux, agent, true);
    mux.bind_conversation_principal(agent, "agent:test".to_string()).unwrap();
    assert!(!app_process(&mux, agent), "a connection bound to an agent");
    let socket = connection(&mux, ClientTransport::WebSocket, "pid:1");
    set_role_for_test(&mux, socket, "main");
    set_verified_app_for_test(&mux, socket, true);
    assert!(!app_process(&mux, socket), "not the local socket");
}

/// A reply names its sending session in `to`, which the page router passes through (it takes
/// `session` as the host's selector), next to the page's own `session: "current"`.
#[test]
fn a_report_reply_reaches_the_feed_through_the_page_router() {
    let mux = Mux::new_for_test("feed-reply-route", SurfaceOptions::default());
    let app = connection(&mux, ClientTransport::Unix, "pid:1");
    set_role_for_test(&mux, app, "main");
    set_verified_app_for_test(&mux, app, true);
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let request = serde_json::json!({"protocol": "cmux.protocol/2", "type": "request",
            "id": "r1", "operation": "feed.reports.reply", "idempotency_key": "p1",
            "params": {"session": "current", "to": "mbp:claude-api-server", "text": "Go ahead"}});
    let (done, wait) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let handled =
            crate::server::page_router::try_handle(&mux, app, &request.to_string(), &writer);
        let _ = done.send(handled);
    });
    assert_eq!(
        wait.recv_timeout(std::time::Duration::from_secs(10)).expect("answered in time"),
        Some(true)
    );
    let reply = || outbound.try_pop();
    let mut text = reply();
    for _ in 0..200 {
        if text.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
        text = reply();
    }
    let reply: serde_json::Value = serde_json::from_str(&text.expect("a reply")).unwrap();
    // No reply sender is installed in a test daemon: routed, validated, not sent.
    assert!(reply["error"].is_null(), "{reply}");
    assert_eq!(reply["result"]["sent"], false, "{reply}");
}

/// The relay path end to end (page_router::try_handle): the app's own Feed page relay reads
/// the view, a relay of another process gets the refusal, and neither waits.
#[test]
fn the_apps_feed_relay_reads_and_another_relay_is_refused() {
    let mux = Mux::new_for_test("feed-relay-gate", SurfaceOptions::default());
    let app = connection(&mux, ClientTransport::Unix, "pid:1");
    set_role_for_test(&mux, app, "main");
    set_verified_app_for_test(&mux, app, true);
    let read = |client: u64| {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let request = serde_json::json!({"protocol": "cmux.protocol/2", "type": "request",
                "id": "r1", "operation": "feed.view.read", "params": {"layout": "list"}});
        let (done, wait) = std::sync::mpsc::channel();
        let mux = mux.clone();
        std::thread::spawn(move || {
            let handled =
                crate::server::page_router::try_handle(&mux, client, &request.to_string(), &writer);
            let _ = done.send(handled);
        });
        assert_eq!(
            wait.recv_timeout(std::time::Duration::from_secs(10)).expect("answered in time"),
            Some(true)
        );
        let reply: serde_json::Value =
            serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
        reply
    };
    let own = connection(&mux, ClientTransport::Unix, "pid:1");
    set_role_for_test(&mux, own, "page_relay");
    set_page_for_test(&mux, own, "feed");
    let reply = read(own);
    assert!(reply["error"].is_null(), "{reply}");
    let other = connection(&mux, ClientTransport::Unix, "pid:2");
    set_role_for_test(&mux, other, "page_relay");
    set_page_for_test(&mux, other, "feed");
    let reply = read(other);
    assert_eq!(reply["error"]["details"]["reason"], "app_process_only", "{reply}");
}
