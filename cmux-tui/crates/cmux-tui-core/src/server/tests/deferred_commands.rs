//! Requests whose work waits on another thread answer from
//! that work, never by waiting on their request thread. Each test runs the
//! request on a thread that disallows blocking, in the detector's panic mode.

use super::*;
use crate::mux::mux_work::on_request_thread_in_panic_mode;

#[test]
fn set_cell_pixels_on_a_request_thread_never_waits_for_the_terminal_hosts() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    let request_mux = mux.clone();
    let answered = on_request_thread_in_panic_mode(move || {
        let request = json!({"id": 7, "cmd": "set-cell-pixels", "width_px": 9, "height_px": 18});
        handle_message(&request_mux, client, &request.to_string(), &writer)
    });

    assert!(answered.is_ok(), "set-cell-pixels waited for the fan-out on its request thread");
    let reply = pop_json(&outbound);
    assert_eq!(reply["id"], 7);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["failures"], json!([]));
    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert_eq!(surface.test_cell_pixel_size(), (9, 18));
}

#[test]
fn resource_cell_pixels_set_on_a_request_thread_never_waits_for_the_terminal_hosts() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

    let request_mux = mux.clone();
    let answered = on_request_thread_in_panic_mode(move || {
        let request = resource_request(
            "cell-pixels",
            "client.cell_pixels.set",
            json!({
                "machine": "current",
                "session": "current",
                "client": "current",
                "width_px": 9,
                "height_px": 18,
            }),
            None,
        );
        handle_connection_message(&request_mux, client, &request, &writer, &scheduler)
    });

    assert!(
        answered.is_ok(),
        "client.cell_pixels.set waited for the fan-out on its request thread"
    );
    let reply = pop_json(&outbound);
    assert_eq!(reply["id"], "cell-pixels");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["result"]["width_px"], 9);
    assert_eq!(reply["result"]["failures"], json!({}));
    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert_eq!(surface.test_cell_pixel_size(), (9, 18));
}

/// Two sets apply in the order requested: the later size wins.
#[test]
fn cell_pixel_sets_apply_in_request_order() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (answers, answered) = std::sync::mpsc::channel();
    for size in [(9, 18), (10, 20), (11, 22)] {
        let answers = answers.clone();
        mux.set_cell_pixel_size_then(size.0, size.1, move |update| {
            answers.send((size, update.map(|update| update.failures.is_empty()))).unwrap();
        });
    }
    let order = (0..3)
        .map(|_| answered.recv_timeout(Duration::from_secs(10)).unwrap())
        .map(|(size, converged)| {
            assert!(converged.unwrap());
            size
        })
        .collect::<Vec<_>>();

    assert_eq!(order, vec![(9, 18), (10, 20), (11, 22)]);
    assert_eq!(mux.cell_pixel_size(), (11, 22));
    assert_eq!(surface.test_cell_pixel_size(), (11, 22));
}

#[test]
fn delete_terminal_commands_on_a_request_thread_never_waits_for_the_history_worker() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    let request_mux = mux.clone();
    let answered = on_request_thread_in_panic_mode(move || {
        let request = json!({"id": 8, "cmd": "delete-terminal-commands", "all": true});
        handle_message(&request_mux, client, &request.to_string(), &writer)
    });

    assert!(
        answered.is_ok(),
        "delete-terminal-commands waited for its worker on the request thread"
    );
    let reply = pop_json(&outbound);
    assert_eq!(reply["id"], 8);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["deleted"], 0);
    assert!(!mux.terminal_command_history_enabled());
}

/// A refused delete still answers at once, on the request thread.
#[test]
fn delete_terminal_commands_from_an_untrusted_client_is_refused_at_once() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());

    let request = json!({"id": 9, "cmd": "delete-terminal-commands", "all": true});
    assert!(handle_message(&mux, client, &request.to_string(), &writer));

    let reply = pop_json(&outbound);
    assert_eq!(reply["id"], 9);
    assert_eq!(reply["ok"], false);
    assert!(reply["error"].as_str().unwrap().contains("trusted local connection"), "{reply}");
}
