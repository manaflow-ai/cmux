//! THE QoS PATH OF A PERSON'S ACTION (OVERSUBSCRIBED, f7). The person's app sends each action (a split, a new tab, a
//! close, a focus) on its main connection. The threads that read, run and answer those requests ran at the default
//! QoS until the connection carried a key (`input_qos.rs`, TYPING FIX 2), so under a full CPU an action waited for a
//! CPU with every script, CLI and agent request. The connection of the person's app (role main, proved: the one
//! classification `origin_gate::person_app_connection`) now runs its `mux-conn`, `mux-control-dispatch` and
//! `mux-line-out` threads at user-interactive from its hello on, and a terminal create it asks for runs its job on
//! the shared `mux-terminal-work` pool at user-initiated. Every other connection keeps the default.
#![cfg(target_os = "macos")]

use super::input_lane::only_connection_lane;
use super::*;
use crate::server::client_hello::tests::Client;
use cmux_local_auth::frontend_proof::{NONCE_LEN, hello_proof, unhex};

const INSTALL_ID: &str = "inst_p8";
const KEY_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const INTERACTIVE: u32 = libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE as u32;
const INITIATED: u32 = libc::qos_class_t::QOS_CLASS_USER_INITIATED as u32;

/// A connection that proved it is the person's app: the real two-step hello with the install key, over a socket.
fn person_app(mux: &Arc<Mux>, label: &str) -> Client {
    let key = FrontendKey::parse(&format!("cmuxik1 {INSTALL_ID} {KEY_HEX}")).unwrap();
    assert!(install_frontend_key(mux, key));
    let mut client = Client::connect(mux, label);
    let started =
        client.request(json!({"cmd": "client-hello", "role": "main", "install_id": INSTALL_ID}));
    assert_eq!(started["ok"], true, "{started}");
    let nonce = unhex::<NONCE_LEN>(started["data"]["nonce"].as_str().unwrap()).unwrap();
    let key = unhex::<32>(KEY_HEX).unwrap();
    let proved = client.request(json!({
        "cmd": "client-hello",
        "install_id": INSTALL_ID,
        "proof": hello_proof(&key, INSTALL_ID, &nonce),
    }));
    assert_eq!(proved["data"]["verified"], true, "{proved}");
    client
}

/// Splits the first pane of `mux` through `client` and waits for the reply.
fn split(mux: &Arc<Mux>, client: &mut Client) {
    let first = mux.new_workspace(Some("qos".into()), Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let reply = client.request(json!({"cmd": "split", "pane": pane, "dir": "down"}));
    assert_ne!(reply["ok"], json!(false), "{reply}");
}

#[test]
fn the_persons_app_connection_runs_its_requests_at_user_interactive_qos() {
    let mux = test_mux();
    let mut client = person_app(&mux, "qos-app");
    // No key was typed on this connection: the hello alone decides.
    split(&mux, &mut client);
    let lane = only_connection_lane(&mux);
    // Each thread recorded its QoS before it read, ran or wrote the split (its reply came after that).
    for role in ["mux-conn", "mux-control-dispatch", "mux-line-out"] {
        assert_eq!(
            lane.observed_thread_qos(role),
            Some(INTERACTIVE),
            "{role} of the person's app connection does not run at user-interactive QoS"
        );
    }
    assert_eq!(
        lane.observed_thread_qos("mux-terminal-work"),
        Some(INITIATED),
        "the create job of the person's split does not run at user-initiated QoS on the shared pool"
    );
    drop(client);
    mux.shutdown();
}

#[test]
fn a_connection_that_did_not_prove_it_is_the_app_keeps_the_default_qos() {
    let mux = test_mux();
    let mut client = Client::connect(&mux, "qos-cli");
    // Declared, not proved: a script can send this line too.
    let declared = client.request(json!({"cmd": "client-hello", "role": "main"}));
    assert_eq!(declared["ok"], true, "{declared}");
    split(&mux, &mut client);
    let lane = only_connection_lane(&mux);
    for role in ["mux-conn", "mux-control-dispatch", "mux-line-out", "mux-terminal-work"] {
        let observed = lane.observed_thread_qos(role);
        assert!(observed.is_some(), "{role} recorded no QoS");
        assert!(
            observed != Some(INTERACTIVE) && observed != Some(INITIATED),
            "{role} of a connection that is not the person's app runs at a raised QoS ({observed:?})"
        );
    }
    drop(client);
    mux.shutdown();
}

/// The shared pool's thread gets its class back after a person's job: the next job on it (a script's create) does
/// not run at user-initiated.
#[test]
fn person_work_gives_the_thread_its_class_back() {
    std::thread::spawn(|| {
        let before = input_qos::current_thread_qos();
        {
            let _work = input_qos::PersonWork::enter();
            assert_eq!(input_qos::current_thread_qos(), INITIATED);
        }
        let unspecified = libc::qos_class_t::QOS_CLASS_UNSPECIFIED as u32;
        let default = libc::qos_class_t::QOS_CLASS_DEFAULT as u32;
        let expected = if before == unspecified { default } else { before };
        assert_eq!(input_qos::current_thread_qos(), expected, "the thread kept the job's QoS");
    })
    .join()
    .unwrap();
}
