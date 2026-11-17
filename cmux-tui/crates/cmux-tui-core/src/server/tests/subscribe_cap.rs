//! One connection may open only a bounded number of v1 `subscribe` event
//! streams: each one is a `mux-events-out` thread and an event mailbox that
//! lives until the connection closes, so a client that sends `subscribe` in a
//! loop must not grow the daemon's threads without bound.

use super::*;

const CAP: usize = EVENT_SUBSCRIPTIONS_PER_CLIENT_CAPACITY;

fn subscribe(mux: &Arc<Mux>, client: u64, writer: &MessageWriter) -> anyhow::Result<Value> {
    handle_command(mux, client, Command::Subscribe { tree_events: None, surface: None }, writer)
}

#[test]
fn one_connection_cannot_open_unbounded_event_subscriptions() {
    let mux = Mux::new_for_test("subscribe-cap", SurfaceOptions::default());
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let (other_writer, _other_outbound) = captured_writer();
    let other = mux.control_clients.register(ClientTransport::Unix, other_writer.clone());

    for index in 0..CAP {
        if let Err(error) = subscribe(&mux, client, &writer) {
            panic!("subscription {index} of {CAP} was refused: {error}");
        }
    }
    let refused = subscribe(&mux, client, &writer);
    // Another connection keeps its own subscriptions.
    let other_reply = subscribe(&mux, other, &other_writer);
    writer.close();
    other_writer.close();

    let refused = refused.expect_err("a subscription past the cap was accepted");
    assert!(refused.to_string().contains("subscriptions"), "{refused}");
    assert!(other_reply.is_ok(), "{other_reply:?}");
    // Each stream's thread ends with its connection and gives its place back.
    let admission = &mux.control_clients.event_subscription_admission;
    assert!(
        admission.wait_until_idle(Instant::now() + Duration::from_secs(10)),
        "{} subscription permits outlived their closed connections",
        admission.active()
    );
}
