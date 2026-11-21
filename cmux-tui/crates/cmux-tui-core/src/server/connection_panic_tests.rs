//! A request handler that panics never leaves its connection half alive. A
//! queued request that panics gets an error reply and the connection goes on
//! serving its later requests; a line that panics on the connection's reader
//! (which has no parsed request to answer) closes the connection and its
//! registration goes. Before, the dispatcher thread died with the panic and
//! every later request waited forever while `ping` still answered.

use std::time::Duration;

use serde_json::json;

use super::tests::Client;
use crate::server::connection_scheduler::panic_seam::{self, Site};
use crate::server::*;

const WAIT: Duration = Duration::from_secs(10);

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("panic-{label}"), crate::SurfaceOptions::default())
}

fn only_client(mux: &Mux) -> u64 {
    let ids = mux.control_clients.client_ids();
    assert_eq!(ids.len(), 1, "{ids:?}");
    ids[0]
}

#[test]
fn a_queued_request_that_panics_is_answered_and_the_connection_serves_on() {
    let mux = mux("dispatch");
    let mut client = Client::connect(&mux, "dispatch");
    client.identify();
    panic_seam::arm(&mux, only_client(&mux), Site::Dispatch);

    let failed = client.request_within(json!({"cmd": "list-workspaces"}), WAIT);
    let failed = failed.expect("a queued request whose handler panicked got no reply");
    assert_eq!(failed["ok"], false, "{failed}");
    let next = client.request_within(json!({"cmd": "list-workspaces"}), WAIT);
    let next = next
        .expect("the request after a panicked one got no reply: the connection's dispatcher died");
    assert_eq!(next["ok"], true, "{next}");
}

#[test]
fn a_panic_on_the_connection_reader_closes_the_connection() {
    let mux = mux("reader");
    let mut client = Client::connect(&mux, "reader");
    client.identify();
    panic_seam::arm(&mux, only_client(&mux), Site::Reader);

    let closed = client.send_and_expect_close(json!({"cmd": "list-workspaces"}), WAIT);

    assert!(
        closed,
        "a line whose handler panicked on the reader left its connection open with no reply"
    );
    client.join_server();
    assert!(
        mux.control_clients.client_ids().is_empty(),
        "the connection whose handler panicked kept its registration"
    );
}
