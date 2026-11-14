//! Capture endpoints never admit a page, agent, phone relay or unproved main connection.
use super::*;
use crate::SurfaceOptions;
use crate::server::origin_gate::{set_role_for_test, set_verified_app_for_test};
use crate::server::{BoundedOutbound, MessageWriter, QueuedSink};
use std::sync::Arc;

#[test]
fn capture_dispatch_requires_local_verified_main_app_and_live_peer() {
    for (transport, role, verified, agent) in [
        (ClientTransport::Unix, "main", false, false),
        (ClientTransport::Unix, "page_relay", true, false),
        (ClientTransport::Unix, "main", true, true),
        (ClientTransport::WebSocket, "main", true, false),
        (ClientTransport::Remote, "main", true, false),
    ] {
        let mux = Mux::new_for_test("remote-capture-dispatch", SurfaceOptions::default());
        let writer = MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        });
        let client = mux.control_clients.register(transport, writer);
        set_role_for_test(&mux, client, role);
        set_verified_app_for_test(&mux, client, verified);
        if agent {
            mux.bind_conversation_principal(client, "agent:capture-test".to_string()).unwrap();
        }
        let before = mux.control_clients.remote_host.status();
        for method in ["capture.prepare", "capture.resume", "capture.cleanup"] {
            let error = call(&mux, client, method, json!({})).unwrap_err();
            assert_eq!(error_code(&error).as_deref(), Some(ORIGIN_FORBIDDEN));
            assert_eq!(mux.control_clients.remote_host.status(), before);
        }
    }
    let mux = Mux::new_for_test("remote-capture-known-peer", SurfaceOptions::default());
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    for method in ["capture.prepare", "capture.resume", "capture.cleanup"] {
        let error = call(&mux, client, method, json!({})).unwrap_err();
        assert_eq!(error_code(&error).as_deref(), Some(ORIGIN_FORBIDDEN));
        assert!(error.to_string().contains("known peer process"));
    }
}
