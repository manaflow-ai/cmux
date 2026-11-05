//! #32724: the app's read barrier (`after: "sync"`) and heartbeat ask `identify` on the app's one
//! daemon connection. Requests on a connection run one at a time on its dispatcher, so an
//! `identify` queued behind a slow request (a Cloud start, a terminal create) waited for it, and
//! the app's 2 s deadline failed `cmux cloud start-chat` on a loaded Mac with "timed out: identify
//! (no reply within 2.0 seconds)". `ping` and a plain `identify` read nothing another request on
//! the connection changes, so they are answered before the queue.

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

/// A connection whose dispatcher is busy: it claims to have started and never takes the next
/// request, as when it runs a request that does not end. Requests queued on it stay unanswered.
fn busy_connection(
    mux: &Arc<Mux>,
) -> (u64, MessageWriter, Arc<BoundedOutbound>, Arc<ConnectionSurfaceScheduler>) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    scheduler.state.lock().unwrap().dispatcher_started = true;
    // The slow request, held open for the whole test.
    let slow = json!({"id": "slow", "cmd": "list-workspaces"}).to_string();
    assert!(handle_connection_message(mux, client, &slow, &writer, &scheduler));
    (client, writer, outbound, scheduler)
}

/// Every reply on `outbound` within `limit`, by id.
fn replies(outbound: &BoundedOutbound, want: usize, limit: Duration) -> Vec<Value> {
    let deadline = Instant::now() + limit;
    let mut seen = Vec::new();
    while seen.len() < want && Instant::now() < deadline {
        match outbound.try_pop() {
            Some(line) => seen.push(serde_json::from_str::<Value>(&line).unwrap()),
            None => std::thread::sleep(Duration::from_millis(2)),
        }
    }
    seen
}

fn end(mux: &Arc<Mux>, client: u64, scheduler: &ConnectionSurfaceScheduler) {
    scheduler.close();
    scheduler.finish_dispatcher();
    disconnect_client(mux, client, false);
}

#[test]
fn identify_and_ping_answer_while_a_slow_request_holds_the_connection() {
    let mux = test_mux();
    let (client, writer, outbound, scheduler) = busy_connection(&mux);

    for (id, cmd) in [("identify", "identify"), ("ping", "ping")] {
        let line = json!({"id": id, "cmd": cmd}).to_string();
        assert!(handle_connection_message(&mux, client, &line, &writer, &scheduler));
    }
    let answered = replies(&outbound, 2, Duration::from_secs(10));
    let held = scheduler.state.lock().unwrap().requests.len();
    end(&mux, client, &scheduler);

    let ids: Vec<&Value> = answered.iter().map(|reply| &reply["id"]).collect();
    assert_eq!(
        ids,
        [&json!("identify"), &json!("ping")],
        "queued behind the slow request: {answered:?}"
    );
    assert!(answered.iter().all(|reply| reply["ok"] == true), "{answered:?}");
    assert!(answered[0]["data"]["capabilities"].is_array(), "{answered:?}");
    assert_eq!(held, 1, "the slow request did not stay queued");
}

/// `identify` with `machine_metadata` keeps its place in the queue: the handshake sends it after
/// `client-hello`'s proof, whose answer it is fenced against.
#[test]
fn identify_with_machine_metadata_keeps_its_place_in_the_queue() {
    let mux = test_mux();
    let (client, writer, outbound, scheduler) = busy_connection(&mux);

    let line = json!({"id": "metadata", "cmd": "identify", "machine_metadata": true}).to_string();
    assert!(handle_connection_message(&mux, client, &line, &writer, &scheduler));
    let answered = replies(&outbound, 1, Duration::from_millis(200));
    let held = scheduler.state.lock().unwrap().requests.len();
    end(&mux, client, &scheduler);

    assert!(answered.is_empty(), "{answered:?}");
    assert_eq!(held, 2);
}

/// Under artificial CPU starvation (four spinning threads per core) every `identify` behind the
/// held request is still answered: none waits for the queue, and no deadline here can pass.
#[test]
fn identify_answers_under_cpu_starvation_while_a_slow_request_holds_the_connection() {
    let mux = test_mux();
    let (client, writer, outbound, scheduler) = busy_connection(&mux);
    let stop = Arc::new(AtomicBool::new(false));
    let cores = std::thread::available_parallelism().map_or(4, |count| count.get());
    let spinners: Vec<_> = (0..cores * 4)
        .map(|_| {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let mut spins = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    spins = std::hint::black_box(spins.wrapping_add(1));
                }
            })
        })
        .collect();

    const ASKS: usize = 20;
    for index in 0..ASKS {
        let line = json!({"id": index, "cmd": "identify"}).to_string();
        assert!(handle_connection_message(&mux, client, &line, &writer, &scheduler));
    }
    let answered = replies(&outbound, ASKS, Duration::from_secs(60));
    stop.store(true, Ordering::Relaxed);
    for spinner in spinners {
        spinner.join().unwrap();
    }
    end(&mux, client, &scheduler);

    assert_eq!(answered.len(), ASKS, "{answered:?}");
    assert!(answered.iter().all(|reply| reply["ok"] == true), "{answered:?}");
}
