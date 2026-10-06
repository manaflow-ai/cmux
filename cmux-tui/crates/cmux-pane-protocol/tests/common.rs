//! Shared helpers for the integration tests.
#![allow(dead_code)]

use std::time::Duration;

use cmux_pane_protocol::envelope::Envelope;
use cmux_pane_protocol::frame::Message;
use cmux_pane_protocol::transport::Transport;

/// The next message, failing the test after 5 s.
pub async fn next_message(transport: &mut Transport) -> Option<Message> {
    tokio::time::timeout(Duration::from_secs(5), transport.recv()).await.expect("timed out")
}

/// The next text envelope; `None` once the connection closed.
pub async fn next_envelope(transport: &mut Transport) -> Option<Envelope> {
    match next_message(transport).await? {
        Message::Text(text) => Some(Envelope::decode(&text).expect("valid envelope")),
        Message::Binary(_) => panic!("unexpected binary message"),
        Message::Close(..) => None,
    }
}

pub async fn send(transport: &Transport, envelope: Envelope) {
    assert!(transport.send(Message::Text(envelope.encode())).await, "send failed");
}
