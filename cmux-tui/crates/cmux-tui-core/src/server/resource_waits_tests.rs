//! A wait's deadline turn may come early (the delay thread could not
//! start, so `post_delayed` hands the item to its lane at once): that turn
//! asks for the deadline again, and the turn at the deadline answers.

use super::*;
use crate::server::ClientTransport;
use crate::server::tests::{captured_writer, test_mux};

const TIMEOUT: Duration = Duration::from_millis(150);

/// A `terminal.wait` drain for a pattern that never matches, driven turn
/// by turn here: its pump never starts, so a wake runs no turn of its own.
fn never_matching_wait(
    mux: &Arc<Mux>,
    name: &str,
) -> (WaitDrain, SubscriptionPump, Arc<crate::server::BoundedOutbound>) {
    let surface = mux.new_workspace(Some(name.into()), None).expect("a terminal");
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let id = ResourceRequestId::parse(name).expect("a request id");
    let (canceled, worker_permit) =
        mux.control_clients.install_resource_wait(client, &id).expect("installed");
    let pump = SubscriptionPump::new(mux);
    let drain = WaitDrain {
        armed: None,
        mux: mux.clone(),
        writer,
        id: id.clone(),
        operation: ResourceOperation::TerminalWait,
        canceled: canceled.clone(),
        registration: ResourceWaitWorkerGuard {
            mux: mux.clone(),
            client,
            request_id: id,
            canceled,
        },
        _worker_permit: worker_permit,
        waker: pump.waker(),
        request: None,
        target: Some(WaitTarget::Output {
            surface,
            regex: Regex::new("cmux-pattern-that-never-matches").expect("a regex"),
        }),
        timeout: Some(TIMEOUT),
        deadline: Some(Instant::now() + TIMEOUT),
    };
    (drain, pump, outbound)
}

fn response(outbound: &crate::server::BoundedOutbound) -> Value {
    let message = outbound.try_pop().expect("the wait answered");
    serde_json::from_str(&message).expect("outbound JSON")
}

#[test]
fn an_early_deadline_turn_asks_for_the_deadline_again_and_the_deadline_answers() {
    let mux = test_mux();
    let (mut drain, _pump, outbound) = never_matching_wait(&mux, "early-deadline-wait");
    assert_eq!(drain.turn(), Turn::Idle, "the first turn arms and reads no match");

    // A turn before the deadline with no notify: the deadline turn that
    // came early. It posts the deadline again.
    let delayed = mux.work.delayed_pending();
    assert_eq!(drain.turn(), Turn::Idle, "an early turn does not answer");
    assert_eq!(
        mux.work.delayed_pending(),
        delayed + 1,
        "an early deadline turn asks for the deadline again"
    );
    assert!(outbound.try_pop().is_none(), "nothing answered before the deadline");

    std::thread::sleep(TIMEOUT);
    assert_eq!(drain.turn(), Turn::Done, "the deadline's turn answers");
    let answer = response(&outbound);
    assert_eq!(answer["id"], "early-deadline-wait", "{answer}");
    assert_eq!(answer["result"]["matched"], false, "{answer}");
    mux.shutdown();
}

#[test]
fn an_early_turn_whose_deadline_cannot_be_posted_answers_at_once() {
    let mux = test_mux();
    let (mut drain, _pump, outbound) = never_matching_wait(&mux, "refused-deadline-wait");
    assert_eq!(drain.turn(), Turn::Idle, "the first turn arms and reads no match");
    // Shutdown refuses every delayed item from here on.
    mux.work.shutdown();
    assert_eq!(drain.turn(), Turn::Done, "a refused deadline answers the wait");
    let answer = response(&outbound);
    assert_eq!(answer["id"], "refused-deadline-wait", "{answer}");
    mux.shutdown();
}
